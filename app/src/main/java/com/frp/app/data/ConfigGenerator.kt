package com.frp.app.data

import android.content.Context
import java.io.File

class ConfigGenerator(private val context: Context) {
    
    fun generateProxyConfig(config: FrpConfig): String {
        return buildString {
            when (config.protocol.lowercase()) {
                "stcp", "sudp", "xtcp" -> {
                    if (config.isVisitor()) {
                        appendLine("[[visitors]]")
                        appendLine("name = \"${config.name}\"")
                        appendLine("type = \"${config.protocol}\"")
                        appendLine("serverName = \"${config.serverName ?: ""}\"")
                        config.secretKey?.takeIf { it.isNotBlank() }?.let {
                            appendLine("secretKey = \"$it\"")
                        }
                        if (config.bindPort != -1) {
                            appendLine("bindAddr = \"${config.bindAddr}\"")
                        }
                        appendLine("bindPort = ${config.bindPort}")
                        if (config.protocol == "xtcp" && config.useFallback && config.fallbackTo.isNotBlank()) {
                            appendLine("fallbackTo = \"${config.fallbackTo}\"")
                            appendLine("fallbackTimeoutMs = ${config.fallbackTimeoutMs}")
                        }
                    } else {
                        appendLine("[[proxies]]")
                        appendLine("name = \"${config.name}\"")
                        appendLine("type = \"${config.protocol}\"")
                        appendLine("localIP = \"${config.localIp}\"")
                        appendLine("localPort = ${config.localPort}")
                        config.secretKey?.takeIf { it.isNotBlank() }?.let {
                            appendLine("secretKey = \"$it\"")
                        }
                    }
                }
                else -> {
                    appendLine("[[proxies]]")
                    appendLine("name = \"${config.name}\"")
                    appendLine("type = \"${config.protocol}\"")
                    appendLine("localIP = \"${config.localIp}\"")
                    appendLine("localPort = ${config.localPort}")
                    if (config.remotePort > 0) {
                        appendLine("remotePort = ${config.remotePort}")
                    }
                }
            }
        }
    }
    
    /**
     * 生成完整 frpc 配置：全局服务器连接配置 + 应用代理/visitor 配置拼接
     */
    fun generateFullConfig(server: ServerConfig, config: FrpConfig, linkedConfig: FrpConfig? = null): String {
        return buildString {
            appendLine("serverAddr = \"${server.serverAddr}\"")
            appendLine("serverPort = ${server.serverPort}")
            server.token.takeIf { it.isNotBlank() }?.let {
                appendLine("auth.token = \"$it\"")
            }
            // STUN server with IP address to bypass Android DNS limitation
            appendLine("natHoleStunServer = \"74.125.24.127:19302\"")
            appendLine()
            
            if (linkedConfig != null) {
                appendLine("# Fallback STCP visitor")
                append(generateProxyConfig(linkedConfig))
                appendLine()
                appendLine("# Primary XTCP visitor")
                append(generateProxyConfig(config))
            } else {
                append(generateProxyConfig(config))
            }
        }
    }
    
    fun createLinkedStcpConfig(xtcpConfig: FrpConfig): FrpConfig {
        val stcpName = "${xtcpConfig.name}-stcp"
        return FrpConfig(
            name = stcpName,
            localIp = xtcpConfig.localIp,
            localPort = xtcpConfig.localPort,
            protocol = "stcp",
            role = "visitor",
            secretKey = xtcpConfig.secretKey,
            serverName = xtcpConfig.stcpServerName.ifBlank { xtcpConfig.serverName?.replace("xtcp", "stcp") ?: "" },
            bindPort = -1,
            bindAddr = ""
        )
    }
    
    fun saveConfigFile(server: ServerConfig, config: FrpConfig, linkedConfig: FrpConfig? = null): File {
        val configContent = generateFullConfig(server, config, linkedConfig)
        val configFile = context.getFileStreamPath("frpc_${config.id}.toml")
        configFile.writeText(configContent)
        return configFile
    }
    
    fun readConfigFile(configId: Long): String? {
        val configFile = context.getFileStreamPath("frpc_$configId.toml")
        return if (configFile.exists()) configFile.readText() else null
    }
    
    fun deleteConfigFile(configId: Long): Boolean {
        val configFile = context.getFileStreamPath("frpc_$configId.toml")
        return if (configFile.exists()) configFile.delete() else false
    }
    
    fun validateConfig(config: FrpConfig): String? {
        if (config.name.isBlank()) return "Name is required"
        
        when (config.protocol.lowercase()) {
            "stcp", "sudp", "xtcp" -> {
                if (config.isVisitor()) {
                    if (config.serverName.isNullOrBlank()) return "Server name is required for visitor"
                    if (config.bindPort <= 0 && config.bindPort != -1) return "Bind port is required for visitor"
                } else {
                    if (config.localPort <= 0) return "Local port is required"
                }
            }
            else -> {
                if (config.localPort <= 0) return "Local port is required"
                if (config.remotePort <= 0) return "Remote port is required"
            }
        }
        
        return null
    }
    
    fun validateServerConfig(server: ServerConfig): String? {
        if (server.serverAddr.isBlank()) return "Server address is required"
        if (server.serverPort !in 1..65535) return "Server port is invalid"
        return null
    }
}
