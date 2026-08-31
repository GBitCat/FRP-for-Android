import 'package:flutter/material.dart';
import 'package:liquid_glacier/liquid_glacier.dart';

import '../state/app_state.dart';
import '../services/frp_engine.dart';
import '../widgets/frosted_dialog.dart';
import '../widgets/glass_bottom_nav.dart';
import 'config_edit_screen.dart';
import 'configs_screen.dart';
import 'dashboard_screen.dart';
import 'manual_config_edit_screen.dart';
import 'settings_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 支持通过 Intent 指定初始 Tab（实机截图/测试用）
    FrpEngine.instance.getInitialTab().then((t) {
      if (mounted && t >= 0 && t <= 2) {
        setState(() => _selectedTab = t);
      }
    });
    // 首次启动：提醒取消本应用的省电策略（只提醒一次）。
    // _load 是异步的，监听 AppState 变化确保标记就绪后弹出。
    appState.addListener(_onAppStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && appState.batteryHintPending) {
        _consumeBatteryHint();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appState.removeListener(_onAppStateChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      appState.resumePolling();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      appState.pausePolling();
    }
  }

  void _onAppStateChanged() {
    if (mounted && appState.batteryHintPending) {
      _consumeBatteryHint();
    }
  }

  void _consumeBatteryHint() {
    appState.batteryHintPending = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showBatteryHint();
    });
  }

  /// 省电策略提醒弹窗
  void _showBatteryHint() {
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.battery_saver_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('省电策略提醒', style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '为保证 frpc 在后台稳定运行（STCP/XTCP 连接不掉线），'
              '建议取消本应用的省电策略 / 电池优化限制。',
              style: TextStyle(height: 1.4),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('知道了'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    FrpEngine.instance.requestIgnoreBatteryOptimizations();
                  },
                  child: const Text('去设置'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
              icon: Icons.tune_outlined,
              iconColor: Theme.of(context).colorScheme.secondaryContainer,
              iconForeground: Theme.of(
                context,
              ).colorScheme.onSecondaryContainer,
              title: 'visitor.FormConfig',
              subtitle: 'Create a configuration with guided fields',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ConfigEditScreen()),
                );
              },
            ),
            _MenuOption(
              icon: Icons.edit_note_outlined,
              iconColor: Theme.of(context).colorScheme.tertiaryContainer,
              iconForeground: Theme.of(context).colorScheme.onTertiaryContainer,
              title: 'Manual Config',
              subtitle: 'Write proxy or visitor TOML directly',
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
    return Scaffold(
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
            children: [...previousChildren, ?currentChild],
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
