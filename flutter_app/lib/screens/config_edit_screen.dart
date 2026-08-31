import 'package:flutter/material.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';
import '../services/config_domain_service.dart';
import '../services/config_validator.dart';
import '../services/port_mapping_parser.dart';
import '../services/secure_clipboard.dart';
import '../services/toml_generator.dart' as toml;
import '../state/app_state.dart';
import '../widgets/frosted_dialog.dart';

class ConfigEditScreen extends StatefulWidget {
  final int? configId;

  const ConfigEditScreen({super.key, this.configId});

  @override
  State<ConfigEditScreen> createState() => _ConfigEditScreenState();
}

class _ConfigEditScreenState extends State<ConfigEditScreen> {
  static const _formProtocols = ['xtcp', 'xudp'];

  bool get _isEditing => widget.configId != null;

  String _name = '';
  String _serverName = '';
  String _bindAddr = '127.0.0.1';
  String _secretKey = '';
  String _serverId = '';
  String _groupName = '';
  String _protocolToAdd = 'xtcp';

  bool _showSecretKey = false;
  bool _useEncryption = false;
  bool _useCompression = false;
  bool _useFallback = false;

  int _originalGroupId = 0;
  final Set<int> _editingConfigIds = {};
  final List<FrpConfig> _originalSources = [];
  final List<FrpConfig> _originalFallbacks = [];
  final List<FrpConfig> _existingPreviewConfigs = [];
  final Set<String> _unsupportedProtocols = {};

  final Map<String, String> _protocolPorts = {};
  final Map<String, TextEditingController> _portControllers = {};
  final Map<String, TextEditingController> _controllers = {};

  bool get _hasUnsupportedConfigs => _unsupportedProtocols.isNotEmpty;
  bool get _supportsFallback => _protocolPorts.keys.any(
    (protocol) => ConfigDomainService.fallbackProtocolFor(protocol) != null,
  );

  TextEditingController _ctrl(String key) => _controllers[key]!;

  @override
  void initState() {
    super.initState();
    _serverId = appState.effectiveServer.serverId;
    if (_isEditing) {
      FrpConfig? selected;
      for (final config in appState.configs) {
        if (config.id == widget.configId) {
          selected = config;
          break;
        }
      }
      if (selected != null) _initializeExisting(selected);
    }
    _initializeControllers();
  }

  void _initializeControllers() {
    _controllers['name'] = TextEditingController(text: _name);
    _controllers['serverName'] = TextEditingController(text: _serverName);
    _controllers['bindAddr'] = TextEditingController(text: _bindAddr);
    _controllers['secretKey'] = TextEditingController(text: _secretKey);
    _controllers['groupName'] = TextEditingController(text: _groupName);
    for (final entry in _protocolPorts.entries) {
      _portControllers[entry.key] = TextEditingController(text: entry.value);
    }
  }

