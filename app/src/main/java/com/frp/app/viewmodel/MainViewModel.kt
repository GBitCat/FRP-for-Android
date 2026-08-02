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
    val isActive: Boolean = false,
    val enabled: Boolean = true
)

class MainViewModel(application: Application) : AndroidViewModel(application) {
    
    private val database = AppDatabase.getDatabase(application)
    private val repository = FrpConfigRepository(database.frpConfigDao(), database.serverConfigDao())
    private val frpManager = FrpManager(application)
    private val connectionStatusParser = ConnectionStatusParser.getInstance()
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
                                isActive = groupConfigs.any { it.isActive },
                                enabled = groupConfigs.any { it.enabled }
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
                            isActive = config.isActive,
                            enabled = config.enabled
                        )
                    )
                }
                
                _configGroups.value = groups
            }
        }
    }
    
    // 全局启动：拼接所有已启用配置，一次启动全部使用
    fun startAll() {
        FrpService.startService(getApplication())
        viewModelScope.launch {
            val configs = repository.getEnabledConfigs()
            _activeConfigId.value = configs.firstOrNull()?.id
        }
    }
    
    fun stopFrp() {
        FrpService.stopService(getApplication())
        connectionStatusParser.reset()
    }
    
    suspend fun getConfigById(id: Long): FrpConfig? {
        return repository.getConfigById(id)
    }
    
    fun addConfig(config: FrpConfig) {
        viewModelScope.launch {
            repository.insertConfig(config)
        }
    }
    
    // 顺序插入多个配置（保证分组主/子配置插入顺序稳定）
    fun addConfigs(configs: List<FrpConfig>) {
        viewModelScope.launch {
            configs.forEach { repository.insertConfig(it) }
        }
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
    
    // 分组启用开关：切换组内全部配置
    fun setGroupEnabled(groupId: Long, enabled: Boolean) {
        viewModelScope.launch {
            repository.updateGroupEnabled(groupId, enabled)
        }
    }
    
    // 单个配置启用开关
    fun setConfigEnabled(configId: Long, enabled: Boolean) {
        viewModelScope.launch {
            repository.updateEnabled(configId, enabled)
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
