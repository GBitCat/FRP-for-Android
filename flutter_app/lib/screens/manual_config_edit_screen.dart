import 'package:flutter/material.dart';

import '../models/frp_config.dart';
import '../state/app_state.dart';
import '../services/manual_frp_config.dart';
import '../widgets/app_dropdown_field.dart';
import '../widgets/editor_card.dart';

typedef ManualConfigSaver = Future<void> Function(
  FrpConfig config,
  bool isEditing,
);

/// 手动编写配置：顶部保留 Server ID 选择 + 分组命名，下方为 TOML 编写区域
class ManualConfigEditScreen extends StatefulWidget {
  final int? configId;
  final ManualConfigSaver? onSave;
  final bool asDialog;

  const ManualConfigEditScreen({
    super.key,
    this.configId,
    this.onSave,
    this.asDialog = false,
  });

  @override
  State<ManualConfigEditScreen> createState() => _ManualConfigEditScreenState();
}

class _ManualConfigEditScreenState extends State<ManualConfigEditScreen> {
  bool get _isEditing => widget.configId != null;

  String _serverId = '';
  String _groupName = '';
  String _toml = '';
  FrpConfig? _original;
  bool _saving = false;
  bool _allowPop = false;
  bool _confirmingClose = false;
  late final String _initialServerId;
  late final String _initialGroupName;
  late final String _initialToml;

  bool get _hasChanges =>
      _serverId != _initialServerId ||
      _groupName != _initialGroupName ||
      _toml != _initialToml;

  final _groupNameCtrl = TextEditingController();
  final _tomlCtrl = TextEditingController();

