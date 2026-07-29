package com.frp.app.manager

import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicLong

class TrafficStats {
    
    companion object {
        private const val TAG = "TrafficStats"
    }
    
    // 流量计数器
    private val totalBytesSent = AtomicLong(0)
    private val totalBytesReceived = AtomicLong(0)
    private val currentBytesSent = AtomicLong(0)
    private val currentBytesReceived = AtomicLong(0)
    
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
    
    // 记录发送流量
    fun recordSent(bytes: Long) {
        totalBytesSent.addAndGet(bytes)
        currentBytesSent.addAndGet(bytes)
        updateState()
    }
    
    // 记录接收流量
    fun recordReceived(bytes: Long) {
        totalBytesReceived.addAndGet(bytes)
        currentBytesReceived.addAndGet(bytes)
        updateState()
    }
    
    // 增加活跃连接数
    fun incrementConnections() {
        _activeConnections.value++
        _totalConnections.value++
        updateState()
    }
    
    // 减少活跃连接数
    fun decrementConnections() {
        if (_activeConnections.value > 0) {
            _activeConnections.value--
        }
        updateState()
    }
    
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
    
    // 重置统计
    fun reset() {
        totalBytesSent.set(0)
        totalBytesReceived.set(0)
        currentBytesSent.set(0)
        currentBytesReceived.set(0)
        _activeConnections.value = 0
        _totalConnections.value = 0
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
