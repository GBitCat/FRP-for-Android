import 'package:flutter/material.dart';

/// 普通 SliverAppBar：透明、随内容滚动被推上去（pinned:false + floating + snap）
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
    );
  }
}
