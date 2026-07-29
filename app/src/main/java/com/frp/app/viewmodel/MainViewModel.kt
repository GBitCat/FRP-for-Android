package com.frp.app.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.frp.app.data.AppDatabase
import com.frp.app.data.FrpConfig
import com.frp.app.data.FrpConfigRepository
import com.frp.app.data.FrpStatus
import com.frp.app.data.FrpStatusHolder
import com.frp.app.data.ServerConfig
import com.frp.app.manager.ConnectionStatusParser
import com.frp.app.manager.FrpManager
import com.frp.app.service.FrpService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

// 分组配置数据类
data class ConfigGroup(
    val groupId: Long,
    val groupName: String,
    val primaryConfig: FrpConfig,
    val subConfigs: List<FrpConfig> = emptyList(),
    val isActive: Boolean = false
)

class MainViewModel(application: Application) : AndroidViewModel(application) {
    
    private val database = AppDatabase.getDatabase(application)
    private val repository = FrpConfigRepository(database.frpConfigDao(), database.serverConfigDao())
    private val frpManager = FrpManager(application)
    private val connectionStatusParser = ConnectionStatusParser(FrpService.logManager, viewModelScope)
    val connectionStatus = connectionStatusParser.status
    
    val allConfigs = repository.allConfigs
    
    // 全局服务器连接配置
    val serverConfig = repository.serverConfig
    
    // 运行状态由 Service 维护（RUNNING/STOPPED/ERROR），ViewModel 只订阅
    val frpStatus: StateFlow<FrpStatus> = FrpStatusHolder.status
    private val _isRunning = MutableStateFlow(false)
    val isRunning: StateFlow<Boolean> = _isRunning.asStateFlow()
    
    private val _activeConfigId = MutableStateFlow<Long?>(null)
    val activeConfigId: StateFlow<Long?> = _activeConfigId.asStateFlow()
    
    // 分组配置列表
    private val _configGroups = MutableStateFlow<List<ConfigGroup>>(emptyList())
    val configGroups: StateFlow<List<ConfigGroup>> = _configGroups.asStateFlow()
    
    init {
        checkRunningStatus()
        loadConfigGroups()
    }
    
    private fun checkRunningStatus() {
        viewModelScope.launch {
            frpStatus.collect { status ->
                _isRunning.value = (status == FrpStatus.RUNNING)
                if (status != FrpStatus.RUNNING) {
                    _activeConfigId.value = null
                } else {
                    val activeConfig = repository.getActiveConfig()
                    _activeConfigId.value = activeConfig?.id
                }
            }
        }
    }
    
    private fun loadConfigGroups() {
        viewModelScope.launch {
            allConfigs.collect { configs ->
                val groups = mutableListOf<ConfigGroup>()
                val processedGroupIds = mutableSetOf<Long>()
                
                // 处理有分组的配置
                configs.filter { it.isInGroup() }.forEach { config ->
                    if (config.groupId !in processedGroupIds) {
                        processedGroupIds.add(config.groupId)
                        val groupConfigs = configs.filter { it.groupId == config.groupId }
                        val primary = groupConfigs.find { it.isGroupPrimary } ?: groupConfigs.first()
                        groups.add(
                            ConfigGroup(
                                groupId = config.groupId,
                                groupName = config.groupName,
                                primaryConfig = primary,
                                subConfigs = groupConfigs.filter { it.id != primary.id },
                                isActive = groupConfigs.any { it.isActive }
                            )
                        )
                    }
                }
                
                // 处理无分组的配置
                configs.filter { !it.isInGroup() }.forEach { config ->
                    groups.add(
                        ConfigGroup(
                            groupId = 0,
                            groupName = "",
                            primaryConfig = config,
                            subConfigs = emptyList(),
                            isActive = config.isActive
                        )
                    )
                }
                
                _configGroups.value = groups
            }
        }
    }
    
    fun startFrp(configId: Long) {
        FrpService.startService(getApplication(), configId)
        _activeConfigId.value = configId
    }
    
    fun startGroup(groupId: Long) {
        viewModelScope.launch {
            val groupConfigs = repository.getConfigsByGroupId(groupId)
            // 启动主配置（XTCP）
            val primary = groupConfigs.find { it.isGroupPrimary } ?: groupConfigs.first()
            startFrp(primary.id)
        }
    }
    
    fun stopFrp() {
        FrpService.stopService(getApplication())
        connectionStatusParser.reset()
    }
    
    suspend fun getConfigById(id: Long): FrpConfig? {
        return repository.getConfigById(id)
    }
    
    fun addConfig(config: FrpConfig): Long {
        var configId = 0L
        viewModelScope.launch {
            configId = repository.insertConfig(config)
        }
        return configId
    }
    
    fun updateConfig(config: FrpConfig) {
        viewModelScope.launch {
            repository.updateConfig(config)
        }
    }
    
    fun deleteConfig(config: FrpConfig) {
        viewModelScope.launch {
            repository.deleteConfig(config)
        }
    }
    
    fun deleteGroup(groupId: Long) {
        viewModelScope.launch {
            repository.deleteGroup(groupId)
        }
    }
    
    fun saveServerConfig(config: ServerConfig) {
        viewModelScope.launch {
            repository.saveServerConfig(config)
        }
    }
    
    fun setActiveConfig(configId: Long) {
        viewModelScope.launch {
            val activeConfig = repository.getActiveConfig()
            activeConfig?.let {
                repository.updateActiveStatus(it.id, false)
            }
            repository.updateActiveStatus(configId, true)
            _activeConfigId.value = configId
        }
    }
    
    override fun onCleared() {
        super.onCleared()
        frpManager.cleanup()
    }
}
