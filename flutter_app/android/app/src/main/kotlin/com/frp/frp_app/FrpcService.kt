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
import java.util.Arrays
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
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
        private const val KEY_PENDING_PAYLOAD = "pending_config_payload"
        private const val ACTION_START = "com.frp.frp_app.action.START"
        private const val ACTION_STOP = "com.frp.frp_app.action.STOP"
        private const val ACTION_RESTORE = "com.frp.frp_app.action.RESTORE"
        private const val EXTRA_CONFIG_CONTENT = "config_content"
        private const val EXTRA_START_ID = "start_id"
        private const val RUNTIME_CONFIG_NAME = "frpc-runtime.toml"
        private const val MAX_CONFIG_BYTES = 512 * 1024
        internal const val MAX_SOCKS_RUNTIME_PAYLOAD_BYTES = 384 * 1024
        private const val MAX_LOG_LINE_CHARS = RuntimeLogSanitizer.MAX_LOG_LINE_CHARS
        private const val MAX_APP_STATUS_ENTRIES = 1024
        private const val TRUNCATED_LOG_SUFFIX = RuntimeLogSanitizer.TRUNCATED_LOG_SUFFIX
        private const val DEFAULT_STUN_PORT = 3478
        private val runIntentLock = Any()
        private val runtimeConfigLock = Any()
        private val runCommandExecutor = ThreadPoolExecutor(
            0, 1, 30, TimeUnit.SECONDS, LinkedBlockingQueue(),
        ) { task -> Thread(task, "frpc-run-intent").apply { isDaemon = true } }
        private val stunEndpointPattern = Regex(
            """(?m)^(\s*natHoleStunServer\s*=\s*)\"([^\"\r\n]+)\"(\s*(?:#.*)?)$""",
        )
        // Older encrypted run intents may still include STUN for a relay-only
        // configuration. Avoid doing DNS on the serial service worker for them.
        private val peerToPeerType = Regex(
            """(?m)^\s*(?:type|"type"|'type')\s*=\s*["']{1,3}\s*(?:xtcp|xudp)\s*["']{1,3}\s*(?:#.*)?$""",
        )

        private data class RunIntentState(
            val desired: Boolean,
            val requestId: String?,
            val encryptedPayload: String?,
            val pendingPayload: String?,
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
            if (!peerToPeerType.containsMatchIn(config)) return config
            val endpoint = parseStunEndpoint(match.groupValues[2])
                ?: return config
            if (android.util.Patterns.IP_ADDRESS.matcher(endpoint.host).matches()) return config
            val resolved = resolveHost(endpoint.host)
            val authority = StunEndpoint(resolved, endpoint.port).authority()
            val replacement = "${match.groupValues[1]}\"$authority\"${match.groupValues[3]}"
            return config.replaceRange(match.range, replacement)
        }

        internal fun redactLogLine(line: String): String = RuntimeLogSanitizer.redact(line)

        internal fun sanitizeLogLine(raw: String): String = RuntimeLogSanitizer.sanitize(raw)

        internal fun readBoundedLogLines(
            reader: Reader,
            onFirstLine: (() -> Unit)? = null,
            onLine: (String) -> Unit,
        ) {
            val buffer = CharArray(1024)
            val line = StringBuilder(MAX_LOG_LINE_CHARS)
            var firstLine = onFirstLine
            var truncated = false
            var afterCarriageReturn = false

            fun emitLine() {
                firstLine?.invoke()
                firstLine = null
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
            set(value) = synchronized(logsLock) {
                if (field !== value) {
                    field = value
                    logSubscription = null
                    logUiStarted = false
                }
            }

        // Include diagnostics produced before the foreground service starts,
        // and retain them across service restarts within this app process.
        private val recentLogs = ArrayDeque<String>(2000)
        private const val LOG_BATCH_SIZE = 64
        private var nextLogId = 1L
        private val logsLock = Any()
        private val logHandler by lazy { Handler(Looper.getMainLooper()) }
        private class LogSubscription(val channel: MethodChannel, var nextId: Long) {
            var deliveryPending = false
            var deliveryFailed = false
        }
        private var logSubscription: LogSubscription? = null
        private var logUiStarted = false

        internal fun setLogUiStarted(owner: MethodChannel?, started: Boolean) = synchronized(logsLock) {
            if (owner != null && channel === owner) {
                logUiStarted = started
                val subscription = logSubscription
                if (started && subscription != null) {
                    subscription.deliveryFailed = false
                    if (subscription.nextId < nextLogId) scheduleLogBatch(subscription)
                }
            }
        }

        internal fun setLogSubscription(owner: MethodChannel, enabled: Boolean) = synchronized(logsLock) {
            if (channel === owner) {
                if (!enabled) logSubscription = null
                else if (logSubscription == null) logSubscription = LogSubscription(owner, nextLogId)
            }
        }

        // Called with logsLock held. The main queue holds at most one wake-up
        // for the reader, regardless of how quickly frpc writes to its ring.
        private fun scheduleLogBatch(subscription: LogSubscription) {
            if (subscription.deliveryPending || subscription.deliveryFailed) return
            subscription.deliveryPending = true
            logHandler.post { deliverLogBatch(subscription) }
        }

        private fun deliverLogBatch(subscription: LogSubscription) {
            val (firstId, lines) = synchronized(logsLock) {
                // A queued callback can outlive its viewer or Activity.
                if (logSubscription !== subscription) return
                if (!logUiStarted) {
                    subscription.deliveryPending = false
                    return
                }
                readLogBatch(subscription.nextId)
            }
            // Wait for Dart to consume this batch. A stalled Flutter thread
            // cannot accumulate serialized copies beyond the in-flight batch.
            val reply = object : MethodChannel.Result {
                override fun success(result: Any?) = finishLogBatch(subscription, firstId + lines.size)
                override fun error(code: String, message: String?, details: Any?) = finishLogBatch(subscription, null)
                override fun notImplemented() = finishLogBatch(subscription, null)
            }
            try {
                subscription.channel.invokeMethod("onLogBatch", mapOf("firstId" to firstId, "lines" to lines), reply)
            } catch (_: RuntimeException) {
                finishLogBatch(subscription, null)
            }
        }

        private fun finishLogBatch(subscription: LogSubscription, deliveredTo: Long?) = synchronized(logsLock) {
            if (logSubscription !== subscription) return@synchronized
            subscription.deliveryPending = false
            if (deliveredTo != null) {
                subscription.nextId = deliveredTo
                if (logUiStarted && deliveredTo < nextLogId) scheduleLogBatch(subscription)
            } else {
                // Retain the cursor for reopening or resuming the viewer.
                // More logs alone must not repeatedly transmit a rejected batch.
                subscription.deliveryFailed = true
            }
        }

        internal fun readLogBatch(cursor: Long): Pair<Long, List<String>> = synchronized(logsLock) {
            val oldestId = nextLogId - recentLogs.size
            val firstId = cursor.coerceIn(oldestId, nextLogId)
            val count = minOf(nextLogId - firstId, LOG_BATCH_SIZE.toLong()).toInt()
            val offset = (firstId - oldestId).toInt()
            firstId to List(count) { recentLogs[offset + it] }
        }

        internal fun readRecentLogs(): String = synchronized(logsLock) {
            recentLogs.joinToString("\n")
        }

        internal fun readLogSnapshot(): Map<String, Any> = synchronized(logsLock) {
            mapOf("firstId" to nextLogId - recentLogs.size, "lines" to recentLogs.toList())
        }

        internal fun recordLog(raw: String): String {
            val line = sanitizeLogLine(raw)
            synchronized(logsLock) {
                val id = nextLogId++
                if (recentLogs.size == 2000) recentLogs.removeFirst()
                recentLogs.addLast(line)
                // Queue in the same order as the snapshot, even when frpc,
                // STUN and SOCKS workers report concurrently.
                if (BuildConfig.BUILD_TYPE == "release") {
                    val subscription = logSubscription
                    if (logUiStarted && subscription != null) scheduleLogBatch(subscription)
                } else {
                    val ch = channel
                    if (ch != null) logHandler.post {
                        if (channel === ch) runCatching { ch.invokeMethod("onLog", listOf(id, line)) }
                    }
                }
            }
            return line
        }

        @Volatile
        internal var beforeStartWorkerForTest: (() -> Unit)? = null

        @Volatile
        internal var beforeStopWorkerForTest: (() -> Unit)? = null

        internal fun submitRunCommand(context: Context, result: MethodChannel.Result, command: (Context) -> Boolean) {
            val app = context.applicationContext
            val reply = MainThreadResult(result)
            // Keep Flutter's submission order across Activity recreation and release the idle worker.
            runCommandExecutor.execute {
                try {
                    reply.success(command(app))
                } catch (error: Exception) {
                    Log.e("FrpEngine", "unable to process frpc command", error)
                    reply.success(false)
                }
            }
        }

        /** 提交用户启动请求，实际进程启动在 onStartCommand 中串行执行。 */
        fun start(
            context: Context,
            configContent: String?,
            socks5Forwards: List<*> = emptyList<Any>(),
        ): Boolean {
            if (configContent.isNullOrBlank() || !utf8Fits(configContent, MAX_CONFIG_BYTES)) return false
            val payload = try {
                FrpcRuntimePayload(configContent, Socks5ForwardRule.fromMaps(socks5Forwards)).encode()
            } catch (_: Exception) {
                return false
            }
            return startWithCommit(context, payload) { editor -> editor.commit() }
        }

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
                !runtimePayloadFits(configContent)
            ) return false
            val startId = UUID.randomUUID().toString()
            val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
            return synchronized(runIntentLock) {
                val previous = readRunIntent(prefs)
                val recorded = try {
                    commitAttempt(
                        prefs.edit()
                            .putBoolean(KEY_WAS_RUNNING, true)
                            .putString(KEY_PENDING_START_ID, startId)
                            .putString(KEY_PENDING_PAYLOAD, SecureStringCodec.encrypt(configContent)),
                    )
                } catch (error: Exception) {
                    Log.e("FrpEngine", "unable to persist pending run intent", error)
                    false
                }
                if (!recorded) {
                    restoreRunIntent(prefs, previous)
                    return@synchronized false
                }
                // Recovery must not claim this new pending request until Android accepts delivery.
                try {
                    startServiceIntent(context, Intent(context, FrpcService::class.java)
                        .setAction(ACTION_START).putExtra(EXTRA_START_ID, startId))
                    true
                } catch (e: Exception) {
                    restoreRunIntent(prefs, previous)
                    Log.e("FrpEngine", "unable to schedule frpc service", e)
                    false
                }
            }
        }

        private fun requestRestore(context: Context) {
            startServiceIntent(
                context,
                Intent(context, FrpcService::class.java).setAction(ACTION_RESTORE)
            )
        }

        private fun startServiceIntent(context: Context, intent: Intent) {
            val component = if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            checkNotNull(component) { "Android could not resolve the frpc service" }
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

        private fun deleteRuntimeConfig(context: Context): Unit = synchronized(runtimeConfigLock) {
            // A previous service can finish its teardown on a different executor.
            val owner = instance
            if (owner == null || owner === context) {
                runtimeConfigFile(context).delete()
                File(context.noBackupFilesDir, "$RUNTIME_CONFIG_NAME.pending").delete()
            }
        }

        internal fun runtimePayloadFits(value: String): Boolean {
            val limit = if (value.trimStart().startsWith("{")) MAX_SOCKS_RUNTIME_PAYLOAD_BYTES
                else MAX_CONFIG_BYTES
            return utf8Fits(value, limit)
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
        fun ensureRunning(context: Context, afterBoot: Boolean = false) {
            val svc = instance
            if (svc == null) {
                val state = readRunIntent(context)
                if (afterBoot && state.desired && state.requestId != null && state.pendingPayload == null) {
                    // Older releases held this request's only config in a service Intent lost at reboot.
                    if (abandonRunIntentIfCurrent(context, state.requestId)) deleteRuntimeConfig(context)
                    return
                }
                if (state.desired && (state.requestId == null || state.pendingPayload != null)) {
                    if (state.requestId == null && state.encryptedPayload.isNullOrEmpty()) {
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
                readRunIntent(prefs)
            }

        private fun readRunIntent(prefs: SharedPreferences) = RunIntentState(
            desired = prefs.getBoolean(KEY_WAS_RUNNING, false),
            requestId = prefs.getString(KEY_PENDING_START_ID, null),
            encryptedPayload = prefs.getString(KEY_LAST_CONFIG_PAYLOAD, null),
            pendingPayload = prefs.getString(KEY_PENDING_PAYLOAD, null),
        )

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
                val previous = readRunIntent(prefs)
                val cleared = try {
                    commitAttempt(
                        prefs.edit()
                            .putBoolean(KEY_WAS_RUNNING, false)
                            .remove(KEY_LAST_CONFIG_PAYLOAD)
                            .remove(KEY_PENDING_PAYLOAD)
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
                    .putString(KEY_PENDING_START_ID, previous.requestId)
                    .putString(KEY_PENDING_PAYLOAD, previous.pendingPayload)
                    .putString(KEY_LAST_CONFIG_PAYLOAD, previous.encryptedPayload)
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
                val previous = readRunIntent(prefs)
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
                            .remove(KEY_PENDING_PAYLOAD)
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
            val previous = readRunIntent(prefs)
            val matches = previous.desired && if (requestId == null) {
                previous.requestId == null
            } else {
                previous.requestId == requestId
            }
            if (!matches) return@synchronized false
            val committed = try {
                prefs.edit()
                    .putString(KEY_LAST_CONFIG_PAYLOAD, encryptedPayload)
                    .remove(KEY_PENDING_PAYLOAD)
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
    @Volatile
    private var socks5Forwarder: Socks5Forwarder? = null
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
        instance = this
        deleteRuntimeConfig(this)
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
                                val started = if (state.pendingPayload != null) {
                                    startFromEncryptedPayload(state.pendingPayload, requestId)
                                } else {
                                    // Older releases delivered the pending config inside their Intent.
                                    startFrpcInternal(intent.getStringExtra(EXTRA_CONFIG_CONTENT), requestId = requestId)
                                }
                                if (!started && !isRunRequested(this)) {
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
                        if (!state.desired || state.requestId == null) {
                            stopAfterFailedRequest(startId, "FRPC 启动失败")
                        }
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
        if (!state.desired) return
        // A reboot can drop the Android service delivery after the pending config was persisted.
        val payload = if (state.requestId == null) state.encryptedPayload else state.pendingPayload ?: return
        if (payload.isNullOrEmpty()) {
            Log.e("FrpEngine", "recovery configuration is missing")
            if (abandonRunIntentIfCurrent(this, state.requestId)) deleteRuntimeConfig(this)
            return
        }
        startFromEncryptedPayload(payload, state.requestId)
    }

    private fun startFromEncryptedPayload(payload: String, requestId: String?): Boolean {
        if (!isCurrentRunIntent(this, requestId)) return false
        val content = try {
            SecureStringCodec.decrypt(payload)
        } catch (e: Exception) {
            Log.e("FrpEngine", "unable to decrypt runtime configuration", e)
            if (abandonRunIntentIfCurrent(this, requestId)) deleteRuntimeConfig(this)
            return false
        }
        return startFrpcInternal(content, payload, requestId)
    }

    private fun hasRecoverableRunningIntent(): Boolean {
        val state = readRunIntent(this)
        return state.desired && if (state.requestId == null) !state.encryptedPayload.isNullOrEmpty()
            else !state.pendingPayload.isNullOrEmpty()
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
        runtimeContent: String?,
        encryptedPayload: String? = null,
        requestId: String? = null,
    ): Boolean {
        if (destroying.get() || !isCurrentRunIntent(this, requestId)) return false
        stopFrpcInternal(deleteConfig = true)
        if (destroying.get() || !isCurrentRunIntent(this, requestId)) return false
        val frpc = frpcBinary()
        val payload = try {
            if (runtimeContent.isNullOrBlank() || !runtimePayloadFits(runtimeContent)) null
            else FrpcRuntimePayload.decode(runtimeContent)
        } catch (_: Exception) { null }
        val configContent = payload?.configContent
        if (payload == null || !frpc.exists() || configContent.isNullOrBlank() ||
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
            val endpointAuth = if (payload.forwards.isEmpty()) null else FrpcEndpointAuth()
            val cfgFile = writeRuntimeConfig(patchedCfg)
            val pb = ProcessBuilder(frpc.absolutePath, "-c", cfgFile.absolutePath)
            pb.environment()["GODEBUG"] = "netdns=go"
            pb.environment()["RES_OPTIONS"] = "ndots:1"
            pb.environment()["RESOLV_CONF"] = resolv.absolutePath
            pb.redirectErrorStream(true)
            val process = endpointAuth?.start(pb, payload.forwards) ?: pb.start()
            frpcProcess = process
            frpcPid = pidOf(process)
            if (destroying.get() || !isCurrentRunIntent(this, requestId)) {
                stopFrpcInternal(deleteConfig = true)
                return false
            }
            if (endpointAuth != null) {
                val forwarder = Socks5Forwarder(payload.forwards, endpointAuth = endpointAuth, report = { message ->
                    // Final traffic snapshots can arrive after the forwarder
                    // field is cleared. These diagnostics have stable owners
                    // and must not feed the frpc status parser (names are user text).
                    recordLog("[SOCKS5] $message")
                })
                socks5Forwarder = forwarder
                forwarder.start()
            }
            lastStartMs = System.currentTimeMillis()
            Log.d("FrpEngine", "frpc started, pid=$frpcPid")
            val recoveryPayload = encryptedPayload ?: SecureStringCodec.encrypt(payload.encode())
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
                        readBoundedLogLines(reader, onFirstLine = {
                            // Serialize the ownership check and unlink with stop/restart.
                            submitProcessTask {
                                if (instance === this && frpcProcess === process) deleteRuntimeConfig(this)
                            }
                        }) { line ->
                            if (instance === this && frpcProcess === process) {
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
                            socks5Forwarder?.close()
                            socks5Forwarder = null
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
                    if (instance === this && frpcProcess === process && processIsAlive(process)) {
                        deleteRuntimeConfig(this)
                    }
                }
            }, 10_000)
            true
        } catch (e: Exception) {
            Log.e("FrpEngine", "start failed (${e.javaClass.simpleName})")
            val detail = if (e is Socks5ListenException) e.message ?: "Unable to bind SOCKS5 forwarding ports"
                else "Failed to start frpc"
            stopFrpcInternal(deleteConfig = true)
            onFrpcLine("[Android] $detail")
            sendStatus("server", "error", detail)
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

    fun readLogs(): String = readRecentLogs()

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
            socks5Forwarder?.close()
            socks5Forwarder = null
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
        socks5Forwarder?.close()
        socks5Forwarder = null
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

    private fun writeRuntimeConfig(content: String): File = synchronized(runtimeConfigLock) {
        check(instance === this && !destroying.get()) { "service no longer owns runtime config" }
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
        target
    }

    private fun onFrpcLine(raw: String) {
        val line = recordLog(raw)
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
