package com.frp.app.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 主题设置持有者：主题模式（跟随系统/浅色/深色）+ 自定义主色。
 * 持久化到 SharedPreferences，切换即时生效（FRPAndroidTheme 订阅）。
 */
object ThemeSettingsHolder {
    private const val PREFS = "frp_settings"
    private const val KEY_MODE = "theme_mode"        // system / light / dark
    private const val KEY_COLOR = "theme_color"      // 主色 ARGB，空 = 跟随系统动态色

    private val _themeMode = MutableStateFlow("system")
    val themeMode: StateFlow<String> = _themeMode.asStateFlow()

    private val _primaryColor = MutableStateFlow<Int?>(null)
    val primaryColor: StateFlow<Int?> = _primaryColor.asStateFlow()

    fun init(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        _themeMode.value = prefs.getString(KEY_MODE, "system") ?: "system"
        val color = prefs.getString(KEY_COLOR, null)
        _primaryColor.value = color?.toIntOrNull()
    }

    fun setThemeMode(context: Context, mode: String) {
        _themeMode.value = mode
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_MODE, mode).apply()
    }

    /** [color] 为 null 表示跟随系统动态色 */
    fun setPrimaryColor(context: Context, color: Int?) {
        _primaryColor.value = color
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_COLOR, color?.toString()).apply()
    }
}
