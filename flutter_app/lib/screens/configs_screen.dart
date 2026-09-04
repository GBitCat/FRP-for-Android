import 'package:flutter/material.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';
import '../widgets/frosted_dialog.dart';
import '../widgets/glass_sliver_appbar.dart';
import '../state/app_state.dart';
import '../services/certificates/certificate_engine.dart';
import '../services/certificates/certificate_models.dart';
import '../services/config_domain_service.dart';
import '../services/secure_clipboard.dart';
import '../widgets/app_card.dart';
import 'config_edit_screen.dart';
import 'manual_config_edit_screen.dart';

Future<bool> _runConfigMutation(
  BuildContext context,
  Future<void> Function() action,
  String failureMessage,
) async {
  try {
    await action();
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failureMessage)));
    }
    return false;
  }
}

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
      MaterialPageRoute(builder: (_) => ConfigEditScreen(configId: configId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = appState;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final groups = state.buildGroups();
        return CustomScrollView(
          slivers: [
            const GlassSliverAppBar(title: 'Configs'),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Servers (${state.servers.length})',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    ...state.servers.map(
                      (s) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ServerListItem(
                          server: s,
                          selected: state.isServerSelected(s.serverId),
                          onSelect: () async {
                            await _runConfigMutation(
                              context,
                              () => state.selectServer(s.serverId),
                              'Unable to switch server',
                            );
                          },
                          onPreview: () => _showServerPreview(context, s),
                          onEdit: () => _showServerEdit(context, initial: s),
                          onDelete: () => _confirmDeleteServer(context, s),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (state.configs.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyConfigs(),
              )
            else ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Configurations (${state.configs.length})',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                sliver: SliverList(
                  delegate: SliverChildListDelegate(
                    groups.map((group) {
                      if (group.isGroup) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _ConfigGroupItem(
                            group: group,
                            onEdit: () =>
                                _openEdit(context, configId: group.primary.id),
                            onDelete: () => _confirmDeleteGroup(context, group),
                            onOptions: () => _showItemMenu(
                              context,
                              onEdit: () => _openEdit(
                                context,
                                configId: group.primary.id,
                              ),
                              onDelete: () =>
                                  _confirmDeleteGroup(context, group),
                            ),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _ConfigItem(
                          config: group.primary,
                          onEdit: () =>
                              _openEdit(context, configId: group.primary.id),
                          onDelete: () =>
                              _confirmDelete(context, group.primary),
                          onOptions: () => _showItemMenu(
                            context,
                            onEdit: () =>
                                _openEdit(context, configId: group.primary.id),
                            onDelete: () =>
                                _confirmDelete(context, group.primary),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
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
  void _showItemMenu(
    BuildContext context, {
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Actions', style: Theme.of(context).textTheme.titleSmall),
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
            Text(
              "Are you sure you want to delete '${s.name}' and all configs assigned to it?",
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(dialogContext);
                    await _runConfigMutation(
                      context,
                      () => appState.deleteServer(s.serverId),
                      'Unable to delete server',
                    );
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

  void _showServerPreview(BuildContext context, ServerConfig server) {
    final state = appState;
    final preview = state.buildFullTomlFor(server);
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
                child: Text(
                  preview,
                  key: const ValueKey('server_config_preview_text'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Close'),
                ),
                TextButton(
                  key: const ValueKey('copy_server_config_preview'),
                  onPressed: () async {
                    try {
                      await SecureClipboard.copy(preview);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Server config copied; clipboard clears in 60s',
                          ),
                        ),
                      );
                    } catch (_) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Unable to copy server config'),
                        ),
                      );
                    }
                  },
                  child: const Text('Copy'),
                ),
              ],
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
          Text(
            "Are you sure you want to delete '${ConfigDomainService.displayName(config)}'?",
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  await _runConfigMutation(
                    context,
                    () => appState.deleteConfig(config.id),
                    'Unable to delete configuration',
                  );
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
          Text('Delete Group', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            "Are you sure you want to delete '${group.groupName}' and all its configs?",
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  await _runConfigMutation(
                    context,
                    () => appState.deleteGroup(group.groupId),
                    'Unable to delete configuration group',
                  );
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
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to add or import from menu',
            style: Theme.of(context).textTheme.bodyMedium
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
          Icon(
            Icons.dns_outlined,
            size: 18,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
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
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: scheme.onPrimaryContainer),
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
    final protocolCounts = <String, int>{};
    for (final member in group.members) {
      final protocol = member.protocol.toUpperCase();
      protocolCounts[protocol] = (protocolCounts[protocol] ?? 0) + 1;
    }
    final protocolText = protocolCounts.entries
        .map(
          (entry) =>
              entry.value > 1 ? '${entry.key} ×${entry.value}' : entry.key,
        )
        .join(' + ');
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
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch(
            value: group.enabled,
            onChanged: (v) async {
              await _runConfigMutation(
                context,
                () => appState.setGroupEnabled(group.groupId, v),
                'Unable to update configuration group',
              );
            },
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
    final portSummary = config.isMultiPort
        ? ' · ${config.effectivePortMappings.length} ports'
        : '';
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
                  ConfigDomainService.displayName(config),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  '${config.manualTypes.isEmpty ? config.protocol.toUpperCase() : config.manualTypes.join(' + ').toUpperCase()}$portSummary · ${config.isVisitor() ? "Visitor" : "Server"}',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch(
            value: config.enabled,
            onChanged: (v) async {
              await _runConfigMutation(
                context,
                () => appState.setConfigEnabled(config.id, v),
                'Unable to update configuration',
              );
            },
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
typedef CertificateInventoryLoader = Future<CertificateInventory> Function();
typedef ServerConfigSaver = Future<void> Function(
  ServerConfig config,
  String? originalServerId,
);

class ServerEditDialog extends StatefulWidget {
  final ServerConfig? initial;
  final CertificateInventoryLoader? certificateInventoryLoader;
  final ServerConfigSaver? onSave;

  const ServerEditDialog({
    super.key,
    this.initial,
    this.certificateInventoryLoader,
    this.onSave,
  });

  @override
  State<ServerEditDialog> createState() => _ServerEditDialogState();
}

class _ServerEditDialogState extends State<ServerEditDialog> {
  late TextEditingController _name;
  late TextEditingController _addr;
  late TextEditingController _port;
  late TextEditingController _token;
  late TextEditingController _serverId;
  late TextEditingController _tlsServerName;
  late TextEditingController _tlsCertFile;
  late TextEditingController _tlsKeyFile;
  late TextEditingController _tlsTrustedCaFile;
  List<ManagedIdentityRecord> _certificateIdentities = const [];
  String? _certificateIdentitySelection;
  String? _certificateLoadError;
  bool _certificatesLoading = true;
  late String _protocol;
  late bool _tcpMux;
  late bool _tlsEnabled;
  late bool _securityExpanded;
  bool _showToken = false;
  bool _saving = false;
  late int _heartbeatInterval;
  late int _heartbeatTimeout;
  late int _keepalive;

  static const _protocols = ServerConfig.supportedProtocols;
  static const _intervals = ServerConfig.intervalPresets;
  static const _controlHeight = 44.0;
  static const _controlFontSize = 14.0;

  @override
  void initState() {
    super.initState();
    final s =
        widget.initial ?? ServerConfig(serverId: ServerConfig.generateId());
    _name = TextEditingController(text: s.name);
    _addr = TextEditingController(text: s.serverAddr);
    _port = TextEditingController(text: s.serverPort.toString());
    _token = TextEditingController(text: s.token);
    _serverId = TextEditingController(text: s.serverId);
    _tlsServerName = TextEditingController(text: s.tlsServerName);
    _tlsCertFile = TextEditingController(text: s.tlsCertFile);
    _tlsKeyFile = TextEditingController(text: s.tlsKeyFile);
    _tlsTrustedCaFile = TextEditingController(text: s.tlsTrustedCaFile);
    _protocol = ServerConfig.normalizeProtocol(s.protocol);
    _tcpMux = s.tcpMux;
    _tlsEnabled = s.tlsEnabled;
    _securityExpanded = s.tlsEnabled;
    _heartbeatInterval = s.heartbeatInterval;
    _heartbeatTimeout = s.heartbeatTimeout;
    _keepalive = s.tcpMuxKeepaliveInterval;
    _loadCertificateIdentities();
  }

  Future<void> _loadCertificateIdentities() async {
    if (mounted && !_certificatesLoading) {
      setState(() {
        _certificatesLoading = true;
        _certificateLoadError = null;
      });
    }
    try {
      final inventory =
          await (widget.certificateInventoryLoader?.call() ??
              CertificateEngine.instance.listInventory());
      if (!mounted) return;
      final configured = _findConfiguredIdentity(inventory.identities);
      setState(() {
        _certificateIdentities = inventory.identities;
        _certificateIdentitySelection = configured?.id;
        if (configured != null && configured.isReady) {
          _tlsCertFile.text = configured.certificatePath;
          _tlsKeyFile.text = configured.privateKeyPath;
          _tlsTrustedCaFile.text = configured.trustedCaPath;
        } else {
          _tlsCertFile.clear();
          _tlsKeyFile.clear();
          _tlsTrustedCaFile.clear();
        }
        _certificateLoadError = null;
        _certificatesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _certificateIdentities = const [];
        _certificateIdentitySelection = null;
        _tlsCertFile.clear();
        _tlsKeyFile.clear();
        _tlsTrustedCaFile.clear();
        _certificateLoadError = 'Unable to load certificate identities';
        _certificatesLoading = false;
      });
    }
  }

  ManagedIdentityRecord? _findConfiguredIdentity(
    List<ManagedIdentityRecord> identities,
  ) {
    final configuredId = widget.initial?.tlsIdentityId.trim() ?? '';
    for (final identity in identities) {
      if (configuredId.isNotEmpty && identity.id == configuredId) {
        return identity;
      }
    }
    for (final identity in identities) {
      if (identity.certificatePath == _tlsCertFile.text.trim() &&
          identity.privateKeyPath == _tlsKeyFile.text.trim() &&
          identity.trustedCaPath == _tlsTrustedCaFile.text.trim() &&
          identity.isReady) {
        return identity;
      }
    }
    return null;
  }

  ManagedIdentityRecord? _identityById(String? id) {
    if (id == null) return null;
    for (final identity in _certificateIdentities) {
      if (identity.id == id) return identity;
    }
    return null;
  }

  void _selectCertificateIdentity(String? id) {
    if (id == null) return;
    final identity = _identityById(id);
    if (identity == null || !identity.isReady) return;
    setState(() {
      _certificateIdentitySelection = identity.id;
      _tlsCertFile.text = identity.certificatePath;
      _tlsKeyFile.text = identity.privateKeyPath;
      _tlsTrustedCaFile.text = identity.trustedCaPath;
    });
  }

  @override
  void dispose() {
    _name.clear();
    _addr.clear();
    _port.clear();
    _token.clear();
    _serverId.clear();
    _tlsServerName.clear();
    _tlsCertFile.clear();
    _tlsKeyFile.clear();
    _tlsTrustedCaFile.clear();
    _name.dispose();
    _addr.dispose();
    _port.dispose();
    _token.dispose();
    _serverId.dispose();
    _tlsServerName.dispose();
    _tlsCertFile.dispose();
    _tlsKeyFile.dispose();
    _tlsTrustedCaFile.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final port = int.tryParse(_port.text);
    if (_addr.text.trim().isEmpty || port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid server address and port')),
      );
      return;
    }
    final selectedIdentity = _identityById(_certificateIdentitySelection);
    if (_tlsEnabled &&
        (selectedIdentity == null || !selectedIdentity.isReady)) {
      setState(() => _securityExpanded = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Select a certificate identity that is ready for mutual TLS',
          ),
        ),
      );
      return;
    }
    final id = _serverId.text.trim();
    final originalId = widget.initial?.serverId;
    if (id.length != 8 ||
        appState.servers.any(
          (e) => e.serverId == id && e.serverId != originalId,
        )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Server ID must be unique and 8 characters'),
        ),
      );
      return;
    }
    final base = widget.initial ?? ServerConfig(serverId: id);
    final updated = base.copyWith(
      name: _name.text.trim(),
      serverAddr: _addr.text.trim(),
      serverPort: port,
      token: _token.text,
      serverId: id,
      protocol: _protocol,
      tcpMux: _tcpMux,
      heartbeatInterval: _heartbeatInterval,
      heartbeatTimeout: _heartbeatTimeout,
      tcpMuxKeepaliveInterval: _keepalive,
      tlsEnabled: _tlsEnabled,
      tlsServerName: _tlsServerName.text.trim(),
      tlsIdentityId:
          selectedIdentity?.id ?? (_tlsEnabled ? '' : base.tlsIdentityId),
      tlsCertFile: selectedIdentity?.certificatePath ?? '',
      tlsKeyFile: selectedIdentity?.privateKeyPath ?? '',
      tlsTrustedCaFile: selectedIdentity?.trustedCaPath ?? '',
    );
    final validationError = updated.storageValidationError();
    if (validationError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(validationError)));
      return;
    }
    setState(() => _saving = true);
    final saved = await _runConfigMutation(
      context,
      () =>
          widget.onSave?.call(updated, originalId) ??
          appState.saveServerConfig(updated, originalServerId: originalId),
      'Unable to save server configuration',
    );
    if (mounted) setState(() => _saving = false);
    if (!saved) return;
    if (!mounted) return;
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
    return PopScope(
      canPop: !_saving,
      child: FrostedCard(
        key: const ValueKey('server_config_dialog'),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.dns_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  widget.initial == null ? 'Add Server' : 'Edit Server',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.72,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle('Connection'),
                    const SizedBox(height: 6),
                    TextField(
                      key: const ValueKey('server_name'),
                      controller: _name,
                      style: _controlTextStyle(),
                      decoration: _compactDecoration(
                        'Name',
                        hint: 'e.g., Home Server',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('server_id'),
                      controller: _serverId,
                      readOnly: true,
                      style: _controlTextStyle(fontFamily: 'monospace'),
                      decoration: _compactDecoration(
                        'Server ID',
                        suffixIcon: IconButton(
                          key: const ValueKey('server_reset_id'),
                          tooltip: 'Reset ID',
                          visualDensity: VisualDensity.compact,
                          onPressed: _resetId,
                          icon: const Icon(Icons.refresh, size: 18),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            key: const ValueKey('server_address'),
                            controller: _addr,
                            autocorrect: false,
                            style: _controlTextStyle(),
                            decoration: _compactDecoration(
                              'Server Address *',
                              hint: 'frp.example.com',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('server_port'),
                            controller: _port,
                            keyboardType: TextInputType.number,
                            style: _controlTextStyle(),
                            decoration: _compactDecoration('Port'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('server_token'),
                      controller: _token,
                      obscureText: !_showToken,
                      enableSuggestions: false,
                      autocorrect: false,
                      style: _controlTextStyle(),
                      decoration: _compactDecoration(
                        'Token',
                        suffixIcon: IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            _showToken
                                ? Icons.visibility
                                : Icons.visibility_off,
                            size: 18,
                          ),
                          onPressed: () =>
                              setState(() => _showToken = !_showToken),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _sectionTitle('Transport'),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            key: const ValueKey('server_protocol'),
                            initialValue: _protocol,
                            isExpanded: true,
                            style: _controlTextStyle(),
                            decoration: _compactDecoration('Protocol'),
                            items: _protocols
                                .map(
                                  (p) => DropdownMenuItem(
                                    value: p,
                                    child: Text(_protocolLabel(p)),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) =>
                                setState(() => _protocol = v ?? 'tcp'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: _tcpMuxControl()),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _intervalField(
                            key: const ValueKey('server_heartbeat_interval'),
                            label: 'Heartbeat',
                            value: _heartbeatInterval,
                            onChanged: (v) => _heartbeatInterval = v,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: _intervalField(
                            key: const ValueKey('server_heartbeat_timeout'),
                            label: 'Timeout',
                            value: _heartbeatTimeout,
                            onChanged: (v) => _heartbeatTimeout = v,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: _intervalField(
                            key: const ValueKey('server_keepalive'),
                            label: 'Keepalive',
                            value: _keepalive,
                            onChanged: (v) => _keepalive = v,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _securityExpansionHeader(),
                    if (_securityExpanded) ...[
                      const SizedBox(height: 8),
                      _tlsEnabledControl(),
                      if (_tlsEnabled) ...[
                        const SizedBox(height: 8),
                        _securityTextField(
                          key: const ValueKey('server_tls_server_name'),
                          controller: _tlsServerName,
                          label: 'TLS Server Name (optional)',
                          hint: 'frps.example.com',
                        ),
                        const SizedBox(height: 8),
                        _certificateIdentityControl(),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 4),
                FilledButton.tonal(
                  onPressed: _saving ? null : _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(fontWeight: FontWeight.w600),
    );
  }

  InputDecoration _compactDecoration(
    String label, {
    String? hint,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      suffixIcon: suffixIcon,
      isDense: true,
      constraints: const BoxConstraints.tightFor(height: _controlHeight),
      contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      labelStyle: const TextStyle(fontSize: _controlFontSize),
      floatingLabelStyle: const TextStyle(fontSize: _controlFontSize),
      hintStyle: const TextStyle(fontSize: _controlFontSize),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    );
  }

  TextStyle _controlTextStyle({String? fontFamily}) {
    return (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
        .copyWith(fontSize: _controlFontSize, fontFamily: fontFamily);
  }

  Widget _tcpMuxControl() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('server_tcp_mux_control'),
      constraints: const BoxConstraints.tightFor(height: _controlHeight),
      padding: const EdgeInsets.only(left: 11, right: 2),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'tcpMux',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _controlTextStyle(),
            ),
          ),
          Transform.scale(
            scale: 0.82,
            child: Switch(
              key: const ValueKey('server_tcp_mux'),
              value: _tcpMux,
              onChanged: (v) => setState(() => _tcpMux = v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _securityExpansionHeader() {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: const ValueKey('server_bidirectional_verification'),
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => _securityExpanded = !_securityExpanded),
      child: Container(
        height: _controlHeight,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              _tlsEnabled
                  ? Icons.verified_user_outlined
                  : Icons.shield_outlined,
              size: 18,
              color: _tlsEnabled ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Bidirectional Verification',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _controlTextStyle(),
              ),
            ),
            Icon(
              _securityExpanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tlsEnabledControl() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('server_tls_enabled_control'),
      height: _controlHeight,
      padding: const EdgeInsets.only(left: 11, right: 2),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text('Enable Mutual TLS', style: _controlTextStyle()),
          ),
          Transform.scale(
            scale: 0.82,
            child: Switch(
              key: const ValueKey('server_tls_enabled'),
              value: _tlsEnabled,
              onChanged: (value) => setState(() => _tlsEnabled = value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _securityTextField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextField(
      key: key,
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      style: _controlTextStyle(),
      decoration: _compactDecoration(label, hint: hint),
    );
  }

  Widget _certificateIdentityControl() {
    final scheme = Theme.of(context).colorScheme;
    if (_certificatesLoading) {
      return Container(
        key: const ValueKey('server_tls_identity_loading'),
        height: _controlHeight,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Loading certificate identities…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _controlTextStyle(),
              ),
            ),
          ],
        ),
      );
    }

    final hasReadyIdentity = _certificateIdentities.any(
      (identity) => identity.isReady,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('server_tls_identity'),
          initialValue: _certificateIdentitySelection,
          isExpanded: true,
          style: _controlTextStyle(),
          decoration: _compactDecoration(
            'Certificate Identity *',
            hint: hasReadyIdentity ? 'Select an identity' : 'No ready identity',
            suffixIcon: _certificateLoadError == null
                ? null
                : IconButton(
                    key: const ValueKey('server_tls_identity_retry'),
                    tooltip: 'Reload certificates',
                    visualDensity: VisualDensity.compact,
                    onPressed: _loadCertificateIdentities,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
          ),
          items: [
            ..._certificateIdentities.map(
              (identity) => DropdownMenuItem(
                value: identity.id,
                enabled: identity.isReady,
                child: Text(
                  identity.isReady
                      ? identity.selectionLabel
                      : '${identity.selectionLabel} · Not ready',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _controlTextStyle().copyWith(
                    color: identity.isReady ? null : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
          onChanged: hasReadyIdentity ? _selectCertificateIdentity : null,
        ),
        if (_certificateLoadError != null) ...[
          const SizedBox(height: 4),
          Text(
            '$_certificateLoadError. Tap refresh to retry.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.error),
          ),
        ] else if (!hasReadyIdentity) ...[
          const SizedBox(height: 4),
          Text(
            'Complete an identity in Certificate Management first.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _intervalField({
    required Key key,
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    final options = <int>{..._intervals, value}.toList()..sort();
    return DropdownButtonFormField<int>(
      key: key,
      initialValue: value,
      isExpanded: true,
      style: _controlTextStyle(),
      decoration: _compactDecoration(label),
      items: options
          .map(
            (interval) => DropdownMenuItem(
              value: interval,
              child: Text(interval < 0 ? 'Off' : '${interval}s'),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        setState(() => onChanged(v));
      },
    );
  }

  String _protocolLabel(String protocol) =>
      protocol == 'websocket' ? 'WS' : protocol.toUpperCase();
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
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
