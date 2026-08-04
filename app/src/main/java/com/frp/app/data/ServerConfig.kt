package com.frp.app.data

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * 全局 FRP 服务器连接配置（单行存储，id 固定为 1）
 * serverAddr / serverPort / token 从各代理配置中独立出来，
 * 启动时与应用配置拼接生成完整 frpc TOML。
 */
@Entity(tableName = "server_config")
data class ServerConfig(
    @PrimaryKey
    var id: Int = 1,
    // 配置区可修改的命名（仪表盘 Server 卡片显示用）
    var name: String = "FRPS Server",
    // 8 位 Server ID（仅用于应用配置归属标识，不参与 TOML 生成）
    var serverId: String = "",
    var serverAddr: String = "",
    var serverPort: Int = 7000,
    var token: String = "",
    var updatedAt: Long = System.currentTimeMillis(),
    
    // 连接 frps 的 transport 配置（与 frpc 全局 transport 段对应）
    var protocol: String = "tcp",            // tcp / kcp / quic / ws / wss
    var tcpMux: Boolean = true,              // TCP 多路复用
    var heartbeatInterval: Int = 30,         // 心跳间隔（秒）
    var heartbeatTimeout: Int = 90,          // 心跳超时（秒）
    var tcpMuxKeepaliveInterval: Int = 30    // TCP 多路复用保活间隔（秒）
) {
    fun isValid(): Boolean = serverAddr.isNotBlank() && serverPort in 1..65535
}
