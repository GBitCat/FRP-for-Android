import 'package:flutter/material.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';
import '../widgets/frosted_dialog.dart';
import '../state/app_state.dart';
import '../widgets/app_card.dart';
import 'config_edit_screen.dart';
import 'manual_config_edit_screen.dart';

class ConfigsScreen extends StatelessWidget {
  const ConfigsScreen({super.key});

  Future<void> _openEdit(BuildContext context, {int? configId}) async {
    final cfg = configId == null
        ? null
        : appState.configs.where((e) => e.id == configId).firstOrNull;
    if (cfg?.manualToml != null && cfg!.manualToml!.trim().isNotEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ManualConfigEditScreen(configId: configId),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConfigEditScreen(configId: configId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = appState;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return Column(
          children: [
            // Server 列表（类似 Configurations 的列表结构）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Servers (${state.servers.length})',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  ...state.servers.map((s) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ServerListItem(
                          server: s,
                          selected: state.isServerSelected(s.serverId),
                          onSelect: () => state.selectServer(s.serverId),
                          onPreview: () => _showServerPreview(context),
                          onEdit: () => _showServerEdit(context, initial: s),
                          onDelete: () => _confirmDeleteServer(context, s),
                        ),
                      )),
                ],
              ),
            ),

            Expanded(
              child: state.configs.isEmpty
                  ? const _EmptyConfigs()
                  : ListenableBuilder(
                      listenable: state,
                      builder: (context, _) {
                        final groups = state.buildGroups();
                        return ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                          itemCount: groups.length + 1,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'Configurations (${state.configs.length})',
                                  style: Theme.of(context).textTheme.headlineSmall,
                                ),
                              );
                            }
                            final group = groups[index - 1];
                            if (group.isGroup) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _ConfigGroupItem(
                                  group: group,
                                  onEdit: () =>
                                      _openEdit(context, configId: group.primary.id),
                                  onDelete: () => _confirmDeleteGroup(context, group),
                                  onOptions: () => _showItemMenu(context,
                                      onEdit: () =>
                                          _openEdit(context, configId: group.primary.id),
                                      onDelete: () => _confirmDeleteGroup(context, group)),
                                ),
                              );
                            }
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _ConfigItem(
                                config: group.primary,
                                onEdit: () =>
                                    _openEdit(context, configId: group.primary.id),
                                onDelete: () => _confirmDelete(context, group.primary),
                                onOptions: () => _showItemMenu(context,
                                    onEdit: () =>
                                        _openEdit(context, configId: group.primary.id),
                                    onDelete: () => _confirmDelete(context, group.primary)),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  void _showServerEdit(BuildContext context, {ServerConfig? initial}) {
    showFrostedDialog<void>(
      context: context,
      builder: (_) => ServerEditDialog(initial: initial),
    );
  }

  /// 三点菜单：统一毛玻璃弹窗（Edit / Delete）
  void _showItemMenu(BuildContext context,
      {required VoidCallback onEdit, required VoidCallback onDelete}) {
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Actions',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            const Divider(),
            _MenuAction(
              icon: Icons.edit_outlined,
              label: 'Edit',
              onTap: () {
                Navigator.pop(dialogContext);
                onEdit();
              },
            ),
            _MenuAction(
              icon: Icons.delete_outline,
              label: 'Delete',
              destructive: true,
              onTap: () {
                Navigator.pop(dialogContext);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteServer(BuildContext context, ServerConfig s) {
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Delete Server',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text("Are you sure you want to delete '${s.name}'?"),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    appState.deleteServer(s.serverId);
                  },
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showServerPreview(BuildContext context) {
    final state = appState;
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Server Config Preview',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  state.generateServerPreview(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

  void _confirmDelete(BuildContext context, FrpConfig config) {
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Delete Configuration',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text("Are you sure you want to delete '${config.name}'?"),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    appState.deleteConfig(config.id);
                  },
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteGroup(BuildContext context, ConfigGroup group) {
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Delete Group',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
                "Are you sure you want to delete '${group.groupName}' and all its configs?"),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    appState.deleteGroup(group.groupId);
                  },
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

class _EmptyConfigs extends StatelessWidget {
  const _EmptyConfigs();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'No configurations yet',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to add or import from menu',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ServerListItem extends StatelessWidget {
  final ServerConfig server;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onPreview;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ServerListItem({
    required this.server,
    required this.selected,
    required this.onSelect,
    required this.onPreview,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: onSelect,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.dns_outlined,
              size: 18,
              color: selected ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              server.name.isEmpty ? 'FRPS Server' : server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
            ),
          ),
          if (selected) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Current',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
              ),
            ),
          ],
          IconButton(
            tooltip: 'Preview config',
            visualDensity: VisualDensity.compact,
            onPressed: onPreview,
            icon: const Icon(Icons.visibility_outlined, size: 18),
          ),
          IconButton(
            tooltip: 'Edit server',
            visualDensity: VisualDensity.compact,
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
          IconButton(
            tooltip: 'Delete server',
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }
}

class _ConfigGroupItem extends StatelessWidget {
  final ConfigGroup group;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onOptions;

  const _ConfigGroupItem({
    required this.group,
    required this.onEdit,
    required this.onDelete,
    required this.onOptions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final protocols = group.members.map((e) => e.protocol.toUpperCase()).toSet();
    final protocolText = protocols.join(' + ');
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.folder_copy_outlined,
              size: 18,
              color: scheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.groupName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  protocolText,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          Switch(
            value: group.enabled,
            onChanged: (v) => appState.setGroupEnabled(group.groupId, v),
          ),
          IconButton(
            tooltip: 'Options',
            onPressed: onOptions,
            icon: const Icon(Icons.more_vert, size: 20),
          ),
        ],
      ),
    );
  }
}

