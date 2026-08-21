import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/frp_config.dart';
import '../services/config_domain_service.dart';
import '../services/config_validator.dart';
import '../services/toml_generator.dart' as toml;
import '../widgets/config_form_fields.dart';
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

  // XTCP 回落
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

  FrpConfig? _original;

  final Map<String, TextEditingController> _controllers = {};

  TextEditingController _ctrl(String key) =>
      _controllers.putIfAbsent(key, () => TextEditingController());

  void _initControllers() {
    _controllers['name'] = TextEditingController(text: _name);
    _controllers['localIp'] = TextEditingController(text: _localIp);
    _controllers['localPort'] = TextEditingController(text: _localPort);
    _controllers['remotePort'] = TextEditingController(text: _remotePort);
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
        _original = cfg;
        _load(cfg);
      }
    } else {
      _serverId = appState.effectiveServer.serverId;
    }
    _initControllers();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(FrpConfig c) {
    _name = c.name;
    _localIp = c.localIp;
    _localPort = c.localPort.toString();
    _remotePort = c.remotePort.toString();
    _protocol = c.protocol;
    _role = c.role;
    _secretKey = c.secretKey ?? '';
    _serverName = c.serverName ?? '';
    _bindPort = c.bindPort.toString();
    _bindAddr = c.bindAddr;
    _serverId = c.serverId;
    _editGroupName = c.groupName;
    _useEncryption = c.useEncryption;
    _useCompression = c.useCompression;
    _useFallback = c.useFallback;
    _useCustomStcp = c.useCustomStcp;
    _stcpName = c.stcpName;
    _stcpSecretKey = c.stcpSecretKey;
    _stcpServerName = c.stcpServerName;
    _stcpBindPort = c.stcpBindPort.toString();
    _stcpBindAddr = c.stcpBindAddr;
    _fallbackTimeoutMs = c.fallbackTimeoutMs.toString();
    _serverNameCustomized = false;
    // 固定规则：名称以 -xtcp 结尾时拆出基础名并开启规则
    if (c.protocol.toLowerCase() == 'xtcp' && c.name.endsWith('-xtcp')) {
      _name = c.name.substring(0, c.name.length - 5);
      _useNamingRule = true;
    } else {
      _name = c.name;
      _useNamingRule = c.protocol.toLowerCase() == 'xtcp';
    }
  }

  bool get _isSecretProtocol => FrpConfig.secretProtocols.contains(_protocol);
  bool get _isVisitor => _role == 'visitor';
  bool get _supportsFallback => _protocol == 'xtcp';

  String get _autoStcpName => '${_name.isEmpty ? "service" : _name}-stcp';

  /// XTCP 固定规则后的有效名称（linux-ssh → linux-ssh-xtcp）
  String get _effectiveName {
    return ConfigDomainService.effectiveName(
      _name,
      protocol: _protocol,
      useNamingRule: _useNamingRule,
    );
  }

  void _syncServerName() {
    if (!_serverNameCustomized && _protocol == 'xtcp') {
      _serverName = _effectiveName;
      _controllers['serverName']?.text = _effectiveName;
    }
  }

  FrpConfig _buildConfig() {
    return (_original ?? FrpConfig()).copyWith(
      name: _effectiveName,
      localIp: _localIp,
      localPort: int.tryParse(_localPort) ?? 0,
      remotePort: int.tryParse(_remotePort) ?? 0,
      protocol: _protocol,
      role: _role,
      secretKey: _secretKey.isEmpty ? null : _secretKey,
      serverName: _serverName.isEmpty ? null : _serverName,
      bindPort: int.tryParse(_bindPort) ?? 0,
      bindAddr: _bindAddr,
      useEncryption: _useEncryption,
      useCompression: _useCompression,
      serverId: _serverId.isEmpty
          ? appState.effectiveServer.serverId
          : _serverId,
      groupName: _original?.isInGroup() == true
          ? _editGroupName
          : (_original?.groupName ?? ''),
      useFallback: _useFallback,
      fallbackTo: _useFallback
          ? (_useCustomStcp
                ? (_stcpName.isEmpty ? _autoStcpName : _stcpName)
                : (_original?.fallbackTo.isNotEmpty == true
                      ? _original!.fallbackTo
                      : _autoStcpName))
          : '',
      fallbackTimeoutMs: int.tryParse(_fallbackTimeoutMs) ?? 3000,
      useCustomStcp: _useCustomStcp,
      stcpName: _stcpName.isEmpty ? _autoStcpName : _stcpName,
      stcpSecretKey: _stcpSecretKey.isEmpty ? _secretKey : _stcpSecretKey,
      stcpServerName: _stcpServerName.isEmpty
          ? _serverName.replaceAll('xtcp', 'stcp')
          : _stcpServerName,
      stcpBindPort: int.tryParse(_stcpBindPort) ?? -1,
      stcpBindAddr: _stcpBindAddr,
    );
  }

  Future<void> _save() async {
    final state = appState;
    final config = _buildConfig();
    final validationError = ConfigValidator.validate(config);
    if (validationError != null) {
      _toast(validationError);
      return;
    }

    if (_isEditing) {
      await state.updateConfig(config);
      if (config.isVisitor() &&
          config.supportsFallback() &&
          config.useFallback) {
        await state.syncLinkedStcp(config);
      }
      // 分组重命名：同步到组内全部配置
      final origGroupId = _original?.groupId ?? 0;
      if (origGroupId > 0 && _editGroupName != _original?.groupName) {
        await state.renameGroup(origGroupId, _editGroupName);
      }
      _toast('Configuration updated');
      if (mounted) Navigator.pop(context);
    } else {
      if (_useFallback && _supportsFallback && _isVisitor) {
        await _showGroupNameDialog(config);
      } else {
        await state.addConfig(config);
        _toast('Configuration added');
        if (mounted) Navigator.pop(context);
      }
    }
  }

  Future<void> _showGroupNameDialog(FrpConfig xtcp) async {
    final groupName = await showFrostedDialog<String>(
      context: context,
      builder: (dialogContext) {
        final controller = TextEditingController();
        return FrostedCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Name this configuration group',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter a name for the XTCP + STCP configuration group:',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Group Name',
                  hintText: 'e.g., SSH P2P Connection',
                  border: OutlineInputBorder(),
                ),
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
                    onPressed: () =>
                        Navigator.pop(dialogContext, controller.text),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (groupName == null) return;
    final state = appState;
    final groupId = DateTime.now().millisecondsSinceEpoch;
    final finalName = groupName.isEmpty ? 'Group $groupId' : groupName;
    final stcp = _useCustomStcp
        ? FrpConfig(
            name: _stcpName.isEmpty ? _autoStcpName : _stcpName,
            protocol: 'stcp',
            role: 'visitor',
            secretKey: _stcpSecretKey.isEmpty ? _secretKey : _stcpSecretKey,
            serverName: _stcpServerName.isEmpty
                ? _serverName.replaceAll('xtcp', 'stcp')
                : _stcpServerName,
            bindPort: int.tryParse(_stcpBindPort) ?? -1,
            localPort: 0,
            bindAddr: _stcpBindAddr,
            useEncryption: _useEncryption,
            useCompression: _useCompression,
            serverId: _serverId,
            groupId: groupId,
            groupName: finalName,
            isGroupPrimary: false,
          )
        : state
              .createLinkedStcpConfig(xtcp)
              .copyWith(
                groupId: groupId,
                groupName: finalName,
                isGroupPrimary: false,
              );
    await state.addConfig(stcp);
    await state.addConfig(
      xtcp.copyWith(
        groupId: groupId,
        groupName: finalName,
        isGroupPrimary: true,
      ),
    );
    _toast('Created group: $finalName');
    if (mounted) Navigator.pop(context);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  String _generatePreview() {
    final server = appState.effectiveServer;
    final config = _buildConfig();
    final stcp =
        _isSecretProtocol && _supportsFallback && _isVisitor && _useFallback
        ? (_useCustomStcp
              ? FrpConfig(
                  name: _stcpName.isEmpty ? _autoStcpName : _stcpName,
                  protocol: 'stcp',
                  role: 'visitor',
                  secretKey: _stcpSecretKey.isEmpty
                      ? _secretKey
                      : _stcpSecretKey,
                  serverName: _stcpServerName.isEmpty
                      ? _serverName
                      : _stcpServerName,
                  bindPort: int.tryParse(_stcpBindPort) ?? -1,
                  localPort: 0,
                  bindAddr: _stcpBindAddr,
                  useEncryption: _useEncryption,
                  useCompression: _useCompression,
                  serverId: _serverId,
                )
              : appState.createLinkedStcpConfig(config))
        : null;
    return toml.generateToml(server, config, stcp);
  }

  String _derivePeerConfig() {
    final peerIp = _localIp.isEmpty ? '127.0.0.1' : _localIp;
    final peerPort = int.tryParse(_localPort) ?? 22;
    final key = _secretKey;
    final header =
        '# ===== Peer frpc config (run on the target machine) =====\n'
        '# Adjust localIP / localPort to the actual service address on the peer\n'
        '# (e.g. localIP = "192.168.3.18", localPort = 22).\n'
        '# secretKey / encryption / compression must match this app.\n\n';
    if (_protocol != 'xtcp') {
      return '$header${proxyBlockForPeer(_effectiveName, _protocol, key, peerIp, peerPort, useEncryption: _useEncryption, useCompression: _useCompression)}';
    }
    final stcpName = _stcpName.isEmpty ? _autoStcpName : _stcpName;
    return '$header${proxyBlockForPeer(_effectiveName, 'xtcp', key, peerIp, peerPort, useEncryption: _useEncryption, useCompression: _useCompression)}\n'
        '${proxyBlockForPeer(stcpName, 'stcp', _stcpSecretKey.isEmpty ? key : _stcpSecretKey, peerIp, peerPort, useEncryption: _useEncryption, useCompression: _useCompression)}';
  }

  @override
  Widget build(BuildContext context) {
    _syncServerName();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Configuration' : 'New Configuration'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 隶属 Server
            const ConfigSectionTitle('Basic Information'),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _serverId,
              decoration: const InputDecoration(
                labelText: 'Belongs to Server',
                border: OutlineInputBorder(),
              ),
              items: appState.servers
                  .map(
                    (sv) => DropdownMenuItem(
                      value: sv.serverId,
                      child: Text(
                        '${sv.name.isEmpty ? "FRPS Server" : sv.name} (${sv.serverId})',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _serverId = v ?? ''),
            ),

            // 分组名称
            if (_original?.isInGroup() == true) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl('editGroupName'),
                onChanged: (v) => setState(() => _editGroupName = v),
                decoration: const InputDecoration(
                  labelText: 'Group Name',
                  border: OutlineInputBorder(),
                ),
              ),
            ],

            const SizedBox(height: 16),

            // 协议选择
            const ConfigSectionTitle('Protocol'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ...FrpConfig.protocols.map((p) {
                  final selected = _protocol == p;
                  return ChoiceChip(
                    label: Text(p.toUpperCase()),
                    selected: selected,
                    onSelected: (_) => setState(() => _protocol = p),
                    selectedColor: FrpConfig.secretProtocols.contains(p)
                        ? scheme.tertiaryContainer
                        : scheme.primaryContainer,
                  );
                }),
              ],
            ),

            const SizedBox(height: 16),

            // 非 secret：命名 + 本地/远程设置
            if (!_isSecretProtocol) ...[
              TextField(
                controller: _ctrl('name'),
                onChanged: (v) => setState(() => _name = v),
                decoration: const InputDecoration(
                  labelText: 'Configuration Name *',
                  hintText: 'e.g., xtcp-visitor',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Local Settings',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              ConfigTextField(
                controller: _ctrl('localIp'),
                onChanged: (v) => setState(() => _localIp = v),
                label: 'Local IP',
              ),
              const SizedBox(height: 12),
              ConfigTextField(
                controller: _ctrl('localPort'),
                onChanged: (v) => setState(() => _localPort = v),
                keyboardType: TextInputType.number,
                label: 'Local Port *',
              ),
              const SizedBox(height: 16),
              Text(
                'Remote Settings',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _ctrl('remotePort'),
                onChanged: (v) => setState(() => _remotePort = v),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Remote Port *',
                  border: OutlineInputBorder(),
                ),
              ),
            ],

            // secret 协议设置
            if (_isSecretProtocol) _buildSecretSettings(context),

            const SizedBox(height: 24),

            // 配置预览
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Configuration Preview',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _generatePreview(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    if (_isSecretProtocol && _isVisitor) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _showPeerConfigDialog(),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Derive Peer Config'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSecretSettings(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                    children: [
                      Text(
                        'Fixed Rule',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Switch(
                        value: _useNamingRule,
                        onChanged: (v) => setState(() => _useNamingRule = v),
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
            const SizedBox(height: 8),

            // 主配置名
            TextField(
              controller: _ctrl('name'),
              onChanged: (v) => setState(() => _name = v),
              decoration: InputDecoration(
                labelText: '${_protocol.toUpperCase()} Name',
                hintText: 'e.g., linux-ssh',
                border: const OutlineInputBorder(),
                suffixText: (_protocol == 'xtcp' && _useNamingRule)
                    ? '-xtcp'
                    : null,
                suffixStyle: TextStyle(color: scheme.primary),
              ),
            ),
            const SizedBox(height: 12),

            // 角色
            Text('Role', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: const Text('Server (Expose)'),
                    selected: _role == 'server',
                    onSelected: (_) => setState(() => _role = 'server'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    label: const Text('Visitor (Access)'),
                    selected: _role == 'visitor',
                    onSelected: (_) => setState(() => _role = 'visitor'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Secret Key
            TextField(
              controller: _ctrl('secretKey'),
              onChanged: (v) => setState(() => _secretKey = v),
              obscureText: !_showSecretKey,
              decoration: InputDecoration(
                labelText: 'Secret Key *',
                hintText: 'Shared secret for authentication',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _showSecretKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _showSecretKey = !_showSecretKey),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),

            // 传输加密/压缩
            Text(
              'Transport Encryption / Compression',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              'Must match the peer frpc transport settings (XTCP P2P requires both ends identical)',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Encryption'),
              trailing: Switch(
                value: _useEncryption,
                onChanged: (v) => setState(() => _useEncryption = v),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Compression'),
              trailing: Switch(
                value: _useCompression,
                onChanged: (v) => setState(() => _useCompression = v),
              ),
            ),
            const SizedBox(height: 4),

            // Visitor 特有
            if (_isVisitor) ...[
              TextField(
                controller: _ctrl('serverName'),
                onChanged: (v) => setState(() {
                  _serverName = v;
                  _serverNameCustomized = true;
                }),
                decoration: const InputDecoration(
                  labelText: 'Server Proxy Name *',
                  hintText: 'Server proxy name, e.g. xtcp_ssh',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Must match the proxy name on server (e.g. xtcp_ssh, stcp_ssh)',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl('bindAddr'),
                      onChanged: (v) => setState(() => _bindAddr = v),
                      decoration: const InputDecoration(
                        labelText: 'Bind Address',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _ctrl('bindPort'),
                      onChanged: (v) => setState(() => _bindPort = v),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Bind Port',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              TextField(
                controller: _ctrl('localIp'),
                onChanged: (v) => setState(() => _localIp = v),
                decoration: const InputDecoration(
                  labelText: 'Local IP',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl('localPort'),
                onChanged: (v) => setState(() => _localPort = v),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Local Port *',
                  border: OutlineInputBorder(),
                ),
              ),
            ],

            // XTCP 回落
            if (_supportsFallback && _isVisitor) ...[
              const SizedBox(height: 8),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fallback to STCP'),
                subtitle: const Text('When XTCP P2P fails, use STCP relay'),
                trailing: Switch(
                  value: _useFallback,
                  onChanged: (v) => setState(() {
                    _useFallback = v;
                    if (v) _useCustomStcp = false;
                  }),
                ),
              ),
              if (_useFallback) ...[
                TextField(
                  controller: _ctrl('fallbackTimeoutMs'),
                  onChanged: (v) => setState(() => _fallbackTimeoutMs = v),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Fallback Timeout (ms)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                _buildStcpFallbackCard(context),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStcpFallbackCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('STCP Fallback Visitor'),
              subtitle: const Text('Fallback target configuration'),
              trailing: Switch(
                value: _useCustomStcp,
                onChanged: (v) => setState(() => _useCustomStcp = v),
              ),
            ),
            Text(
              _useCustomStcp
                  ? 'Custom configuration'
                  : 'Auto (uses XTCP settings)',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (_useCustomStcp) ...[
              TextField(
                controller: _ctrl('stcpName'),
                onChanged: (v) => setState(() => _stcpName = v),
                decoration: InputDecoration(
                  labelText: 'STCP Name',
                  hintText: _autoStcpName,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _ctrl('stcpSecretKey'),
                onChanged: (v) => setState(() => _stcpSecretKey = v),
                obscureText: !_showSecretKey,
                decoration: const InputDecoration(
                  labelText: 'STCP Secret Key',
                  hintText: 'Same as XTCP',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _ctrl('stcpServerName'),
                onChanged: (v) => setState(() => _stcpServerName = v),
                decoration: const InputDecoration(
                  labelText: 'STCP Server Name',
                  hintText: 'Same as XTCP',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl('stcpBindAddr'),
                      onChanged: (v) => setState(() => _stcpBindAddr = v),
                      decoration: const InputDecoration(
                        labelText: 'STCP Bind Addr',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _ctrl('stcpBindPort'),
                      onChanged: (v) => setState(() => _stcpBindPort = v),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'STCP Bind Port',
                        hintText: '-1',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const Divider(),
              const SizedBox(height: 4),
              Text(
                'Auto-generated STCP config:',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                'name: $_autoStcpName\n'
                'secretKey: ${_stcpSecretKey.isEmpty ? (_secretKey.isEmpty ? "(from XTCP)" : _secretKey) : _stcpSecretKey}\n'
                'serverName: ${_stcpServerName.isEmpty ? _serverName.replaceAll('xtcp', 'stcp') : _stcpServerName}\n'
                'bindPort: -1',
                style: TextStyle(
                  fontSize: 12,
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
