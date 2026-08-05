import 'package:flutter/material.dart';

import '../models/frp_config.dart';
import '../state/app_state.dart';


/// 手动编写配置：顶部保留 Server ID 选择 + 分组命名，下方为 TOML 编写区域
class ManualConfigEditScreen extends StatefulWidget {
  final int? configId;
  const ManualConfigEditScreen({super.key, this.configId});

  @override
  State<ManualConfigEditScreen> createState() => _ManualConfigEditScreenState();
}

class _ManualConfigEditScreenState extends State<ManualConfigEditScreen> {
  bool get _isEditing => widget.configId != null;

  String _serverId = '';
  String _groupName = '';
  String _toml = '';
  FrpConfig? _original;

  final _groupNameCtrl = TextEditingController();
  final _tomlCtrl = TextEditingController();

  static const _template = '# \u8fd9\u91cc\u624b\u52a8\u7f16\u5199 frpc \u914d\u7f6e\uff08[[proxies]] / [[visitors]] \u5757\uff09\n'
      '# \u793a\u4f8b\uff1a\n'
      '# [[visitors]]\n'
      '# name = "my_xtcp"\n'
      '# type = "xtcp"\n'
      '# serverName = "xtcp_ssh"\n'
      '# secretKey = "your-secret"\n'
      '# bindPort = 39522\n'
      '# keepTunnelOpen = true\n'
      '# fallbackTo = "my_stcp"\n'
      '# fallbackTimeoutMs = 3000\n'
      '#\n'
      '# [visitors.transport]\n'
      '# useEncryption = true\n'
      '# useCompression = true';

  @override
  void initState() {
    super.initState();
    _serverId = appState.effectiveServer.serverId;
    if (_isEditing) {
      final cfg = appState.configs.where((e) => e.id == widget.configId).firstOrNull;
      if (cfg != null) {
        _original = cfg;
        _serverId = cfg.serverId.isEmpty ? appState.effectiveServer.serverId : cfg.serverId;
        _groupName = cfg.groupName;
        _toml = cfg.manualToml ?? '';
      }
    } else {
      _toml = _template;
    }
    _groupNameCtrl.text = _groupName;
    _tomlCtrl.text = _toml;
  }

  @override
  void dispose() {
    _groupNameCtrl.dispose();
    _tomlCtrl.dispose();
    super.dispose();
  }

  String _deriveName() {
    // 分组命名优先
    if (_groupName.trim().isNotEmpty) return _groupName.trim();
    // 从 TOML 提取实际 name（跳过注释行，避免模板里的 name 被误用）
    for (final line in _toml.split('\n')) {
      if (line.trimLeft().startsWith('#')) continue;
      final m = RegExp(r'name\s*=\s*"([^"]+)"').firstMatch(line);
      if (m != null && m.group(1)!.isNotEmpty) return m.group(1)!;
    }
    return 'manual-${DateTime.now().millisecondsSinceEpoch % 100000}';
  }

  /// 为每个 visitors/proxies 块上方添加 # Config: "分组名" (type) 注释（幂等）
  String _addConfigComments(String toml) {
    final lines = toml.split('\n');
    final groupLabel =
        _groupName.trim().isEmpty ? _deriveName() : _groupName.trim();
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final t = line.trimLeft();
      if (t.startsWith('[[visitors]]') || t.startsWith('[[proxies]]')) {
        // 已有注释则不重复添加
        final already =
            out.isNotEmpty && out.last.trimLeft().startsWith('# Config:');
        if (!already) {
          // 查找本块的 type
          var type = 'unknown';
          for (var j = i + 1; j < lines.length; j++) {
            final tj = lines[j].trimLeft();
            if (tj.startsWith('[[')) break;
            if (tj.startsWith('#')) continue;
            final m = RegExp(r'''type\s*=\s*"([^"]+)"''').firstMatch(lines[j]);
            if (m != null && m.group(1)!.isNotEmpty) {
              type = m.group(1)!.toLowerCase();
              break;
            }
          }
          out.add('# Config: $groupLabel ($type)');
        }
      }
      out.add(line);
    }
    return out.join('\n');
  }

  /// 识别未被注释的 type = "..."（如 xtcp / stcp / tcp）
  String _detectType() {
    for (final line in _toml.split('\n')) {
      if (line.trimLeft().startsWith('#')) continue;
      final m = RegExp(r'''type\s*=\s*"([^"]+)"''').firstMatch(line);
      if (m != null && m.group(1)!.isNotEmpty) return m.group(1)!.toLowerCase();
    }
    return 'manual';
  }

  Future<void> _save() async {
    if (_toml.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Config content is empty')),
      );
      return;
    }
    final state = appState;
    final now = DateTime.now().millisecondsSinceEpoch;
    final name = _deriveName();
    final type = _detectType();
    final finalToml = _addConfigComments(_toml);
    if (_isEditing && _original != null) {
      await state.updateConfig(_original!.copyWith(
        name: name,
        protocol: type,
        groupName: _groupName,
        serverId: _serverId.isEmpty ? appState.effectiveServer.serverId : _serverId,
        manualToml: finalToml,
        updatedAt: now,
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuration updated')),
      );
    } else {
      await state.addConfig(FrpConfig(
        name: name,
        protocol: type,
        role: 'visitor',
        localPort: 0,
        manualToml: finalToml,
        groupName: _groupName,
        serverId: _serverId.isEmpty ? appState.effectiveServer.serverId : _serverId,
        enabled: true,
        createdAt: now,
        updatedAt: now,
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuration added')),
      );
    }
    if (mounted) Navigator.pop(context);
  }

  InputDecoration _dec(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Manual Config' : 'Manual Config'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Basic Information', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            // Server ID \u9009\u62e9
            DropdownButtonFormField<String>(
              initialValue: _serverId,
              decoration: _dec('Belongs to Server'),
              items: appState.servers
                  .map((sv) => DropdownMenuItem(
                        value: sv.serverId,
                        child: Text(
                          '${sv.name.isEmpty ? "FRPS Server" : sv.name} (${sv.serverId})',
                        ),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _serverId = v ?? ''),
            ),
            const SizedBox(height: 12),
            // \u5206\u7ec4\u547d\u540d
            TextField(
              controller: _groupNameCtrl,
              onChanged: (v) => setState(() => _groupName = v),
              decoration: _dec('Group Name', hint: 'Optional group for this config'),
            ),
            const SizedBox(height: 16),
            // \u624b\u52a8\u7f16\u5199\u533a\u57df
            Text('Config Content', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              flex: 9,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  controller: _tomlCtrl,
                  onChanged: (v) => setState(() => _toml = v),
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: '# \u5728\u6b64\u7f16\u5199 frpc \u914d\u7f6e...',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
              ),
            ),
            const Spacer(flex: 1),
          ],
          ),
          ),
        ),
      ),
    );
  }
}
