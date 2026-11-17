import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/frp_config.dart';
import '../services/log_file_export.dart';
import '../services/secure_clipboard.dart';
import '../services/socks5_log_entry.dart';
import '../state/app_state.dart';
import '../widgets/app_form_style.dart';

/// The native service owns the full history; the stream only contains new lines.
abstract interface class LogsSource {
  Stream<String> get logStream;
  List<String> get logs;
  Future<String> readLogs();
}

class _EngineLogsSource implements LogsSource {
  const _EngineLogsSource();

  @override
  Stream<String> get logStream => appState.engine.logStream;

  @override
  List<String> get logs => appState.engine.logs;

  @override
  Future<String> readLogs() => appState.engine.readLogs();
}

enum _LogCategory {
  all('All'),
  frpc('frpc'),
  stun('stun'),
  socks5('Socks5');

  const _LogCategory(this.label);
  final String label;
}

typedef LogsFileSaver = Future<bool> Function(
  List<String> lines, {
  required bool filtered,
});

class LogsScreen extends StatefulWidget {
  const LogsScreen({
    super.key,
    this.source,
    this.configurations,
    this.saveLogs,
  });

  final LogsSource? source;
  final ValueListenable<List<FrpConfig>>? configurations;
  final LogsFileSaver? saveLogs;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  static const _historyLimit = 2000;
  static final _socksPattern = RegExp(
    r'\bsocks5(?:_udp)?\b',
    caseSensitive: false,
  );
  static final _stunPattern = RegExp(
    r'\bstun\b|\bnat_?hole_?stun_?server\b',
    caseSensitive: false,
  );
  final _scrollController = ScrollController();
  final _filterController = TextEditingController();
  late final LogsSource _source;
  late Listenable _configurationChanges;
  StreamSubscription<String>? _sub;
  List<String> _logs = [];
  List<_LogLine> _entries = [];
  Map<String, _SocksLogConfiguration> _configurations = {};
  String? _configurationKey;
  String? _connectionId;
  final List<String> _initialLiveLogs = [];
  bool _loadingInitial = true;
  bool _scrollScheduled = false;
  String _filter = '';
  _LogCategory _category = _LogCategory.all;
  bool _autoScroll = true;
  bool _savingLogs = false;

  @override
  void initState() {
    super.initState();
    _source = widget.source ?? const _EngineLogsSource();
    _configurationChanges = widget.configurations ?? appState;
    _configurationChanges.addListener(_onConfigurationsChanged);
    _logs = _trimHistory(_source.logs);
    _entries = _logs.map(_LogLine.new).toList();
    _refreshConfigurations();
    _sub = _source.logStream.listen(_onLog);
    _loadInitial();
    _scrollToBottom();
  }

