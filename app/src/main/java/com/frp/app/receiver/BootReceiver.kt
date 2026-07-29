package com.frp.app.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.frp.app.data.AppDatabase
import com.frp.app.service.FrpService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class BootReceiver : BroadcastReceiver() {
    
    companion object {
        private const val TAG = "BootReceiver"
    }
    
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            Log.d(TAG, "Boot completed, checking for active config")
            
            val pendingResult = goAsync()
            CoroutineScope(Dispatchers.IO).launch {
                try {
                    val database = AppDatabase.getDatabase(context)
                    val activeConfig = database.frpConfigDao().getActiveConfig()
                    
                    activeConfig?.let { config ->
                        Log.d(TAG, "Found active config: ${config.name}, starting FRP")
                        FrpService.startService(context, config.id)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error checking active config", e)
                } finally {
                    pendingResult.finish()
                }
            }
        }
    }
}
