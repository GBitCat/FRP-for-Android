import 'package:flutter/material.dart';

import '../models/connection_status.dart';
import '../state/app_state.dart';
import '../widgets/app_card.dart';
import '../widgets/frosted_dialog.dart';
import '../widgets/glass_sliver_appbar.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  Color _statusColor(BuildContext context, ConnectionType type) {
    final scheme = Theme.of(context).colorScheme;
    return switch (type) {
      ConnectionType.p2p => const Color(0xFF4CAF50),
      ConnectionType.relay => const Color(0xFFFF9800),
      ConnectionType.error => const Color(0xFFF44336),
      ConnectionType.connected => const Color(0xFF4CAF50),
      ConnectionType.connecting => scheme.primary,
      ConnectionType.unknown => scheme.onSurfaceVariant.withValues(alpha: 0.5),
    };
  }

  /// 切换服务器弹窗（统一毛玻璃样式）
  void _showServerPicker(BuildContext context) {
    final state = appState;
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Switch Server',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            ...state.servers.map((s) {
              final selected = state.isServerSelected(s.serverId);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(s.name.isEmpty ? 'FRPS Server' : s.name),
                subtitle: Text(
                  s.serverId,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                trailing: selected
                    ? Icon(
                        Icons.check_circle,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  state.selectServer(s.serverId);
                  Navigator.pop(dialogContext);
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = appState;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final server = state.effectiveServer;
        final scheme = Theme.of(context).colorScheme;

        return CustomScrollView(
          slivers: [
            const GlassSliverAppBar(title: 'Dashboard'),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  // 服务器连接配置卡片
                  AppCard(
                    leading: const Icon(Icons.dns_outlined),
                    title: server.name.isEmpty ? 'FRPS Server' : server.name,
                    trailing: IconButton(
                      tooltip: 'Switch server',
                      onPressed: () => _showServerPicker(context),
                      icon: const Icon(Icons.swap_horiz, size: 20),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              state.running
                                  ? Icons.cloud_done_outlined
                                  : Icons.help_outline,
                              size: 16,
                              color: state.running
                                  ? const Color(0xFF4CAF50)
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              state.running ? 'Active' : 'Inactive',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: state.running
                                        ? const Color(0xFF4CAF50)
                                        : scheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(width: 12),
                            Icon(
                              Icons.swap_horiz,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                state.running
                                    ? state.serverStatus.label
                                    : 'No connection',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                            const Spacer(),
                            Switch(
                              value: state.running,
                              onChanged: (v) =>
                                  v ? state.start() : state.stop(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // IP 与内存卡片并排（强制等高）
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _IpAddressCard(
                            ipv4: state.ipv4,
                            ipv6: state.ipv6,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _MemoryCard(
                            mb: state.memoryMb,
                            totalMb: state.totalMemoryMb,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // 流量统计卡片
                  if (state.trafficEnabled) ...[
                    _TrafficCard(
                      upload: state.uploadSpeed,
                      download: state.downloadSpeed,
                      total: state.totalBytes,
                    ),
                    const SizedBox(height: 12),
                  ],

                  // 各应用连接状态卡片
                  AppCard(
                    leading: const Icon(Icons.apps_outlined),
                    title: 'Applications',
                    child: state.configs.isEmpty
                        ? Text(
                            'No apps',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          )
                        : ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 108),
                            child: SingleChildScrollView(
                              child: Column(
                                children: state.buildAppRows().map((row) {
                                  final type = row.status;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            row.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
                                          ),
                                        ),
                                        StatusDot(_statusColor(context, type)),
                                        const SizedBox(width: 6),
                                        Text(
                                          row.label,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                color: _statusColor(
                                                  context,
                                                  type,
                                                ),
                                              ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                  ),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _IpAddressCard extends StatelessWidget {
  final String ipv4;
  final String ipv6;
  const _IpAddressCard({required this.ipv4, required this.ipv6});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      leading: const Icon(Icons.language),
      title: 'Network',
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('IPv4', style: Theme.of(context).textTheme.labelSmall),
          Text(
            ipv4.isEmpty ? 'No network connection' : ipv4,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text('IPv6', style: Theme.of(context).textTheme.labelSmall),
          Text(
            ipv6.isEmpty ? 'No network connection' : ipv6,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  final double mb;
  final double totalMb;
  const _MemoryCard({required this.mb, required this.totalMb});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 进度条上限 = 设备实际物理内存
    final heapPercent = totalMb > 0 ? (mb / totalMb).clamp(0.0, 1.0) : 0.0;
    return AppCard(
      leading: const Icon(Icons.memory),
      title: 'App Memory',
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${mb.round()} MB',
                style: Theme.of(
                  context,
                ).textTheme.headlineSmall?.copyWith(color: scheme.primary),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  'RSS',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: heapPercent),
          const SizedBox(height: 4),
          Text(
            'RAM ${(heapPercent * 100).round()}%',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  final double upload;
  final double download;
  final double total;
  const _TrafficCard({
    required this.upload,
    required this.download,
    required this.total,
  });

  static String _speed(double v) {
    if (v >= 1024 * 1024) return '${(v / 1024 / 1024).toStringAsFixed(1)} MB/s';
    if (v >= 1024) return '${(v / 1024).toStringAsFixed(1)} KB/s';
    return '${v.toStringAsFixed(0)} B/s';
  }

  static String _bytes(double v) {
    if (v >= 1024 * 1024 * 1024) {
      return '${(v / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (v >= 1024 * 1024) {
      return '${(v / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (v >= 1024) {
      return '${(v / 1024).toStringAsFixed(1)} KB';
    }
    return '${v.toStringAsFixed(0)} B';
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      leading: const Icon(Icons.data_usage),
      title: 'Traffic',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('0 conn', style: Theme.of(context).textTheme.labelSmall),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _TrafficColumn(value: _speed(upload), label: 'Upload'),
          ),
          Expanded(
            child: _TrafficColumn(value: _speed(download), label: 'Download'),
          ),
          Expanded(
            child: _TrafficColumn(value: _bytes(total), label: 'Total'),
          ),
        ],
      ),
    );
  }
}

class _TrafficColumn extends StatelessWidget {
  final String value;
  final String label;
  const _TrafficColumn({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