  static const _template =
      '# \u8fd9\u91cc\u624b\u52a8\u7f16\u5199 frpc \u914d\u7f6e\uff08[[proxies]] / [[visitors]] \u5757\uff09\n'
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
      final cfg = appState.configs
          .where((e) => e.id == widget.configId)
          .firstOrNull;
      if (cfg != null) {
        _original = cfg;
        _serverId = cfg.serverId.isEmpty
            ? appState.effectiveServer.serverId
            : cfg.serverId;
        _groupName = cfg.groupName;
        _toml = cfg.manualToml ?? '';
      }
    } else {
      _toml = _template;
    }
    _groupNameCtrl.text = _groupName;
    _tomlCtrl.text = _toml;
    _initialServerId = _serverId;
    _initialGroupName = _groupName;
    _initialToml = _toml;
  }

  @override
  void dispose() {
    _groupNameCtrl.clear();
    _tomlCtrl.clear();
    _groupNameCtrl.dispose();
    _tomlCtrl.dispose();
    super.dispose();
  }

  String _addConfigComments(
    String source,
    String name,
    List<ManualFrpBlock> blocks,
  ) {
    // Preserve arbitrary multiline strings verbatim (they may contain lines
    // identical to table headers). The server preview adds a document label.
    if (source.contains("'''") || source.contains('"""')) return source;
    final sections = {
      for (final section in ['proxies', 'visitors'])
        section: blocks.where((block) => block.section == section).iterator,
    };
    final header = RegExp(
      r'''^\s*\[\[\s*(?:"(proxies|visitors)"|'(proxies|visitors)'|(proxies|visitors))\s*\]\]\s*(?:#.*)?$''',
    );
    final lines = <String>[];
    for (final line in source.split('\n')) {
      final match = header.firstMatch(line);
      if (match != null) {
        final iterator = sections[match[1] ?? match[2] ?? match[3]]!;
        if (iterator.moveNext() &&
            !(lines.lastOrNull?.trimLeft().startsWith('# Config:') ?? false)) {
          final type = iterator.current.values['type'] ?? 'unknown';
          lines.add('# Config: $name ($type)');
        }
      }
      lines.add(line);
    }
    return lines.join('\n');
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_toml.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Config content is empty')));
      return;
    }
    final state = appState;
    final now = DateTime.now().millisecondsSinceEpoch;
    setState(() => _saving = true);
    var saved = false;
    try {
      final blocks = manualFrpBlocks(_toml);
      final primary = blocks.firstOrNull?.values;
      final name = _groupName.trim().isNotEmpty
          ? _groupName.trim()
          : primary?['name'] as String? ?? 'manual-${now % 100000}';
      final type = (primary?['type'] as String?)?.toLowerCase() ?? 'manual';
      final finalToml = _addConfigComments(_toml, name, blocks);
      final FrpConfig candidate;
      if (_isEditing && _original != null) {
        candidate = _original!.copyWith(
          name: name,
          protocol: type,
          groupName: _groupName,
          serverId: _serverId.isEmpty
              ? appState.effectiveServer.serverId
              : _serverId,
          manualToml: finalToml,
          updatedAt: now,
        );
      } else {
        candidate = FrpConfig(
          name: name,
          protocol: type,
          role: 'visitor',
          localPort: 0,
          manualToml: finalToml,
          groupName: _groupName,
          serverId: _serverId.isEmpty
              ? appState.effectiveServer.serverId
              : _serverId,
          enabled: true,
          createdAt: now,
          updatedAt: now,
        );
      }
      final onSave = widget.onSave;
      if (onSave != null) {
        await onSave(candidate, _isEditing);
      } else if (_isEditing && _original != null) {
        await state.updateConfig(candidate);
      } else {
        await state.addConfig(candidate);
      }
      saved = true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to save configuration')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!saved || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _isEditing ? 'Configuration updated' : 'Configuration added',
        ),
      ),
    );
    _close();
  }

  void _close() {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _requestClose() async {
    if (_saving || _confirmingClose) return;
    if (!_hasChanges) {
      _close();
      return;
    }
    _confirmingClose = true;
    final action = await confirmUnsavedEditorChanges(context);
    _confirmingClose = false;
    if (!mounted) return;
    switch (action) {
      case UnsavedEditorAction.save:
        await _save();
        return;
      case UnsavedEditorAction.discard:
        _close();
        return;
      case null:
        return;
    }
  }

  InputDecoration _dec(String label, {String? hint}) {
    return AppFormStyle.decoration(label: label, hint: hint);
  }

  @override
  Widget build(BuildContext context) {
    final title = _isEditing ? 'Edit Manual Config' : 'Manual Config';
    return PopScope(
      canPop: !_saving && (_allowPop || !_hasChanges),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _requestClose();
      },
      child: widget.asDialog
          ? EditorCard(
              title: title,
              saving: _saving,
              onClose: _requestClose,
              onSave: _save,
              child: SingleChildScrollView(child: _formContent(context)),
            )
          : Scaffold(
              appBar: AppBar(
                leading: BackButton(onPressed: _requestClose),
                title: Text(title),
                actions: [
                  TextButton(
                    onPressed: _saving ? null : _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _formContent(context),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _formContent(BuildContext context) => AbsorbPointer(
    absorbing: _saving,
    child: Column(
      mainAxisSize: widget.asDialog ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Basic Information',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        AppDropdownButtonFormField<String>(
          initialValue: _serverId,
          decoration: _dec('Belongs to Server'),
          items: appState.servers
              .map(
                (sv) => DropdownMenuItem(
                  value: sv.serverId,
                  child: Text(
                    '${sv.name.isEmpty ? "FRPS Server" : sv.name} (${sv.serverId})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: (v) => setState(() => _serverId = v ?? ''),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _groupNameCtrl,
          onChanged: (v) => setState(() => _groupName = v),
          decoration: _dec(
            'Group Name',
            hint: 'Optional group for this config',
          ),
        ),
        const SizedBox(height: 16),
        Text('Config Content', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (widget.asDialog)
          _tomlEditor(context)
        else ...[
          Expanded(flex: 9, child: _tomlEditor(context)),
          const Spacer(flex: 1),
        ],
      ],
    ),
  );

  Widget _tomlEditor(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    ),
    child: TextField(
      controller: _tomlCtrl,
      onChanged: (v) => setState(() => _toml = v),
      minLines: widget.asDialog ? 10 : null,
      maxLines: null,
      expands: !widget.asDialog,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      decoration: const InputDecoration(
        hintText: '# 在此编写 frpc 配置...',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.all(12),
      ),
    ),
  );
}
