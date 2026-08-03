package com.frp.app.manager

import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicLong

class TrafficStats private constructor() {
    
    companion object {
        private const val TAG = "TrafficStats"
        
        @Volatile
        private var instance: TrafficStats? = null
        
        fun getInstance(): TrafficStats =
            instance ?: synchronized(this) {
                instance ?: TrafficStats().also { instance = it }
            }
    }
    
    // 是否启用流量统计（设置中可切换；禁用时不采样，消除轮询开销）
    private val _enabled = MutableStateFlow(false)
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()
    
    fun setEnabled(value: Boolean) {
        _enabled.value = value
    }
    
    // 流量计数器
    private val totalBytesSent = AtomicLong(0)
    private val totalBytesReceived = AtomicLong(0)
    private val currentBytesSent = AtomicLong(0)
    private val currentBytesReceived = AtomicLong(0)
    
    // UID 流量采样基准（上次采样值）
    private var lastSampleRx = -1L
    private var lastSampleTx = -1L
    
    // 连接统计峰值
    private var peakConnections = 0
    
    // 连接统计
    private val _activeConnections = MutableStateFlow(0)
    val activeConnections: StateFlow<Int> = _activeConnections.asStateFlow()
    
    private val _totalConnections = MutableStateFlow(0)
    val totalConnections: StateFlow<Int> = _totalConnections.asStateFlow()
    
    // 流量状态
    private val _trafficState = MutableStateFlow(TrafficState())
    val trafficState: StateFlow<TrafficState> = _trafficState.asStateFlow()
    
    // 上次更新时间
    private var lastUpdateTime = System.currentTimeMillis()
    
    // 更新状态
    private fun updateState() {
        val currentTime = System.currentTimeMillis()
        val timeDiff = (currentTime - lastUpdateTime) / 1000.0 // 转换为秒
        
        val uploadSpeed = if (timeDiff > 0) {
            currentBytesSent.get() / timeDiff
        } else {
            0.0
        }
        
        val downloadSpeed = if (timeDiff > 0) {
            currentBytesReceived.get() / timeDiff
        } else {
            0.0
        }
        
        _trafficState.value = TrafficState(
            totalSent = totalBytesSent.get(),
            totalReceived = totalBytesReceived.get(),
            currentSent = currentBytesSent.get(),
            currentReceived = currentBytesReceived.get(),
            uploadSpeed = uploadSpeed,
            downloadSpeed = downloadSpeed,
            activeConnections = _activeConnections.value,
            totalConnections = _totalConnections.value
        )
        
        // 重置当前计数器
        currentBytesSent.set(0)
        currentBytesReceived.set(0)
        lastUpdateTime = currentTime
    }
    
    /**
     * 采样 app UID 的累计网络流量（TrafficStats API，含 frpc 进程），
     * 与上次采样的差值喂入统计（驱动速度与总量）。每秒调用一次。
     */
    fun sampleUidTraffic(uid: Int) {
        val rx = android.net.TrafficStats.getUidRxBytes(uid)
        val tx = android.net.TrafficStats.getUidTxBytes(uid)
        if (rx > 0 && lastSampleRx >= 0 && rx >= lastSampleRx) {
            totalBytesReceived.addAndGet(rx - lastSampleRx)
            currentBytesReceived.addAndGet(rx - lastSampleRx)
        }
        if (tx > 0 && lastSampleTx >= 0 && tx >= lastSampleTx) {
            totalBytesSent.addAndGet(tx - lastSampleTx)
            currentBytesSent.addAndGet(tx - lastSampleTx)
        }
        lastSampleRx = rx
        lastSampleTx = tx
        // 总是刷新状态：有流量时计算速度，空闲时自动归零，保证实时更新
        updateState()
    }
    
    /**
     * 解析 /proc/net/tcp{,6} 统计当前 uid 的 ESTABLISHED TCP 连接数（实时活跃隧道数）。
     */
    fun sampleTcpConnections(uid: Int) {
        var count = 0
        for (path in listOf("/proc/net/tcp", "/proc/net/tcp6")) {
            try {
                val lines = java.io.File(path).readLines()
                for (line in lines.drop(1)) {
                    // sl local_address rem_address st tx_queue ... uid ...
                    val parts = line.trim().split(Regex("\\s+"))
                    if (parts.size >= 8 && parts[3] == "01" && parts[7].toIntOrNull() == uid) {
                        count++
                    }
                }
            } catch (_: Exception) {
                // 某些设备可能禁止读取
            }
        }
        _activeConnections.value = count
        if (count > peakConnections) peakConnections = count
        _totalConnections.value = peakConnections
    }
    
    // 重置统计
    fun reset() {
        totalBytesSent.set(0)
        totalBytesReceived.set(0)
        currentBytesSent.set(0)
        currentBytesReceived.set(0)
        _activeConnections.value = 0
        _totalConnections.value = 0
        peakConnections = 0
        lastSampleRx = -1
        lastSampleTx = -1
        lastUpdateTime = System.currentTimeMillis()
        updateState()
    }
    
    // 格式化字节数
    fun formatBytes(bytes: Long): String {
        return when {
            bytes < 1024 -> "$bytes B"
            bytes < 1024 * 1024 -> "${bytes / 1024} KB"
            bytes < 1024 * 1024 * 1024 -> "${"%.2f".format(bytes / (1024.0 * 1024.0))} MB"
            else -> "${"%.2f".format(bytes / (1024.0 * 1024.0 * 1024.0))} GB"
        }
    }
    
    // 格式化速度
    fun formatSpeed(bytesPerSecond: Double): String {
        return when {
            bytesPerSecond < 1024 -> "${"%.1f".format(bytesPerSecond)} B/s"
            bytesPerSecond < 1024 * 1024 -> "${"%.1f".format(bytesPerSecond / 1024)} KB/s"
            bytesPerSecond < 1024 * 1024 * 1024 -> "${"%.2f".format(bytesPerSecond / (1024.0 * 1024.0))} MB/s"
            else -> "${"%.2f".format(bytesPerSecond / (1024.0 * 1024.0 * 1024.0))} GB/s"
        }
    }
}

data class TrafficState(
    val totalSent: Long = 0,
    val totalReceived: Long = 0,
    val currentSent: Long = 0,
    val currentReceived: Long = 0,
    val uploadSpeed: Double = 0.0,
    val downloadSpeed: Double = 0.0,
    val activeConnections: Int = 0,
    val totalConnections: Int = 0
)
