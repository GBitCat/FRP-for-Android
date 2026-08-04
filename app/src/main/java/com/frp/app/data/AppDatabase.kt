package com.frp.app.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(entities = [FrpConfig::class, ServerConfig::class], version = 14, exportSchema = true)
abstract class AppDatabase : RoomDatabase() {
    
    abstract fun frpConfigDao(): FrpConfigDao
    abstract fun serverConfigDao(): ServerConfigDao
    
    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null
        
        // 7 -> 8: 新增 server_config 表，并从最近使用的代理配置中迁移服务器连接信息
        private val MIGRATION_7_8 = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS `server_config` (
                        `id` INTEGER PRIMARY KEY NOT NULL,
                        `serverAddr` TEXT NOT NULL DEFAULT '',
                        `serverPort` INTEGER NOT NULL DEFAULT 7000,
                        `token` TEXT NOT NULL DEFAULT '',
                        `updatedAt` INTEGER NOT NULL DEFAULT 0
                    )
                    """.trimIndent()
                )
                // 从最近更新的配置中继承服务器设置，避免用户重新填写
                db.execSQL(
                    """
                    INSERT INTO `server_config` (`id`, `serverAddr`, `serverPort`, `token`, `updatedAt`)
                    SELECT 1, `serverAddr`, `serverPort`, COALESCE(`token`, ''), `updatedAt`
                    FROM `frp_configs`
                    WHERE `serverAddr` != ''
                    ORDER BY `updatedAt` DESC
                    LIMIT 1
                    """.trimIndent()
                )
            }
        }
        // 8 -> 9: frp_configs 新增 useEncryption/useCompression 传输加密压缩开关
        private val MIGRATION_8_9 = object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `frp_configs` ADD COLUMN `useEncryption` INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE `frp_configs` ADD COLUMN `useCompression` INTEGER NOT NULL DEFAULT 0")
            }
        }
        // 9 -> 10: server_config 新增 transport 连接配置（协议/多路复用/心跳/保活）
        private val MIGRATION_9_10 = object : Migration(9, 10) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `server_config` ADD COLUMN `protocol` TEXT NOT NULL DEFAULT 'tcp'")
                db.execSQL("ALTER TABLE `server_config` ADD COLUMN `tcpMux` INTEGER NOT NULL DEFAULT 1")
                db.execSQL("ALTER TABLE `server_config` ADD COLUMN `heartbeatInterval` INTEGER NOT NULL DEFAULT 30")
                db.execSQL("ALTER TABLE `server_config` ADD COLUMN `heartbeatTimeout` INTEGER NOT NULL DEFAULT 90")
                db.execSQL("ALTER TABLE `server_config` ADD COLUMN `tcpMuxKeepaliveInterval` INTEGER NOT NULL DEFAULT 30")
            }
        }
        // 10 -> 11: frp_configs 新增 enabled 启用开关（拼接 TOML 时过滤）
        private val MIGRATION_10_11 = object : Migration(10, 11) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `frp_configs` ADD COLUMN `enabled` INTEGER NOT NULL DEFAULT 1")
            }
        }
        // 11 -> 12: isActive 重命名为 running（明确"正在运行"语义，区别于 enabled 启用开关）
        private val MIGRATION_11_12 = object : Migration(11, 12) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `frp_configs` RENAME COLUMN `isActive` TO `running`")
            }
        }
        // 12 -> 13: server_config 新增 name 命名（仪表盘 Server 卡片显示）
        private val MIGRATION_12_13 = object : Migration(12, 13) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `server_config` ADD COLUMN `name` TEXT NOT NULL DEFAULT 'FRPS Server'")
            }
        }
        // 13 -> 14: server_config 与 frp_configs 新增 serverId（应用配置归属 Server）
        private val MIGRATION_13_14 = object : Migration(13, 14) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `server_config` ADD COLUMN `serverId` TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE `frp_configs` ADD COLUMN `serverId` TEXT NOT NULL DEFAULT ''")
            }
        }
        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "frp_database"
                )
                .addMigrations(MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10, MIGRATION_10_11, MIGRATION_11_12, MIGRATION_12_13, MIGRATION_13_14)
                // 不使用 fallbackToDestructiveMigration：迁移失败宁可崩溃也不清空用户数据
                .build()
                INSTANCE = instance
                instance
            }
        }
    }
}
