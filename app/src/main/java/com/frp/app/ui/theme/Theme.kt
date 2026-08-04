package com.frp.app.ui.theme

import android.app.Activity
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import com.frp.app.data.ThemeSettingsHolder

private val DarkColorScheme = darkColorScheme(
    primary = DarkPrimary,
    secondary = DarkSecondary,
    tertiary = DarkTertiary,
    primaryContainer = DarkPrimaryVariant,
    secondaryContainer = DarkSecondaryVariant,
    background = Color(0xFF121212),
    surface = Color(0xFF1E1E1E),
    onPrimary = Color.White,
    onSecondary = Color.White,
    onBackground = Color.White,
    onSurface = Color.White,
    surfaceVariant = Color(0xFF2D2D2D)
)

private val LightColorScheme = lightColorScheme(
    primary = LightPrimary,
    secondary = LightSecondary,
    tertiary = LightTertiary,
    primaryContainer = LightPrimaryVariant,
    secondaryContainer = LightSecondaryVariant,
    background = Color(0xFFF5F5F5),
    surface = Color.White,
    onPrimary = Color.White,
    onSecondary = Color.White,
    onBackground = Color(0xFF1C1B1F),
    onSurface = Color(0xFF1C1B1F),
    surfaceVariant = Color(0xFFE7E0EC)
)

@Composable
fun FRPAndroidTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit
) {
    // 主题设置（参考 FlClash）：模式 + 自定义主色
    val themeMode by ThemeSettingsHolder.themeMode.collectAsState()
    val customPrimary by ThemeSettingsHolder.primaryColor.collectAsState()
    val isDark = when (themeMode) {
        "light" -> false
        "dark" -> true
        else -> darkTheme
    }
    val colorScheme = when {
        customPrimary != null -> customColorScheme(Color(customPrimary!!), isDark)
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (isDark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        isDark -> DarkColorScheme
        else -> LightColorScheme
    }
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            // 状态栏背景与 TopAppBar 保持一致（primaryContainer），图标明暗随主题
            window.statusBarColor = colorScheme.primaryContainer.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !isDark
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}


/** 颜色混合：target 与 base 按 ratio 混合（ratio=1 用 target） */
private fun Color.blendWith(base: Color, ratio: Float): Color {
    val r = red * ratio + base.red * (1 - ratio)
    val g = green * ratio + base.green * (1 - ratio)
    val b = blue * ratio + base.blue * (1 - ratio)
    return Color(r, g, b)
}

/**
 * 基于自定义主色生成 ColorScheme（近似 Material You fromSeed）。
 * 浅色：主色 + 白色容器；深色：主色提亮 + 深色容器。
 */
fun customColorScheme(seed: Color, dark: Boolean): ColorScheme {
    return if (dark) {
        darkColorScheme(
            primary = seed,
            onPrimary = Color.White,
            primaryContainer = seed.blendWith(Color.Black, 0.7f),
            onPrimaryContainer = Color.White,
            secondary = seed.blendWith(Color.LightGray, 0.6f),
            secondaryContainer = seed.blendWith(Color.Black, 0.75f),
            onSecondaryContainer = Color.White,
            tertiary = seed.blendWith(Color.Gray, 0.5f),
            background = Color(0xFF121212),
            surface = Color(0xFF1E1E1E),
            surfaceVariant = Color(0xFF2D2D2D),
            onBackground = Color.White,
            onSurface = Color.White
        )
    } else {
        lightColorScheme(
            primary = seed,
            onPrimary = Color.White,
            primaryContainer = seed.blendWith(Color.White, 0.35f),
            onPrimaryContainer = Color(0xFF1C1B1F),
            secondary = seed.blendWith(Color.Gray, 0.45f),
            secondaryContainer = seed.blendWith(Color.White, 0.55f),
            onSecondaryContainer = Color(0xFF1C1B1F),
            tertiary = seed.blendWith(Color.DarkGray, 0.4f),
            background = Color(0xFFF5F5F5),
            surface = Color.White,
            surfaceVariant = Color(0xFFE7E0EC),
            onBackground = Color(0xFF1C1B1F),
            onSurface = Color(0xFF1C1B1F)
        )
    }
}
