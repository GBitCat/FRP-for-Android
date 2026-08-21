package com.frp.frp_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.InetAddress
import java.util.ArrayDeque
import java.util.UUID

/**
 * frpc 前台服务：
 * - 常驻通知 + 前台服务提升进程优先级，保证后台驻留（frpc 连接不断）
 * - 管理 frpc 进程 / 日志解析 / 状态推送（通过 MainActivity 挂载的 MethodChannel）
 * - 记录运行状态，开机自启 / 进程重建时自动恢复
 */
class FrpcService : Service() {
    companion object {
        private const val CHANNEL_ID = "frpc_service"
        private const val NOTIF_ID = 1001
        private const val PREFS = "frp_state"
        private const val KEY_WAS_RUNNING = "was_running"
        private const val KEY_LAST_CONFIG_PAYLOAD = "last_config_payload"
        private const val KEY_PENDING_START_ID = "pending_start_id"
        private const val ACTION_START = "com.frp.frp_app.action.START"
        private const val ACTION_RESTORE = "com.frp.frp_app.action.RESTORE"
        private const val EXTRA_CONFIG_CONTENT = "config_content"
        private const val EXTRA_START_ID = "start_id"
        private const val RUNTIME_CONFIG_NAME = "frpc-runtime.toml"
        private const val MAX_CONFIG_BYTES = 512 * 1024

        internal fun redactLogLine(line: String): String = line.replace(
            Regex(
                "(?i)\\b(token|secretKey|password|clientSecret)\\s*[=:]\\s*(\\\"[^\\\"]*\\\"|[^\\s,;]+)"
            )
        ) { match -> "${match.groupValues[1]}=***" }

        @Volatile
        var instance: FrpcService? = null

        /**
         * 静态状态推送通道：由 MainActivity 挂载。
         * 与服务的启动时序解耦——服务启动前/后设置都有效，避免推送丢失。
         */
        @Volatile
        var channel: MethodChannel? = null

        /** 提交用户启动请求，实际进程启动在 onStartCommand 中串行执行。 */
        fun start(context: Context, configContent: String?): Boolean {
            if (configContent.isNullOrBlank() ||
                configContent.toByteArray(Charsets.UTF_8).size > MAX_CONFIG_BYTES
            ) return false
            val startId = UUID.randomUUID().toString()
            val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
            if (!prefs.edit().putString(KEY_PENDING_START_ID, startId).commit()) return false
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
                if (prefs.getString(KEY_PENDING_START_ID, null) == startId) {
                    prefs.edit().remove(KEY_PENDING_START_ID).commit()
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
        fun stop(context: Context) {
            val svc = instance
            if (svc != null) {
                svc.stopFrpc()
            } else {
                val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
                // commit is intentional: a queued first START must not race this
                // stop and restore a stale asynchronously-applied user intent.
                prefs.edit()
                    .putBoolean(KEY_WAS_RUNNING, false)
                    .remove(KEY_LAST_CONFIG_PAYLOAD)
                    .remove(KEY_PENDING_START_ID)
                    .commit()
                deleteRuntimeConfig(context)
                context.stopService(Intent(context, FrpcService::class.java))
            }
        }

        internal fun runtimeConfigFile(context: Context): File =
            File(context.noBackupFilesDir, RUNTIME_CONFIG_NAME)

        private fun deleteRuntimeConfig(context: Context) {
            runtimeConfigFile(context).delete()
            File(context.noBackupFilesDir, "$RUNTIME_CONFIG_NAME.pending").delete()
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
                val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
                if (prefs.getBoolean(KEY_WAS_RUNNING, false)) {
                    try {
                        requestRestore(context)
                    } catch (e: Exception) {
                        Log.e("FrpEngine", "unable to restore frpc service", e)
                    }
                }
            } else {
                svc.restoreIfNeeded()
            }
        }
    }

    private var restored = false
    // 当前状态快照：channel 挂载后重放，避免后台连接期间推送丢失导致仪表盘不同步
    private var serverStatus: Pair<String, String>? = null
    private val appStatuses = java.util.concurrent.ConcurrentHashMap<String, String>()
    private var frpcProcess: Process? = null
    private var frpcPid: Int = -1
    private var readerThread: Thread? = null
    private var monitorThread: Thread? = null
    private val logs = ArrayDeque<String>(2000)
    private val logsLock = Any()

    // 自动恢复相关
    private var lastStartMs = 0L
    private var restartPending = false
    private var healthHandler: Handler? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var networkReceiver: BroadcastReceiver? = null

    private val healthRunnable = object : Runnable {
        override fun run() {
            // 定时健康检查兜底：was_running 且 frpc 不在 → 自动拉起
            restoreIfNeeded()
            healthHandler?.postDelayed(this, 15_000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        registerNetworkMonitor()
        healthHandler = Handler(Looper.getMainLooper())
        healthHandler?.postDelayed(healthRunnable, 15_000)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        startForeground(NOTIF_ID, buildNotification("FRPC 正在运行"))
        when (intent?.action) {
            ACTION_START -> {
                restored = true
                val configContent = intent.getStringExtra(EXTRA_CONFIG_CONTENT)
                val requestId = intent.getStringExtra(EXTRA_START_ID)
                val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
                val accepted = !requestId.isNullOrEmpty() &&
                    prefs.getString(KEY_PENDING_START_ID, null) == requestId
                if (accepted) prefs.edit().remove(KEY_PENDING_START_ID).commit()
                if (!accepted || !startFrpc(configContent)) {
                    updateNotification("FRPC 启动失败")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
            ACTION_RESTORE, null -> {
                // 开机恢复 / START_STICKY 重建：仅在冷启动时恢复一次。
                if (!restored) {
                    restored = true
                    restoreIfNeeded()
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        instance = null
        healthHandler?.removeCallbacks(healthRunnable)
        unregisterNetworkMonitor()
        // 系统回收 Service 时保留用户运行意图，便于 START_STICKY 恢复。
        stopFrpcInternal(clearRunningIntent = false, deleteConfig = true)
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.e("FrpEngine", "foreground service timed out, type=$fgsType")
        stopFrpcInternal(clearRunningIntent = true, deleteConfig = true)
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ---- 对外接口（MainActivity 调用） ----

    /** frpc 进程是否存活 */
    fun isFrpcRunning(): Boolean =
        frpcProcess?.isAlive == true

    /** 上次连接在运行但当前 frpc 未运行 → 自动恢复（带节流，避免崩溃循环） */
    fun restoreIfNeeded() {
        if (isFrpcRunning()) return
        if (System.currentTimeMillis() - lastStartMs < 10_000) return
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_WAS_RUNNING, false)) return
        val payload = prefs.getString(KEY_LAST_CONFIG_PAYLOAD, null)
        if (!payload.isNullOrEmpty()) {
            try {
                startFrpc(SecureStringCodec.decrypt(payload), payload)
            } catch (e: Exception) {
                Log.e("FrpEngine", "unable to decrypt recovery configuration", e)
                saveRunning(false, null)
                deleteRuntimeConfig(this)
            }
        }
    }

    /** frpc 意外退出后延迟自动重启（节流：10 秒内不重复启动） */
    private fun scheduleRestart() {
        if (restartPending) return
        if (System.currentTimeMillis() - lastStartMs < 10_000) return
        restartPending = true
        Handler(Looper.getMainLooper()).postDelayed({
            restartPending = false
            restoreIfNeeded()
        }, 3_000)
    }

    fun startFrpc(configContent: String?, encryptedPayload: String? = null): Boolean {
        stopFrpcInternal(clearRunningIntent = true, deleteConfig = true)
        val frpc = frpcBinary()
        if (!frpc.exists() || configContent.isNullOrBlank() ||
            configContent.toByteArray(Charsets.UTF_8).size > MAX_CONFIG_BYTES
        ) {
            sendStatus("server", "error", "frpc binary or config missing")
            deleteRuntimeConfig(this)
            return false
        }
        return try {
            val resolv = File(filesDir, "resolv.conf")
            resolv.writeText(
                "nameserver 8.8.8.8\nnameserver 114.114.114.114\nnameserver 1.1.1.1\n"
            )
            // STUN 域名解析为 IP（Android 上 Go DNS 走 [::1]:53 会被拒）
            val patchedCfg = configContent.replace(
                Regex("natHoleStunServer = \"([^\"]+)\"")
            ) { m ->
                val original = m.groupValues[1]
                val host = original.substringBefore(':')
                val port = original.substringAfter(':', "3478")
                val resolved = try {
                    InetAddress.getByName(host).hostAddress ?: host
                } catch (e: Exception) {
                    host
                }
                "natHoleStunServer = \"$resolved:$port\""
            }
            val cfgFile = writeRuntimeConfig(patchedCfg)
            val pb = ProcessBuilder(frpc.absolutePath, "-c", cfgFile.absolutePath)
            pb.environment()["GODEBUG"] = "netdns=go"
            pb.environment()["RES_OPTIONS"] = "ndots:1"
            pb.environment()["RESOLV_CONF"] = resolv.absolutePath
            pb.redirectErrorStream(true)
            val process = pb.start()
            frpcProcess = process
            frpcPid = pidOf(process)
            lastStartMs = System.currentTimeMillis()
            Log.d("FrpEngine", "frpc started, pid=$frpcPid")
            synchronized(logsLock) { logs.clear() }
            check(saveRunning(true, encryptedPayload ?: SecureStringCodec.encrypt(configContent))) {
                "unable to persist encrypted recovery configuration"
            }
            updateNotification("FRPC 正在运行")
            sendStatus("server", "connecting", "Starting frpc...")

            readerThread = Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(process.inputStream))
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        line?.let {
                            deleteRuntimeConfig(this)
                            onFrpcLine(it)
                        }
                    }
                } catch (e: Exception) {
                }
            }.apply { start() }

            monitorThread = Thread {
                try {
                    val code = process.waitFor()
                    if (frpcProcess === process) {
                        frpcProcess = null
                        frpcPid = -1
                        deleteRuntimeConfig(this)
                        // 意外退出：保留 was_running（用户运行意图），延迟自动重启
                        sendStatus("server", "disconnected", "frpc exited ($code)")
                        sendAppReset()
                        scheduleRestart()
                    }
                } catch (e: Exception) {
                    // ignore
                }
            }.apply { start() }
            Handler(Looper.getMainLooper()).postDelayed({
                if (frpcProcess === process && process.isAlive) deleteRuntimeConfig(this)
            }, 10_000)
            true
        } catch (e: Exception) {
            Log.e("FrpEngine", "start failed", e)
            sendStatus("server", "error", "Failed to start frpc")
            stopFrpcInternal(clearRunningIntent = true, deleteConfig = true)
            false
        }
    }

    /** 用户主动停止：停止 frpc 并退出前台服务 */
    fun stopFrpc() {
        stopFrpcInternal(clearRunningIntent = true, deleteConfig = true)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    fun readLogs(): String = synchronized(logsLock) { logs.joinToString("\n") }

    /** 应用内存占用：Flutter 进程 RSS + frpc 子进程 RSS（MB） */
    fun getMemoryMb(): Double {
        val appRss = rssMb(android.os.Process.myPid())
        val frpcRss = if (frpcPid > 0) rssMb(frpcPid) else 0.0
        return appRss + frpcRss
    }

    // ---- 内部实现 ----

    private fun frpcBinary(): File = File(applicationInfo.nativeLibraryDir, "libfrpc.so")

    private fun stopFrpcInternal(clearRunningIntent: Boolean, deleteConfig: Boolean) {
        val process = frpcProcess
        // 先清空引用，防止 monitorThread 把主动停止误判为异常退出。
        frpcProcess = null
        frpcPid = -1
        process?.let { p ->
            try {
                p.destroy()
                p.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
                if (p.isAlive) p.destroyForcibly()
            } catch (e: Exception) {
                // ignore
            }
        }
        restartPending = false
        if (clearRunningIntent) saveRunning(false, null)
        if (deleteConfig) deleteRuntimeConfig(this)
        sendStatus("server", "disconnected", "")
        sendAppReset()
    }

    /// 网络变化监听：网络恢复时立即尝试恢复连接
    private fun registerNetworkMonitor() {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            if (Build.VERSION.SDK_INT >= 24) {
                networkCallback = object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        Handler(Looper.getMainLooper()).post {
                            if (!restartPending) restoreIfNeeded()
                        }
                    }
                }
                cm.registerDefaultNetworkCallback(networkCallback!!)
            } else {
                networkReceiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context?, intent: Intent?) {
                        Handler(Looper.getMainLooper()).post {
                            if (!restartPending) restoreIfNeeded()
                        }
                    }
                }
                @Suppress("DEPRECATION")
                registerReceiver(
                    networkReceiver,
                    IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION)
                )
            }
        } catch (e: Exception) {
            // ignore
        }
    }

    private fun unregisterNetworkMonitor() {
        try {
            networkCallback?.let {
                getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it)
            }
            networkReceiver?.let {
                @Suppress("DEPRECATION")
                unregisterReceiver(it)
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

    private fun saveRunning(running: Boolean, encryptedPayload: String?): Boolean {
        val editor = getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(KEY_WAS_RUNNING, running)
            .remove(KEY_PENDING_START_ID)
        if (running && !encryptedPayload.isNullOrEmpty()) {
            editor.putString(KEY_LAST_CONFIG_PAYLOAD, encryptedPayload)
        } else {
            editor.remove(KEY_LAST_CONFIG_PAYLOAD)
        }
        return editor.commit()
    }

    private fun onFrpcLine(raw: String) {
        val line = redactLogLine(raw.replace(Regex("\u001B\\[[;\\d]*m"), ""))
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
        Handler(Looper.getMainLooper()).post {
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
        appStatuses[name] = type
        val ch = channel ?: return
        Handler(Looper.getMainLooper()).post {
            try {
                ch.invokeMethod("onAppStatus", mapOf("name" to name, "type" to type))
            } catch (e: Exception) {
            }
        }
    }

    private fun sendAppReset() {
        appStatuses.clear()
        val ch = channel ?: return
        Handler(Looper.getMainLooper()).post {
            try {
                ch.invokeMethod("onAppStatus", mapOf("name" to "", "type" to "reset"))
            } catch (e: Exception) {
            }
        }
    }

    /** channel 挂载后重放当前状态，保证仪表盘与后台实际连接同步 */
    fun syncToChannel() {
        val ch = channel ?: return
        Handler(Looper.getMainLooper()).post {
            try {
                serverStatus?.let { (type, detail) ->
                    ch.invokeMethod(
                        "onStatus",
                        mapOf("scope" to "server", "type" to type, "detail" to detail)
                    )
                }
                appStatuses.forEach { (name, type) ->
                    ch.invokeMethod("onAppStatus", mapOf("name" to name, "type" to type))
                }
            } catch (e: Exception) {
            }
        }
    }

    private fun sendLog(line: String) {
        val ch = channel ?: return
        Handler(Looper.getMainLooper()).post {
            try {
                ch.invokeMethod("onLog", line)
            } catch (e: Exception) {
            }
        }
    }

    /// 读取 /proc/<pid>/statm 的 resident 页数，换算为 MB
    private fun rssMb(pid: Int): Double {
        return try {
            val statm = File("/proc/$pid/statm").readText().trim().split(Regex("\\s+"))
            val residentPages = statm.getOrNull(1)?.toLongOrNull() ?: 0L
            residentPages * 4096.0 / 1024.0 / 1024.0
        } catch (e: Exception) {
            0.0
        }
    }

    /// 兼容 API < 26 获取 Process pid（反射，避免直接调用 API 26 的 Process.pid()）
    private fun pidOf(p: Process?): Int {
        if (p == null) return -1
        return try {
            val m = Process::class.java.getMethod("pid")
            m.invoke(p) as Int
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
        val pi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
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
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(content))
    }
}
