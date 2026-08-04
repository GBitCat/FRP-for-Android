package com.frp.app.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.io.BufferedReader
import java.io.InputStreamReader

class ConfigImportExport(private val context: Context) {
    
    companion object {
        private const val TAG = "ConfigImportExport"
        private const val EXPORT_FILENAME = "frp_configs.json"
    }
    
    private val gson = Gson()
    
    // 导出配置到JSON（包含 Server 配置）
    fun exportAll(configs: List<FrpConfig>, server: ServerConfig?): String {
        return gson.toJson(ExportData(configs = configs, server = server))
    }
    
    // 从JSON导入配置（兼容新格式 ExportData 与旧格式 List<FrpConfig>）
    fun importAll(json: String): ExportData? {
        return try {
            val trimmed = json.trim()
            if (trimmed.startsWith("{")) {
                gson.fromJson(trimmed, ExportData::class.java)
            } else {
                // 旧格式：纯配置列表
                val type = object : TypeToken<List<FrpConfig>>() {}.type
                val configs = gson.fromJson<List<FrpConfig>>(trimmed, type)
                ExportData(configs = configs ?: emptyList())
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error importing configs", e)
            null
        }
    }
    
    // 导出配置到JSON（旧接口，仅配置列表）
    fun exportConfigs(configs: List<FrpConfig>): String {
        return gson.toJson(configs)
    }
    
    // 从JSON导入配置（旧接口）
    fun importConfigs(json: String): List<FrpConfig>? {
        return importAll(json)?.configs
    }
    
    // 从URI读取配置
    fun readConfigFromUri(uri: Uri): String? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { inputStream ->
                BufferedReader(InputStreamReader(inputStream)).use { reader ->
                    reader.readText()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error reading config from URI", e)
            null
        }
    }
    
    // 写入配置到URI
    fun writeConfigToUri(uri: Uri, json: String): Boolean {
        return try {
            context.contentResolver.openOutputStream(uri)?.use { outputStream ->
                outputStream.write(json.toByteArray())
                outputStream.flush()
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error writing config to URI", e)
            false
        }
    }
    
    // 生成导入Intent (打开文件)
    fun createImportIntent(): Intent {
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
        }
    }
    
    // 生成导出Intent (保存文件) - 使用SAF让用户选择保存位置
    fun createExportIntent(): Intent {
        return Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, EXPORT_FILENAME)
        }
    }
    
    // 解析旧版frpc配置文件格式
    fun parseFrpcConfig(configText: String): FrpConfig? {
        return try {
            val lines = configText.lines()
            var name = ""
            var serverAddr = ""
            var serverPort = 7000
            var token: String? = null
            var localIp = "127.0.0.1"
            var localPort = 0
            var remotePort = 0
            var protocol = "tcp"
            
            var currentSection = ""
            
            for (line in lines) {
                val trimmed = line.trim()
                if (trimmed.startsWith("#") || trimmed.isEmpty()) continue
                
                // TOML 值去引号（"value" 或 'value'）
                fun unquote(v: String): String = v.trim().removeSurrounding("\"").removeSurrounding("'")
                
                when {
                    trimmed.startsWith("[") && trimmed.endsWith("]") -> {
                        currentSection = trimmed.substring(1, trimmed.length - 1)
                    }
                    // TOML 顶层键：serverAddr / serverPort / auth.token
                    currentSection.isEmpty() && trimmed.startsWith("serverAddr") -> {
                        serverAddr = unquote(trimmed.substringAfter("="))
                    }
                    currentSection.isEmpty() && trimmed.startsWith("serverPort") -> {
                        serverPort = unquote(trimmed.substringAfter("=")).toIntOrNull() ?: 7000
                    }
                    currentSection.isEmpty() && trimmed.startsWith("auth.token") -> {
                        token = unquote(trimmed.substringAfter("="))
                    }
                    currentSection == "common" -> {
                        when {
                            trimmed.startsWith("server_addr") -> {
                                serverAddr = unquote(trimmed.split("=").getOrNull(1) ?: "")
                            }
                            trimmed.startsWith("server_port") -> {
                                serverPort = unquote(trimmed.split("=").getOrNull(1) ?: "").toIntOrNull() ?: 7000
                            }
                            trimmed.startsWith("token") -> {
                                token = unquote(trimmed.split("=").getOrNull(1) ?: "")
                            }
                        }
                    }
                    currentSection.isNotEmpty() && currentSection != "common" -> {
                        name = currentSection
                        when {
                            trimmed.startsWith("type") -> {
                                protocol = unquote(trimmed.split("=").getOrNull(1) ?: "") ?: "tcp"
                            }
                            trimmed.startsWith("local_ip") -> {
                                localIp = unquote(trimmed.split("=").getOrNull(1) ?: "") ?: "127.0.0.1"
                            }
                            trimmed.startsWith("local_port") -> {
                                localPort = unquote(trimmed.split("=").getOrNull(1) ?: "").toIntOrNull() ?: 0
                            }
                            trimmed.startsWith("remote_port") -> {
                                remotePort = unquote(trimmed.split("=").getOrNull(1) ?: "").toIntOrNull() ?: 0
                            }
                        }
                    }
                }
            }
            
            if (name.isNotEmpty() && serverAddr.isNotEmpty() && localPort > 0 && remotePort > 0) {
                FrpConfig(
                    name = name,
                    serverAddr = serverAddr,
                    serverPort = serverPort,
                    token = token,
                    localIp = localIp,
                    localPort = localPort,
                    remotePort = remotePort,
                    protocol = protocol
                )
            } else {
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing frpc config", e)
            null
        }
    }
}


/** 导出数据：Server 配置 + 应用配置列表（version 用于未来格式兼容） */
data class ExportData(
    val version: Int = 1,
    val server: ServerConfig? = null,
    val configs: List<FrpConfig> = emptyList()
)