class _ConfigItem extends StatelessWidget {
  final FrpConfig config;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onOptions;

  const _ConfigItem({
    required this.config,
    required this.onEdit,
    required this.onDelete,
    required this.onOptions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final secret = config.needsSecretKey();
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: secret
                  ? scheme.tertiaryContainer.withValues(alpha: 0.6)
                  : scheme.primaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              secret ? Icons.lock_outline : Icons.route_outlined,
              size: 18,
              color: secret ? scheme.onTertiaryContainer : scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  config.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  '${config.manualTypes.isEmpty ? config.protocol.toUpperCase() : config.manualTypes.join(' + ').toUpperCase()} · ${config.isVisitor() ? "Visitor" : "Server"}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          Switch(
            value: config.enabled,
            onChanged: (v) => appState.setConfigEnabled(config.id, v),
          ),
          IconButton(
            tooltip: 'Options',
            onPressed: onOptions,
            icon: const Icon(Icons.more_vert, size: 20),
          ),
        ],
      ),
    );
  }
}

/// Server 编辑对话框（含 8 位 ID 展示与重置）
class ServerEditDialog extends StatefulWidget {
  final ServerConfig? initial;
  const ServerEditDialog({super.key, this.initial});

  @override
  State<ServerEditDialog> createState() => _ServerEditDialogState();
}

class _ServerEditDialogState extends State<ServerEditDialog> {
  late TextEditingController _name;
  late TextEditingController _addr;
  late TextEditingController _port;
  late TextEditingController _token;
  late TextEditingController _serverId;
  late String _protocol;
  late bool _tcpMux;
  late int _heartbeatInterval;
  late int _heartbeatTimeout;
  late int _keepalive;

  static const _protocols = ['tcp', 'kcp', 'quic', 'ws', 'wss'];
  static const _intervals = [10, 20, 30, 45, 60, 90, 120];

  @override
  void initState() {
    super.initState();
    final s = widget.initial ??
        ServerConfig(serverId: ServerConfig.generateId());
    _name = TextEditingController(text: s.name);
    _addr = TextEditingController(text: s.serverAddr);
    _port = TextEditingController(text: s.serverPort.toString());
    _token = TextEditingController(text: s.token);
    _serverId = TextEditingController(text: s.serverId);
    _protocol = s.protocol;
    _tcpMux = s.tcpMux;
    _heartbeatInterval = s.heartbeatInterval;
    _heartbeatTimeout = s.heartbeatTimeout;
    _keepalive = s.tcpMuxKeepaliveInterval;
  }

  @override
  void dispose() {
    _name.dispose();
    _addr.dispose();
    _port.dispose();
    _token.dispose();
    _serverId.dispose();
    super.dispose();
  }

  void _save() {
    final s = appState.effectiveServer;
    appState.saveServerConfig(s.copyWith(
      name: _name.text,
      serverAddr: _addr.text,
      serverPort: int.tryParse(_port.text) ?? 7000,
      token: _token.text,
      serverId: _serverId.text,
      protocol: _protocol,
      tcpMux: _tcpMux,
      heartbeatInterval: _heartbeatInterval,
      heartbeatTimeout: _heartbeatTimeout,
      tcpMuxKeepaliveInterval: _keepalive,
    ));
    Navigator.pop(context);
  }

  void _resetId() {
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reset Server ID',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            const Text('确定重置 Server ID 吗？将生成新的 8 位 ID，已有应用配置的归属将同步更新到新 ID。'),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    final newId = ServerConfig.generateId();
                    _serverId.text = newId;
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FrostedCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.initial == null ? 'Add Server' : 'Edit Server Connection',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.65,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                    // 顶部留白：避免第一个输入框的浮动标签被滚动区域裁剪
                    const SizedBox(height: 6),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g., Home Server',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _serverId,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Server ID',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                TextButton(onPressed: _resetId, child: const Text('Reset ID')),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _addr,
              decoration: const InputDecoration(
                labelText: 'Server Address *',
                hintText: 'e.g., frp.example.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              decoration: const InputDecoration(
                labelText: 'Token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Transport', style: Theme.of(context).textTheme.titleSmall),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: _protocol,
              decoration: const InputDecoration(
                labelText: 'Protocol',
                border: OutlineInputBorder(),
              ),
              items: _protocols
                  .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                  .toList(),
              onChanged: (v) => setState(() => _protocol = v ?? 'tcp'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('TCP Multiplexing (tcpMux)'),
              value: _tcpMux,
              onChanged: (v) => setState(() => _tcpMux = v),
            ),
            _intervalRow('Heartbeat Interval (s)', _heartbeatInterval, (v) => _heartbeatInterval = v),
            _intervalRow('Heartbeat Timeout (s)', _heartbeatTimeout, (v) => _heartbeatTimeout = v),
            _intervalRow('tcpMux Keepalive (s)', _keepalive, (v) => _keepalive = v),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _intervalRow(String label, int value, ValueChanged<int> onChanged) {
    return Row(
      children: [
        Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
        DropdownButton<int>(
          value: value,
          items: _intervals
              .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
              .toList(),
          onChanged: (v) => setState(() => onChanged(v ?? value)),
        ),
      ],
    );
  }
}

class _MenuAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const _MenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = destructive ? scheme.error : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
