import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/socks5_config.dart';
import '../widgets/app_dropdown_field.dart';
import '../widgets/frosted_dialog.dart';

typedef Socks5ConfigSaver = Future<void> Function(Socks5Config? value);

class Socks5ConfigDialog extends StatefulWidget {
  final Socks5Config? initial;
  final bool supportsTcp;
  final bool supportsUdp;
  final Socks5ConfigSaver onSave;

  const Socks5ConfigDialog({
    super.key,
    this.initial,
    required this.supportsTcp,
    required this.supportsUdp,
    required this.onSave,
  });

  @override
  State<Socks5ConfigDialog> createState() => _Socks5ConfigDialogState();
}

class _Socks5ConfigDialogState extends State<Socks5ConfigDialog> {
  final _scroll = ScrollController();
  late Socks5Config _value;
  bool _saving = false;
  bool _childOpen = false;
  String? _error;

  bool get _busy => _saving || _childOpen;
  bool get _hasTarget =>
      _value.targetIp.isNotEmpty &&
      _value.copyWith(connections: []).validationError() == null;

  @override
  void initState() {
    super.initState();
    _value = widget.initial ?? const Socks5Config(targetIp: '');
  }

  @override
  void didUpdateWidget(covariant Socks5ConfigDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initial != widget.initial && !_busy) {
      _value = widget.initial ?? const Socks5Config(targetIp: '');
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _persist(Socks5Config next) async {
    final error = next.validationError();
    if (error != null) throw FormatException(error);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(next);
      if (mounted) setState(() => _value = next);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _change(Socks5Config next) async {
    if (_busy) return;
    try {
      await _persist(next);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _saveError(error));
      _revealError(_scroll);
    }
  }

  Future<void> _showEditor({
    required String title,
    required String editorKey,
    required List<_EditorField> fields,
    required Future<void> Function(Map<String, String>) onSave,
    required String saveKey,
    required String closeKey,
  }) async {
    if (_busy) return;
    setState(() => _childOpen = true);
    try {
      await showFrostedDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SocksEditorDialog(
          title: title,
          editorKey: editorKey,
          fields: fields,
          onSave: onSave,
          saveKey: saveKey,
          closeKey: closeKey,
        ),
      );
    } finally {
      if (mounted) setState(() => _childOpen = false);
    }
  }

  Future<void> _editAccount() => _showEditor(
    title: 'SOCKS5 account',
    editorKey: 'socks5_account_editor',
    saveKey: 'socks_save',
    closeKey: 'socks_account_close',
    fields: [
      _EditorField(
        keyName: 'socks_target_ip',
        label: 'Target IP',
        initial: _value.targetIp,
        hint: '127.0.0.1',
        helper: 'Address reachable from the providing device.',
      ),
      _EditorField(
        keyName: 'socks_username',
        label: 'Username',
        initial: _value.username,
      ),
      _EditorField(
        keyName: 'socks_password',
        label: 'Password',
        initial: _value.password,
        secret: true,
        helper: 'Leave both account fields empty for no authentication.',
      ),
    ],
    onSave: (fields) => _persist(
      _value.copyWith(
        targetIp: fields['socks_target_ip']!.trim(),
        username: fields['socks_username']!,
        password: fields['socks_password']!,
      ),
    ),
  );

  Future<void> _editConnection([Socks5Connection? original]) async {
    if (_busy || !_hasTarget) return;
    final id = original?.id ?? Socks5Connection.generateId();
    await _showEditor(
      title: original == null
          ? 'Add SOCKS connection'
          : 'Edit SOCKS connection',
      editorKey: 'socks5_connection_editor',
      saveKey: 'socks_connection_save',
      closeKey: 'socks_connection_close',
      fields: [
        _EditorField(
          keyName: 'socks_connection_name',
          label: 'Connection name',
          initial: original?.name ?? '',
        ),
        _EditorField(
          keyName: 'socks_connection_target_ip',
          label: 'Target IP',
          initial: original?.targetIp ?? '',
          hint: _value.targetIp,
          helper: 'Leave empty to use parent target IP.',
        ),
        _EditorField(
          keyName: 'socks_connection_mode',
          label: 'Mode',
          initial: (original?.mode ?? Socks5ConnectionMode.onDemand).name,
          options: {
            for (final mode in Socks5ConnectionMode.values)
              mode.name: _modeLabel(mode),
          },
        ),
        _EditorField(
          keyName: 'socks_tcp_ports',
          label: 'TCP ports',
          initial: original?.tcpPorts.join(',') ?? '',
          available: widget.supportsTcp,
          hint: '80,443',
          helper: widget.supportsTcp
              ? 'Separate ports with commas.'
              : 'This configuration has no TCP visitor.',
        ),
        _EditorField(
          keyName: 'socks_udp_ports',
          label: 'UDP ports',
          initial: original?.udpPorts.join(',') ?? '',
          available: widget.supportsUdp,
          hint: '53,123',
          helper: widget.supportsUdp
              ? 'Separate ports with commas.'
              : 'This configuration has no UDP visitor.',
        ),
      ],
      onSave: (fields) async {
        final connection = Socks5Connection(
          id: id,
          name: fields['socks_connection_name']!.trim(),
          targetIp: fields['socks_connection_target_ip']!.trim(),
          enabled: original?.enabled ?? true,
          mode: Socks5ConnectionMode.values.byName(
            fields['socks_connection_mode']!,
          ),
          tcpPorts: widget.supportsTcp
              ? Socks5Config.parsePorts(fields['socks_tcp_ports']!)
              : const [],
          udpPorts: widget.supportsUdp
              ? Socks5Config.parsePorts(fields['socks_udp_ports']!)
              : const [],
        );
        final connections = [
          for (final entry in _value.connections)
            if (entry.id == id) connection else entry,
          if (original == null) connection,
        ];
        await _persist(_value.copyWith(connections: connections));
      },
    );
  }