  @override
  void didUpdateWidget(covariant LogsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.configurations != oldWidget.configurations) {
      _configurationChanges.removeListener(_onConfigurationsChanged);
      _configurationChanges = widget.configurations ?? appState;
      _configurationChanges.addListener(_onConfigurationsChanged);
      _refreshConfigurations();
    }
  }

  void _onConfigurationsChanged() {
    if (!mounted) return;
    setState(_refreshConfigurations);
    _scrollToBottom();
  }

  String _serverName(String serverId) {
    if (widget.configurations == null) {
      for (final server in appState.servers) {
        if (server.serverId == serverId && server.name.trim().isNotEmpty) {
          return server.name;
        }
      }
    }
    return serverId.isEmpty ? 'Local' : serverId;
  }

  void _refreshConfigurations() {
    final options = <String, _SocksLogConfiguration>{};
    void add(Socks5LogContext context, {String? serverId}) {
      final option = options.putIfAbsent(
        context.configKey,
        () => _SocksLogConfiguration(
          key: context.configKey,
          name: context.configName,
          serverName: _serverName(
            serverId ?? context.configKey.split('/').first,
          ),
        ),
      );
      option.connections.putIfAbsent(
        context.connectionId,
        () => context.connectionName,
      );
    }

    // Saved names take precedence over old names in the retained history.
    // Disabled rows are useful filters too, even before they have emitted logs.
    for (final config in widget.configurations?.value ?? appState.configs) {
      for (final connection in config.socks5?.connections ?? []) {
        add(
          Socks5LogContext.fromConfig(config, connection),
          serverId: config.serverId,
        );
      }
    }
    for (final line in _entries) {
      final context = line.socks5?.context;
      if (context != null) add(context);
    }
    _configurations = options;
    if (!options.containsKey(_configurationKey)) {
      _configurationKey = null;
      _connectionId = null;
    } else if (!options[_configurationKey]!.connections.containsKey(
      _connectionId,
    )) {
      _connectionId = null;
    }
  }

  List<String> _trimHistory(List<String> lines) => lines.length > _historyLimit
      ? lines.sublist(lines.length - _historyLimit)
      : List.of(lines);

  void _onLog(String line) {
    if (!mounted || line.isEmpty) return;
    if (_loadingInitial) {
      _initialLiveLogs.add(line);
      if (_initialLiveLogs.length > _historyLimit) _initialLiveLogs.removeAt(0);
    }
    setState(() {
      _logs = _trimHistory([..._logs, line]);
      _entries = [..._entries, _LogLine(line)];
      if (_entries.length > _historyLimit) _entries.removeAt(0);
      _refreshConfigurations();
    });
    _scrollToBottom();
  }

  Future<void> _loadInitial() async {
    String all;
    try {
      all = await _source.readLogs();
    } catch (_) {
      all = '';
    }
    if (!mounted) return;
    final history = all.split('\n').where((e) => e.isNotEmpty).toList();
    setState(() {
      if (history.isNotEmpty) {
        // The native snapshot can already include the first stream events.
        // Match its tail to the buffered events before appending newer lines.
        var overlap = history.length < _initialLiveLogs.length
            ? history.length
            : _initialLiveLogs.length;
        for (; overlap > 0; overlap--) {
          var matches = true;
          for (var i = 0; i < overlap; i++) {
            if (history[history.length - overlap + i] != _initialLiveLogs[i]) {
              matches = false;
              break;
            }
          }
          if (matches) break;
        }
        _logs = _trimHistory([...history, ..._initialLiveLogs.skip(overlap)]);
      }
      _entries = _logs.map(_LogLine.new).toList();
      _refreshConfigurations();
      _initialLiveLogs.clear();
      _loadingInitial = false;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    if (!_autoScroll || _scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_autoScroll || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.pixels != position.maxScrollExtent) {
        position.jumpTo(position.maxScrollExtent);
        // Lazy, wrapped rows can change the estimated extent after a jump.
        _scrollToBottom();
      }
    });
  }

  void _setFilter(String value) {
    setState(() => _filter = value);
    _scrollToBottom();
  }

  _LogCategory _lineCategory(String line) {
    // Native diagnostics have tags; frpc's STUN errors are untagged text.
    if (_socksPattern.hasMatch(line)) return _LogCategory.socks5;
    if (_stunPattern.hasMatch(line)) return _LogCategory.stun;
    return _LogCategory.frpc;
  }

  InputDecoration _compactDecoration({String? hint}) =>
      AppFormStyle.decoration(hint: hint).copyWith(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        constraints: const BoxConstraints(minHeight: 36),
      );

  String _configurationLabel(_SocksLogConfiguration option) {
    final sameName = _configurations.values.where((v) => v.name == option.name);
    if (sameName.length == 1) return option.name;
    final label = '${option.name} · ${option.serverName}';
    if (sameName.where((v) => v.serverName == option.serverName).length == 1) {
      return label;
    }
    return '$label · ${option.key.split('/').last}';
  }

  String _connectionLabel(Map<String, String> connections, String id) {
    final name = connections[id]!;
    if (connections.values.where((value) => value == name).length == 1) {
      return name;
    }
    return '$name · ${id.length > 8 ? id.substring(id.length - 8) : id}';
  }

  Widget _filterMenu({
    required String keyName,
    required String label,
    required String value,
    required List<(String, String)> choices,
    required ValueChanged<String> onSelected,
    bool enabled = true,
  }) {
    final selected = choices.firstWhere((choice) => choice.$1 == value).$2;
    final available = MediaQuery.sizeOf(context).width - 32;
    final menuWidth = available < 280 ? available : 280.0;
    return PopupMenuButton<String>(
      key: ValueKey(keyName),
      enabled: enabled,
      tooltip: '$label: $selected',
      initialValue: value,
      constraints: BoxConstraints(minWidth: menuWidth, maxWidth: menuWidth),
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final choice in choices)
          PopupMenuItem(
            value: choice.$1,
            child: Text(
              choice.$2,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
      child: Semantics(
        label: label,
        enabled: enabled,
        child: SizedBox(
          height: 36,
          child: InputDecorator(
            decoration: _compactDecoration().copyWith(enabled: enabled),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selected,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: enabled
                          ? Theme.of(context).colorScheme.onSurface
                          : Theme.of(context).disabledColor,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: enabled ? null : Theme.of(context).disabledColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setAutoScroll(bool value) {
    setState(() => _autoScroll = value);
    if (value) _scrollToBottom();
  }

  Widget _autoScrollControl({required bool compact}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Tooltip(
        message: 'Auto-scroll',
        child: Icon(
          Icons.vertical_align_bottom,
          size: 14,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      if (!compact) ...[
        const SizedBox(width: 4),
        const Flexible(
          child: Text('Auto-scroll', style: TextStyle(fontSize: 11)),
        ),
      ],
      Semantics(
        label: 'Auto-scroll',
        toggled: _autoScroll,
        excludeSemantics: true,
        onTap: () => _setAutoScroll(!_autoScroll),
        child: InkWell(
          onTap: () => _setAutoScroll(!_autoScroll),
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Transform.scale(
                scale: 0.75,
                child: Switch(
                  key: const ValueKey('logs_auto_scroll'),
                  value: _autoScroll,
                  onChanged: _setAutoScroll,
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _toolbar(int visibleCount) {
    final socks = _category == _LogCategory.socks5;
    final connections =
        _configurations[_configurationKey]?.connections ??
        const <String, String>{};
    final category = _filterMenu(
      keyName: 'logs_category',
      label: 'Category',
      value: _category.name,
      choices: [
        for (final item in _LogCategory.values) (item.name, item.label),
      ],
      onSelected: (value) {
        setState(() => _category = _LogCategory.values.byName(value));
        _scrollToBottom();
      },
    );
    final configuration = _filterMenu(
      keyName: 'logs_configuration',
      label: 'Configuration',
      value: _configurationKey ?? '',
      choices: [
        ('', 'All configurations'),
        for (final option in _configurations.values)
          (option.key, _configurationLabel(option)),
      ],
      onSelected: (value) {
        setState(() {
          _configurationKey = value.isEmpty ? null : value;
          _connectionId = null;
        });
        _scrollToBottom();
      },
    );
    final ports = _filterMenu(
      keyName: 'logs_ports',
      label: 'Ports',
      value: _connectionId ?? '',
      choices: [
        ('', 'All ports'),
        for (final id in connections.keys)
          (id, _connectionLabel(connections, id)),
      ],
      enabled: _configurationKey != null,
      onSelected: (value) {
        setState(() => _connectionId = value.isEmpty ? null : value);
        _scrollToBottom();
      },
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Most phones can keep the three filters beside the compact switch.
          // Narrow screens retain readable Configuration and Ports fields below.
          final singleRow = socks && constraints.maxWidth >= 368;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (singleRow)
                    _autoScrollControl(compact: true)
                  else
                    Expanded(child: _autoScrollControl(compact: false)),
                  const SizedBox(width: 6),
                  SizedBox(width: singleRow ? 88 : 100, child: category),
                  if (singleRow) ...[
                    const SizedBox(width: 6),
                    Expanded(flex: 4, child: configuration),
                    const SizedBox(width: 6),
                    Expanded(flex: 3, child: ports),
                  ],
                ],
              ),
              if (socks && !singleRow) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(child: configuration),
                    const SizedBox(width: 8),
                    Expanded(child: ports),
                  ],
                ),
              ],
              Text(
                '$visibleCount lines',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _configurationChanges.removeListener(_onConfigurationsChanged);
    _sub?.cancel();
    _scrollController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _copyAll() async {
    try {
      await SecureClipboard.copy(_logs.join('\n'));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs copied; clipboard clears in 60s')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Unable to copy logs')));
    }
  }

  bool get _hasLogFilter => _category != _LogCategory.all || _filter.isNotEmpty;

  List<_LogLine> _visibleEntries() {
    final query = _filter.toLowerCase();
    return _entries.where((line) {
      if (_category != _LogCategory.all &&
          _lineCategory(line.raw) != _category) {
        return false;
      }
      if (_category == _LogCategory.socks5 && _configurationKey != null) {
        final context = line.socks5?.context;
        if (context?.configKey != _configurationKey) return false;
        if (_connectionId != null && context?.connectionId != _connectionId) {
          return false;
        }
      }
      return query.isEmpty || line.display.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _saveLogs() async {
    if (_savingLogs || _loadingInitial) return;
    // Freeze the same filtered rows the viewer uses before opening the picker.
    // Preserve the raw, already-redacted records and their diagnostic fields.
    final snapshot = List<String>.unmodifiable(
      _visibleEntries().map((line) => line.raw),
    );
    if (snapshot.isEmpty) return;
    final filtered = _hasLogFilter;
    setState(() => _savingLogs = true);
    try {
      final saved = await (widget.saveLogs ?? LogFileExport.save)(
        snapshot,
        filtered: filtered,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved ? 'Saved ${snapshot.length} log lines' : 'Log save cancelled',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Unable to save logs')));
    } finally {
      if (mounted) setState(() => _savingLogs = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _visibleEntries();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            key: const ValueKey('logs_save'),
            tooltip: _hasLogFilter ? 'Save filtered logs' : 'Save logs',
            onPressed: _savingLogs || _loadingInitial || visible.isEmpty
                ? null
                : _saveLogs,
            icon: _savingLogs
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt),
          ),
          IconButton(
            tooltip: 'Copy all',
            onPressed: _logs.isEmpty ? null : _copyAll,
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: TextField(
              controller: _filterController,
              onChanged: _setFilter,
              style: const TextStyle(fontSize: 12),
              decoration: _compactDecoration(hint: 'Filter logs').copyWith(
                prefixIcon: const Icon(Icons.search, size: 18),
                prefixIconConstraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                suffixIconConstraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                suffixIcon: _filter.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _filterController.clear();
                          _setFilter('');
                        },
                      ),
              ),
            ),
          ),
          _toolbar(visible.length),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      _logs.isEmpty ? 'No logs yet' : 'No matching logs',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    key: const ValueKey('logs_list'),
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final line = visible[index].display;
                      final color = _lineColor(scheme, line);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: color,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Color _lineColor(ColorScheme scheme, String line) {
    final l = line.toLowerCase();
    if (l.contains('error') ||
        l.contains('failed') ||
        l.contains("doesn't exist")) {
      return const Color(0xFFF44336);
    }
    if (l.contains('success') || l.contains('established')) {
      return const Color(0xFF4CAF50);
    }
    if (l.contains('warning')) {
      return const Color(0xFFFF9800);
    }
    return scheme.onSurface;
  }
}

class _LogLine {
  _LogLine(this.raw) : socks5 = Socks5LogEntry.tryParse(raw);

  final String raw;
  final Socks5LogEntry? socks5;
  String get display => socks5?.displayLine ?? raw;
}

class _SocksLogConfiguration {
  _SocksLogConfiguration({
    required this.key,
    required this.name,
    required this.serverName,
  });

  final String key;
  final String name;
  final String serverName;
  final Map<String, String> connections = {};
}
