import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 玻璃 SliverAppBar：随内容滚动被推上去（pinned:false + floating + snap）
class GlassSliverAppBar extends StatelessWidget {
  final String title;
  final List<Widget>? actions;
  const GlassSliverAppBar({super.key, required this.title, this.actions});

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      title: Text(title),
      actions: actions,
      pinned: false,
      floating: true,
      snap: true,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      // 磨砂顶栏：内容滚到下方时被模糊
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(color: Colors.transparent),
        ),
      ),
    );
  }
}
