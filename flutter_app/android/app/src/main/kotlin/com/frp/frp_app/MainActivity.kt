package com.frp.frp_app

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.NetworkInterface

/**
 * 主界面：MethodChannel 桥接 Dart 与 FrpcService。
 * frpc 进程由 FrpcService（前台服务）管理，保证后台驻留；
 * Activity 销毁时不停 frpc（连接保持），仅在用户主动开关时停止。
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var secureChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.frp.app/engine"
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val configContent = call.argument<String>("configContent")
                        result.success(FrpcService.start(this, configContent))
                    }
                    "stop" -> {
                        FrpcService.stop(this)
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
                    "getMemoryMb" -> result.success(
                        FrpcService.instance?.getMemoryMb() ?: getFallbackMemoryMb()
                    )
                    "getTotalMemoryMb" -> result.success(getTotalMemoryMb())
                    "readLogs" -> result.success(FrpcService.instance?.readLogs() ?: "")
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        secureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.frp.app/secure_store"
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "encrypt" -> result.success(
                            SecureStringCodec.encrypt(requireNotNull(call.argument("value")))
                        )
                        "decrypt" -> result.success(
                            SecureStringCodec.decrypt(requireNotNull(call.argument("value")))
                        )
                        "encryptBackup" -> result.success(
                            BackupCipher.encrypt(
                                requireNotNull(call.argument<ByteArray>("data")),
                                requireNotNull(call.argument<String>("password")),
                            )
                        )
                        "decryptBackup" -> result.success(
                            BackupCipher.decrypt(
                                requireNotNull(call.argument<ByteArray>("data")),
                                requireNotNull(call.argument<String>("password")),
                            )
                        )
                        else -> result.notImplemented()
                    }
                } catch (e: IllegalArgumentException) {
                    result.error("INVALID_ARGUMENT", e.message, null)
                } catch (e: Exception) {
                    result.error("SECURE_STORAGE_ERROR", e.message, null)
                }
            }
        }
        // 挂载状态推送通道（服务持有，Activity 存活期间推送），并重放当前状态
        FrpcService.channel = channel
        FrpcService.instance?.syncToChannel()
    }

    override fun onStart() {
        super.onStart()
        FrpcService.channel = channel
        FrpcService.instance?.syncToChannel()
        // 健康检查后按需启动：服务/frpc 正常时不重复 start（避免回 App 时重启 frpc 断连）
        FrpcService.ensureRunning(this)
        // Android 13+：请求通知权限（前台服务通知需要）
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun onDestroy() {
        // 不停 frpc：进程由 FrpcService 托管，Activity 销毁不影响后台连接
        FrpcService.channel = null
        secureChannel?.setMethodCallHandler(null)
        super.onDestroy()
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

    /// 设备实际物理内存（MB），作为内存占用进度条的 100% 参考上限
    private fun getTotalMemoryMb(): Double {
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            mi.totalMem / 1024.0 / 1024.0
        } catch (e: Exception) {
            0.0
        }
    }

    /// 服务未启动时的兜底：仅 Flutter 进程 RSS
    private fun getFallbackMemoryMb(): Double {
        return try {
            val statm = File("/proc/${android.os.Process.myPid()}/statm")
                .readText().trim().split(Regex("\\s+"))
            val residentPages = statm.getOrNull(1)?.toLongOrNull() ?: 0L
            residentPages * 4096.0 / 1024.0 / 1024.0
        } catch (e: Exception) {
            0.0
        }
    }
}
