package com.frp.app.manager

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class ConnectionType {
    UNKNOWN,    // 未连接
    P2P,        // XTCP 直连
    RELAY,      // STCP 中转
    ERROR       // 配置错误
}

data class ConnectionStatus(
    val type: ConnectionType = ConnectionType.UNKNOWN,
    val detail: String = ""
)

class ConnectionStatusParser(
    private val logManager: LogManager,
    private val scope: CoroutineScope
) {
    companion object {
        private const val TAG = "ConnStatus"
        private val ANSI_REGEX = Regex("\u001B\\[[;\\d]*m")
    }

    private val _status = MutableStateFlow(ConnectionStatus())
    val status: StateFlow<ConnectionStatus> = _status.asStateFlow()

    private var lastLogCount = 0

    init {
        scope.launch(Dispatchers.Default) {
            logManager.logs.collect { logs ->
                if (logs.size > lastLogCount) {
                    val newLogs = logs.drop(lastLogCount)
                    lastLogCount = logs.size
                    parseNewLogs(newLogs)
                }
            }
        }
    }

    private fun parseNewLogs(logs: List<LogEntry>) {
        for (log in logs) {
            if (log.tag != "frpc") continue
            val msg = log.message.replace(ANSI_REGEX, "")

            // === XTCP P2P 成功 ===
            if (msg.contains("nathole traffic", ignoreCase = true)) {
                updateStatus(ConnectionType.P2P, "P2P via XTCP")
                continue
            }
            if (msg.contains("connection established", ignoreCase = true) && msg.contains("xtcp", ignoreCase = true)) {
                updateStatus(ConnectionType.P2P, "P2P via XTCP")
                continue
            }
            if (msg.contains("punch hole", ignoreCase = true) || msg.contains("punch ok", ignoreCase = true)) {
                updateStatus(ConnectionType.P2P, "P2P via XTCP")
                continue
            }

            // === 配置错误：serverName 不匹配 ===
            if (msg.contains("doesn't exist", ignoreCase = true)) {
                // "xtcp server for [xxx] doesn't exist" 或 "custom listener for [xxx] doesn't exist"
                val nameMatch = Regex("for \\[(.+?)\\]").find(msg)
                val badName = nameMatch?.groupValues?.get(1) ?: "unknown"
                updateStatus(ConnectionType.ERROR, "Server proxy '$badName' not found - check Server Proxy Name")
                continue
            }

            // === XTCP 失败 → STCP fallback ===
            if (msg.contains("open tunnel timeout", ignoreCase = true) && msg.contains("xtcp", ignoreCase = true)) {
                // 只有在没有更具体的错误时才显示通用超时
                if (_status.value.type != ConnectionType.ERROR) {
                    updateStatus(ConnectionType.RELAY, "XTCP timeout, relay via STCP")
                }
                continue
            }
            if (msg.contains("nathole precheck error", ignoreCase = true)) {
                if (_status.value.type != ConnectionType.ERROR) {
                    updateStatus(ConnectionType.RELAY, "XTCP precheck failed, using STCP relay")
                }
                continue
            }

            // === STCP 中转成功 ===
            if (msg.contains("connection established", ignoreCase = true) && msg.contains("stcp", ignoreCase = true)) {
                updateStatus(ConnectionType.RELAY, "Relay via STCP")
                continue
            }
            if (msg.contains("local tcp connection", ignoreCase = true) && msg.contains("stcp", ignoreCase = true)) {
                updateStatus(ConnectionType.RELAY, "Relay via STCP")
                continue
            }

            // visitor 启动
            if (msg.contains("start visitor success", ignoreCase = true)) {
                if (_status.value.type == ConnectionType.UNKNOWN) {
                    _status.value = ConnectionStatus(ConnectionType.UNKNOWN, "Connecting...")
                }
            }
        }
    }

    private fun updateStatus(type: ConnectionType, detail: String) {
        val old = _status.value
        if (old.type != type || old.detail != detail) {
            _status.value = ConnectionStatus(type, detail)
            Log.d(TAG, "Connection status: $type - $detail")
        }
    }

    fun reset() {
        lastLogCount = 0
        _status.value = ConnectionStatus()
    }
}
