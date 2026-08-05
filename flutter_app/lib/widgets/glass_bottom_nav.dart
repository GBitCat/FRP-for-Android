import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 长底玻璃包裹导航栏：
/// 整条底部区域用玻璃带包裹（模糊 + 半透明 + 细边），
/// 选中项不用气泡，仅通过颜色高亮区分。
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
  static const double _barHeight = 84;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 折射：背景轻微放大，模拟透过玻璃的扭曲效果
    const refraction = 1.03;
    final glassFilter = ImageFilter.compose(
      outer: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      inner: ImageFilter.matrix(
        Float64List.fromList([
          refraction, 0, 0, 0, //
          0, refraction, 0, 0, //
          0, 0, 1, 0, //
          0, 0, 0, 1, //
        ]),
      ),
    );

    return SafeArea(
      top: false,
      child: SizedBox(
        height: _barHeight,
        child: Stack(
          children: [
            // 长底玻璃带：整条底部区域玻璃包裹。
            // margin 必须放在 ClipRRect 之外，否则 BackdropFilter
            // 会模糊整个矩形区域，导致玻璃带外面多出一层模糊。
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: glassFilter,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(
                              alpha: isDark ? 0.04 : 0.07,
                            ),
                            Colors.white.withValues(
                              alpha: isDark ? 0.02 : 0.04,
                            ),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(24),
                        // 边缘立体感：light 模式用深色描边，dark 模式用白色描边
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.35)
                              : Colors.black.withValues(alpha: 0.16),
                          width: 1,
                        ),
                        // 轻微投影增强立体感（不越界模糊，仅玻璃带周围一圈）
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: isDark ? 0.25 : 0.10,
                            ),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
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
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
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
