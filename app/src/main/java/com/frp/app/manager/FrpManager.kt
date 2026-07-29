package com.frp.app.manager

import android.content.Context
import android.util.Log
import kotlinx.coroutines.*
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader

class FrpManager(private val context: Context) {
    
    private var frpcProcess: Process? = null
    private var logJob: Job? = null
    private var monitorJob: Job? = null
    private var onExitCallback: ((Int) -> Unit)? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    companion object {
        private const val TAG = "FrpManager"
        private const val FRPC_BINARY = "frpc"
        private const val FRPC_VERSION_FILE = "frpc_version"
    }
    
    fun isFrpcAvailable(): Boolean {
        val frpcFile = context.getFileStreamPath(FRPC_BINARY)
        return frpcFile.exists() && frpcFile.canExecute()
    }
    
    // 检查是否需要更新frpc
    fun needsUpdate(): Boolean {
        val versionFile = context.getFileStreamPath(FRPC_VERSION_FILE)
        if (!versionFile.exists()) return true
        
        val currentVersion = try {
            versionFile.readText().trim()
        } catch (e: Exception) {
            ""
        }
        
        // 从assets读取版本信息（这里简化为总是更新）
        return true
    }
    
    // frpc 已打包为 libfrpc.so 放在 jniLibs 中，系统自动解压到 nativeLibraryDir
    private fun getFrpcFile(): java.io.File {
        return java.io.File(context.applicationInfo.nativeLibraryDir, "libfrpc.so")
    }

    fun installFrpc(): Boolean {
        return try {
            // 二进制已通过 jniLibs 打包，无需从 assets 复制
            val frpcFile = getFrpcFile()
            if (!frpcFile.exists()) {
                Log.e(TAG, "libfrpc.so not found in nativeLibraryDir: " + frpcFile.absolutePath)
                return false
            }
            
            // 保存版本信息
            val versionFile = context.getFileStreamPath(FRPC_VERSION_FILE)
            versionFile.writeText("0.70.1")
            
            Log.d(TAG, "frpc ready at: " + frpcFile.absolutePath + " executable: " + frpcFile.canExecute())
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to install frpc", e)
            false
        }
    }
    
    fun startFrpc(configPath: String, onLog: (String) -> Unit, onExit: ((Int) -> Unit)? = null): Boolean {
        onExitCallback = onExit
        if (frpcProcess != null) {
            Log.w(TAG, "frpc is already running")
            return false
        }
        
        val frpcFile = getFrpcFile()
        if (!frpcFile.exists()) {
            Log.e(TAG, "frpc binary not found at: " + frpcFile.absolutePath)
            return false
        }
        Log.d(TAG, "Using frpc at: " + frpcFile.absolutePath)
        
        return try {
            // 写入自定义 resolv.conf，让 Go DNS 解析器使用公共 DNS（绕过 Android DNS 限制）
            val resolvConf = File(context.filesDir, "resolv.conf")
            resolvConf.writeText("nameserver 8.8.8.8\nnameserver 114.114.114.114\nnameserver 1.1.1.1\n")
            
            val processBuilder = ProcessBuilder(
                frpcFile.absolutePath,
                "-c", configPath
            )
            
            // 设置环境变量：强制 Go 使用纯 Go DNS 解析器 + 指定 resolv.conf 路径
            val env = processBuilder.environment()
            env["GODEBUG"] = "netdns=go"
            env["RES_OPTIONS"] = "ndots:1"
            // 部分 Go 版本支持自定义 resolv.conf 路径
            env["RESOLV_CONF"] = resolvConf.absolutePath
            
            processBuilder.redirectErrorStream(true)
            frpcProcess = processBuilder.start()
            
            logJob = scope.launch {
                try {
                    val reader = BufferedReader(InputStreamReader(frpcProcess!!.inputStream))
                    var line: String?
                    while (reader.readLine().also { line = it } != null) {
                        line?.let { onLog(it) }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading frpc output", e)
                }
            }
            
            // 监控进程退出（frpc异常退出视为错误状态）
            monitorJob = scope.launch {
                try {
                    val code = frpcProcess!!.waitFor()
                    Log.w(TAG, "frpc exited with code: $code")
                    onExitCallback?.invoke(code)
                } catch (e: Exception) {
                    Log.e(TAG, "Error monitoring frpc process", e)
                }
            }
            
            Log.d(TAG, "frpc started with config: $configPath")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start frpc", e)
            false
        }
    }
    
    fun stopFrpc() {
        onExitCallback = null
        monitorJob?.cancel()
        monitorJob = null
        logJob?.cancel()
        frpcProcess?.let { process ->
            try {
                process.destroy()
                process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
                if (process.isAlive) {
                    process.destroyForcibly()
                }
                Log.d(TAG, "frpc stopped")
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping frpc", e)
            }
        }
        frpcProcess = null
    }
    
    fun isRunning(): Boolean {
        return frpcProcess?.isAlive == true
    }
    
    fun cleanup() {
        stopFrpc()
        scope.cancel()
    }
}
