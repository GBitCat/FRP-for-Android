import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'glass_surface.dart';

/// 统一弹窗：毛玻璃背景（无延迟）+ 居中圆角卡片 + 淡入缩放动画
/// 点击空白处关闭（barrierDismissible = true 时）
Future<T?> showFrostedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'dialog',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: barrierDismissible ? () => Navigator.of(context).pop() : null,
      child: const FrostedScrim(),
    ),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          child,
          Center(
            child: FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
                child: Builder(builder: builder),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 毛玻璃背景（无延迟出现）
class FrostedScrim extends StatelessWidget {
  const FrostedScrim({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          color: Colors.black.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}

/// 统一弹窗卡片样式（FlClash 风格）
class FrostedCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double maxWidth;
  const FrostedCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.maxWidth = 420,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      radius: 16,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
