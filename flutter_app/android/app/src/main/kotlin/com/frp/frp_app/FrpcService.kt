package com.frp.frp_app

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStreamReader
import java.io.Reader
import java.net.InetAddress
import java.net.Inet6Address
import java.util.ArrayDeque
import java.util.Arrays
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal enum class StartRequestDisposition {
    START_PENDING,
    RESTORE_COMMITTED,
    REJECT,
}

/**
 * frpc 前台服务：
 * - 常驻通知 + 前台服务提升进程优先级，保证后台驻留（frpc 连接不断）
 * - 管理 frpc 进程 / 日志解析 / 状态推送（通过 MainActivity 挂载的 MethodChannel）
 * - 记录运行状态，开机自启 / 进程重建时自动恢复
 */
@SuppressLint("ApplySharedPref", "UseKtx")
class FrpcService : Service() {
    companion object {
        private const val CHANNEL_ID = "frpc_service"
        private const val NOTIF_ID = 1001
        private const val PREFS = "frp_state"
        private const val KEY_WAS_RUNNING = "was_running"
        private const val KEY_LAST_CONFIG_PAYLOAD = "last_config_payload"
        private const val KEY_PENDING_START_ID = "pending_start_id"
        private const val ACTION_START = "com.frp.frp_app.action.START"
        private const val ACTION_STOP = "com.frp.frp_app.action.STOP"
        private const val ACTION_RESTORE = "com.frp.frp_app.action.RESTORE"
        private const val EXTRA_CONFIG_CONTENT = "config_content"
        private const val EXTRA_START_ID = "start_id"
        private const val RUNTIME_CONFIG_NAME = "frpc-runtime.toml"
        private const val MAX_CONFIG_BYTES = 512 * 1024
        private const val MAX_LOG_LINE_CHARS = 4096
        private const val MAX_APP_STATUS_ENTRIES = 1024
        private const val TRUNCATED_LOG_SUFFIX = " … [truncated]"
        private const val DEFAULT_STUN_PORT = 3478
        private val runIntentLock = Any()
        private val stunEndpointPattern = Regex(
            """(?m)^(\s*natHoleStunServer\s*=\s*)\"([^\"\r\n]+)\"(\s*(?:#.*)?)$""",
        )
        private val ansiEscapePattern = Regex("\u001B\\[[;\\d]*m")

        private data class RunIntentState(
            val desired: Boolean,
            val requestId: String?,
            val encryptedPayload: String?,
        )

        internal fun classifyStartRequest(
            desired: Boolean,
            pendingRequestId: String?,
            encryptedPayload: String?,
            deliveredRequestId: String?,
        ): StartRequestDisposition = when {
            !deliveredRequestId.isNullOrEmpty() &&
                desired && pendingRequestId == deliveredRequestId ->
                StartRequestDisposition.START_PENDING
            desired && pendingRequestId == null && !encryptedPayload.isNullOrEmpty() ->
                StartRequestDisposition.RESTORE_COMMITTED
            else -> StartRequestDisposition.REJECT
        }

        internal data class StunEndpoint(val host: String, val port: Int) {
            fun authority(): String =
                if (':' in host) "[$host]:$port" else "$host:$port"
        }

        internal fun parseStunEndpoint(value: String): StunEndpoint? {
            val endpoint = value.trim()
            if (endpoint.isEmpty() || endpoint.any { it.isWhitespace() }) return null

            val host: String
            val portText: String?
            if (endpoint.startsWith('[')) {
                val closingBracket = endpoint.indexOf(']')
                if (closingBracket <= 1) return null
                host = endpoint.substring(1, closingBracket)
                val suffix = endpoint.substring(closingBracket + 1)
                if (suffix.isEmpty()) {
                    portText = null
                } else {
                    if (!suffix.startsWith(':') || suffix.length == 1) return null
                    portText = suffix.substring(1)
                }
            } else {
                if ('[' in endpoint || ']' in endpoint) return null
                when (endpoint.count { it == ':' }) {
                    0 -> {
                        host = endpoint
                        portText = null
                    }
                    1 -> {
                        host = endpoint.substringBeforeLast(':')
                        portText = endpoint.substringAfterLast(':')
                    }
                    else -> {
                        // An unbracketed IPv6 literal has no unambiguous port.
                        host = endpoint
                        portText = null
                    }
                }
            }
            if (host.isBlank()) return null
            if (':' in host) {
                val address = try {
                    InetAddress.getByName(host)
                } catch (_: Exception) {
                    return null
                }
                if (address !is Inet6Address) return null
            }
            val port = portText?.toIntOrNull() ?: DEFAULT_STUN_PORT
            if (port !in 1..65535 || (portText != null && portText != port.toString())) {
                return null
            }
            return StunEndpoint(host, port)
        }

        internal fun shouldStopAfterFallback(
            observedStartId: Int,
            currentStartId: Int,
            wasRunning: Boolean,
            pendingStartId: String?,
        ): Boolean =
            observedStartId == currentStartId && !wasRunning && pendingStartId.isNullOrEmpty()

        private fun patchStunEndpoints(config: String): String =
            patchFirstStunEndpoint(config) { host ->
                try {
                    InetAddress.getByName(host).hostAddress ?: host
                } catch (_: Exception) {
                    host
                }
            }

        internal fun patchFirstStunEndpoint(
            config: String,
            resolveHost: (String) -> String,
        ): String {
            // natHoleStunServer is a global FRP option. Resolve at most its
            // first occurrence so malformed imported TOML cannot queue an
            // unbounded number of blocking DNS lookups on processExecutor.
            val match = stunEndpointPattern.find(config) ?: return config
            val endpoint = parseStunEndpoint(match.groupValues[2])
                ?: return config
            val resolved = resolveHost(endpoint.host)
            val authority = StunEndpoint(resolved, endpoint.port).authority()
            val replacement = "${match.groupValues[1]}\"$authority\"${match.groupValues[3]}"
            return config.replaceRange(match.range, replacement)
        }

        internal fun redactLogLine(line: String): String {
            val key = """authorization|token|secret(?:[\s_-]*key)?|client[\s_-]*secret|password|passwd|credential|api[\s_-]*key|private[\s_-]*key|access[\s_-]*key|cookie|sk"""
            val field = Regex(
                """(?i)(?<![\w-])(?:(['\"]?)($key)\1)(?![\w-])\s*([=:])\s*(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|(?:bearer\s+)?[^\r\n,;}\]]+?(?=\s+(?:['\"]?(?:$key)['\"]?)(?![\w-])\s*[=:]|[,;}\]]|$))""",
            )
            return line.replace(field) { match ->
                val quote = match.groupValues[1]
                val name = match.groupValues[2]
                val separator = match.groupValues[3]
                if (quote.isNotEmpty()) {
                    "$quote$name$quote$separator$quote***$quote"
                } else {
                    "$name=***"
                }
            }
        }

        internal fun sanitizeLogLine(raw: String): String {
            val bounded = if (raw.length <= MAX_LOG_LINE_CHARS) {
                raw
            } else {
                raw.take(MAX_LOG_LINE_CHARS - TRUNCATED_LOG_SUFFIX.length) +
                    TRUNCATED_LOG_SUFFIX
            }
            return redactLogLine(bounded.replace(ansiEscapePattern, ""))
        }

        internal fun readBoundedLogLines(reader: Reader, onLine: (String) -> Unit) {
            val buffer = CharArray(1024)
            val line = StringBuilder(MAX_LOG_LINE_CHARS)
            var truncated = false
            var afterCarriageReturn = false

            fun emitLine() {
                if (truncated) {
                    line.setLength(MAX_LOG_LINE_CHARS - TRUNCATED_LOG_SUFFIX.length)
                    line.append(TRUNCATED_LOG_SUFFIX)
                }
                onLine(line.toString())
                line.setLength(0)
                truncated = false
            }

            while (true) {
                val count = reader.read(buffer)
                if (count < 0) break
                for (index in 0 until count) {
                    val character = buffer[index]
                    if (afterCarriageReturn) {
                        afterCarriageReturn = false
                        if (character == '\n') continue
                    }
                    when (character) {
                        '\r' -> {
                            emitLine()
                            afterCarriageReturn = true
                        }
                        '\n' -> emitLine()
                        else -> {
                            if (line.length < MAX_LOG_LINE_CHARS) line.append(character)
                            else truncated = true
                        }
                    }
                }
            }
            if (line.isNotEmpty() || truncated) emitLine()
        }

        internal fun recordBoundedAppStatus(
            statuses: MutableMap<String, String>,
            name: String,
            type: String,
            maxEntries: Int = MAX_APP_STATUS_ENTRIES,
        ): Boolean = synchronized(statuses) {
            require(maxEntries > 0)
            if (!statuses.containsKey(name) && statuses.size >= maxEntries) {
                return@synchronized false
            }
            statuses[name] = type
            true
        }

        @Volatile
        var instance: FrpcService? = null

        /**
         * 静态状态推送通道：由 MainActivity 挂载。
         * 与服务的启动时序解耦——服务启动前/后设置都有效，避免推送丢失。
         */
        @Volatile
        var channel: MethodChannel? = null

        @Volatile
        internal var beforeStartWorkerForTest: (() -> Unit)? = null

        @Volatile
        internal var beforeStopWorkerForTest: (() -> Unit)? = null

        /** 提交用户启动请求，实际进程启动在 onStartCommand 中串行执行。 */
        fun start(context: Context, configContent: String?): Boolean =
            startWithCommit(context, configContent) { editor -> editor.commit() }

        internal fun startWithCommitForTest(
            context: Context,
            configContent: String?,
            commitAttempt: (SharedPreferences.Editor) -> Boolean,
        ): Boolean = startWithCommit(context, configContent, commitAttempt)

        private fun startWithCommit(
            context: Context,
            configContent: String?,
            commitAttempt: (SharedPreferences.Editor) -> Boolean,
        ): Boolean {
            if (configContent.isNullOrBlank() ||
                !utf8Fits(configContent, MAX_CONFIG_BYTES)
            ) return false
            val startId = UUID.randomUUID().toString()
            val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
            val startWrite = synchronized(runIntentLock) {
                val previous = RunIntentState(
                    desired = prefs.getBoolean(KEY_WAS_RUNNING, false),
                    requestId = prefs.getString(KEY_PENDING_START_ID, null),
                    encryptedPayload = prefs.getString(KEY_LAST_CONFIG_PAYLOAD, null),
                )
                val recorded = try {
                    commitAttempt(
                        prefs.edit()
                            .putBoolean(KEY_WAS_RUNNING, true)
                            .putString(KEY_PENDING_START_ID, startId),
                    )
                } catch (error: Exception) {
                    Log.e("FrpEngine", "unable to persist pending run intent", error)
                    false
                }
                if (!recorded) restoreRunIntent(prefs, previous)
                previous to recorded
            }
            if (!startWrite.second) return false
            return try {
                startServiceIntent(
                    context,
                    Intent(context, FrpcService::class.java)
                        .setAction(ACTION_START)
                        .putExtra(EXTRA_CONFIG_CONTENT, configContent)
                        .putExtra(EXTRA_START_ID, startId)
                )
                true
            } catch (e: Exception) {
                synchronized(runIntentLock) {
                    if (prefs.getString(KEY_PENDING_START_ID, null) == startId) {
                        restoreRunIntent(prefs, startWrite.first)
                    }
                }
                Log.e("FrpEngine", "unable to schedule frpc service", e)
                false
            }
        }

        private fun requestRestore(context: Context) {
            startServiceIntent(
                context,
                Intent(context, FrpcService::class.java).setAction(ACTION_RESTORE)
            )
        }

        private fun startServiceIntent(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
        }

        /** 停止用户运行意图，即使 Service 还没有完成创建也能生效。 */
        fun stop(context: Context): Boolean = stopWithCommit(context) { editor ->
            editor.commit()
        }

        internal fun stopWithCommitForTest(
            context: Context,
            commitAttempt: (SharedPreferences.Editor) -> Boolean,
        ): Boolean = stopWithCommit(context, commitAttempt)

        private fun stopWithCommit(
            context: Context,
            commitAttempt: (SharedPreferences.Editor) -> Boolean,
        ): Boolean {
            // Revoke the persisted and queued intent before submitting process
            // cleanup, so a not-yet-delivered START cannot win this stop.
            if (!clearRunIntent(context, commitAttempt)) return false
            val svc = instance
            if (svc != null) {
                try {
                    startServiceIntent(
                        context,
                        Intent(context, FrpcService::class.java).setAction(ACTION_STOP),
                    )
                } catch (error: Exception) {
                    Log.e("FrpEngine", "unable to schedule frpc stop", error)
                    svc.stopProcessWithoutStoppingService()
                }
            } else {
                deleteRuntimeConfig(context)
                // Do not call stopService() while a startForegroundService()
                // request may still be queued. The queued service must enter
                // onStartCommand(), call startForeground(), observe that its
                // request ID was revoked above, and then stop itself cleanly.
            }
            return true
        }

        internal fun runtimeConfigFile(context: Context): File =
            File(context.noBackupFilesDir, RUNTIME_CONFIG_NAME)

        private fun deleteRuntimeConfig(context: Context) {
            runtimeConfigFile(context).delete()
            File(context.noBackupFilesDir, "$RUNTIME_CONFIG_NAME.pending").delete()
        }

        private fun utf8Fits(value: String, maxBytes: Int): Boolean {
            if (value.length > maxBytes) return false
            val bytes = value.toByteArray(Charsets.UTF_8)
            return try {
                bytes.size <= maxBytes
            } finally {
                Arrays.fill(bytes, 0)
            }
        }

        /**
         * 健康检查后按需启动：
         * - 服务不存在：仅当上次连接在运行（was_running）时才冷启动恢复
         * - 服务存在但 frpc 进程异常退出：自动重启 frpc
         * - 服务与 frpc 均正常：不做任何事（避免回到 App 时重启 frpc 导致断连）
         */
        fun ensureRunning(context: Context) {
            val svc = instance
            if (svc == null) {
                val state = readRunIntent(context)
                if (state.desired && state.requestId == null) {
                    if (state.encryptedPayload.isNullOrEmpty()) {
                        abandonRunIntentIfCurrent(context, requestId = null)
                        deleteRuntimeConfig(context)
                    } else {
                        try {
                            requestRestore(context)
                        } catch (e: Exception) {
                            Log.e("FrpEngine", "unable to restore frpc service", e)
                        }
                    }
                }
            } else {
                svc.restoreIfNeeded()
            }
        }

        /** User/native run intent survives Activity and Dart-isolate recreation. */
        fun isRunRequested(context: Context): Boolean = readRunIntent(context).desired

        private fun readRunIntent(context: Context): RunIntentState =
            synchronized(runIntentLock) {
                val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
                RunIntentState(
                    desired = prefs.getBoolean(KEY_WAS_RUNNING, false),
                    requestId = prefs.getString(KEY_PENDING_START_ID, null),
                    encryptedPayload = prefs.getString(KEY_LAST_CONFIG_PAYLOAD, null),
                )
            }

        private fun isCurrentRunIntent(context: Context, requestId: String?): Boolean {
            val state = readRunIntent(context)
            return state.desired && if (requestId == null) {
                state.requestId == null
            } else {
                state.requestId == requestId
            }
        }

        private fun clearRunIntent(
            context: Context,
            commitAttempt: (SharedPreferences.Editor) -> Boolean = { editor -> editor.commit() },
        ): Boolean =
            synchronized(runIntentLock) {
                val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
                val previous = RunIntentState(
                    desired = prefs.getBoolean(KEY_WAS_RUNNING, false),
                    requestId = prefs.getString(KEY_PENDING_START_ID, null),
                    encryptedPayload = prefs.getString(KEY_LAST_CONFIG_PAYLOAD, null),
                )
                val cleared = try {
                    commitAttempt(
                        prefs.edit()
                            .putBoolean(KEY_WAS_RUNNING, false)
                            .remove(KEY_LAST_CONFIG_PAYLOAD)
                            .remove(KEY_PENDING_START_ID),
                    )
                } catch (error: Exception) {
                    Log.e("FrpEngine", "unable to persist stopped run intent", error)
                    false
                }
                if (cleared) return@synchronized true

                // SharedPreferences applies an Editor to its in-process map
                // before disk I/O. Restore the complete previous intent when
                // commit reports failure so the caller can leave frpc running
                // instead of exposing contradictory native and Dart states.
                restoreRunIntent(prefs, previous)
                false
            }

        private fun restoreRunIntent(prefs: SharedPreferences, previous: RunIntentState) {
            try {
                val restored = prefs.edit()
                    .putBoolean(KEY_WAS_RUNNING, previous.desired)
                    .apply {
                        if (previous.requestId == null) remove(KEY_PENDING_START_ID)
                        else putString(KEY_PENDING_START_ID, previous.requestId)
                        if (previous.encryptedPayload == null) {
                            remove(KEY_LAST_CONFIG_PAYLOAD)
                        } else {
                            putString(KEY_LAST_CONFIG_PAYLOAD, previous.encryptedPayload)
                        }
                    }
                    .commit()
                if (!restored) {
                    Log.e("FrpEngine", "unable to persist restored run intent")
                }
            } catch (error: Exception) {
                Log.e("FrpEngine", "unable to restore run intent after commit failure", error)
            }
        }

        private fun abandonRunIntentIfCurrent(context: Context, requestId: String?): Boolean =
            abandonRunIntentIfCurrent(context, requestId) { editor -> editor.commit() }

        internal fun abandonRunIntentIfCurrentForTest(
            context: Context,
            requestId: String?,
            commitAttempt: (SharedPreferences.Editor) -> Boolean,
        ): Boolean = abandonRunIntentIfCurrent(context, requestId, commitAttempt)

        private fun abandonRunIntentIfCurrent(
            context: Context,
            requestId: String?,
            commitAttempt: (SharedPreferences.Editor) -> Boolean,
        ): Boolean =
            synchronized(runIntentLock) {
                val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
                val previous = RunIntentState(
                    desired = prefs.getBoolean(KEY_WAS_RUNNING, false),
                    requestId = prefs.getString(KEY_PENDING_START_ID, null),
                    encryptedPayload = prefs.getString(KEY_LAST_CONFIG_PAYLOAD, null),
                )
                val matches = previous.desired && if (requestId == null) {
                    previous.requestId == null
                } else {
                    previous.requestId == requestId
                }
                if (!matches) return@synchronized false
                val abandoned = try {
                    commitAttempt(
                        prefs.edit()
                            .putBoolean(KEY_WAS_RUNNING, false)
                            .remove(KEY_LAST_CONFIG_PAYLOAD)
                            .remove(KEY_PENDING_START_ID),
                    )
                } catch (error: Exception) {
                    Log.e("FrpEngine", "unable to persist abandoned run intent", error)
                    false
                }
                if (!abandoned) restoreRunIntent(prefs, previous)
                abandoned
            }

        private fun commitRunningPayload(
            context: Context,
            requestId: String?,
            encryptedPayload: String,
        ): Boolean = synchronized(runIntentLock) {
            val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
            val previous = RunIntentState(
                desired = prefs.getBoolean(KEY_WAS_RUNNING, false),
                requestId = prefs.getString(KEY_PENDING_START_ID, null),
                encryptedPayload = prefs.getString(KEY_LAST_CONFIG_PAYLOAD, null),
            )
            val matches = previous.desired && if (requestId == null) {
                previous.requestId == null
            } else {
                previous.requestId == requestId
            }
            if (!matches) return@synchronized false
            val committed = try {
                prefs.edit()
                    .putString(KEY_LAST_CONFIG_PAYLOAD, encryptedPayload)
                    .remove(KEY_PENDING_START_ID)
                    .commit()
            } catch (error: Exception) {
                Log.e("FrpEngine", "unable to persist recovery configuration", error)
                false
            }
            if (!committed) restoreRunIntent(prefs, previous)
            committed
        }
    }

