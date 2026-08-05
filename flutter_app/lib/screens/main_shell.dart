import 'package:flutter/material.dart';
import 'package:liquid_glacier/liquid_glacier.dart';

import '../services/frp_engine.dart';
import '../widgets/frosted_dialog.dart';
import '../widgets/glass_background.dart';
import '../widgets/glass_bottom_nav.dart';
import 'configs_screen.dart';
import 'dashboard_screen.dart';
import 'manual_config_edit_screen.dart';
import 'settings_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    // 支持通过 Intent 指定初始 Tab（实机截图/测试用）
    FrpEngine.instance.getInitialTab().then((t) {
      if (mounted && t >= 0 && t <= 2) {
        setState(() => _selectedTab = t);
      }
    });
  }

  /// + 按钮：统一 FlClash 风格悬浮选项（毛玻璃 + 居中卡片）
  void _showAddConfigMenu(BuildContext context) {
    showFrostedDialog<void>(
      context: context,
      builder: (_) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add Configuration',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Divider(),
            _MenuOption(
              icon: Icons.edit_note_outlined,
              iconColor: Theme.of(context).colorScheme.tertiaryContainer,
              iconForeground: Theme.of(context).colorScheme.onTertiaryContainer,
              title: 'Manual Config',
              subtitle: 'Create a new frpc configuration',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ManualConfigEditScreen(),
                  ),
                );
              },
            ),
            _MenuOption(
              icon: Icons.dns_outlined,
              iconColor: Theme.of(context).colorScheme.primaryContainer,
              iconForeground: Theme.of(context).colorScheme.onPrimaryContainer,
              title: 'Server Config',
              subtitle: 'Add a new server connection',
              onTap: () {
                Navigator.of(context).pop();
                showFrostedDialog<void>(
                  context: context,
                  builder: (_) => ServerEditDialog(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 照片背景铺满整屏（含顶部标题区）
        const Positioned.fill(child: GlassBackground()),
        Scaffold(
          backgroundColor: Colors.transparent,
      floatingActionButton: _selectedTab == 1
          ? LiquidGlassFAB(
              onPressed: () => _showAddConfigMenu(context),
              tooltip: 'Add config',
              child: const Icon(Icons.add),
            )
          : null,
      // 内容延伸到导航栏后面，透出被遮挡的设置项（导航栏除胶囊外完全透明）
      extendBody: true,
      bottomNavigationBar: GlassBottomNavigationBar(
        currentIndex: _selectedTab,
        onTap: (i) => setState(() => _selectedTab = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            activeIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.list_outlined),
            activeIcon: Icon(Icons.list),
            label: 'Configs',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        // 过渡 Stack 铺满并顶对齐：避免内容较矮的页面（如仪表盘）被垂直居中导致“先居中再弹顶”
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            fit: StackFit.expand,
            alignment: Alignment.topLeft,
            children: [
              ...previousChildren,
              ?currentChild,
            ],
          );
        },
        // 干净的全页水平平移（无淡入淡出/缩放，避免回弹感）
        transitionBuilder: (child, animation) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          );
        },
            child: KeyedSubtree(
              key: ValueKey(_selectedTab),
              child: switch (_selectedTab) {
                0 => const DashboardScreen(),
                1 => const ConfigsScreen(),
                _ => const SettingsScreen(),
              },
            ),
      ),
    ),
      ],
    );
  }
}

class _MenuOption extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconForeground;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuOption({
    required this.icon,
    required this.iconColor,
    required this.iconForeground,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: iconForeground),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
