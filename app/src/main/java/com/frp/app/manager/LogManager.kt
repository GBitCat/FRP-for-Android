package com.frp.app.manager

import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.ConcurrentLinkedQueue

class LogManager {
    
    companion object {
        private const val TAG = "LogManager"
        private const val MAX_LOG_LINES = 1000
    }
    
    private val logQueue = ConcurrentLinkedQueue<LogEntry>()
    
    private val _logs = MutableStateFlow<List<LogEntry>>(emptyList())
    val logs: StateFlow<List<LogEntry>> = _logs.asStateFlow()
    
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.getDefault())
    
    // 添加日志
    fun addLog(level: LogLevel, tag: String, message: String) {
        val entry = LogEntry(
            timestamp = System.currentTimeMillis(),
            level = level,
            tag = tag,
            message = message
        )
        
        logQueue.add(entry)
        
        // 限制日志数量
        while (logQueue.size > MAX_LOG_LINES) {
            logQueue.poll()
        }
        
        // 更新StateFlow
        _logs.value = logQueue.toList()
        
        // 同时输出到系统日志
        when (level) {
            LogLevel.DEBUG -> Log.d(tag, message)
            LogLevel.INFO -> Log.i(tag, message)
            LogLevel.WARN -> Log.w(tag, message)
            LogLevel.ERROR -> Log.e(tag, message)
        }
    }
    
    // 添加frpc日志
    fun addFrpLog(line: String) {
        val level = when {
            line.contains("[D]") || line.contains("DEBUG") -> LogLevel.DEBUG
            line.contains("[W]") || line.contains("WARN") -> LogLevel.WARN
            line.contains("[E]") || line.contains("ERROR") -> LogLevel.ERROR
            else -> LogLevel.INFO
        }
        
        addLog(level, "frpc", line)
    }
    
    // 清除日志
    fun clearLogs() {
        logQueue.clear()
        _logs.value = emptyList()
    }
    
    // 获取格式化的日志
    fun getFormattedLogs(): String {
        return logQueue.joinToString("\n") { entry ->
            "${dateFormat.format(Date(entry.timestamp))} [${entry.level}] ${entry.tag}: ${entry.message}"
        }
    }
    
    // 按级别过滤日志
    fun getLogsByLevel(level: LogLevel): List<LogEntry> {
        return logQueue.filter { it.level == level }
    }
}

data class LogEntry(
    val timestamp: Long,
    val level: LogLevel,
    val tag: String,
    val message: String
) {
    fun getFormattedTimestamp(): String {
        return SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date(timestamp))
    }
}

enum class LogLevel {
    DEBUG,
    INFO,
    WARN,
    ERROR
}
