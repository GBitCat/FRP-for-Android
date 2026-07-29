package com.frp.app.data

import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Dao
interface ServerConfigDao {
    @Query("SELECT * FROM server_config WHERE id = 1")
    fun getServerConfig(): Flow<ServerConfig?>

    @Query("SELECT * FROM server_config WHERE id = 1")
    fun getServerConfigSync(): ServerConfig?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun saveServerConfig(config: ServerConfig)
}
