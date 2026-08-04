package com.frp.app.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.io.BufferedReader
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStreamReader
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class ConfigImportExport(private val context: Context) {
    
    companion object {
        private const val TAG = "ConfigImportExport"
        private const val EXPORT_FILENAME = "frp_backup.zip"
        private val gson = Gson()
        
        /**
         * 构建导出 zip：frp_configs.json（server + 应用配置）+ frpc_all.toml（完整配置）。
         */
        fun buildExportZip(configs: List<FrpConfig>, server: ServerConfig?, toml: String): ByteArray {
            val baos = ByteArrayOutputStream()
            ZipOutputStream(baos).use { zos ->
                zos.putNextEntry(ZipEntry("frp_configs.json"))
                zos.write(gson.toJson(ExportData(configs = configs, server = server)).toByteArray())
                zos.closeEntry()
                zos.putNextEntry(ZipEntry("frpc_all.toml"))
                zos.write(toml.toByteArray())
                zos.closeEntry()
            }
            return baos.toByteArray()
        }
        
        /**
         * 解析导入内容：zip 包（取其中 .json）或纯 JSON 文本。
         */
        fun parseImportBytes(bytes: ByteArray): ExportData? {
            return try {
                if (bytes.size > 4 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte()) {
                    ZipInputStream(ByteArrayInputStream(bytes)).use { zis ->
                        var entry = zis.nextEntry
                        while (entry != null) {
                            if (entry.name.endsWith(".json")) {
                                val json = zis.readBytes().toString(Charsets.UTF_8)
                                return importAll(json)
                            }
                            entry = zis.nextEntry
                        }
                        null
                    }
                } else {
                    importAll(String(bytes, Charsets.UTF_8))
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error parsing import bytes", e)
                null
            }
        }
        
        private fun importAll(json: String): ExportData? {
            return try {
                val trimmed = json.trim()
                if (trimmed.startsWith("{")) {
                    gson.fromJson(trimmed, ExportData::class.java)
                } else {
                    val type = object : TypeToken<List<FrpConfig>>() {}.type
                    val configs = gson.fromJson<List<FrpConfig>>(trimmed, type)
                    ExportData(configs = configs ?: emptyList())
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error importing configs", e)
                null
            }
        }
    }
    
    private val gson: Gson = Gson()
    
    // 导出配置到JSON（包含 Server 配置）
    fun exportAll(configs: List<FrpConfig>, server: ServerConfig?): String {
        return gson.toJson(ExportData(configs = configs, server = server))
    }
    
    // 从JSON导入配置（兼容新格式 ExportData 与旧格式 List<FrpConfig>）
    fun importAll(json: String): ExportData? = ConfigImportExport.importAll(json)
    
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
        return writeBytesToUri(uri, json.toByteArray())
    }
    
    // 写入原始字节到URI（zip 导出用）
    fun writeBytesToUri(uri: Uri, bytes: ByteArray): Boolean {
        return try {
            context.contentResolver.openOutputStream(uri)?.use { outputStream ->
                outputStream.write(bytes)
                outputStream.flush()
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error writing to URI", e)
            false
        }
    }
    
    // 从URI读取原始字节（zip 导入用）
    fun readBytesFromUri(uri: Uri): ByteArray? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Exception) {
            Log.e(TAG, "Error reading bytes from URI", e)
            null
        }
    }
    
    // 生成导入Intent (打开文件，支持 json / zip)
    fun createImportIntent(): Intent {
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "application/zip"))
        }
    }
    
    // 生成导出Intent (保存 zip) - 使用SAF让用户选择保存位置
    fun createExportIntent(): Intent {
        return Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/zip"
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