  Future<void> _deleteConnection(Socks5Connection connection) async {
    if (_busy) return;
    setState(() => _childOpen = true);
    final confirmed = await showFrostedDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Padding(
        padding: const EdgeInsets.all(16),
        child: FrostedCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Delete connection?',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              Text('Delete “${connection.name}” and its port forwards?'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('socks_connection_delete_cancel'),
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    key: const ValueKey('socks_connection_delete_confirm'),
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: Text(
                      'Delete',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _childOpen = false);
    if (confirmed == true) {
      await _change(
        _value.copyWith(
          connections: _value.connections
              .where((entry) => entry.id != connection.id)
              .toList(),
        ),
      );
    }
  }

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(value, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );

  Widget _connection(Socks5Connection connection) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        key: ValueKey('socks_connection_${connection.id}'),
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.6)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _busy ? null : () => _editConnection(connection),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connection.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _modeLabel(connection.mode),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                      Text(
                        'Target IP: ${connection.effectiveTargetIp(_value.targetIp)}'
                        '${connection.targetIp.isEmpty ? ' (inherited)' : ''}',
                        key: ValueKey(
                          'socks_connection_target_${connection.id}',
                        ),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                      if (connection.tcpPorts.isNotEmpty)
                        Text(
                          'TCP  ${connection.tcpPorts.join(', ')}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (connection.udpPorts.isNotEmpty)
                        Text(
                          'UDP  ${connection.udpPorts.join(', ')}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                Switch(
                  key: ValueKey('socks_connection_enabled_${connection.id}'),
                  value: connection.enabled,
                  onChanged: _busy
                      ? null
                      : (enabled) => _change(
                          _value.copyWith(
                            connections: [
                              for (final entry in _value.connections)
                                if (entry.id == connection.id)
                                  entry.copyWith(enabled: enabled)
                                else
                                  entry,
                            ],
                          ),
                        ),
                ),
                IconButton(
                  key: ValueKey('socks_connection_delete_${connection.id}'),
                  tooltip: 'Delete connection',
                  onPressed: _busy ? null : () => _deleteConnection(connection),
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_busy,
    child: _SocksModalCard(
      cardKey: 'socks5_config_dialog',
      title: 'SOCKS5',
      maxHeightFraction: 0.6,
      body: SingleChildScrollView(
        key: const ValueKey('socks5_form_scroll'),
        controller: _scroll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detail(
              'Target IP',
              _value.targetIp.isEmpty ? 'Not set' : _value.targetIp,
            ),
            _detail(
              'Username',
              _value.username.isEmpty ? 'None' : _value.username,
            ),
            _detail('Password', _value.password.isEmpty ? 'None' : '***'),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Ports',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const ValueKey('socks_connection_add'),
                  tooltip: 'Add connection',
                  onPressed:
                      _busy ||
                          !_hasTarget ||
                          (!widget.supportsTcp && !widget.supportsUdp)
                      ? null
                      : () => _editConnection(),
                  icon: const Icon(Icons.add_rounded, size: 22),
                ),
              ],
            ),
            if (!_hasTarget)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Set a target IP with Edit before adding a connection.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (_value.connections.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'No SOCKS connections.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final connection in _value.connections)
              _connection(connection),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Text(
                  _error!,
                  key: const ValueKey('socks_save_error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      footer: Row(
        children: [
          TextButton(
            key: const ValueKey('socks_edit'),
            onPressed: _busy ? null : _editAccount,
            child: const Text('Edit'),
          ),
          const Spacer(),
          TextButton(
            key: const ValueKey('socks_close'),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}

class _EditorField {
  final String keyName;
  final String label;
  final String initial;
  final String? hint;
  final String? helper;
  final bool secret;
  final bool available;
  final Map<String, String>? options;

  const _EditorField({
    required this.keyName,
    required this.label,
    required this.initial,
    this.hint,
    this.helper,
    this.secret = false,
    this.available = true,
    this.options,
  });
}

class _SocksEditorDialog extends StatefulWidget {
  final String title;
  final String editorKey;
  final String saveKey;
  final String closeKey;
  final List<_EditorField> fields;
  final Future<void> Function(Map<String, String>) onSave;

  const _SocksEditorDialog({
    required this.title,
    required this.editorKey,
    required this.saveKey,
    required this.closeKey,
    required this.fields,
    required this.onSave,
  });

  @override
  State<_SocksEditorDialog> createState() => _SocksEditorDialogState();
}

class _SocksEditorDialogState extends State<_SocksEditorDialog> {
  final _scroll = ScrollController();
  late final Map<String, TextEditingController> _controllers;
  late final String _initial;
  bool _saving = false;
  bool _confirming = false;
  bool _allowPop = false;
  String? _error;

  Map<String, String> get _values => {
    for (final entry in _controllers.entries) entry.key: entry.value.text,
  };

  bool get _dirty => jsonEncode(_values) != _initial;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final field in widget.fields)
        field.keyName: TextEditingController(text: field.initial),
    };
    _initial = jsonEncode(_values);
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _close() {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_values);
      if (mounted) _close();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _saveError(error);
      });
      _revealError(_scroll);
    }
  }

  Future<void> _requestClose() async {
    if (_saving || _confirming || _allowPop) return;
    if (!_dirty) {
      _close();
      return;
    }
    _confirming = true;
    FocusScope.of(context).unfocus();
    final choice = await showFrostedDialog<_UnsavedChoice>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Padding(
        padding: const EdgeInsets.all(16),
        child: FrostedCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Unsaved changes',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              const Text('Save your SOCKS5 changes before closing?'),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  TextButton(
                    key: const ValueKey('socks_keep_editing'),
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Keep editing'),
                  ),
                  TextButton(
                    key: const ValueKey('socks_discard_changes'),
                    onPressed: () =>
                        Navigator.pop(dialogContext, _UnsavedChoice.discard),
                    child: const Text('Discard'),
                  ),
                  TextButton(
                    key: const ValueKey('socks_save_changes'),
                    onPressed: () =>
                        Navigator.pop(dialogContext, _UnsavedChoice.save),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    _confirming = false;
    if (!mounted) return;
    if (choice == _UnsavedChoice.save) {
      await _save();
    } else if (choice == _UnsavedChoice.discard) {
      _close();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _allowPop || (!_saving && !_dirty),
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _requestClose();
    },
    child: _SocksModalCard(
      cardKey: widget.editorKey,
      title: widget.title,
      maxHeightFraction: 0.85,
      body: SingleChildScrollView(
        key: const ValueKey('socks_editor_scroll'),
        controller: _scroll,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final field in widget.fields)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 12),
                child: field.options != null
                    ? AppDropdownButtonFormField<String>(
                        key: ValueKey(field.keyName),
                        initialValue: _controllers[field.keyName]!.text,
                        decoration: AppFormStyle.decoration(label: field.label),
                        items: [
                          for (final option in field.options!.entries)
                            DropdownMenuItem(
                              value: option.key,
                              child: Text(option.value),
                            ),
                        ],
                        onChanged: _saving || !field.available
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() {
                                  _controllers[field.keyName]!.text = value;
                                  _error = null;
                                });
                              },
                      )
                    : TextField(
                        key: ValueKey(field.keyName),
                        controller: _controllers[field.keyName],
                        enabled: field.available,
                        readOnly: _saving,
                        obscureText: field.secret,
                        enableSuggestions: false,
                        autocorrect: false,
                        onChanged: (_) => setState(() => _error = null),
                        decoration: AppFormStyle.decoration(
                          label: field.label,
                          hint: field.hint,
                          helper: field.helper,
                        ).copyWith(helperMaxLines: 3),
                      ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  key: const ValueKey('socks_editor_save_error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      footer: Row(
        children: [
          TextButton(
            key: ValueKey(widget.saveKey),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Save'),
          ),
          const Spacer(),
          TextButton(
            key: ValueKey(widget.closeKey),
            onPressed: _saving ? null : _requestClose,
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}

enum _UnsavedChoice { discard, save }

String _modeLabel(Socks5ConnectionMode mode) => switch (mode) {
  Socks5ConnectionMode.immediate => 'Immediate',
  Socks5ConnectionMode.onDemand => 'On demand',
};

String _saveError(Object error) => error is FormatException
    ? error.message
    : 'Unable to save SOCKS5 configuration. Your changes are still here.';

void _revealError(ScrollController scroll) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
  });
}

class _SocksModalCard extends StatelessWidget {
  final String cardKey;
  final String title;
  final double maxHeightFraction;
  final Widget body;
  final Widget footer;

  const _SocksModalCard({
    required this.cardKey,
    required this.title,
    required this.maxHeightFraction,
    required this.body,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available = math.max(
      0.0,
      media.size.height - media.viewInsets.bottom - media.padding.vertical - 32,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, media.viewInsets.bottom + 16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.min(media.size.height * maxHeightFraction, available),
        ),
        child: FrostedCard(
          key: ValueKey(cardKey),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.swap_horiz_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(child: body),
              const SizedBox(height: 8),
              const Divider(height: 1),
              SizedBox(height: 48, child: footer),
            ],
          ),
        ),
      ),
    );
  }
}
