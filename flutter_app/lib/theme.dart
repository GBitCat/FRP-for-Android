import 'package:flutter/material.dart';

/// FlClash 风格主题：Material 3 + 蓝色主色 + 圆角卡片 + 柔和阴影
/// 可选主题色（与设置页一致）
const List<Color> appAccents = [
  Color(0xFF3B6CF6),
  Color(0xFFE91E63),
  Color(0xFF4CAF50),
  Color(0xFFFF9800),
  Color(0xFF9C27B0),
  Color(0xFF00BCD4),
  Color(0xFF795548),
];

class AppTheme {
  AppTheme._();

  static const Color lightBackground = Color(0xFFF4F6FB);
  static const Color darkBackground = Color(0xFF101318);
  static const Color cardBorder = Color(0x14000000);

  static ThemeData light(Color accent) {
    final scheme = ColorScheme.fromSeed(seedColor: accent);
    return _base(scheme.copyWith(
      surface: Colors.white,
      surfaceContainerLow: Colors.white,
      surfaceContainerHighest: const Color(0xFFF0F2F7),
    ));
  }

  static ThemeData dark(Color accent) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    );
    return _base(scheme.copyWith(
      surface: const Color(0xFF171A21),
      surfaceContainerLow: const Color(0xFF171A21),
      surfaceContainerHighest: const Color(0xFF22262F),
    ));
  }

  static ThemeData _base(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? darkBackground : lightBackground,
      appBarTheme: AppBarTheme(
        // 顶部与空白区域一致（透明背景，不再使用主题色）
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        margin: EdgeInsets.zero,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primaryContainer,
        elevation: 8,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          // 关闭状态滑块：普通表面色（白色卡片上可见）
          return scheme.surface;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary.withValues(alpha: 0.4);
          }
          // 关闭状态轨道：浅灰色（白色/深色卡片上均可见）
          return scheme.onSurface.withValues(alpha: 0.12);
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return scheme.onSurface.withValues(alpha: 0.28);
        }),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        thickness: 1,
      ),
    );
  }
}
