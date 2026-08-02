package com.frp.app.data

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "frp_configs")
data class FrpConfig(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val name: String,
    // 已废弃：服务器连接配置已独立为全局 ServerConfig，此字段仅为兼容旧数据保留
    val serverAddr: String = "",
    val serverPort: Int = 7000,
    val token: String? = null,
    val localIp: String = "127.0.0.1",
    val localPort: Int,
    val remotePort: Int = 0,
    val protocol: String = "tcp",
    
    // STCP/XTCP 特有配置
    val role: String = "visitor",
    val secretKey: String? = null,
    val serverName: String? = null,
    val bindPort: Int = 0,
    val bindAddr: String = "127.0.0.1",
    
    // 传输加密/压缩（需与对端 frpc 的 transport 配置一致；XTCP P2P 直连两端必须一致）
    val useEncryption: Boolean = false,
    val useCompression: Boolean = false,
    
    // XTCP 回落配置
    val useFallback: Boolean = false,
    val fallbackTo: String = "",
    val fallbackTimeoutMs: Int = 3000,
    val useCustomStcp: Boolean = false,
    
    // STCP Fallback 自定义配置
    val stcpName: String = "",
    val stcpSecretKey: String = "",
    val stcpServerName: String = "",
    val stcpBindPort: Int = -1,
    val stcpBindAddr: String = "127.0.0.1",
    
    // 分组配置
    val groupId: Long = 0,           // 分组ID，0表示无分组
    val groupName: String = "",      // 分组名称
    val isGroupPrimary: Boolean = false, // 是否是分组中的主配置（XTCP）
    
    val linkedConfigId: Long = 0,
    
    // 启用开关：enabled 的配置会被拼接到统一 TOML，随服务端连接一起启动
    val enabled: Boolean = true,
    
    val isActive: Boolean = false,
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis()
) {
    companion object {
        val PROTOCOLS = listOf("tcp", "udp", "http", "https", "stcp", "sudp", "xtcp")
        val SECRET_PROTOCOLS = listOf("stcp", "sudp", "xtcp")
        
        fun needsSecretKey(protocol: String): Boolean = protocol.lowercase() in SECRET_PROTOCOLS
        fun supportsFallback(protocol: String): Boolean = protocol.lowercase() == "xtcp"
    }
    
    fun needsSecretKey(): Boolean = needsSecretKey(protocol)
    fun isVisitor(): Boolean = role == "visitor"
    fun supportsFallback(): Boolean = supportsFallback(protocol)
    fun isInGroup(): Boolean = groupId > 0
}
