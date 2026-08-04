import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 全局玻璃背景：多个彩色球 + 整体模糊化
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: isDark ? const Color(0xFF101318) : const Color(0xFFF4F6FB),
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 45, sigmaY: 45),
        child: Stack(
          children: [
            Positioned(top: -120, left: -80, child: _ball(const Color(0xFF4FC3F7), 380)),
            Positioned(top: 280, right: -110, child: _ball(const Color(0xFF7C4DFF), 440)),
            Positioned(top: 880, left: -130, child: _ball(const Color(0xFFFF6E9C), 400)),
            Positioned(top: 1450, right: 60, child: _ball(const Color(0xFFFFB74D), 360)),
            Positioned(top: 1900, left: 120, child: _ball(const Color(0xFF69F0AE), 300)),
            Positioned(bottom: 160, right: 320, child: _ball(const Color(0xFFFFE082), 260)),
            Positioned(top: 2300, left: 600, child: _ball(const Color(0xFF40C4FF), 280)),
          ],
        ),
      ),
    );
  }

  Widget _ball(Color c, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [c, c.withValues(alpha: 0.55)],
        ),
        boxShadow: [
          BoxShadow(color: c, blurRadius: 120, spreadRadius: 40),
        ],
      ),
    );
  }
}
