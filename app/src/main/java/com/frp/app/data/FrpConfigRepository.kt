package com.frp.app.data

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class FrpConfigRepository(
    private val frpConfigDao: FrpConfigDao,
    private val serverConfigDao: ServerConfigDao
) {
    
    val allConfigs: Flow<List<FrpConfig>> = frpConfigDao.getAllConfigs()
    val ungroupedConfigs: Flow<List<FrpConfig>> = frpConfigDao.getUngroupedConfigs()
    val groupPrimaryConfigs: Flow<List<FrpConfig>> = frpConfigDao.getGroupPrimaryConfigs()
    
    // 全局服务器连接配置
    val serverConfig: Flow<ServerConfig?> = serverConfigDao.getServerConfig()
    
    suspend fun getServerConfig(): ServerConfig? {
        return withContext(Dispatchers.IO) {
            serverConfigDao.getServerConfigSync()
        }
    }
    
    suspend fun saveServerConfig(config: ServerConfig) {
        withContext(Dispatchers.IO) {
            val old = serverConfigDao.getServerConfigSync()
            val withId = if (config.serverId.isBlank()) {
                config.copy(serverId = generateServerId())
            } else {
                config
            }
            serverConfigDao.saveServerConfig(withId.copy(updatedAt = System.currentTimeMillis()))
            // Server 保存后同步已有配置归属：未选择或旧 id 的配置跟随新 id，
            // 保证 Server 预览能正确拼接隶属应用
            val oldId = old?.serverId ?: ""
            if (oldId != withId.serverId || old == null) {
                frpConfigDao.reassignServerId(withId.serverId, oldId)
            }
        }
    }
    
    /** 生成 8 位字母数字 Server ID（仅用于应用归属标识） */
    private fun generateServerId(): String = ServerConfig.generateId()
    
    suspend fun getAllConfigsSync(): List<FrpConfig> {
        return withContext(Dispatchers.IO) {
            frpConfigDao.getAllConfigsSync()
        }
    }
    
    suspend fun getConfigById(id: Long): FrpConfig? {
        return withContext(Dispatchers.IO) {
            frpConfigDao.getConfigById(id)
        }
    }
    
    suspend fun getConfigsByGroupId(groupId: Long): List<FrpConfig> {
        return withContext(Dispatchers.IO) {
            frpConfigDao.getConfigsByGroupId(groupId)
        }
    }
    
    suspend fun insertConfig(config: FrpConfig): Long {
        return withContext(Dispatchers.IO) {
            frpConfigDao.insertConfig(config)
        }
    }
    
    suspend fun updateConfig(config: FrpConfig) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateConfig(config.copy(updatedAt = System.currentTimeMillis()))
        }
    }
    
    suspend fun deleteConfig(config: FrpConfig) {
        withContext(Dispatchers.IO) {
            frpConfigDao.deleteConfig(config)
        }
    }
    
    suspend fun deleteGroup(groupId: Long) {
        withContext(Dispatchers.IO) {
            frpConfigDao.deleteGroup(groupId)
        }
    }
    
    suspend fun updateRunningStatus(id: Long, running: Boolean) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateRunningStatus(id, running)
        }
    }
    
    suspend fun updateGroupRunningStatus(groupId: Long, running: Boolean) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateGroupRunningStatus(groupId, running)
        }
    }
    
    suspend fun getRunningConfig(): FrpConfig? {
        return withContext(Dispatchers.IO) {
            frpConfigDao.getRunningConfig()
        }
    }
    
    suspend fun getEnabledConfigs(): List<FrpConfig> {
        return withContext(Dispatchers.IO) {
            frpConfigDao.getEnabledConfigsSync()
        }
    }
    
    suspend fun updateEnabled(id: Long, enabled: Boolean) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateEnabled(id, enabled)
        }
    }
    
    suspend fun updateGroupEnabled(groupId: Long, enabled: Boolean) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateGroupEnabled(groupId, enabled)
        }
    }
    
    suspend fun updateGroupName(groupId: Long, name: String) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateGroupName(groupId, name)
        }
    }
    
    suspend fun renameStcpConfig(oldName: String, newName: String) {
        withContext(Dispatchers.IO) {
            frpConfigDao.renameStcpConfig(oldName, newName)
        }
    }
    
    suspend fun updateAllRunningStatus(running: Boolean) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateAllRunningStatus(running)
        }
    }
}
