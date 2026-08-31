import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';
import '../services/config_domain_service.dart';
import '../services/config_validator.dart';
import '../services/port_mapping_parser.dart';
import '../services/toml_generator.dart' as toml;
import '../widgets/frosted_dialog.dart';
import '../state/app_state.dart';

class ConfigEditScreen extends StatefulWidget {
  final int? configId;
  const ConfigEditScreen({super.key, this.configId});

  @override
  State<ConfigEditScreen> createState() => _ConfigEditScreenState();
}

class _ConfigEditScreenState extends State<ConfigEditScreen> {
  bool get _isEditing => widget.configId != null;

  // 表单状态
  String _name = '';
  String _localIp = '127.0.0.1';
  String _localPort = '';
  String _remotePort = '';
  String _localPorts = '';
  String _remotePorts = '';
  String _customDomains = '';
  String _protocol = 'tcp';
  String _role = 'visitor';
  String _secretKey = '';
  String _serverName = '';
  String _bindPort = '9002';
  String _bindAddr = '127.0.0.1';
  bool _showSecretKey = false;
  String _serverId = '';
  String _editGroupName = '';

  // 传输加密/压缩
  bool _useEncryption = false;
  bool _useCompression = false;

  // XTCP/XUDP 回落（字段名保留 STCP 以兼容已有备份数据）
  bool _useFallback = false;
  String _fallbackTimeoutMs = '3000';
  bool _useCustomStcp = false;
  String _stcpName = '';
  String _stcpSecretKey = '';
  String _stcpServerName = '';
  String _stcpBindPort = '-1';
  String _stcpBindAddr = '127.0.0.1';

  // 固定规则（XTCP 自动 -xtcp 后缀）
  bool _useNamingRule = true;
  bool _serverNameCustomized = false;

  final Map<int, _ProtocolDraft> _protocolDrafts = {};
  final Map<int, FrpConfig> _originalByDraftId = {};
  final List<int> _includedDraftIds = [];
  final Set<int> _editingConfigIds = {};
  int _originalGroupId = 0;
  int _activeDraftId = 0;
  int _primaryDraftId = 0;
  int _nextDraftId = 1;

  final Map<String, TextEditingController> _controllers = {};

  TextEditingController _ctrl(String key) =>
      _controllers.putIfAbsent(key, () => TextEditingController());