  void _initializeExisting(FrpConfig selected) {
    _originalGroupId = selected.groupId;
    _serverId =
        appState.servers.any((server) => server.serverId == selected.serverId)
        ? selected.serverId
        : appState.effectiveServer.serverId;
    _groupName = selected.groupName;

    final candidates = selected.groupId > 0
        ? appState.configs
              .where(
                (config) =>
                    config.groupId == selected.groupId &&
                    (config.manualToml == null ||
                        config.manualToml!.trim().isEmpty),
              )
              .toList()
        : <FrpConfig>[selected];
    _existingPreviewConfigs.addAll(candidates);
    _editingConfigIds.addAll(candidates.map((config) => config.id));

    final fallbackIds = <int>{};
    for (final primary in candidates) {
      final fallbackProtocol = ConfigDomainService.fallbackProtocolFor(
        primary.protocol,
      );
      if (!primary.useFallback ||
          fallbackProtocol == null ||
          primary.fallbackTo.isEmpty) {
        continue;
      }
      for (final candidate in candidates) {
        if (candidate.protocol == fallbackProtocol &&
            candidate.name == primary.fallbackTo) {
          fallbackIds.add(candidate.id);
        }
      }
    }

    for (final config in candidates) {
      if (fallbackIds.contains(config.id)) {
        _originalFallbacks.add(config);
      } else if (_formProtocols.contains(config.protocol.toLowerCase())) {
        _originalSources.add(config);
      } else {
        _unsupportedProtocols.add(config.protocol.toUpperCase());
      }
    }

    if (_originalSources.isEmpty) return;
    final primary = _originalSources.firstWhere(
      (config) => config.isGroupPrimary,
      orElse: () => _originalSources.first,
    );
    final sameProtocolCount = _originalSources
        .where((config) => config.protocol == primary.protocol)
        .length;
    _name = _baseFromGeneratedValue(
      primary.name,
      primary.protocol,
      bindPort: primary.bindPort,
      hadMultiplePorts: sameProtocolCount > 1,
    );
    _serverName = _baseFromGeneratedValue(
      primary.serverName ?? '',
      primary.protocol,
      bindPort: primary.bindPort,
      hadMultiplePorts: sameProtocolCount > 1,
    );
    _bindAddr = primary.bindAddr.trim().isEmpty
        ? '127.0.0.1'
        : primary.bindAddr;
    _secretKey = primary.secretKey ?? '';
    _useEncryption = _originalSources.any((config) => config.useEncryption);
    _useCompression = _originalSources.any((config) => config.useCompression);
    _useFallback = _originalSources.any((config) => config.useFallback);

    for (final protocol in _formProtocols) {
      final ports =
          _originalSources
              .where((config) => config.protocol == protocol)
              .map((config) => config.bindPort)
              .toList()
            ..sort();
      if (ports.isEmpty) continue;
      _protocolPorts[protocol] = PortMappingParser.formatPorts(ports);
    }
    _protocolToAdd = _protocolPorts.keys.isEmpty
        ? 'xtcp'
        : _protocolPorts.keys.first;
  }

