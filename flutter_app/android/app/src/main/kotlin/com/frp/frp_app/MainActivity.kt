package com.frp.frp_app

import android.Manifest
import android.app.ActivityManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.NetworkInterface
import java.util.Arrays
import java.util.Collections
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** Runs or cancels an owned secure operation while invoking cleanup exactly once. */
internal class CancellableSecureTask(
    private val operation: () -> Unit,
    private val cleanup: () -> Unit,
) : Runnable {
    private val claimed = AtomicBoolean(false)

    override fun run() {
        if (!claimed.compareAndSet(false, true)) return
        try {
            operation()
        } finally {
            cleanup()
        }
    }

    internal fun cancelBeforeRun(): Boolean {
        if (!claimed.compareAndSet(false, true)) return false
        cleanup()
        return true
    }
}

internal fun cancelQueuedSecureTasks(tasks: List<Runnable>): Int =
    tasks.filterIsInstance<CancellableSecureTask>().count { it.cancelBeforeRun() }

object ScreenCapturePolicy {
    fun shouldProtect(applicationFlags: Int): Boolean =
        (applicationFlags and ApplicationInfo.FLAG_DEBUGGABLE) == 0
}

/**
 * 主界面：MethodChannel 桥接 Dart 与 FrpcService。
 * frpc 进程由 FrpcService（前台服务）管理，保证后台驻留；
 * Activity 销毁时不停 frpc（连接保持），仅在用户主动开关时停止。
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var secureChannel: MethodChannel? = null
    private var documentIoBridge: DocumentIoBridge? = null
    private val clipboardHandler = Handler(Looper.getMainLooper())
    private val secureExecutor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "frp-secure-bridge").apply { isDaemon = true }
    }
    private val secureResults = Collections.synchronizedSet(mutableSetOf<MainThreadResult>())
    private var sensitiveClipSequence = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (ScreenCapturePolicy.shouldProtect(applicationInfo.flags)) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        documentIoBridge = DocumentIoBridge(this, flutterEngine.dartExecutor.binaryMessenger)
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
                        result.success(FrpcService.stop(this))
                    }
                    "isRunRequested" -> result.success(FrpcService.isRunRequested(this))
                    "getInitialTab" -> result.success(intent?.getIntExtra("initial_tab", -1) ?: -1)
                    "getTlsStorageRoot" -> {
                        try {
                            val directory = File(noBackupFilesDir, "tls")
                            check(directory.exists() || directory.mkdirs()) {
                                "unable to create certificate storage"
                            }
                            check(
                                directory.isDirectory &&
                                    !OsConstants.S_ISLNK(Os.lstat(directory.path).st_mode),
                            ) {
                                "certificate storage is unsafe"
                            }
                            result.success(directory.canonicalPath)
                        } catch (error: Exception) {
                            result.error(
                                "TLS_STORAGE_UNAVAILABLE",
                                error.message ?: "certificate storage is unavailable",
                                null,
                            )
                        }
                    }
                    "setExcludeFromRecents" -> {
                        try {
                            applyExcludeFromRecents(call.argument<Boolean>("exclude") ?: false)
                            result.success(true)
                        } catch (_: Exception) {
                            result.error(
                                "RECENTS_UPDATE_FAILED",
                                "Unable to update recent-app visibility",
                                null,
                            )
                        }
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
                        "encrypt" -> submitSecureOperation(result) {
                            SecureStringCodec.encrypt(
                                requireNotNull(call.argument<String>("value")),
                            )
                        }
                        "decrypt" -> submitSecureOperation(result) {
                            SecureStringCodec.decrypt(
                                requireNotNull(call.argument<String>("value")),
                            )
                        }
                        "encryptBackup" -> submitBackupOperation(call, result) { data, password ->
                            BackupCipher.encrypt(data, password)
                        }
                        "decryptBackup" -> submitBackupOperation(call, result) { data, password ->
                            BackupCipher.decrypt(data, password)
                        }
                        "copySensitiveText" -> {
                            copySensitiveText(requireNotNull(call.argument("value")))
                            result.success(null)
                        }
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
        cancelQueuedSecureTasks(secureExecutor.shutdownNow())
        val resultsToCancel = synchronized(secureResults) { secureResults.toList() }
        resultsToCancel.forEach {
            it.error(
                "SECURE_STORAGE_CANCELLED",
                "Activity closed before the secure operation completed",
            )
        }
        documentIoBridge?.close()
        documentIoBridge = null
        super.onDestroy()
    }

    @Deprecated("Deprecated in Android API; required for Storage Access Framework results")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (documentIoBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    /** 引导用户取消本应用的电池优化/省电策略 */
    @android.annotation.SuppressLint("BatteryLife", "UseKtx")
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
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        for (task in am.appTasks) {
            task.setExcludeFromRecents(exclude)
        }
    }

    /** Marks credentials as sensitive and removes them from the clipboard after 60 seconds. */
    private fun copySensitiveText(value: String) {
        require(value.length <= 2 * 1024 * 1024) {
            "Clipboard content exceeds the 2 MiB limit"
        }
        val valueBytes = value.toByteArray(Charsets.UTF_8)
        try {
            require(valueBytes.size <= 2 * 1024 * 1024) {
                "Clipboard content exceeds the 2 MiB limit"
            }
        } finally {
            Arrays.fill(valueBytes, 0)
        }
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val sequence = ++sensitiveClipSequence
        val marker = "FRP sensitive data $sequence"
        val clip = ClipData.newPlainText(marker, value)
        if (Build.VERSION.SDK_INT >= 33) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
        }
        clipboard.setPrimaryClip(clip)
        clipboardHandler.postDelayed({
            if (sequence != sensitiveClipSequence) return@postDelayed
            if (clipboard.primaryClipDescription?.label?.toString() != marker) {
                return@postDelayed
            }
            if (Build.VERSION.SDK_INT >= 28) {
                clipboard.clearPrimaryClip()
            } else {
                clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
            }
        }, 60_000)
    }

    private fun submitSecureOperation(
        result: MethodChannel.Result,
        ownedByteArrays: List<ByteArray> = emptyList(),
        operation: () -> Any?,
    ) {
        lateinit var completion: MainThreadResult
        completion = MainThreadResult(result) { secureResults.remove(completion) }
        secureResults.add(completion)
        val task = CancellableSecureTask(
            operation = {
                try {
                    val value = operation()
                    completion.success(value) {
                        if (value is ByteArray) Arrays.fill(value, 0)
                    }
                } catch (error: IllegalArgumentException) {
                    completion.error("INVALID_ARGUMENT", error.message)
                } catch (error: Exception) {
                    completion.error("SECURE_STORAGE_ERROR", error.message)
                }
            },
            cleanup = {
                ownedByteArrays.forEach { bytes -> Arrays.fill(bytes, 0) }
            },
        )
        try {
            secureExecutor.execute(task)
        } catch (_: RejectedExecutionException) {
            task.cancelBeforeRun()
            completion.error(
                "SECURE_STORAGE_CANCELLED",
                "Activity is no longer available",
            )
        }
    }

    private fun submitBackupOperation(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
        operation: (ByteArray, String) -> ByteArray,
    ) {
        val data = requireNotNull(call.argument<ByteArray>("data"))
        var ownershipTransferred = false
        try {
            val password = requireNotNull(call.argument<String>("password"))
            // MethodChannel supplies an immutable JVM String. It cannot be
            // wiped in place, so bound it before queueing and avoid making
            // additional password copies; it becomes GC-eligible afterward.
            BackupCipher.validatePassword(password)
            submitSecureOperation(result, ownedByteArrays = listOf(data)) {
                operation(data, password)
            }
            ownershipTransferred = true
        } finally {
            if (!ownershipTransferred) Arrays.fill(data, 0)
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
        return ProcessMemory.rssMb(android.os.Process.myPid())
    }
}