  void _initControllers() {
    _controllers['name'] = TextEditingController(text: _name);
    _controllers['localIp'] = TextEditingController(text: _localIp);
    _controllers['localPort'] = TextEditingController(text: _localPort);
    _controllers['remotePort'] = TextEditingController(text: _remotePort);
    _controllers['localPorts'] = TextEditingController(text: _localPorts);
    _controllers['remotePorts'] = TextEditingController(text: _remotePorts);
    _controllers['customDomains'] = TextEditingController(text: _customDomains);
    _controllers['secretKey'] = TextEditingController(text: _secretKey);
    _controllers['serverName'] = TextEditingController(text: _serverName);
    _controllers['bindAddr'] = TextEditingController(text: _bindAddr);
    _controllers['bindPort'] = TextEditingController(text: _bindPort);
    _controllers['fallbackTimeoutMs'] = TextEditingController(
      text: _fallbackTimeoutMs,
    );
    _controllers['stcpName'] = TextEditingController(text: _stcpName);
    _controllers['stcpSecretKey'] = TextEditingController(text: _stcpSecretKey);
    _controllers['stcpServerName'] = TextEditingController(
      text: _stcpServerName,
    );
    _controllers['stcpBindAddr'] = TextEditingController(text: _stcpBindAddr);
    _controllers['stcpBindPort'] = TextEditingController(text: _stcpBindPort);
    _controllers['editGroupName'] = TextEditingController(text: _editGroupName);
  }

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      final id = widget.configId!;
      final cfg = appState.configs.where((e) => e.id == id).firstOrNull;
      if (cfg != null) {
        _initializeExistingDrafts(cfg);
      }
    } else {
      _serverId = appState.effectiveServer.serverId;
      _activeDraftId = _addDraft(_ProtocolDraft.defaults(_protocol));
      _primaryDraftId = _activeDraftId;
    }
    _initControllers();
    if (_activeDraftId == 0) {
      _activeDraftId = _addDraft(_ProtocolDraft.defaults(_protocol));
      _primaryDraftId = _activeDraftId;
    }
    _protocolDrafts[_activeDraftId] = _captureCurrentDraft();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _initializeExistingDrafts(FrpConfig selected) {
    _originalGroupId = selected.groupId;
    _serverId =
        appState.servers.any((server) => server.serverId == selected.serverId)
        ? selected.serverId
        : appState.effectiveServer.serverId;
    _editGroupName = selected.groupName;

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
    final primary = candidates.firstWhere(
      (config) => config.isGroupPrimary,
      orElse: () => selected,
    );
    final ordered = <FrpConfig>[
      primary,
      ...candidates.where((config) => config.id != primary.id),
    ];
    var selectedDraftId = 0;
    for (final config in ordered) {
      final draftId = _addDraft(
        _ProtocolDraft.fromConfig(config),
        original: config,
      );
      _editingConfigIds.add(config.id);
      if (config.id == primary.id) _primaryDraftId = draftId;
      if (config.id == selected.id) selectedDraftId = draftId;
    }

    _activeDraftId = selectedDraftId != 0
        ? selectedDraftId
        : _includedDraftIds.first;
    if (_primaryDraftId == 0) _primaryDraftId = _activeDraftId;
    _applyDraft(_protocolDrafts[_activeDraftId]!, updateControllers: false);
  }

  int _addDraft(_ProtocolDraft draft, {FrpConfig? original}) {
    final draftId = _nextDraftId++;
    _protocolDrafts[draftId] = draft;
    _includedDraftIds.add(draftId);
    if (original != null) _originalByDraftId[draftId] = original;
    return draftId;
  }

  bool get _isSecretProtocol => FrpConfig.secretProtocols.contains(_protocol);
  bool get _isHttpProtocol => _protocol == 'http' || _protocol == 'https';
  bool get _supportsMultiPort => _protocol == 'tcp' || _protocol == 'udp';
  bool get _isVisitor => _role == 'visitor';
  bool get _supportsFallback => _protocol == 'xtcp' || _protocol == 'xudp';

  String get _fallbackProtocol =>
      ConfigDomainService.fallbackProtocolFor(_protocol) ?? 'stcp';

  String get _autoFallbackName => ConfigDomainService.fallbackNameFor(
    _effectiveName.isEmpty ? 'service' : _effectiveName,
    protocol: _protocol,
  );

  int get _autoFallbackBindPort =>
      ConfigDomainService.defaultFallbackBindPortFor(
        FrpConfig(protocol: _protocol, bindPort: int.tryParse(_bindPort) ?? 0),
      );

  /// XTCP 固定规则后的有效名称（linux-ssh → linux-ssh-xtcp）
  String get _effectiveName {
    return ConfigDomainService.effectiveName(
      _name,
      protocol: _protocol,
      useNamingRule: _useNamingRule,
    );
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

  void _syncServerName() {
    if (!_serverNameCustomized && _protocol == 'xtcp') {
      _serverName = _effectiveName;
      _controllers['serverName']?.text = _effectiveName;
    }
  }

  PortMappingParseResult get _parsedPortMappings =>
      PortMappingParser.parse(_localPorts, _remotePorts);

  void _changeProtocol(String protocol) {
    final target = protocol.toLowerCase();
    if (target == _protocol) return;

    final current = _captureCurrentDraft();
    final previousDraftId = _activeDraftId;
    _protocolDrafts[previousDraftId] = current;
    final removePristine =
        !_originalByDraftId.containsKey(previousDraftId) && current.isPristine;
    if (removePristine) {
      _includedDraftIds.remove(previousDraftId);
      _protocolDrafts.remove(previousDraftId);
    }

    var nextDraftId = _includedDraftIds.firstWhere(
      (draftId) => _protocolDrafts[draftId]?.protocol == target,
      orElse: () => 0,
    );
    if (nextDraftId == 0) {
      nextDraftId = _addDraft(_newDraftForProtocol(target));
    }
    if (removePristine && _primaryDraftId == previousDraftId) {
      _primaryDraftId = nextDraftId;
    }
    _switchDraft(nextDraftId, captureCurrent: false);
  }

  void _addProtocolInstance() {
    _protocolDrafts[_activeDraftId] = _captureCurrentDraft();
    final nextDraftId = _addDraft(_newDraftForProtocol(_protocol));
    _switchDraft(nextDraftId, captureCurrent: false);
  }

  _ProtocolDraft _newDraftForProtocol(String protocol) {
    if (!FrpConfig.secretProtocols.contains(protocol)) {
      return _ProtocolDraft.defaults(protocol);
    }
    return _ProtocolDraft.defaults(
      protocol,
      bindPort: '${_nextAvailableVisitorPort(protocol)}',
    );
  }

  int _nextAvailableVisitorPort(String protocol) {
    final udp = protocol == 'sudp' || protocol == 'xudp';
    final used = <int>{};
    for (final draftId in _includedDraftIds) {
      final draft = _protocolDrafts[draftId];
      if (draft == null || draft.role != 'visitor') continue;
      final draftUsesUdp = draft.protocol == 'sudp' || draft.protocol == 'xudp';
      if (draftUsesUdp != udp) continue;
      final port = int.tryParse(draft.bindPort) ?? -1;
      if (port <= 0) continue;
      used.add(port);
      // Keep the adjacent UDP port available for a possible XUDP→SUDP pair.
      if (draft.protocol == 'xudp' && port < 65535) used.add(port + 1);
    }

    final maxCandidate = protocol == 'xudp' ? 65534 : 65535;
    for (var candidate = 9002; candidate <= maxCandidate; candidate++) {
      if (used.contains(candidate)) continue;
      if (protocol == 'xudp' && used.contains(candidate + 1)) continue;
      return candidate;
    }
    return 9002;
  }

  void _switchDraft(int draftId, {bool captureCurrent = true}) {
    if (draftId == _activeDraftId) return;
    final next = _protocolDrafts[draftId];
    if (next == null) return;
    if (captureCurrent && _activeDraftId != 0) {
      _protocolDrafts[_activeDraftId] = _captureCurrentDraft();
    }
    _activeDraftId = draftId;
    _applyDraft(next);
  }

  void _removeProtocol(int draftId) {
    if (_includedDraftIds.length <= 1) return;
    _protocolDrafts[_activeDraftId] = _captureCurrentDraft();
    _includedDraftIds.remove(draftId);
    _protocolDrafts.remove(draftId);
    _originalByDraftId.remove(draftId);
    if (_primaryDraftId == draftId) {
      _primaryDraftId = _includedDraftIds.first;
    }
    if (_activeDraftId != draftId) return;

    final nextDraftId = _includedDraftIds.first;
    _activeDraftId = nextDraftId;
    _applyDraft(_protocolDrafts[nextDraftId]!);
  }

  _ProtocolDraft _captureCurrentDraft() => _ProtocolDraft(
    protocol: _protocol,
    name: _name,
    localIp: _localIp,
    localPort: _localPort,
    remotePort: _remotePort,
    localPorts: _localPorts,
    remotePorts: _remotePorts,
    customDomains: _customDomains,
    role: _role,
    secretKey: _secretKey,
    serverName: _serverName,
    bindPort: _bindPort,
    bindAddr: _bindAddr,
    useEncryption: _useEncryption,
    useCompression: _useCompression,
    useFallback: _useFallback,
    fallbackTimeoutMs: _fallbackTimeoutMs,
    useCustomStcp: _useCustomStcp,
    stcpName: _stcpName,
    stcpSecretKey: _stcpSecretKey,
    stcpServerName: _stcpServerName,
    stcpBindPort: _stcpBindPort,
    stcpBindAddr: _stcpBindAddr,
    useNamingRule: _useNamingRule,
    serverNameCustomized: _serverNameCustomized,
  );

  void _applyDraft(_ProtocolDraft draft, {bool updateControllers = true}) {
    _protocol = draft.protocol;
    _name = draft.name;
    _localIp = draft.localIp;
    _localPort = draft.localPort;
    _remotePort = draft.remotePort;
    _localPorts = draft.localPorts;
    _remotePorts = draft.remotePorts;
    _customDomains = draft.customDomains;
    _role = draft.role;
    _secretKey = draft.secretKey;
    _serverName = draft.serverName;
    _bindPort = draft.bindPort;
    _bindAddr = draft.bindAddr;
    _useEncryption = draft.useEncryption;
    _useCompression = draft.useCompression;
    _useFallback = draft.useFallback;
    _fallbackTimeoutMs = draft.fallbackTimeoutMs;
    _useCustomStcp = draft.useCustomStcp;
    _stcpName = draft.stcpName;
    _stcpSecretKey = draft.stcpSecretKey;
    _stcpServerName = draft.stcpServerName;
    _stcpBindPort = draft.stcpBindPort;
    _stcpBindAddr = draft.stcpBindAddr;
    _useNamingRule = draft.useNamingRule;
    _serverNameCustomized = draft.serverNameCustomized;
    if (!updateControllers) return;

    final values = <String, String>{
      'name': _name,
      'localIp': _localIp,
      'localPort': _localPort,
      'remotePort': _remotePort,
      'localPorts': _localPorts,
      'remotePorts': _remotePorts,
      'customDomains': _customDomains,
      'secretKey': _secretKey,
      'serverName': _serverName,
      'bindPort': _bindPort,
      'bindAddr': _bindAddr,
      'fallbackTimeoutMs': _fallbackTimeoutMs,
      'stcpName': _stcpName,
      'stcpSecretKey': _stcpSecretKey,
      'stcpServerName': _stcpServerName,
      'stcpBindPort': _stcpBindPort,
      'stcpBindAddr': _stcpBindAddr,
    };
    for (final entry in values.entries) {
      final controller = _controllers[entry.key];
      if (controller != null && controller.text != entry.value) {
        controller.text = entry.value;
      }
    }
  }

  FrpConfig _buildConfigFromDraft(_ProtocolDraft draft, {FrpConfig? original}) {
    final supportsMultiPort =
        draft.protocol == 'tcp' || draft.protocol == 'udp';
    final isHttp = draft.protocol == 'http' || draft.protocol == 'https';
    final parsed = supportsMultiPort
        ? PortMappingParser.parse(draft.localPorts, draft.remotePorts)
        : const PortMappingParseResult();
    final mappings = supportsMultiPort && parsed.isValid
        ? parsed.mappings
        : const <PortMapping>[];
    final firstMapping = mappings.isEmpty ? null : mappings.first;
    final effectiveName = ConfigDomainService.effectiveName(
      draft.name,
      protocol: draft.protocol,
      useNamingRule: draft.useNamingRule,
    );
    final autoFallbackName = ConfigDomainService.fallbackNameFor(
      effectiveName.isEmpty ? 'service' : effectiveName,
      protocol: draft.protocol,
    );
    final fallbackProtocol =
        ConfigDomainService.fallbackProtocolFor(draft.protocol) ?? 'stcp';
    return (original ?? const FrpConfig()).copyWith(
      name: effectiveName,
      localIp: draft.localIp,
      localPort: firstMapping?.localPort ?? int.tryParse(draft.localPort) ?? 0,
      remotePort: isHttp
          ? 0
          : firstMapping?.remotePort ?? int.tryParse(draft.remotePort) ?? 0,
      portMappings: supportsMultiPort ? mappings : const [],
      protocol: draft.protocol,
      customDomains: isHttp
          ? (draft.customDomains
                .split(RegExp(r'[,\n]'))
                .map((domain) => domain.trim())
                .where((domain) => domain.isNotEmpty)
                .toSet()
                .toList())
          : const [],
      role: draft.role,
      secretKey: draft.secretKey.isEmpty ? null : draft.secretKey,
      serverName: draft.serverName.isEmpty ? null : draft.serverName,
      bindPort: int.tryParse(draft.bindPort) ?? 0,
      bindAddr: draft.bindAddr,
      useEncryption: draft.useEncryption,
      useCompression: draft.useCompression,
      serverId: _effectiveServerId,
      groupName: _editGroupName,
      useFallback: draft.useFallback,
      fallbackTo: draft.useFallback
          ? (draft.useCustomStcp
                ? (draft.stcpName.isEmpty ? autoFallbackName : draft.stcpName)
                : (original?.fallbackTo.isNotEmpty == true
                      ? original!.fallbackTo
                      : autoFallbackName))
          : '',
      fallbackTimeoutMs: int.tryParse(draft.fallbackTimeoutMs) ?? 3000,
      useCustomStcp: draft.useCustomStcp,
      stcpName: draft.stcpName.isEmpty ? autoFallbackName : draft.stcpName,
      stcpSecretKey: draft.stcpSecretKey.isEmpty
          ? draft.secretKey
          : draft.stcpSecretKey,
      stcpServerName: draft.stcpServerName.isEmpty
          ? ConfigDomainService.fallbackServerNameFor(
              draft.serverName,
              protocol: draft.protocol,
              fallbackProtocol: fallbackProtocol,
            )
          : draft.stcpServerName,
      stcpBindPort: int.tryParse(draft.stcpBindPort) ?? -1,
      stcpBindAddr: draft.stcpBindAddr,
    );
  }

  _ConfigCollection _collectConfigSet() {
    final snapshots = Map<int, _ProtocolDraft>.of(_protocolDrafts)
      ..[_activeDraftId] = _captureCurrentDraft();
    final entries = <_DraftConfigEntry>[];
    final errors = <String>[];

    for (final draftId in _includedDraftIds) {
      final draft = snapshots[draftId];
      if (draft == null) continue;
      final protocol = draft.protocol;
      if (protocol == 'tcp' || protocol == 'udp') {
        final mappingError = PortMappingParser.parse(
          draft.localPorts,
          draft.remotePorts,
        ).error;
        if (mappingError != null) {
          errors.add('${_draftLabel(draftId)}: $mappingError');
          continue;
        }
      }
      final config = _buildConfigFromDraft(
        draft,
        original: _originalByDraftId[draftId],
      );
      final validationError = ConfigValidator.validate(config);
      if (validationError != null) {
        errors.add('${_draftLabel(draftId)}: $validationError');
        continue;
      }
      entries.add(_DraftConfigEntry(draftId: draftId, config: config));
    }

    for (var i = 0; i < entries.length; i++) {
      final primary = entries[i].config;
      final fallbackProtocol = ConfigDomainService.fallbackProtocolFor(
        primary.protocol,
      );
      if (fallbackProtocol == null ||
          !primary.isVisitor() ||
          !primary.useFallback) {
        continue;
      }
      final fallbackIndex = entries.indexWhere(
        (entry) =>
            entry.config.protocol == fallbackProtocol &&
            entry.config.name == primary.fallbackTo,
      );
      FrpConfig? fallback = fallbackIndex < 0
          ? null
          : entries[fallbackIndex].config;
      if (fallback != null && !fallback.isVisitor()) {
        errors.add(
          '${primary.protocol.toUpperCase()} fallback: '
          '${fallbackProtocol.toUpperCase()} "${fallback.name}" must use Visitor role',
        );
        continue;
      }
      fallback ??= _buildLinkedFallback(
        primary,
      ).copyWith(name: primary.fallbackTo);
      if (fallbackIndex < 0) {
        final fallbackError = ConfigValidator.validate(fallback);
        if (fallbackError != null) {
          errors.add(
            '${fallbackProtocol.toUpperCase()} fallback: $fallbackError',
          );
        } else {
          entries.add(_DraftConfigEntry(config: fallback));
        }
      }
      entries[i] = _DraftConfigEntry(
        draftId: entries[i].draftId,
        config: primary.copyWith(fallbackTo: fallback.name),
      );
    }
    _appendVisitorBindConflicts(entries, errors);
    return _ConfigCollection(entries: entries, errors: errors);
  }

  void _appendVisitorBindConflicts(
    List<_DraftConfigEntry> entries,
    List<String> errors,
  ) {
    final listeners = <FrpConfig>[];
    for (final entry in entries) {
      final config = entry.config;
      final family = _visitorTransportFamily(config.protocol);
      if (!config.isVisitor() || family == null || config.bindPort <= 0) {
        continue;
      }
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

  FrpConfig _buildLinkedFallback(FrpConfig primary) =>
      appState.createLinkedFallbackConfig(primary);

  Future<void> _save() async {
    _protocolDrafts[_activeDraftId] = _captureCurrentDraft();
    final collection = _collectConfigSet();
    if (collection.errors.isNotEmpty) {
      _toast(collection.errors.first);
      return;
    }
    if (collection.configs.isEmpty) {
      _toast('At least one protocol configuration is required');
      return;
    }

    final emittedNames = <String>{};
    for (final config in collection.configs) {
      for (final name in config.configuredNames) {
        if (!emittedNames.add(name)) {
          _toast('Proxy name is duplicated in this group: $name');
          return;
        }
      }
    }

    final state = appState;
    final externalConfigs = state.configs.where(
      (config) => !_editingConfigIds.contains(config.id),
    );
    if (collection.configs.length > 1) {
      for (final existing in externalConfigs) {
        if (existing.serverId.isNotEmpty &&
            existing.serverId != _effectiveServerId) {
          continue;
        }
        final collision = emittedNames.intersection(
          existing.configuredNames.toSet(),
        );
        if (collision.isNotEmpty) {
          _toast('Proxy name already exists: ${collision.first}');
          return;
        }
      }
    }
    for (final config in collection.configs) {
      final collision = ConfigDomainService.findMultiPortNameCollision(
        config,
        externalConfigs,
      );
      if (collision != null) {
        _toast('Proxy name already exists: $collision');
        return;
      }
    }

    final preservedGroupMembers = _originalGroupId > 0
        ? state.configs
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
      while (state.configs.any((config) => config.groupId == groupId)) {
        groupId += 1;
      }
    }
    final primaryEntry = collection.entries.firstWhere(
      (entry) => entry.draftId == _primaryDraftId,
      orElse: () => collection.entries.first,
    );
    final primaryConfig = primaryEntry.config;
    final groupName = _editGroupName.trim().isNotEmpty
        ? _editGroupName.trim()
        : _defaultGroupName(primaryConfig.name);
    final preservedPrimary = preservedGroupMembers.any(
      (config) => config.isGroupPrimary,
    );
    var markedPrimary = preservedPrimary;
    final replacements = <FrpConfig>[];
    for (final entry in collection.entries) {
      final config = entry.config;
      final isPrimary =
          grouped && !markedPrimary && identical(entry, primaryEntry);
      if (isPrimary) markedPrimary = true;
      replacements.add(
        config.copyWith(
          groupId: grouped ? groupId : 0,
          groupName: groupName,
          isGroupPrimary: isPrimary,
        ),
      );
    }

    await state.replaceConfigSet(
      existingIds: _editingConfigIds,
      replacements: replacements,
    );
    if (grouped && preservedGroupMembers.isNotEmpty) {
      await state.renameGroup(groupId, groupName);
    }
    _toast(
      grouped
          ? 'Configuration group saved (${replacements.length} protocols)'
          : (_isEditing ? 'Configuration updated' : 'Configuration added'),
    );
    if (mounted) Navigator.pop(context);
  }

  String _defaultGroupName(String name) {
    final stripped = name.replaceFirst(
      RegExp(r'-(?:xtcp|xudp|stcp|sudp)$', caseSensitive: false),
      '',
    );
    return stripped.isEmpty ? name : stripped;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  String _generatePreview() {
    final collection = _collectConfigSet();
    final preview = StringBuffer(
      toml.generateServerPreview(_previewServer, collection.configs),
    );
    if (collection.errors.isNotEmpty) {
      if (preview.isNotEmpty && !preview.toString().endsWith('\n')) {
        preview.writeln();
      }
      preview.writeln('# Incomplete protocol drafts');
      for (final error in collection.errors) {
        preview.writeln('# $error');
      }
    }
    return preview.toString();
  }

  String _derivePeerConfig() {
    final peerIp = _localIp.isEmpty ? '127.0.0.1' : _localIp;
    final peerPort = int.tryParse(_localPort) ?? 22;
    final key = _secretKey;
    final primaryPeerName = _isVisitor && _serverName.trim().isNotEmpty
        ? _serverName.trim()
        : _effectiveName;
    final header =
        '# ===== Peer frpc config (run on the target machine) =====\n'
        '# Adjust localIP / localPort to the actual service address on the peer\n'
        '# (e.g. localIP = "192.168.3.18", localPort = 22).\n'
        '# secretKey / encryption / compression must match this app.\n\n';
    if (!_supportsFallback || !_useFallback) {
      return '$header${proxyBlockForPeer(primaryPeerName, _protocol, key, peerIp, peerPort, useEncryption: _useEncryption, useCompression: _useCompression)}';
    }
    final fallbackPeerName = _stcpServerName.trim().isNotEmpty
        ? _stcpServerName.trim()
        : ConfigDomainService.fallbackServerNameFor(
            primaryPeerName,
            protocol: _protocol,
            fallbackProtocol: _fallbackProtocol,
          );
    return '$header${proxyBlockForPeer(primaryPeerName, _protocol, key, peerIp, peerPort, useEncryption: _useEncryption, useCompression: _useCompression)}\n'
        '${proxyBlockForPeer(fallbackPeerName, _fallbackProtocol, _stcpSecretKey.isEmpty ? key : _stcpSecretKey, peerIp, peerPort, useEncryption: _useEncryption, useCompression: _useCompression)}';
  }

  InputDecoration _compactDecoration(
    String label, {
    String? hint,
    String? helper,
    Widget? suffixIcon,
    String? suffixText,
    TextStyle? suffixStyle,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      suffixIcon: suffixIcon,
      suffixText: suffixText,
      suffixStyle: suffixStyle,
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

  Widget _portMappingStatus(BuildContext context) {
    final waitingForPair =
        _localPorts.trim().isEmpty || _remotePorts.trim().isEmpty;
    final parsed = waitingForPair ? null : _parsedPortMappings;
    final error = parsed?.error;
    final count = parsed?.mappings.length ?? 0;
    final text = waitingForPair
        ? 'Comma-separated ports or ranges; pairs expand in order (max 128).'
        : error ?? '$count port ${count == 1 ? "mapping" : "mappings"}';
    return Text(
      text,
      key: const ValueKey('port_mapping_status'),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: error == null
            ? Theme.of(context).colorScheme.onSurfaceVariant
            : Theme.of(context).colorScheme.error,
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

  List<int> _draftIdsForProtocol(String protocol) => _includedDraftIds
      .where((draftId) => _protocolDrafts[draftId]?.protocol == protocol)
      .toList();

  String _draftLabel(int draftId) {
    final protocol = _protocolDrafts[draftId]?.protocol ?? 'unknown';
    final matching = _draftIdsForProtocol(protocol);
    if (matching.length <= 1) return protocol.toUpperCase();
    return '${protocol.toUpperCase()} ${matching.indexOf(draftId) + 1}';
  }

  String _draftWidgetSuffix(int draftId) {
    final protocol = _protocolDrafts[draftId]?.protocol ?? 'unknown';
    final matching = _draftIdsForProtocol(protocol);
    if (matching.length <= 1) return protocol;
    return '${protocol}_${matching.indexOf(draftId) + 1}';
  }

  Widget _protocolChip(BuildContext context, int draftId) {
    final colors = Theme.of(context).colorScheme;
    final selected = draftId == _activeDraftId;
    final canRemove = _includedDraftIds.length > 1;
    final label = _draftLabel(draftId);
    final widgetSuffix = _draftWidgetSuffix(draftId);
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;

    return Material(
      key: ValueKey('protocol_chip_$widgetSuffix'),
      color: selected ? colors.secondaryContainer : colors.surface,
      shape: StadiumBorder(
        side: selected
            ? BorderSide.none
            : BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            selected: selected,
            label: '$label protocol member',
            child: InkWell(
              onTap: () => setState(() => _switchDraft(draftId)),
              child: Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  12,
                  7,
                  canRemove ? 6 : 12,
                  7,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) ...[
                      Icon(Icons.check, size: 16, color: foreground),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      label,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: foreground),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (canRemove)
            Tooltip(
              message: 'Remove $label',
              child: InkWell(
                key: ValueKey('remove_protocol_$widgetSuffix'),
                onTap: () => setState(() => _removeProtocol(draftId)),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(4, 7, 10, 7),
                  child: Icon(Icons.close, size: 18, color: foreground),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncServerName();
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Form Config' : 'Form Config'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
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
                  controller: _ctrl('editGroupName'),
                  onChanged: (value) => setState(() => _editGroupName = value),
                  decoration: _compactDecoration(
                    'Group Name',
                    helper: 'Defaults to the primary protocol name when blank',
                  ),
                ),
                const SizedBox(height: 12),
                _sectionTitle(context, 'Protocol'),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('protocol_dropdown_$_protocol'),
                        initialValue: _protocol,
                        decoration: _compactDecoration('Protocol'),
                        items: FrpConfig.protocols
                            .map(
                              (protocol) => DropdownMenuItem(
                                value: protocol,
                                child: Text(protocol.toUpperCase()),
                              ),
                            )
                            .toList(),
                        onChanged: (protocol) {
                          if (protocol == null) return;
                          setState(() => _changeProtocol(protocol));
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      key: const ValueKey('add_protocol_instance'),
                      tooltip: 'Add another ${_protocol.toUpperCase()}',
                      onPressed: () => setState(_addProtocolInstance),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Protocols in this configuration',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      '${_includedDraftIds.length}',
                      key: const ValueKey('protocol_count'),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  key: const ValueKey('configured_protocols'),
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final draftId in _includedDraftIds)
                      _protocolChip(context, draftId),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Switching keeps every member\'s fields. Use + to add another member with the same protocol.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (!_isSecretProtocol) ...[
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('config_name'),
                    controller: _ctrl('name'),
                    onChanged: (value) => setState(() => _name = value),
                    decoration: _compactDecoration(
                      'Configuration Name *',
                      hint: 'e.g., ssh or web',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _sectionTitle(context, 'Connection'),
                  const SizedBox(height: 6),
                  if (_supportsMultiPort) ...[
                    TextField(
                      controller: _ctrl('localIp'),
                      onChanged: (value) => setState(() => _localIp = value),
                      decoration: _compactDecoration('Local IP'),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('local_ports'),
                            controller: _ctrl('localPorts'),
                            onChanged: (value) =>
                                setState(() => _localPorts = value),
                            keyboardType: TextInputType.text,
                            autocorrect: false,
                            smartDashesType: SmartDashesType.disabled,
                            decoration: _compactDecoration(
                              'Local Port(s) *',
                              hint: '22,8000-8002',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('remote_ports'),
                            controller: _ctrl('remotePorts'),
                            onChanged: (value) =>
                                setState(() => _remotePorts = value),
                            keyboardType: TextInputType.text,
                            autocorrect: false,
                            smartDashesType: SmartDashesType.disabled,
                            decoration: _compactDecoration(
                              'Remote Port(s) *',
                              hint: '10022,9000-9002',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _portMappingStatus(context),
                  ] else ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _ctrl('localIp'),
                            onChanged: (value) =>
                                setState(() => _localIp = value),
                            decoration: _compactDecoration('Local IP'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _ctrl('localPort'),
                            onChanged: (value) =>
                                setState(() => _localPort = value),
                            keyboardType: TextInputType.number,
                            decoration: _compactDecoration('Local Port *'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_isHttpProtocol)
                      TextField(
                        controller: _ctrl('customDomains'),
                        onChanged: (value) =>
                            setState(() => _customDomains = value),
                        keyboardType: TextInputType.url,
                        decoration: _compactDecoration(
                          'Custom Domains *',
                          hint: 'web.example.com, api.example.com',
                          helper: 'Separate multiple domains with commas',
                        ),
                      )
                    else
                      TextField(
                        controller: _ctrl('remotePort'),
                        onChanged: (value) =>
                            setState(() => _remotePort = value),
                        keyboardType: TextInputType.number,
                        decoration: _compactDecoration('Remote Port *'),
                      ),
                  ],
                ],
                if (_isSecretProtocol) ...[
                  const SizedBox(height: 10),
                  _buildSecretSettings(context),
                ],
                const SizedBox(height: 12),
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
                      if (_isSecretProtocol && _isVisitor) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _showPeerConfigDialog,
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('Derive Peer Config'),
                          ),
                        ),
                      ],
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

  Widget _buildSecretSettings(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.tertiaryContainer.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_protocol.toUpperCase()} Settings',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_protocol == 'xtcp')
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Fixed Rule',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      _smallSwitch(
                        _useNamingRule,
                        (value) => setState(() => _useNamingRule = value),
                      ),
                    ],
                  ),
              ],
            ),
            if (_protocol == 'xtcp')
              Text(
                _useNamingRule
                    ? 'Auto suffix: -xtcp appended to the name'
                    : 'Name is used as-is',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            const SizedBox(height: 6),

            // 主配置名
            TextField(
              key: const ValueKey('config_name'),
              controller: _ctrl('name'),
              onChanged: (v) => setState(() => _name = v),
              decoration: _compactDecoration(
                '${_protocol.toUpperCase()} Name',
                hint: 'e.g., linux-ssh',
                suffixText: (_protocol == 'xtcp' && _useNamingRule)
                    ? '-xtcp'
                    : null,
                suffixStyle: TextStyle(color: scheme.primary),
              ),
            ),
            const SizedBox(height: 8),

            // 角色
            Text('Role', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment<String>(
                  value: 'server',
                  label: Text('Server (Expose)'),
                ),
                ButtonSegment<String>(
                  value: 'visitor',
                  label: Text('Visitor (Access)'),
                ),
              ],
              selected: {_role},
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (selection) =>
                  setState(() => _role = selection.first),
            ),
            const SizedBox(height: 8),

            // Secret Key
            TextField(
              key: const ValueKey('secret_key'),
              controller: _ctrl('secretKey'),
              onChanged: (v) => setState(() => _secretKey = v),
              obscureText: !_showSecretKey,
              decoration: _compactDecoration(
                'Secret Key *',
                hint: 'Shared secret for authentication',
                suffixIcon: IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _showSecretKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _showSecretKey = !_showSecretKey),
                ),
              ),
            ),
            const Divider(height: 16),

            // 传输加密/压缩
            _sectionTitle(context, 'Transport'),
            const SizedBox(height: 2),
            Text(
              'Encryption and compression must match the peer.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 2),
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
            const SizedBox(height: 6),

            // Visitor 特有
            if (_isVisitor) ...[
              TextField(
                key: const ValueKey('server_proxy_name'),
                controller: _ctrl('serverName'),
                onChanged: (value) => setState(() {
                  _serverName = value;
                  _serverNameCustomized = true;
                }),
                decoration: _compactDecoration(
                  'Server Proxy Name *',
                  hint: 'e.g., xtcp_ssh',
                  helper: 'Must match the proxy name on the server',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl('bindAddr'),
                      onChanged: (value) => setState(() => _bindAddr = value),
                      decoration: _compactDecoration('Bind Address'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('bind_port'),
                      controller: _ctrl('bindPort'),
                      onChanged: (value) => setState(() => _bindPort = value),
                      keyboardType: TextInputType.number,
                      decoration: _compactDecoration('Bind Port'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              TextField(
                controller: _ctrl('localIp'),
                onChanged: (value) => setState(() => _localIp = value),
                decoration: _compactDecoration('Local IP'),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('secret_local_port'),
                controller: _ctrl('localPort'),
                onChanged: (value) => setState(() => _localPort = value),
                keyboardType: TextInputType.number,
                decoration: _compactDecoration('Local Port *'),
              ),
            ],

            // XTCP/XUDP 回落
            if (_supportsFallback && _isVisitor) ...[
              const Divider(height: 16),
              _compactSwitch(
                context,
                title: 'Fallback to ${_fallbackProtocol.toUpperCase()}',
                subtitle:
                    'Use ${_fallbackProtocol.toUpperCase()} relay if ${_protocol.toUpperCase()} P2P fails',
                value: _useFallback,
                onChanged: (value) => setState(() {
                  _useFallback = value;
                  if (value) _useCustomStcp = false;
                }),
              ),
              if (_useFallback) ...[
                const SizedBox(height: 6),
                TextField(
                  controller: _ctrl('fallbackTimeoutMs'),
                  onChanged: (value) =>
                      setState(() => _fallbackTimeoutMs = value),
                  keyboardType: TextInputType.number,
                  decoration: _compactDecoration('Fallback Timeout (ms)'),
                ),
                const SizedBox(height: 8),
                _buildFallbackCard(context),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFallbackCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallbackLabel = _fallbackProtocol.toUpperCase();
    final primaryLabel = _protocol.toUpperCase();
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.secondaryContainer.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _compactSwitch(
              context,
              title: '$fallbackLabel Fallback Visitor',
              subtitle: _useCustomStcp
                  ? 'Custom configuration'
                  : 'Auto (uses $primaryLabel settings)',
              value: _useCustomStcp,
              onChanged: (value) => setState(() {
                _useCustomStcp = value;
                if (value &&
                    _fallbackProtocol == 'sudp' &&
                    (int.tryParse(_stcpBindPort) ?? -1) <= 0) {
                  _stcpBindPort = '$_autoFallbackBindPort';
                  _controllers['stcpBindPort']?.text = _stcpBindPort;
                }
              }),
            ),
            if (_useCustomStcp) ...[
              const SizedBox(height: 6),
              TextField(
                controller: _ctrl('stcpName'),
                onChanged: (v) => setState(() => _stcpName = v),
                decoration: _compactDecoration(
                  '$fallbackLabel Name',
                  hint: _autoFallbackName,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _ctrl('stcpSecretKey'),
                onChanged: (v) => setState(() => _stcpSecretKey = v),
                obscureText: !_showSecretKey,
                decoration: _compactDecoration(
                  '$fallbackLabel Secret Key',
                  hint: 'Same as $primaryLabel',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _ctrl('stcpServerName'),
                onChanged: (v) => setState(() => _stcpServerName = v),
                decoration: _compactDecoration(
                  '$fallbackLabel Server Name',
                  hint: 'Same as $primaryLabel',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl('stcpBindAddr'),
                      onChanged: (v) => setState(() => _stcpBindAddr = v),
                      decoration: _compactDecoration(
                        '$fallbackLabel Bind Addr',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _ctrl('stcpBindPort'),
                      onChanged: (v) => setState(() => _stcpBindPort = v),
                      keyboardType: TextInputType.number,
                      decoration: _compactDecoration(
                        '$fallbackLabel Bind Port',
                        hint: '-1',
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const Divider(height: 10),
              Text(
                'Auto-generated $fallbackLabel config:',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                'name: $_autoFallbackName\n'
                'secretKey: ${_stcpSecretKey.isEmpty ? (_secretKey.isEmpty ? "(from $primaryLabel)" : _secretKey) : _stcpSecretKey}\n'
                'serverName: ${_stcpServerName.isEmpty ? ConfigDomainService.fallbackServerNameFor(_serverName, protocol: _protocol, fallbackProtocol: _fallbackProtocol) : _stcpServerName}\n'
                'bindPort: $_autoFallbackBindPort',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.25,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
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
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: text));
                    _toast('Peer config copied');
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
  final List<_DraftConfigEntry> entries;
  final List<String> errors;

  const _ConfigCollection({required this.entries, required this.errors});

  List<FrpConfig> get configs => [for (final entry in entries) entry.config];
}

class _DraftConfigEntry {
  final int? draftId;
  final FrpConfig config;

  const _DraftConfigEntry({this.draftId, required this.config});
}

class _ProtocolDraft {
  final String protocol;
  final String name;
  final String localIp;
  final String localPort;
  final String remotePort;
  final String localPorts;
  final String remotePorts;
  final String customDomains;
  final String role;
  final String secretKey;
  final String serverName;
  final String bindPort;
  final String bindAddr;
  final bool useEncryption;
  final bool useCompression;
  final bool useFallback;
  final String fallbackTimeoutMs;
  final bool useCustomStcp;
  final String stcpName;
  final String stcpSecretKey;
  final String stcpServerName;
  final String stcpBindPort;
  final String stcpBindAddr;
  final bool useNamingRule;
  final bool serverNameCustomized;

  const _ProtocolDraft({
    required this.protocol,
    this.name = '',
    this.localIp = '127.0.0.1',
    this.localPort = '',
    this.remotePort = '',
    this.localPorts = '',
    this.remotePorts = '',
    this.customDomains = '',
    this.role = 'visitor',
    this.secretKey = '',
    this.serverName = '',
    this.bindPort = '9002',
    this.bindAddr = '127.0.0.1',
    this.useEncryption = false,
    this.useCompression = false,
    this.useFallback = false,
    this.fallbackTimeoutMs = '3000',
    this.useCustomStcp = false,
    this.stcpName = '',
    this.stcpSecretKey = '',
    this.stcpServerName = '',
    this.stcpBindPort = '-1',
    this.stcpBindAddr = '127.0.0.1',
    this.useNamingRule = false,
    this.serverNameCustomized = false,
  });

  factory _ProtocolDraft.defaults(
    String protocol, {
    String bindPort = '9002',
  }) => _ProtocolDraft(
    protocol: protocol,
    bindPort: bindPort,
    useNamingRule: protocol == 'xtcp',
  );

  factory _ProtocolDraft.fromConfig(FrpConfig config) {
    final protocol = config.protocol.toLowerCase();
    final localPort = config.localPort > 0 ? '${config.localPort}' : '';
    final remotePort = config.remotePort > 0 ? '${config.remotePort}' : '';
    final mappings = config.effectivePortMappings;
    final useNamingRule = protocol == 'xtcp' && config.name.endsWith('-xtcp');
    final name = useNamingRule
        ? config.name.substring(0, config.name.length - 5)
        : config.name;
    return _ProtocolDraft(
      protocol: protocol,
      name: name,
      localIp: config.localIp,
      localPort: localPort,
      remotePort: remotePort,
      localPorts: config.supportsMultiplePorts()
          ? PortMappingParser.formatPorts(
              mappings.map((mapping) => mapping.localPort),
            )
          : localPort,
      remotePorts: config.supportsMultiplePorts()
          ? PortMappingParser.formatPorts(
              mappings.map((mapping) => mapping.remotePort),
            )
          : remotePort,
      customDomains: config.customDomains.join(', '),
      role: config.role,
      secretKey: config.secretKey ?? '',
      serverName: config.serverName ?? '',
      bindPort: '${config.bindPort}',
      bindAddr: config.bindAddr,
      useEncryption: config.useEncryption,
      useCompression: config.useCompression,
      useFallback: config.useFallback,
      fallbackTimeoutMs: '${config.fallbackTimeoutMs}',
      useCustomStcp: config.useCustomStcp,
      stcpName: config.stcpName,
      stcpSecretKey: config.stcpSecretKey,
      stcpServerName: config.stcpServerName,
      stcpBindPort: '${config.stcpBindPort}',
      stcpBindAddr: config.stcpBindAddr,
      useNamingRule: useNamingRule,
      serverNameCustomized:
          (config.serverName ?? '').isNotEmpty &&
          config.serverName != config.name,
    );
  }

  bool get isPristine =>
      name.trim().isEmpty &&
      localIp == '127.0.0.1' &&
      localPort.trim().isEmpty &&
      remotePort.trim().isEmpty &&
      localPorts.trim().isEmpty &&
      remotePorts.trim().isEmpty &&
      customDomains.trim().isEmpty &&
      role == 'visitor' &&
      secretKey.isEmpty &&
      serverName.isEmpty &&
      bindPort == '9002' &&
      bindAddr == '127.0.0.1' &&
      !useEncryption &&
      !useCompression &&
      !useFallback &&
      fallbackTimeoutMs == '3000' &&
      !useCustomStcp &&
      stcpName.isEmpty &&
      stcpSecretKey.isEmpty &&
      stcpServerName.isEmpty &&
      stcpBindPort == '-1' &&
      stcpBindAddr == '127.0.0.1';
}

/// 对端 frpc 配置块（server 角色 [[proxies]]）
String proxyBlockForPeer(
  String name,
  String protocol,
  String key,
  String ip,
  int port, {
  required bool useEncryption,
  required bool useCompression,
}) {
  final b = StringBuffer();
  b.writeln('[[proxies]]');
  b.writeln('name = "$name"');
  b.writeln('type = "$protocol"');
  b.writeln('localIP = "$ip"');
  b.writeln('localPort = $port');
  if (key.isNotEmpty) b.writeln('secretKey = "$key"');
  if (useEncryption || useCompression) {
    b.writeln();
    b.writeln('[proxies.transport]');
    b.writeln('useEncryption = $useEncryption');
    b.writeln('useCompression = $useCompression');
  }
  return b.toString();
}