  String _baseFromGeneratedValue(
    String value,
    String protocol, {
    required int bindPort,
    required bool hadMultiplePorts,
  }) {
    var result = value.trim();
    if (hadMultiplePorts) {
      result = result.replaceFirst(
        RegExp(
          '-${RegExp.escape(protocol)}-${RegExp.escape('$bindPort')}\$',
          caseSensitive: false,
        ),
        '',
      );
    }
    return result.replaceFirst(
      RegExp('-${RegExp.escape(protocol)}\$', caseSensitive: false),
      '',
    );
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final controller in _portControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String get _effectiveServerId {
    if (appState.servers.any((server) => server.serverId == _serverId)) {
      return _serverId;
    }
    return appState.effectiveServer.serverId;
  }

  ServerConfig get _previewServer => appState.servers.firstWhere(
    (server) => server.serverId == _effectiveServerId,
    orElse: () => appState.effectiveServer,
  );

  void _addProtocol() {
    final protocol = _protocolToAdd.toLowerCase();
    if (_protocolPorts.containsKey(protocol)) {
      _toast(
        '${protocol.toUpperCase()} is already added; enter multiple ports in its Bind Port(s) field',
      );
      return;
    }
    setState(() {
      _protocolPorts[protocol] = '9002';
      _portControllers[protocol] = TextEditingController(text: '9002');
    });
  }

  void _removeProtocol(String protocol) {
    setState(() {
      _protocolPorts.remove(protocol);
      _portControllers.remove(protocol)?.dispose();
      if (_protocolPorts.isEmpty) _useFallback = false;
    });
  }

  PortListParseResult _parseProtocolPorts(String protocol) {
    return PortMappingParser.parsePorts(
      _protocolPorts[protocol] ?? '',
      label: '${protocol.toUpperCase()} bind',
      allowDisabledPort: protocol == 'xtcp',
    );
  }

  String _normalizedBase(String input) {
    return input.trim().replaceFirst(
      RegExp(r'-(?:stcp|sudp|xtcp|xudp)(?:-\d+)?$', caseSensitive: false),
      '',
    );
  }

  String _generatedValue(
    String input,
    String protocol,
    int bindPort, {
    required bool hasMultiplePorts,
  }) {
    final base = _normalizedBase(input);
    if (base.isEmpty) return '';
    final portSuffix = hasMultiplePorts ? '-$bindPort' : '';
    return '$base-$protocol$portSuffix';
  }

  FrpConfig? _takeOriginalSource(
    String protocol,
    int bindPort,
    Set<int> usedIds,
  ) {
    for (final original in _originalSources) {
      if (!usedIds.contains(original.id) &&
          original.protocol == protocol &&
          original.bindPort == bindPort) {
        usedIds.add(original.id);
        return original;
      }
    }
    for (final original in _originalSources) {
      if (!usedIds.contains(original.id) && original.protocol == protocol) {
        usedIds.add(original.id);
        return original;
      }
    }
    return null;
  }

  FrpConfig? _takeOriginalFallback(FrpConfig generated, Set<int> usedIds) {
    for (final original in _originalFallbacks) {
      if (!usedIds.contains(original.id) &&
          original.protocol == generated.protocol &&
          original.name == generated.name) {
        usedIds.add(original.id);
        return original;
      }
    }
    for (final original in _originalFallbacks) {
      if (!usedIds.contains(original.id) &&
          original.protocol == generated.protocol) {
        usedIds.add(original.id);
        return original;
      }
    }
    return null;
  }

  FrpConfig _buildSourceConfig(
    String protocol,
    int bindPort, {
    required bool hasMultiplePorts,
    FrpConfig? original,
  }) {
    final config = original ?? const FrpConfig();
    return config.copyWith(
      name: _generatedValue(
        _name,
        protocol,
        bindPort,
        hasMultiplePorts: hasMultiplePorts,
      ),
      protocol: protocol,
      role: 'visitor',
      secretKey: _secretKey.trim().isEmpty ? null : _secretKey.trim(),
      serverName: _generatedValue(
        _serverName,
        protocol,
        bindPort,
        hasMultiplePorts: hasMultiplePorts,
      ),
      bindPort: bindPort,
      bindAddr: _bindAddr.trim().isEmpty ? '127.0.0.1' : _bindAddr.trim(),
      useEncryption: _useEncryption,
      useCompression: _useCompression,
      useFallback: _useFallback,
      fallbackTo: '',
      fallbackTimeoutMs: 3000,
      useCustomStcp: false,
      stcpName: '',
      stcpSecretKey: '',
      stcpServerName: '',
      stcpBindPort: -1,
      stcpBindAddr: '127.0.0.1',
      serverId: _effectiveServerId,
      groupName: _groupName,
      manualToml: null,
    );
  }

  int _allocateSudpBindPort(int primaryPort, Set<int> occupiedUdpPorts) {
    var candidate = primaryPort < 65535 ? primaryPort + 1 : 9002;
    while (candidate <= 65535 && occupiedUdpPorts.contains(candidate)) {
      candidate += 1;
    }
    if (candidate <= 65535) {
      occupiedUdpPorts.add(candidate);
      return candidate;
    }
    for (candidate = 9002; candidate < primaryPort; candidate++) {
      if (occupiedUdpPorts.add(candidate)) return candidate;
    }
    return primaryPort;
  }

  _ConfigCollection _collectConfigSet() {
    if (_hasUnsupportedConfigs) {
      return _ConfigCollection(
        entries: const [],
        errors: [
          'This group contains unsupported form protocols: ${_unsupportedProtocols.join(', ')}',
        ],
      );
    }

    final errors = <String>[];
    if (_normalizedBase(_name).isEmpty) errors.add('Name is required');
    if (_normalizedBase(_serverName).isEmpty) {
      errors.add('Server name is required');
    }
    if (_secretKey.trim().isEmpty) errors.add('Secret key is required');
    if (_protocolPorts.isEmpty) errors.add('Add at least one protocol');

    final sourceEntries = <_GeneratedConfigEntry>[];
    final usedSourceIds = <int>{};
    for (final entry in _protocolPorts.entries) {
      final parsed = _parseProtocolPorts(entry.key);
      if (parsed.error != null) {
        errors.add(parsed.error!);
        continue;
      }
      final hasMultiplePorts = parsed.ports.length > 1;
      for (final port in parsed.ports) {
        final original = _takeOriginalSource(entry.key, port, usedSourceIds);
        final config = _buildSourceConfig(
          entry.key,
          port,
          hasMultiplePorts: hasMultiplePorts,
          original: original,
        );
        final error = ConfigValidator.validate(config);
        if (error != null) {
          errors.add('${entry.key.toUpperCase()} $port: $error');
          continue;
        }
        sourceEntries.add(_GeneratedConfigEntry(config: config));
      }
    }

    final occupiedUdpPorts = sourceEntries
        .where((entry) => entry.config.protocol == 'xudp')
        .map((entry) => entry.config.bindPort)
        .where((port) => port > 0)
        .toSet();
    final fallbackEntries = <_GeneratedConfigEntry>[];
    final usedFallbackIds = <int>{};
    for (var i = 0; i < sourceEntries.length; i++) {
      var primary = sourceEntries[i].config;
      if (!_useFallback || !primary.supportsFallback()) continue;

      var fallback = ConfigDomainService.createLinkedFallbackConfig(primary);
      if (fallback.protocol == 'sudp') {
        fallback = fallback.copyWith(
          bindPort: _allocateSudpBindPort(primary.bindPort, occupiedUdpPorts),
          bindAddr: primary.bindAddr,
        );
      }
      final original = _takeOriginalFallback(fallback, usedFallbackIds);
      if (original != null) {
        fallback = fallback.copyWith(
          id: original.id,
          createdAt: original.createdAt,
          enabled: original.enabled,
        );
      }
      primary = primary.copyWith(fallbackTo: fallback.name);
      sourceEntries[i] = _GeneratedConfigEntry(config: primary);

      final error = ConfigValidator.validate(fallback);
      if (error != null) {
        errors.add('${fallback.protocol.toUpperCase()} fallback: $error');
      } else {
        fallbackEntries.add(
          _GeneratedConfigEntry(config: fallback, isFallback: true),
        );
      }
    }

    final entries = [...sourceEntries, ...fallbackEntries];
    final names = <String>{};
    for (final entry in entries) {
      if (!names.add(entry.config.name)) {
        errors.add('Generated name is duplicated: ${entry.config.name}');
      }
    }
    _appendVisitorBindConflicts(entries, errors);
    return _ConfigCollection(entries: entries, errors: errors);
  }

  void _appendVisitorBindConflicts(
    List<_GeneratedConfigEntry> entries,
    List<String> errors,
  ) {
    final listeners = <FrpConfig>[];
    for (final entry in entries) {
      final config = entry.config;
      final family = _visitorTransportFamily(config.protocol);
      if (family == null || config.bindPort <= 0) continue;
      for (final existing in listeners) {
        if (_visitorTransportFamily(existing.protocol) != family ||
            existing.bindPort != config.bindPort ||
            !_bindAddressesConflict(existing.bindAddr, config.bindAddr)) {
          continue;
        }
        errors.add(
          '${config.protocol.toUpperCase()} "${config.name}" and '
          '${existing.protocol.toUpperCase()} "${existing.name}" both listen '
          'on ${config.bindAddr}:${config.bindPort}/$family',
        );
        break;
      }
      listeners.add(config);
    }
  }

  String? _visitorTransportFamily(String protocol) =>
      switch (protocol.toLowerCase()) {
        'stcp' || 'xtcp' => 'tcp',
        'sudp' || 'xudp' => 'udp',
        _ => null,
      };

  bool _bindAddressesConflict(String first, String second) {
    final a = first.trim().toLowerCase();
    final b = second.trim().toLowerCase();
    const wildcards = {'', '0.0.0.0', '::', '[::]'};
    return a == b || wildcards.contains(a) || wildcards.contains(b);
  }

  Future<void> _save() async {
    final collection = _collectConfigSet();
    if (collection.errors.isNotEmpty) {
      _toast(collection.errors.first);
      return;
    }

    final externalConfigs = appState.configs.where(
      (config) => !_editingConfigIds.contains(config.id),
    );
    final generatedNames = collection.configs
        .expand((config) => config.configuredNames)
        .toSet();
    for (final existing in externalConfigs) {
      if (existing.serverId.isNotEmpty &&
          existing.serverId != _effectiveServerId) {
        continue;
      }
      final collision = generatedNames.intersection(
        existing.configuredNames.toSet(),
      );
      if (collision.isNotEmpty) {
        _toast('Proxy name already exists: ${collision.first}');
        return;
      }
    }

    final preservedGroupMembers = _originalGroupId > 0
        ? appState.configs
              .where(
                (config) =>
                    config.groupId == _originalGroupId &&
                    !_editingConfigIds.contains(config.id),
              )
              .toList()
        : const <FrpConfig>[];
    final grouped =
        collection.configs.length + preservedGroupMembers.length > 1;
    var groupId = _originalGroupId;
    if (grouped && groupId <= 0) {
      groupId = DateTime.now().millisecondsSinceEpoch;
      while (appState.configs.any((config) => config.groupId == groupId)) {
        groupId += 1;
      }
    }

    final groupName = _groupName.trim().isEmpty
        ? _normalizedBase(_name)
        : _groupName.trim();
    var markedPrimary = preservedGroupMembers.any(
      (config) => config.isGroupPrimary,
    );
    final replacements = <FrpConfig>[];
    for (final entry in collection.entries) {
      final isPrimary = grouped && !markedPrimary && !entry.isFallback;
      if (isPrimary) markedPrimary = true;
      replacements.add(
        entry.config.copyWith(
          groupId: grouped ? groupId : 0,
          groupName: groupName,
          isGroupPrimary: isPrimary,
        ),
      );
    }

    await appState.replaceConfigSet(
      existingIds: _editingConfigIds,
      replacements: replacements,
    );
    if (grouped && preservedGroupMembers.isNotEmpty) {
      await appState.renameGroup(groupId, groupName);
    }
    _toast(
      grouped
          ? 'Configuration group saved (${replacements.length} configs)'
          : (_isEditing ? 'Configuration updated' : 'Configuration added'),
    );
    if (mounted) Navigator.pop(context);
  }

  String _generatePreview() {
    if (_hasUnsupportedConfigs) {
      return toml.generateServerPreview(
        _previewServer,
        _existingPreviewConfigs,
      );
    }
    final collection = _collectConfigSet();
    final preview = StringBuffer(
      toml.generateServerPreview(_previewServer, collection.configs),
    );
    if (collection.errors.isNotEmpty) {
      if (preview.isNotEmpty && !preview.toString().endsWith('\n')) {
        preview.writeln();
      }
      preview.writeln('# Incomplete configuration');
      for (final error in collection.errors) {
        preview.writeln('# $error');
      }
    }
    return preview.toString();
  }

  String _derivePeerConfig() {
    final collection = _collectConfigSet();
    final result = StringBuffer(
      '# ===== Peer frpc config (run on the target machine) =====\n'
      '# Adjust localIP / localPort to the actual service address on the peer.\n'
      '# secretKey / encryption / compression must match this app.\n\n',
    );
    final fallbackLocalPorts = {
      for (final entry in collection.entries)
        if (!entry.isFallback && entry.config.fallbackTo.isNotEmpty)
          entry.config.fallbackTo: entry.config.bindPort,
    };
    for (final entry in collection.entries) {
      final config = entry.config;
      var localPort = entry.isFallback
          ? fallbackLocalPorts[config.name] ?? config.bindPort
          : config.bindPort;
      // -1 disables the visitor listener and is not a valid peer localPort.
      if (localPort <= 0) localPort = 22;
      result.writeln(
        proxyBlockForPeer(
          config.serverName ?? config.name,
          config.protocol,
          config.secretKey ?? '',
          '127.0.0.1',
          localPort,
          useEncryption: config.useEncryption,
          useCompression: config.useCompression,
        ).trimRight(),
      );
      result.writeln();
    }
    return result.toString().trimRight();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  InputDecoration _compactDecoration(
    String label, {
    String? hint,
    String? helper,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      suffixIcon: suffixIcon,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    );
  }

  Widget _smallSwitch(bool value, ValueChanged<bool> onChanged) {
    return SizedBox(
      width: 44,
      height: 32,
      child: FittedBox(
        fit: BoxFit.contain,
        child: Switch(
          value: value,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _compactSwitch(
    BuildContext context, {
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyMedium),
                  if (subtitle != null)
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
            _smallSwitch(value, onChanged),
          ],
        ),
      ),
    );
  }

  Widget _protocolCard(BuildContext context, String protocol) {
    final parsed = _parseProtocolPorts(protocol);
    final count = parsed.ports.length;
    final status =
        parsed.error ??
        '$count bind ${count == 1 ? "port" : "ports"}; '
            '${count > 1 ? "names include each port number" : "no port suffix"}';
    final statusColor = parsed.error == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : Theme.of(context).colorScheme.error;
    return Card(
      key: ValueKey('protocol_card_$protocol'),
      margin: const EdgeInsets.only(top: 8),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    protocol.toUpperCase(),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: ValueKey('remove_protocol_$protocol'),
                  tooltip: 'Remove ${protocol.toUpperCase()}',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _removeProtocol(protocol),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            TextField(
              key: ValueKey('bind_ports_$protocol'),
              controller: _portControllers[protocol],
              onChanged: (value) => setState(() {
                _protocolPorts[protocol] = value;
              }),
              keyboardType: TextInputType.text,
              autocorrect: false,
              smartDashesType: SmartDashesType.disabled,
              decoration: _compactDecoration(
                '${protocol.toUpperCase()} Bind Port(s) *',
                hint: '9002,9010-9012',
              ),
            ),
            const SizedBox(height: 4),
            Text(
              status,
              key: ValueKey('bind_ports_status_$protocol'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: statusColor),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Form Config' : 'Form Config'),
        actions: [
          TextButton(
            onPressed: _hasUnsupportedConfigs ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Card(
          key: const ValueKey('form_config_card'),
          elevation: 2,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle(context, 'Basic Information'),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  key: const ValueKey('server_selector'),
                  initialValue: _serverId,
                  isExpanded: true,
                  decoration: _compactDecoration('Belongs to Server'),
                  items: appState.servers
                      .map(
                        (server) => DropdownMenuItem(
                          value: server.serverId,
                          child: Text(
                            '${server.name.isEmpty ? "FRPS Server" : server.name} (${server.serverId})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => _serverId = value ?? ''),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('group_name'),
                  controller: _ctrl('groupName'),
                  onChanged: (value) => setState(() => _groupName = value),
                  decoration: _compactDecoration(
                    'Group Name',
                    helper: 'Defaults to the primary protocol name when blank',
                  ),
                ),
                const SizedBox(height: 12),
                if (_hasUnsupportedConfigs) ...[
                  Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        'This existing group contains ${_unsupportedProtocols.join(', ')}. '
                        'The grouped Form Config editor supports XTCP/XUDP visitors; '
                        'the original configuration is preserved and shown below.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _sectionTitle(context, 'Configuration'),
                const SizedBox(height: 6),
                TextField(
                  key: const ValueKey('config_name'),
                  controller: _ctrl('name'),
                  onChanged: (value) => setState(() => _name = value),
                  decoration: _compactDecoration(
                    'Name *',
                    hint: 'Application-Name',
                    helper:
                        'Protocol is appended automatically, e.g. Application-Name-xtcp',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('server_proxy_name'),
                  controller: _ctrl('serverName'),
                  onChanged: (value) => setState(() => _serverName = value),
                  decoration: _compactDecoration(
                    'Server Name *',
                    hint: 'Server-Name',
                    helper: 'Uses the same protocol and multi-port suffix rule',
                  ),
                ),
                const SizedBox(height: 12),
                _sectionTitle(context, 'Protocols'),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey('protocol_dropdown'),
                        initialValue: _protocolToAdd,
                        decoration: _compactDecoration('Protocol'),
                        items: _formProtocols
                            .map(
                              (protocol) => DropdownMenuItem(
                                value: protocol,
                                child: Text(protocol.toUpperCase()),
                              ),
                            )
                            .toList(),
                        onChanged: (protocol) => setState(() {
                          if (protocol != null) _protocolToAdd = protocol;
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      key: const ValueKey('add_protocol'),
                      tooltip: 'Add protocol',
                      onPressed: _addProtocol,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _protocolPorts.isEmpty
                            ? 'Add XTCP, XUDP, or both to this group.'
                            : 'Each protocol accepts comma-separated ports or ranges.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Text(
                      '${_protocolPorts.length}',
                      key: const ValueKey('protocol_count'),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
                for (final protocol in _protocolPorts.keys)
                  _protocolCard(context, protocol),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('bind_address'),
                  controller: _ctrl('bindAddr'),
                  onChanged: (value) => setState(() => _bindAddr = value),
                  decoration: _compactDecoration('Bind Address'),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('secret_key'),
                  controller: _ctrl('secretKey'),
                  onChanged: (value) => setState(() => _secretKey = value),
                  obscureText: !_showSecretKey,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: _compactDecoration(
                    'Secret Key *',
                    hint: 'Shared secret for all protocols in this group',
                    suffixIcon: IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        _showSecretKey
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _showSecretKey = !_showSecretKey),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _compactSwitch(
                        context,
                        title: 'Encryption',
                        value: _useEncryption,
                        onChanged: (value) =>
                            setState(() => _useEncryption = value),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _compactSwitch(
                        context,
                        title: 'Compression',
                        value: _useCompression,
                        onChanged: (value) =>
                            setState(() => _useCompression = value),
                      ),
                    ),
                  ],
                ),
                if (_supportsFallback) ...[
                  const SizedBox(height: 4),
                  _compactSwitch(
                    context,
                    title: 'Fallback',
                    subtitle:
                        'Automatically generate STCP from XTCP and SUDP from XUDP',
                    value: _useFallback,
                    onChanged: (value) => setState(() => _useFallback = value),
                  ),
                ],
                const SizedBox(height: 12),
                if (_protocolPorts.isNotEmpty && !_hasUnsupportedConfigs) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const ValueKey('derive_peer_config'),
                      onPressed: _showPeerConfigDialog,
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Derive Peer Config'),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  clipBehavior: Clip.antiAlias,
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: ExpansionTile(
                    key: const ValueKey('configuration_preview'),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                    childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    title: Text(
                      'Configuration Preview',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          _generatePreview(),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            height: 1.25,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showPeerConfigDialog() {
    final text = _derivePeerConfig();
    showFrostedDialog<void>(
      context: context,
      builder: (dialogContext) => FrostedCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Peer frpc Config',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Run this on the target machine. Adjust localIP / localPort to the actual service address.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  key: const ValueKey('peer_config_text'),
                  text,
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
                  onPressed: () async {
                    try {
                      await SecureClipboard.copy(text);
                      if (mounted) {
                        _toast('Peer config copied; clipboard clears in 60s');
                      }
                    } catch (_) {
                      if (mounted) _toast('Unable to copy peer config');
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

class _ConfigCollection {
  final List<_GeneratedConfigEntry> entries;
  final List<String> errors;

  const _ConfigCollection({required this.entries, required this.errors});

  List<FrpConfig> get configs => [for (final entry in entries) entry.config];
}

class _GeneratedConfigEntry {
  final FrpConfig config;
  final bool isFallback;

  const _GeneratedConfigEntry({required this.config, this.isFallback = false});
}

/// Peer frpc proxy block. Form Config creates visitor blocks locally and uses
/// these matching proxy blocks for the copyable peer-side configuration.
String proxyBlockForPeer(
  String name,
  String protocol,
  String key,
  String ip,
  int port, {
  required bool useEncryption,
  required bool useCompression,
}) {
  final buffer = StringBuffer();
  buffer.writeln('[[proxies]]');
  buffer.writeln('name = "$name"');
  buffer.writeln('type = "$protocol"');
  buffer.writeln('localIP = "$ip"');
  buffer.writeln('localPort = $port');
  if (key.isNotEmpty) buffer.writeln('secretKey = "$key"');
  if (useEncryption || useCompression) {
    buffer.writeln();
    buffer.writeln('[proxies.transport]');
    buffer.writeln('useEncryption = $useEncryption');
    buffer.writeln('useCompression = $useCompression');
  }
  return buffer.toString();
}
