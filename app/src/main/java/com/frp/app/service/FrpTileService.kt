package com.frp.app.service

import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import com.frp.app.MainActivity
import com.frp.app.data.FrpStatus
import com.frp.app.data.FrpStatusHolder

class FrpTileService : TileService() {

    companion object {
        private const val TAG = "FrpTileService"
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        
        val status = FrpStatusHolder.status.value
        
        when (status) {
            FrpStatus.RUNNING -> {
                // 点击停止
                FrpService.stopService(this)
            }
            FrpStatus.STOPPED, FrpStatus.ERROR -> {
                // 点击打开应用（需要选择配置）
                val intent = Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivityAndCollapse(intent)
            }
        }
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        val status = FrpStatusHolder.status.value

        when (status) {
            FrpStatus.RUNNING -> {
                tile.state = Tile.STATE_ACTIVE
                tile.label = "FRP"
                tile.subtitle = "Running"
            }
            FrpStatus.ERROR -> {
                tile.state = Tile.STATE_ACTIVE
                tile.label = "FRP"
                tile.subtitle = "Error"
            }
            FrpStatus.STOPPED -> {
                tile.state = Tile.STATE_INACTIVE
                tile.label = "FRP"
                tile.subtitle = "Stopped"
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            tile.stateDescription = when (status) {
                FrpStatus.RUNNING -> "Running"
                FrpStatus.ERROR -> "Error"
                FrpStatus.STOPPED -> "Stopped"
            }
        }

        tile.updateTile()
        Log.d(TAG, "Tile updated: ${status.name}")
    }
}
