package com.frp.frp_app

import android.app.ActivityManager
import android.content.Intent
import android.content.Context
import android.net.Uri
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.concurrent.CopyOnWriteArrayList

/**
 * frpc 原生引擎：
 * - libfrpc.so 由 jniLibs 打包，系统解压到 nativeLibraryDir
 * - start: 写入 resolv.conf（绕过 Android DNS 限制）→ ProcessBuilder 启动 frpc -c config
 * - 日志解析：识别服务端连接 / XTCP P2P / STCP 回落 / 错误，通过 MethodChannel 推送 Dart
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var frpcProcess: Process? = null
    private var frpcPid: Int = -1
    private var readerThread: Thread? = null
    private var monitorThread: Thread? = null
    private val logs = CopyOnWriteArrayList<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.frp.app/engine"
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val configPath = call.argument<String>("configPath")
                        result.success(startFrpc(configPath))
                    }
                    "stop" -> {
                        stopFrpc()
                        result.success(true)
                    }
                    "getInitialTab" -> result.success(intent?.getIntExtra("initial_tab", -1) ?: -1)
                    "setExcludeFromRecents" -> {
                        applyExcludeFromRecents(call.argument<Boolean>("exclude") ?: false)
                        result.success(true)
                    }
                    "getVersionName" -> result.success(
                        try {
                            packageManager.getPackageInfo(packageName, 0).versionName
                        } catch (e: Exception) {
                            ""
                        }
                    )
                    "getIpv4" -> result.success(getIpv4())
                    "getIpv6" -> result.success(getIpv6())
                    "getMemoryMb" -> result.success(getMemoryMb())
                    "readLogs" -> result.success(logs.joinToString("\n"))
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** 引导用户取消本应用的电池优化/省电策略 */
    private fun requestIgnoreBatteryOptimizations() {
        try {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName"),
            )
            startActivity(intent)
        } catch (e: Exception) {
            // 部分设备不支持直接请求，退回电池优化设置列表
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (e2: Exception) {
                // ignore
            }
        }
    }

    /** 隐藏/恢复「最近任务」卡片 */
    private fun applyExcludeFromRecents(exclude: Boolean) {
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            for (task in am.appTasks) {
                task.setExcludeFromRecents(exclude)
            }
        } catch (e: Exception) {
            // ignore
        }
    }

    private fun frpcBinary(): File = File(applicationInfo.nativeLibraryDir, "libfrpc.so")

    private fun startFrpc(configPath: String?): Boolean {
        stopFrpc()
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

    private fun stopFrpc() {
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
        sendStatus("server", "disconnected", "")
        sendAppReset()
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
        val ch = channel
        runOnUiThread {
            ch?.invokeMethod(
                "onStatus",
                mapOf("scope" to scope, "type" to type, "detail" to detail)
            )
        }
    }

    private fun sendAppStatus(name: String, type: String) {
        if (name.isBlank()) return
        val ch = channel
        runOnUiThread {
            ch?.invokeMethod("onAppStatus", mapOf("name" to name, "type" to type))
        }
    }

    private fun sendAppReset() {
        val ch = channel
        runOnUiThread {
            ch?.invokeMethod("onAppStatus", mapOf("name" to "", "type" to "reset"))
        }
    }

    private fun sendLog(line: String) {
        val ch = channel
        runOnUiThread {
            ch?.invokeMethod("onLog", line)
        }
    }

    private fun getIpv4(): String? {
        return try {
            NetworkInterface.getNetworkInterfaces().toList()
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
                ?.hostAddress
        } catch (e: Exception) {
            null
        }
    }

    private fun getIpv6(): String? {
        return try {
            NetworkInterface.getNetworkInterfaces().toList()
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet6Address>()
                .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
                ?.hostAddress
        } catch (e: Exception) {
            null
        }
    }

    /// 应用内存占用（参考 FlClash）：
    /// Flutter 进程 RSS + frpc 子进程 RSS（MB）
    private fun getMemoryMb(): Double {
        val appRss = rssMb(android.os.Process.myPid())
        val frpcRss = if (frpcPid > 0) rssMb(frpcPid) else 0.0
        val total = appRss + frpcRss
        Log.d("FrpEngine", "memory: app=${"%.1f".format(appRss)} frpc=$frpcPid:${"%.1f".format(frpcRss)} total=${"%.1f".format(total)}")
        return total
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

    override fun onDestroy() {
        stopFrpc()
        super.onDestroy()
    }
}