    // 当前状态快照：channel 挂载后重放，避免后台连接期间推送丢失导致仪表盘不同步
    @Volatile
    private var serverStatus: Pair<String, String>? = null
    private val appStatuses = java.util.concurrent.ConcurrentHashMap<String, String>()
    @Volatile
    private var frpcProcess: Process? = null
    @Volatile
    private var frpcPid: Int = -1
    @Volatile
    private var terminatingProcess: Process? = null
    private val logs = ArrayDeque<String>(2000)
    private val logsLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val processExecutor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "frp-process-control").apply { isDaemon = true }
    }
    private val destroying = AtomicBoolean(false)
    @Volatile
    private var latestServiceStartId = 0

    // 自动恢复相关
    private var lastStartMs = 0L
    private var restartPending = false
    private var healthHandler: Handler? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private val healthRunnable = object : Runnable {
        override fun run() {
            // 定时健康检查兜底：was_running 且 frpc 不在 → 自动拉起
            restoreIfNeeded()
            healthHandler?.postDelayed(this, 15_000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        // A previous app-process crash may have happened before the normal
        // first-log/10-second deletion. No child exists yet, so remove that
        // stale plaintext configuration before accepting a new request.
        deleteRuntimeConfig(this)
        instance = this
        registerNetworkMonitor()
        healthHandler = Handler(Looper.getMainLooper())
        healthHandler?.postDelayed(healthRunnable, 15_000)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        latestServiceStartId = startId
        createChannel()
        startForeground(NOTIF_ID, buildNotification("FRPC 正在运行"))
        return when (intent?.action) {
            ACTION_START -> {
                val configContent = intent.getStringExtra(EXTRA_CONFIG_CONTENT)
                val requestId = intent.getStringExtra(EXTRA_START_ID)
                val state = readRunIntent(this)
                when (classifyStartRequest(
                    desired = state.desired,
                    pendingRequestId = state.requestId,
                    encryptedPayload = state.encryptedPayload,
                    deliveredRequestId = requestId,
                )) {
                    StartRequestDisposition.START_PENDING -> {
                        if (!submitProcessTask {
                                runDebugTestHook(beforeStartWorkerForTest)
                                if (!startFrpcInternal(configContent, requestId = requestId)) {
                                    stopAfterFailedRequest(startId, "FRPC 启动失败")
                                }
                            }
                        ) {
                            stopAfterFailedRequest(startId, "FRPC 启动失败")
                        }
                        START_REDELIVER_INTENT
                    }
                    StartRequestDisposition.RESTORE_COMMITTED -> {
                        // START_REDELIVER_INTENT also replays the most recent
                        // request after it has committed. Restore from the
                        // current encrypted payload instead of replaying stale
                        // plaintext carried by that historical Intent.
                        if (!submitProcessTask {
                                restoreIfNeededInternal()
                                if (!isFrpcRunning() && !hasRecoverableRunningIntent()) {
                                    stopAfterFailedRequest(startId, "FRPC 恢复失败")
                                }
                            }
                        ) {
                            stopAfterFailedRequest(startId, "FRPC 恢复失败")
                        }
                        START_REDELIVER_INTENT
                    }
                    StartRequestDisposition.REJECT -> {
                        stopAfterFailedRequest(startId, "FRPC 启动失败")
                        START_NOT_STICKY
                    }
                }
            }
            ACTION_RESTORE, null -> {
                if (!submitProcessTask {
                        restoreIfNeededInternal()
                        if (!isFrpcRunning() && !hasRecoverableRunningIntent()) {
                            stopAfterFailedRequest(startId, "FRPC 恢复失败")
                        }
                    }
                ) {
                    stopAfterFailedRequest(startId, "FRPC 恢复失败")
                }
                START_STICKY
            }
            ACTION_STOP -> {
                if (!submitProcessTask {
                        runDebugTestHook(beforeStopWorkerForTest)
                        stopFrpcInternal(deleteConfig = true)
                        mainHandler.post { stopServiceForStartId(startId) }
                    }
                ) {
                    stopServiceForStartId(startId)
                }
                START_NOT_STICKY
            }
            else -> {
                stopAfterFailedRequest(startId, "FRPC 启动请求无效")
                START_NOT_STICKY
            }
        }
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        destroying.set(true)
        healthHandler?.removeCallbacks(healthRunnable)
        unregisterNetworkMonitor()
        try {
            processExecutor.execute {
                // 系统回收 Service 时保留用户运行意图，便于 sticky/redelivered 恢复。
                stopFrpcInternal(deleteConfig = true)
            }
        } catch (_: RejectedExecutionException) {
            startTerminalCleanup()
        }
        processExecutor.shutdown()
        Thread {
            try {
                if (!processExecutor.awaitTermination(7, TimeUnit.SECONDS)) {
                    processExecutor.shutdownNow()
                    startTerminalCleanup()
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                processExecutor.shutdownNow()
                startTerminalCleanup()
            }
        }.apply {
            name = "frpc-cleanup-watchdog"
            isDaemon = true
            start()
        }
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.e("FrpEngine", "foreground service timed out, type=$fgsType")
        if (latestServiceStartId != startId) return
        clearRunIntent(this)
        // Leave the foreground state immediately; onDestroy queues bounded
        // child-process cleanup away from the main thread.
        stopServiceForStartId(startId)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ---- 对外接口（MainActivity 调用） ----

    /** frpc 进程是否存活 */
    fun isFrpcRunning(): Boolean =
        processIsAlive(frpcProcess)

    /** 上次连接在运行但当前 frpc 未运行 → 自动恢复（带节流，避免崩溃循环） */
    fun restoreIfNeeded() {
        submitProcessTask { restoreIfNeededInternal() }
    }

    private fun restoreIfNeededInternal() {
        if (isFrpcRunning()) return
        if (System.currentTimeMillis() - lastStartMs < 10_000) return
        val state = readRunIntent(this)
        if (!state.desired || state.requestId != null) return
        val payload = state.encryptedPayload
        if (payload.isNullOrEmpty()) {
            Log.e("FrpEngine", "recovery configuration is missing")
            abandonRunIntentIfCurrent(this, requestId = null)
            deleteRuntimeConfig(this)
            return
        }
        try {
            startFrpcInternal(SecureStringCodec.decrypt(payload), payload)
        } catch (e: Exception) {
            Log.e("FrpEngine", "unable to decrypt recovery configuration", e)
            abandonRunIntentIfCurrent(this, requestId = null)
            deleteRuntimeConfig(this)
        }
    }

    private fun hasRecoverableRunningIntent(): Boolean {
        val state = readRunIntent(this)
        return state.desired && state.requestId == null &&
            !state.encryptedPayload.isNullOrEmpty()
    }

    /** frpc 意外退出后延迟自动重启（节流：10 秒内不重复启动） */
    private fun scheduleRestart() {
        if (restartPending) return
        if (System.currentTimeMillis() - lastStartMs < 10_000) return
        restartPending = true
        mainHandler.postDelayed({
            submitProcessTask {
                restartPending = false
                restoreIfNeededInternal()
            }
        }, 3_000)
    }

    private fun startFrpcInternal(
        configContent: String?,
        encryptedPayload: String? = null,
        requestId: String? = null,
    ): Boolean {
        if (destroying.get() || !isCurrentRunIntent(this, requestId)) return false
        stopFrpcInternal(deleteConfig = true)
        if (destroying.get() || !isCurrentRunIntent(this, requestId)) return false
        val frpc = frpcBinary()
        if (!frpc.exists() || configContent.isNullOrBlank() ||
            !utf8Fits(configContent, MAX_CONFIG_BYTES)
        ) {
            sendStatus("server", "error", "frpc binary or config missing")
            abandonRunIntentIfCurrent(this, requestId)
            deleteRuntimeConfig(this)
            return false
        }
        return try {
            val resolv = File(filesDir, "resolv.conf")
            resolv.writeText(
                "nameserver 8.8.8.8\nnameserver 114.114.114.114\nnameserver 1.1.1.1\n"
            )
            // STUN 域名解析为 IP（Android 上 Go DNS 走 [::1]:53 会被拒）
            val patchedCfg = patchStunEndpoints(configContent)
            if (destroying.get() || !isCurrentRunIntent(this, requestId)) return false
            val cfgFile = writeRuntimeConfig(patchedCfg)
            val pb = ProcessBuilder(frpc.absolutePath, "-c", cfgFile.absolutePath)
            pb.environment()["GODEBUG"] = "netdns=go"
            pb.environment()["RES_OPTIONS"] = "ndots:1"
            pb.environment()["RESOLV_CONF"] = resolv.absolutePath
            pb.redirectErrorStream(true)
            val process = pb.start()
            frpcProcess = process
            frpcPid = pidOf(process)
            if (destroying.get() || !isCurrentRunIntent(this, requestId)) {
                stopFrpcInternal(deleteConfig = true)
                return false
            }
            lastStartMs = System.currentTimeMillis()
            Log.d("FrpEngine", "frpc started, pid=$frpcPid")
            synchronized(logsLock) { logs.clear() }
            val recoveryPayload = encryptedPayload ?: SecureStringCodec.encrypt(configContent)
            if (!commitRunningPayload(this, requestId, recoveryPayload)) {
                stopFrpcInternal(deleteConfig = true)
                abandonRunIntentIfCurrent(this, requestId)
                return false
            }
            updateNotification("FRPC 正在运行")
            sendStatus("server", "connecting", "Starting frpc...")

            Thread {
                try {
                    InputStreamReader(process.inputStream).use { reader ->
                        readBoundedLogLines(reader) { line ->
                            if (instance === this && frpcProcess === process) {
                                deleteRuntimeConfig(this)
                                onFrpcLine(line)
                            }
                        }
                    }
                } catch (e: Exception) {
                }
            }.apply {
                name = "frpc-output-reader"
                isDaemon = true
                start()
            }

            Thread {
                try {
                    val code = process.waitFor()
                    submitProcessTask {
                        if (frpcProcess === process) {
                            frpcProcess = null
                            frpcPid = -1
                            deleteRuntimeConfig(this)
                            // 意外退出：保留 was_running（用户运行意图），延迟自动重启
                            sendStatus("server", "disconnected", "frpc exited ($code)")
                            sendAppReset()
                            scheduleRestart()
                        }
                    }
                } catch (e: Exception) {
                    // ignore
                }
            }.apply {
                name = "frpc-process-monitor"
                isDaemon = true
                start()
            }
            mainHandler.postDelayed({
                submitProcessTask {
                    if (frpcProcess === process && processIsAlive(process)) {
                        deleteRuntimeConfig(this)
                    }
                }
            }, 10_000)
            true
        } catch (e: Exception) {
            Log.e("FrpEngine", "start failed", e)
            sendStatus("server", "error", "Failed to start frpc")
            stopFrpcInternal(deleteConfig = true)
            abandonRunIntentIfCurrent(this, requestId)
            false
        }
    }

    /** Fallback when Android rejects delivery of an explicit STOP command. */
    private fun stopProcessWithoutStoppingService() {
        val observedStartId = latestServiceStartId
        val submitted = submitProcessTask {
            stopFrpcInternal(deleteConfig = true)
            mainHandler.post {
                val state = readRunIntent(this)
                if (shouldStopAfterFallback(
                        observedStartId = observedStartId,
                        currentStartId = latestServiceStartId,
                        wasRunning = state.desired,
                        pendingStartId = state.requestId,
                    )
                ) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
        if (!submitted) {
            runOnMainThread {
                val state = readRunIntent(this)
                if (shouldStopAfterFallback(
                        observedStartId = observedStartId,
                        currentStartId = latestServiceStartId,
                        wasRunning = state.desired,
                        pendingStartId = state.requestId,
                    )
                ) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    fun readLogs(): String = synchronized(logsLock) { logs.joinToString("\n") }

    /** 应用内存占用：Flutter 进程 RSS + frpc 子进程 RSS（MB） */
    fun getMemoryMb(): Double {
        val appRss = ProcessMemory.rssMb(android.os.Process.myPid())
        val frpcRss = if (frpcPid > 0) ProcessMemory.rssMb(frpcPid) else 0.0
        return appRss + frpcRss
    }

    // ---- 内部实现 ----

    private fun frpcBinary(): File = File(applicationInfo.nativeLibraryDir, "libfrpc.so")

    private fun submitProcessTask(task: () -> Unit): Boolean {
        if (destroying.get()) return false
        return try {
            processExecutor.execute {
                if (!destroying.get()) task()
            }
            true
        } catch (_: RejectedExecutionException) {
            false
        }
    }

    private fun stopAfterFailedRequest(startId: Int, message: String) {
        runOnMainThread {
            updateNotification(message)
            // Only consume this start request. A newer queued request must
            // retain the foreground-service lifetime and notification.
            stopServiceForStartId(startId)
        }
    }

    private fun stopServiceForStartId(startId: Int): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper())
        val stopped = stopSelfResult(startId)
        if (stopped) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        return stopped
    }

    private fun runOnMainThread(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post(action)
    }

    private fun runDebugTestHook(hook: (() -> Unit)?) {
        if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            hook?.invoke()
        }
    }

    /** Terminal lifecycle fallback after the bounded executor shutdown window. */
    private fun startTerminalCleanup() {
        Thread {
            val processes = listOfNotNull(frpcProcess, terminatingProcess).distinct()
            frpcProcess = null
            frpcPid = -1
            terminatingProcess = null
            processes.forEach { process ->
                try {
                    process.destroy()
                    if (processIsAlive(process)) {
                        if (Build.VERSION.SDK_INT >= 26) process.destroyForcibly()
                        else {
                            val pid = pidOf(process)
                            if (pid > 0) android.os.Process.killProcess(pid)
                        }
                    }
                } catch (_: Exception) {
                    // Service destruction cannot wait indefinitely for a child.
                }
            }
            if (ownsGlobalServiceState()) {
                deleteRuntimeConfig(this)
                sendStatus("server", "disconnected", "")
                sendAppReset()
            }
        }.apply {
            name = "frpc-terminal-cleanup"
            isDaemon = true
            start()
        }
    }

    private fun stopFrpcInternal(deleteConfig: Boolean) {
        val process = frpcProcess
        val processPid = frpcPid
        // 先清空引用，防止 monitorThread 把主动停止误判为异常退出。
        terminatingProcess = process
        frpcProcess = null
        frpcPid = -1
        process?.let { p ->
            try {
                p.destroy()
                if (!waitForExit(p, 5_000) && processIsAlive(p)) {
                    if (Build.VERSION.SDK_INT >= 26) {
                        p.destroyForcibly()
                    } else if (processPid > 0) {
                        android.os.Process.killProcess(processPid)
                    } else {
                        p.destroy()
                    }
                    waitForExit(p, 1_000)
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                try {
                    if (Build.VERSION.SDK_INT >= 26) p.destroyForcibly()
                    else if (processPid > 0) android.os.Process.killProcess(processPid)
                } catch (_: Exception) {
                    // Best effort during executor shutdown.
                }
            } catch (_: Exception) {
                // Best effort; state cleanup below must still run.
            } finally {
                if (terminatingProcess === p) terminatingProcess = null
            }
        }
        restartPending = false
        if (ownsGlobalServiceState()) {
            if (deleteConfig) deleteRuntimeConfig(this)
            sendStatus("server", "disconnected", "")
            sendAppReset()
        }
    }

    private fun ownsGlobalServiceState(): Boolean {
        val activeInstance = instance
        return activeInstance == null || activeInstance === this
    }

    /// 网络变化监听：网络恢复时立即尝试恢复连接
    private fun registerNetworkMonitor() {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    restoreIfNeeded()
                }
            }
            cm.registerDefaultNetworkCallback(networkCallback!!)
        } catch (e: Exception) {
            // ignore
        }
    }

    private fun unregisterNetworkMonitor() {
        try {
            networkCallback?.let {
                getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it)
            }
        } catch (e: Exception) {
            // ignore
        }
    }

    private fun writeRuntimeConfig(content: String): File {
        val target = runtimeConfigFile(this)
        val pending = File(noBackupFilesDir, "$RUNTIME_CONFIG_NAME.pending")
        pending.delete()
        pending.createNewFile()
        pending.setReadable(false, false)
        pending.setWritable(false, false)
        pending.setExecutable(false, false)
        check(pending.setReadable(true, true)) { "unable to restrict config read access" }
        check(pending.setWritable(true, true)) { "unable to restrict config write access" }
        pending.writeText(content)
        if (target.exists()) check(target.delete()) { "unable to replace runtime config" }
        check(pending.renameTo(target)) { "unable to install runtime config" }
        return target
    }

    private fun onFrpcLine(raw: String) {
        val line = sanitizeLogLine(raw)
        synchronized(logsLock) {
            logs.addLast(line)
            if (logs.size > 2000) logs.removeFirst()
        }
        sendLog(line)
        parseLine(line)
    }

    private fun parseLine(msg: String) {
        when {
            msg.contains("login to server success", ignoreCase = true) ->
                sendStatus("server", "connected", "Connected to server")
            msg.contains("try to connect to server", ignoreCase = true) ->
                sendStatus("server", "connecting", "Connecting to server...")
            msg.contains("login to the server failed", ignoreCase = true) ||
                msg.contains("connect to server error", ignoreCase = true) ->
                sendStatus("server", "error", "Server connection failed")

            msg.contains("establishing nat hole connection successful", ignoreCase = true) ||
                msg.contains("punch ok", ignoreCase = true) ||
                msg.contains("xudp tunnel established via p2p", ignoreCase = true) ||
                msg.contains("xudp p2p quic datagram transport ready", ignoreCase = true) ||
                msg.contains("xudp relay recovered p2p path", ignoreCase = true) ->
                sendAppStatus(extractName(msg), "p2p")
            msg.contains("nathole prepare error", ignoreCase = true) ||
                msg.contains("make hole error", ignoreCase = true) ||
                msg.contains("nathole precheck error", ignoreCase = true) ||
                msg.contains("xudp p2p failed, falling back to relay", ignoreCase = true) ||
                msg.contains("xudp relay: relay visitor conn established", ignoreCase = true) ->
                sendAppStatus(extractName(msg), "relay")
            msg.contains("doesn't exist", ignoreCase = true) ->
                sendAppStatus(extractName(msg), "error")

            msg.contains("connection established", ignoreCase = true) &&
                msg.contains("stcp", ignoreCase = true) ->
                sendAppStatus(extractName(msg), "relay")
            msg.contains("connection established", ignoreCase = true) &&
                msg.contains("xtcp", ignoreCase = true) ->
                sendAppStatus(extractName(msg), "p2p")
        }
    }

    private fun extractName(msg: String): String {
        val m = Regex(
            "\\[([^\\]]+)\\] (xudp|establishing|nathole|punch|make hole|open tunnel|for|connection established)"
        )
            .find(msg)
        return m?.groupValues?.get(1) ?: ""
    }

    private fun sendStatus(scope: String, type: String, detail: String) {
        if (scope == "server") {
            serverStatus = type to detail
        }
        val ch = channel ?: return
        mainHandler.post {
            try {
                ch.invokeMethod(
                    "onStatus",
                    mapOf("scope" to scope, "type" to type, "detail" to detail)
                )
            } catch (e: Exception) {
                // Activity 已销毁等情况
            }
        }
    }

    private fun sendAppStatus(name: String, type: String) {
        if (name.isBlank()) return
        if (!recordBoundedAppStatus(appStatuses, name, type)) return
        val ch = channel ?: return
        mainHandler.post {
            try {
                ch.invokeMethod("onAppStatus", mapOf("name" to name, "type" to type))
            } catch (e: Exception) {
            }
        }
    }

    private fun sendAppReset() {
        synchronized(appStatuses) { appStatuses.clear() }
        val ch = channel ?: return
        mainHandler.post {
            try {
                ch.invokeMethod("onAppStatus", mapOf("name" to "", "type" to "reset"))
            } catch (e: Exception) {
            }
        }
    }

    /** channel 挂载后重放当前状态，保证仪表盘与后台实际连接同步 */
    fun syncToChannel() {
        val ch = channel ?: return
        val statusSnapshot = synchronized(appStatuses) { appStatuses.toMap() }
        mainHandler.post {
            try {
                serverStatus?.let { (type, detail) ->
                    ch.invokeMethod(
                        "onStatus",
                        mapOf("scope" to "server", "type" to type, "detail" to detail)
                    )
                }
                statusSnapshot.forEach { (name, type) ->
                    ch.invokeMethod("onAppStatus", mapOf("name" to name, "type" to type))
                }
            } catch (e: Exception) {
            }
        }
    }

    private fun sendLog(line: String) {
        val ch = channel ?: return
        mainHandler.post {
            try {
                ch.invokeMethod("onLog", line)
            } catch (e: Exception) {
            }
        }
    }

    /// 兼容 API < 26 获取 Process pid（反射，避免直接调用 API 26 的 Process.pid()）
    private fun pidOf(p: Process?): Int {
        if (p == null) return -1
        return try {
            val m = Process::class.java.getMethod("pid")
            (m.invoke(p) as Number).toInt()
        } catch (e: Exception) {
            try {
                val f = p.javaClass.getDeclaredField("pid")
                f.isAccessible = true
                f.getInt(p)
            } catch (e2: Exception) {
                -1
            }
        }
    }

    private fun processIsAlive(process: Process?): Boolean {
        if (process == null) return false
        return if (Build.VERSION.SDK_INT >= 26) {
            process.isAlive
        } else {
            try {
                process.exitValue()
                false
            } catch (_: IllegalThreadStateException) {
                true
            }
        }
    }

    private fun waitForExit(process: Process, timeoutMs: Long): Boolean {
        if (Build.VERSION.SDK_INT >= 26) {
            return process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
        }
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (processIsAlive(process) && SystemClock.elapsedRealtime() < deadline) {
            Thread.sleep(50)
        }
        return !processIsAlive(process)
    }

    // ---- 前台通知 ----

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "FRPC 后台服务",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(content: String): Notification {
        val launchIntent = Intent().setComponent(
            ComponentName(this, MainActivity::class.java)
        )
        val pi = PendingIntent.getActivity(
            this, 0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("FRP Android")
            .setContentText(content)
            .setOngoing(true)
            .setContentIntent(pi)
            .build()
    }

    private fun updateNotification(content: String) {
        runOnMainThread {
            if (!destroying.get()) {
                val nm = getSystemService(NotificationManager::class.java)
                nm.notify(NOTIF_ID, buildNotification(content))
            }
        }
    }
}
