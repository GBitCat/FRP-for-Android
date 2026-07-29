package com.frp.app.data

import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Dao
interface FrpConfigDao {
    @Query("SELECT * FROM frp_configs ORDER BY updatedAt DESC")
    fun getAllConfigs(): Flow<List<FrpConfig>>
    
    @Query("SELECT * FROM frp_configs ORDER BY updatedAt DESC")
    fun getAllConfigsSync(): List<FrpConfig>
    
    // 获取无分组的配置
    @Query("SELECT * FROM frp_configs WHERE groupId = 0 ORDER BY updatedAt DESC")
    fun getUngroupedConfigs(): Flow<List<FrpConfig>>
    
    // 获取所有分组的主配置
    @Query("SELECT * FROM frp_configs WHERE isGroupPrimary = 1 ORDER BY updatedAt DESC")
    fun getGroupPrimaryConfigs(): Flow<List<FrpConfig>>
    
    // 获取指定分组的所有配置
    @Query("SELECT * FROM frp_configs WHERE groupId = :groupId ORDER BY isGroupPrimary DESC")
    fun getConfigsByGroupId(groupId: Long): List<FrpConfig>
    
    @Query("SELECT * FROM frp_configs WHERE id = :id")
    fun getConfigById(id: Long): FrpConfig?
    
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertConfig(config: FrpConfig): Long
    
    @Update
    fun updateConfig(config: FrpConfig)
    
    @Delete
    fun deleteConfig(config: FrpConfig)
    
    @Query("DELETE FROM frp_configs WHERE groupId = :groupId")
    fun deleteGroup(groupId: Long)
    
    @Query("UPDATE frp_configs SET isActive = :isActive WHERE id = :id")
    fun updateActiveStatus(id: Long, isActive: Boolean)
    
    @Query("UPDATE frp_configs SET isActive = :isActive WHERE groupId = :groupId")
    fun updateGroupActiveStatus(groupId: Long, isActive: Boolean)
    
    @Query("SELECT * FROM frp_configs WHERE isActive = 1 LIMIT 1")
    fun getActiveConfig(): FrpConfig?
}
