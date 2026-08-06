package com.frp.frp_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
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
import java.util.concurrent.CopyOnWriteArrayList

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
        private const val KEY_LAST_CONFIG = "last_config_path"

        @Volatile
        var instance: FrpcService? = null

        /**
         * 静态状态推送通道：由 MainActivity 挂载。
         * 与服务的启动时序解耦——服务启动前/后设置都有效，避免推送丢失。
         */
        @Volatile
        var channel: MethodChannel? = null

        fun start(context: Context) {
            val intent = Intent(context, FrpcService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
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
                val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
                if (prefs.getBoolean(KEY_WAS_RUNNING, false)) {
                    start(context)
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
    private val logs = CopyOnWriteArrayList<String>()

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        startForeground(NOTIF_ID, buildNotification("FRPC 正在运行"))
        // 开机自启 / 进程重建：仅在冷启动时自动恢复一次。
        // 重复 start（如每次回到 App）不得重启 frpc，否则会造成连接瞬间断开。
        if (!restored) {
            restored = true
            restoreIfNeeded()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        instance = null
        stopFrpcInternal()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ---- 对外接口（MainActivity 调用） ----

    /** frpc 进程是否存活 */
    fun isFrpcRunning(): Boolean =
        frpcProcess?.isAlive == true

    /** 上次连接在运行但当前 frpc 未运行 → 自动恢复 */
    fun restoreIfNeeded() {
        if (isFrpcRunning()) return
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_WAS_RUNNING, false)) return
        val cfg = prefs.getString(KEY_LAST_CONFIG, null)
        if (!cfg.isNullOrEmpty() && File(cfg).exists()) {
            startFrpc(cfg)
        }
    }

    fun startFrpc(configPath: String?): Boolean {
        stopFrpcInternal()
        val frpc = frpcBinary()
        if (!frpc.exists() || configPath.isNullOrEmpty() || !File(configPath).exists()) {
            sendStatus("server", "error", "frpc binary or config missing")
            return false
        }
        return try {
            val resolv = File(filesDir, "resolv.conf")
            resolv.writeText(
                "nameserver 8.8.8.8\nnameserver 114.114.114.114\nnameserver 1.1.1.1\n"
            )
            // STUN 域名解析为 IP（Android 上 Go DNS 走 [::1]:53 会被拒）
            val cfgFile = File(configPath)
            val cfgText = cfgFile.readText()
            val patchedCfg = cfgText.replace(
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
            if (patchedCfg != cfgText) cfgFile.writeText(patchedCfg)
            val pb = ProcessBuilder(frpc.absolutePath, "-c", configPath)
            pb.environment()["GODEBUG"] = "netdns=go"
            pb.environment()["RES_OPTIONS"] = "ndots:1"
            pb.environment()["RESOLV_CONF"] = resolv.absolutePath
            pb.redirectErrorStream(true)
            val process = pb.start()
            frpcProcess = process
            frpcPid = pidOf(process)
            Log.d("FrpEngine", "frpc started, pid=$frpcPid")
            logs.clear()
            saveRunning(true, configPath)
            updateNotification("FRPC 正在运行")
            sendStatus("server", "connecting", "Starting frpc...")

            readerThread = Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(process.inputStream))
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        line?.let { onFrpcLine(it) }
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
                        saveRunning(false, null)
                        sendStatus("server", "disconnected", "frpc exited ($code)")
                        sendAppReset()
                    }
                } catch (e: Exception) {
                    // ignore
                }
            }.apply { start() }
            true
        } catch (e: Exception) {
            Log.e("FrpEngine", "start failed", e)
            sendStatus("server", "error", "Failed to start frpc")
            false
        }
    }

    /** 用户主动停止：停止 frpc 并退出前台服务 */
    fun stopFrpc() {
        stopFrpcInternal()
        stopSelf()
    }

    fun readLogs(): String = logs.joinToString("\n")

    /** 应用内存占用：Flutter 进程 RSS + frpc 子进程 RSS（MB） */
    fun getMemoryMb(): Double {
        val appRss = rssMb(android.os.Process.myPid())
        val frpcRss = if (frpcPid > 0) rssMb(frpcPid) else 0.0
        val total = appRss + frpcRss
        Log.d("FrpEngine", "memory: app=${"%.1f".format(appRss)} frpc=$frpcPid:${"%.1f".format(frpcRss)} total=${"%.1f".format(total)}")
        return total
    }

    // ---- 内部实现 ----

    private fun frpcBinary(): File = File(applicationInfo.nativeLibraryDir, "libfrpc.so")

    private fun stopFrpcInternal() {
        frpcProcess?.let { p ->
            try {
                p.destroy()
                p.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
                if (p.isAlive) p.destroyForcibly()
            } catch (e: Exception) {
                // ignore
            }
        }
        frpcProcess = null
        frpcPid = -1
        saveRunning(false, null)
        sendStatus("server", "disconnected", "")
        sendAppReset()
    }

    private fun saveRunning(running: Boolean, configPath: String?) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(KEY_WAS_RUNNING, running)
            .putString(KEY_LAST_CONFIG, configPath)
            .apply()
    }

    private fun onFrpcLine(raw: String) {
        val line = raw.replace(Regex("\u001B\\[[;\\d]*m"), "")
        logs.add(line)
        if (logs.size > 2000) logs.removeAt(0)
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
                msg.contains("punch ok", ignoreCase = true) ->
                sendAppStatus(extractName(msg), "p2p")
            msg.contains("nathole prepare error", ignoreCase = true) ||
                msg.contains("make hole error", ignoreCase = true) ||
                msg.contains("nathole precheck error", ignoreCase = true) ->
                sendAppStatus(extractName(msg), "relay")
            msg.contains("doesn't exist", ignoreCase = true) ->
                sendAppStatus(extractName(msg), "error")

            msg.contains("connection established", ignoreCase = true) &&
                msg.contains("stcp", ignoreCase = true) ->
                sendStatus("app", "relay", "Relay via STCP")
            msg.contains("connection established", ignoreCase = true) &&
                msg.contains("xtcp", ignoreCase = true) ->
                sendStatus("app", "p2p", "P2P via XTCP")
        }
    }

    private fun extractName(msg: String): String {
        val m = Regex("\\[([^\\]]+)\\] (establishing|nathole|punch|make hole|open tunnel|for)")
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
