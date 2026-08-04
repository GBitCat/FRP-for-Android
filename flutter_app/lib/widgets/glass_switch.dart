import 'package:flutter/material.dart';

/// 纯 Liquid Glass 风格开关：自绘（轨道渐变 + 玻璃滑块），不再混用 Material Switch
class GlassSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const GlassSwitch({super.key, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        width: 52,
        height: 30,
        padding: const EdgeInsets.all(3),
        // 裁剪内部内容：避免滑块阴影溢出轨道圆角形成“飞边”
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: value
                ? [
                    scheme.primary.withValues(alpha: 0.60),
                    scheme.primary.withValues(alpha: 0.35),
                  ]
                : [
                    Colors.white.withValues(alpha: 0.14),
                    Colors.white.withValues(alpha: 0.05),
                  ],
          ),
          border: Border.all(
            color: value
                ? Colors.white.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.18),
            width: 0.8,
          ),
          // 去掉轨道外阴影，避免深色背景上形成模糊毛边（飞边）
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // 纯白实心滑块，去掉渐变与高光点，避免“折纸/贴片”观感
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
