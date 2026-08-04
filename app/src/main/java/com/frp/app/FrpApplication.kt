package com.frp.app

import com.frp.app.data.FrpStatusHolder
import com.frp.app.data.ThemeSettingsHolder

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

class FrpApplication : Application() {
    
    companion object {
        const val CHANNEL_ID = "frp_service_channel"
        const val CHANNEL_NAME = "FRP Service"
    }

    override fun onCreate() {
        super.onCreate()
        FrpStatusHolder.init(this)
        ThemeSettingsHolder.init(this)
        createNotificationChannel()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "FRP service notification channel"
            }
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }
}
