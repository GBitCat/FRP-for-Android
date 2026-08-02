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
            serverConfigDao.saveServerConfig(config.copy(updatedAt = System.currentTimeMillis()))
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
    
    suspend fun updateActiveStatus(id: Long, isActive: Boolean) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateActiveStatus(id, isActive)
        }
    }
    
    suspend fun updateGroupActiveStatus(groupId: Long, isActive: Boolean) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateGroupActiveStatus(groupId, isActive)
        }
    }
    
    suspend fun getActiveConfig(): FrpConfig? {
        return withContext(Dispatchers.IO) {
            frpConfigDao.getActiveConfig()
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
    
    suspend fun updateAllActiveStatus(isActive: Boolean) {
        withContext(Dispatchers.IO) {
            frpConfigDao.updateAllActiveStatus(isActive)
        }
    }
}
