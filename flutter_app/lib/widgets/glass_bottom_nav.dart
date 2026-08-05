import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// iOS 风格玻璃胶囊导航栏：
/// 整体完全透明，只有选中项的大椭圆区域做模糊玻璃，区域外内容完全透出
class GlassBottomNavigationBar extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<BottomNavigationBarItem> items;

  const GlassBottomNavigationBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  State<GlassBottomNavigationBar> createState() =>
      _GlassBottomNavigationBarState();
}

class _GlassBottomNavigationBarState extends State<GlassBottomNavigationBar> {
  static const double _pillWidth = 156;
  static const double _pillHeight = 56;
  static const double _barHeight = 84;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final width = MediaQuery.sizeOf(context).width;
    final itemW = width / widget.items.length;
    final pillLeft = widget.currentIndex * itemW + (itemW - _pillWidth) / 2;

    return SafeArea(
      top: false,
      child: SizedBox(
        height: _barHeight,
        child: Stack(
          children: [
            // 选中项的大椭圆玻璃胶囊（模糊 + 半透明 + 细边 + 阴影）
            AnimatedPositioned(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              left: pillLeft,
              bottom: 12,
              width: _pillWidth,
              height: _pillHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_pillHeight / 2),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: isDark ? 0.22 : 0.36),
                          Colors.white.withValues(alpha: isDark ? 0.12 : 0.22),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(_pillHeight / 2),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.35),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 选项（图标 + 标签）
            Row(
              children: List.generate(widget.items.length, (i) {
                final item = widget.items[i];
                final selected = widget.currentIndex == i;
                final color = selected
                    ? (isDark ? Colors.white : scheme.primary)
                    : scheme.onSurfaceVariant;
                return Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onTap(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconTheme(
                          data: IconThemeData(color: color, size: 24),
                          child: selected ? item.activeIcon : item.icon,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.label ?? '',
                          style: TextStyle(
                            fontSize: selected ? 13 : 11,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
