package com.frp.app.manager

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class ConnectionType {
    UNKNOWN,    // 未连接 / 连接中
    CONNECTED,  // 已连到 frps（服务端连接成功）
    P2P,        // XTCP 直连
    RELAY,      // STCP 中转
    ERROR       // 配置错误 / 连接失败
}

data class ConnectionStatus(
    val type: ConnectionType = ConnectionType.UNKNOWN,
    val detail: String = ""
)

/**
 * 连接状态解析器（全局单例）：解析 frpc 日志，识别 P2P / 中转 / 错误。
 *
 * Service 与 UI 共享同一实例，避免重复解析、重复日志与状态竞争。
 * Service 启动 FRP 时调用 [start]，停止时调用 [stop] + [reset]。
 */
class ConnectionStatusParser private constructor() {

    companion object {
        private const val TAG = "ConnStatus"
        private val ANSI_REGEX = Regex("\u001B\\[[;\\d]*m")

        @Volatile
        private var INSTANCE: ConnectionStatusParser? = null

        fun getInstance(): ConnectionStatusParser =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: ConnectionStatusParser().also { INSTANCE = it }
            }
    }

    private val _status = MutableStateFlow(ConnectionStatus())
    val status: StateFlow<ConnectionStatus> = _status.asStateFlow()
    
    // 每个应用（visitor）各自的连接状态：visitor 名 -> 状态
    private val _appStatuses = MutableStateFlow<Map<String, ConnectionStatus>>(emptyMap())
    val appStatuses: StateFlow<Map<String, ConnectionStatus>> = _appStatuses.asStateFlow()
    
    // 服务端连接状态（frpc ↔ frps）：未启动/连接中/已连接/失败
    private val _serverStatus = MutableStateFlow(ConnectionStatus(ConnectionType.UNKNOWN, "No connection"))
    val serverStatus: StateFlow<ConnectionStatus> = _serverStatus.asStateFlow()

    private var lastLogCount = 0
    private var collectJob: Job? = null

    /** 开始监听日志；重复调用会先取消旧监听再重新开始（保留已解析进度，不重复解析旧日志） */
    @Synchronized
    fun start(logManager: LogManager, scope: CoroutineScope) {
        collectJob?.cancel()
        collectJob = scope.launch(Dispatchers.Default) {
            logManager.logs.collect { logs ->
                // 日志被清空后重新基线
                if (logs.size < lastLogCount) lastLogCount = 0
                if (logs.size > lastLogCount) {
                    val newLogs = logs.drop(lastLogCount)
                    lastLogCount = logs.size
                    parseNewLogs(newLogs)
                }
            }
        }
    }

    /** 停止监听（FRP 停止时调用） */
    @Synchronized
    fun stop() {
        collectJob?.cancel()
        collectJob = null
    }

    /** 重置当前状态（FRP 停止时调用） */
    fun reset() {
        _status.value = ConnectionStatus()
        _appStatuses.value = emptyMap()
        _serverStatus.value = ConnectionStatus(ConnectionType.UNKNOWN, "No connection")
    }

    private fun parseNewLogs(logs: List<LogEntry>) {
        for (log in logs) {
            if (log.tag != "frpc") continue
            val msg = log.message.replace(ANSI_REGEX, "")

            // === 服务端连接状态 ===
            when {
                msg.contains("login to server success", ignoreCase = true) ->
                    _serverStatus.value = ConnectionStatus(ConnectionType.CONNECTED, "Connected to server")
                msg.contains("try to connect to server", ignoreCase = true) ->
                    _serverStatus.value = ConnectionStatus(ConnectionType.UNKNOWN, "Connecting to server...")
                msg.contains("login to the server failed", ignoreCase = true) ||
                    msg.contains("connect to server error", ignoreCase = true) ->
                    _serverStatus.value = ConnectionStatus(ConnectionType.ERROR, "Server connection failed")
            }

            // 提取事件前的 visitor 名（日志格式：[runid] [visitorName] event...）
            fun visitorName(vararg keywords: String): String? {
                for (kw in keywords) {
                    val m = Regex("\\[([^\\]]+)\\] $kw").find(msg)
                    if (m != null) return m.groupValues[1]
                }
                return null
            }

            // === XTCP P2P 成功（按应用标记） ===
            val p2pName = visitorName(
                "establishing nat hole connection successful",
                "nathole traffic",
                "punch hole", "punch ok"
            )
            if (p2pName != null) {
                setAppStatus(p2pName, ConnectionType.P2P, "P2P via XTCP")
                aggregateGlobal()
                continue
            }

            // === XTCP 打洞失败 → 回落中继（按应用标记） ===
            val failName = visitorName(
                "nathole prepare error", "nathole precheck error",
                "make hole error", "init tunnel session error",
                "open tunnel error"
            )
            if (failName != null) {
                setAppStatus(failName, ConnectionType.RELAY, "XTCP failed, relay via STCP")
                aggregateGlobal()
                continue
            }

            // === 配置错误：serverName 不匹配 ===
            if (msg.contains("doesn't exist", ignoreCase = true)) {
                val nameMatch = Regex("for \\[(.+?)\\]").find(msg)
                val badName = nameMatch?.groupValues?.get(1) ?: "unknown"
                setAppStatus(badName, ConnectionType.ERROR, "Server proxy '$badName' not found")
                aggregateGlobal()
                continue
            }

            // === STCP 中转成功（全局） ===
            if (msg.contains("connection established", ignoreCase = true) && msg.contains("stcp", ignoreCase = true)) {
                updateStatus(ConnectionType.RELAY, "Relay via STCP")
                continue
            }

            // === visitor 启动：初始化各应用状态 ===
            val addedMatch = Regex("visitor added: \\[([^\\]]+)\\]").find(msg)
            if (addedMatch != null) {
                val names = addedMatch.groupValues[1].split(" ").filter { it.isNotBlank() }
                val map = _appStatuses.value.toMutableMap()
                names.forEach { name -> map.putIfAbsent(name, ConnectionStatus(ConnectionType.UNKNOWN, "Connecting...")) }
                _appStatuses.value = map
                aggregateGlobal()
                continue
            }

            // === 兜底：全局状态更新（无名字事件，保持原语义） ===
            when {
                msg.contains("nathole traffic", ignoreCase = true) ->
                    updateStatus(ConnectionType.P2P, "P2P via XTCP")
                msg.contains("connection established", ignoreCase = true) && msg.contains("xtcp", ignoreCase = true) ->
                    updateStatus(ConnectionType.P2P, "P2P via XTCP")
                msg.contains("open tunnel timeout", ignoreCase = true) && msg.contains("xtcp", ignoreCase = true) ->
                    if (_status.value.type != ConnectionType.ERROR) updateStatus(ConnectionType.RELAY, "XTCP timeout, relay via STCP")
                msg.contains("nathole precheck error", ignoreCase = true) ->
                    if (_status.value.type != ConnectionType.ERROR) updateStatus(ConnectionType.RELAY, "XTCP precheck failed, using STCP relay")
                msg.contains("local tcp connection", ignoreCase = true) && msg.contains("stcp", ignoreCase = true) ->
                    updateStatus(ConnectionType.RELAY, "Relay via STCP")
                msg.contains("start visitor success", ignoreCase = true) ->
                    if (_status.value.type == ConnectionType.UNKNOWN) {
                        _status.value = ConnectionStatus(ConnectionType.UNKNOWN, "Connecting...")
                    }
            }
        }
    }

    /** 设置单个应用（visitor）的连接状态 */
    private fun setAppStatus(name: String, type: ConnectionType, detail: String) {
        if (name.isBlank()) return
        val map = _appStatuses.value.toMutableMap()
        map[name] = ConnectionStatus(type, detail)
        _appStatuses.value = map
        Log.d(TAG, "App status [$name]: $type - $detail")
    }

    /** 聚合全局状态：ERROR 优先 > P2P > RELAY > UNKNOWN */
    private fun aggregateGlobal() {
        val apps = _appStatuses.value.values
        val global = when {
            apps.any { it.type == ConnectionType.ERROR } -> ConnectionStatus(ConnectionType.ERROR, "One or more configs error")
            apps.any { it.type == ConnectionType.P2P } -> ConnectionStatus(ConnectionType.P2P, "P2P via XTCP")
            apps.any { it.type == ConnectionType.RELAY } -> ConnectionStatus(ConnectionType.RELAY, "Relay via STCP")
            apps.isNotEmpty() -> ConnectionStatus(ConnectionType.UNKNOWN, "Connecting...")
            else -> ConnectionStatus()
        }
        if (global != _status.value) {
            _status.value = global
            Log.d(TAG, "Connection status: ${global.type} - ${global.detail}")
        }
    }

    private fun updateStatus(type: ConnectionType, detail: String) {
        val old = _status.value
        if (old.type != type || old.detail != detail) {
            _status.value = ConnectionStatus(type, detail)
            Log.d(TAG, "Connection status: $type - $detail")
        }
    }
}
