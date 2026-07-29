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
    var serverAddr: String = "",
    var serverPort: Int = 7000,
    var token: String = "",
    var updatedAt: Long = System.currentTimeMillis()
) {
    fun isValid(): Boolean = serverAddr.isNotBlank() && serverPort in 1..65535
}
