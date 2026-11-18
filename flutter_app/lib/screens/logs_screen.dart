import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/frp_config.dart';
import '../services/frp_engine.dart' show RuntimeLog;
import '../services/log_file_export.dart';
import '../services/secure_clipboard.dart';
import '../services/socks5_log_entry.dart';
import '../state/app_state.dart';
import '../widgets/app_form_style.dart';

export '../services/frp_engine.dart' show RuntimeLog;

/// The native service owns the full history; the stream only contains new lines.
abstract interface class LogsSource {
  Stream<RuntimeLog> get logStream;
  List<RuntimeLog> get logs;
  Future<List<RuntimeLog>> readLogs();
}

class _EngineLogsSource implements LogsSource {
  const _EngineLogsSource();

  @override
  Stream<RuntimeLog> get logStream => appState.engine.logStream;

  @override
  List<RuntimeLog> get logs => appState.engine.logs;

  @override
  Future<List<RuntimeLog>> readLogs() => appState.engine.readLogSnapshot();
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
    this.anchorLatestLog = kReleaseMode,
  });

  final LogsSource? source;
  final ValueListenable<List<FrpConfig>>? configurations;
  final LogsFileSaver? saveLogs;
  @visibleForTesting
  final bool anchorLatestLog;

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
  StreamSubscription<RuntimeLog>? _sub;
  final _entries = ListQueue<_LogLine>();
  final _visible = ListQueue<_LogLine>();
  final _pending = ListQueue<RuntimeLog>();
  final _owners = <(String, String), ({Socks5LogContext context, int count})>{};
  int? _frameCallback;
  Timer? _displayCooldown;
  Map<String, _SocksLogConfiguration> _configurations = {};
  String? _configurationKey;
  String? _connectionId;
  bool _loadingInitial = true;
  bool _scrollScheduled = false;
  String _filter = '';
  _LogCategory _category = _LogCategory.all;
  bool _autoScroll = true;
  bool _savingLogs = false;
  // When following is paused, older and newer rows grow on opposite sides
  // of this ID. New arrivals leave the reader's pixel position intact.
  int? _pausedAtId;
  double _tailAnchor = 1;

  @override
  void initState() {
    super.initState();
    _source = widget.source ?? const _EngineLogsSource();
    _configurationChanges = widget.configurations ?? appState;
    _configurationChanges.addListener(_onConfigurationsChanged);
    for (final row in _source.logs) {
      _append(_LogLine(row));
    }
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
    for (final owner in _owners.values) {
      add(owner.context);
    }
    final oldFilters = (_configurationKey, _connectionId);
    _configurations = options;
    if (!options.containsKey(_configurationKey)) {
      _configurationKey = null;
      _connectionId = null;
    } else if (!options[_configurationKey]!.connections.containsKey(
      _connectionId,
    )) {
      _connectionId = null;
    }
    if (oldFilters != (_configurationKey, _connectionId)) _refilter();
  }

  bool _updateOwner(_LogLine row, int delta) {
    final context = row.socks5?.context;
    if (context == null) return false;
    final key = (context.configKey, context.connectionId);
    final old = _owners[key];
    final count = (old?.count ?? 0) + delta;
    if (count == 0) {
      _owners.remove(key);
      return true;
    }
    final current = delta > 0 ? context : old!.context;
    _owners[key] = (context: current, count: count);
    return old == null ||
        current.configName != old.context.configName ||
        current.connectionName != old.context.connectionName;
  }

  bool _append(_LogLine row) {
    // Native callback order is serialized under the same lock as its snapshot.
    if (row.raw.isEmpty ||
        (_entries.isNotEmpty && row.record.id <= _entries.last.record.id)) {
      return false;
    }
    _entries.addLast(row);
    var changed = _updateOwner(row, 1);
    if (_matches(row)) _visible.addLast(row);
    if (_entries.length > _historyLimit) {
      final expired = _entries.removeFirst();
      changed = _updateOwner(expired, -1) || changed;
      if (_visible.isNotEmpty && identical(_visible.first, expired)) {
        _visible.removeFirst();
      }
    }
    return changed;
  }

  void _onLog(RuntimeLog row) {
    if (!mounted) return;
    _pending.addLast(row);
    if (_pending.length > _historyLimit) _pending.removeFirst();
    if (kReleaseMode && widget.source == null && _loadingInitial) return;
    if (_displayCooldown == null) _scheduleRefresh();
  }

  void _scheduleRefresh() {
    _frameCallback ??= WidgetsBinding.instance.scheduleFrameCallback((_) {
      _frameCallback = null;
      if (!mounted || _pending.isEmpty) return;
      _flushPending();
      _scrollToBottom();
      // Low-rate events appear on the next frame. During sustained traffic,
      // cap visible updates at five per second, regardless of the log rate.
      _displayCooldown = Timer(const Duration(milliseconds: 200), () {
        _displayCooldown = null;
        if (mounted && _pending.isNotEmpty) _scheduleRefresh();
      });
    });
  }

  void _flushPending() {
    if (_pending.isEmpty) return;
    setState(() {
      var changed = false;
      while (_pending.isNotEmpty) {
        changed = _append(_LogLine(_pending.removeFirst())) || changed;
      }
      if (changed) _refreshConfigurations();
    });
  }

  Future<void> _loadInitial() async {
    List<RuntimeLog> history;
    try {
      history = await _source.readLogs();
    } catch (_) {
      history = const [];
    }
    if (!mounted) return;
    setState(() {
      if (kReleaseMode && widget.source == null) {
        // Subscribing precedes the Android snapshot on the same FIFO channel.
        // A batch delivered during the read can overlap the end of the snapshot.
        for (final row in history) {
          _append(_LogLine(row));
        }
        final lastSnapshotId = history.lastOrNull?.id ?? 0;
        for (final row in _pending) {
          if (row.id > lastSnapshotId) _append(_LogLine(row));
        }
        _pending.clear();
      } else {
        final merged = <int, _LogLine>{
          for (final row in history) row.id: _LogLine(row),
          for (final row in _entries) row.record.id: row,
          for (final row in _pending) row.id: _LogLine(row),
        };
        _pending.clear();
        _entries.clear();
        _visible.clear();
        _owners.clear();
        final ids = merged.keys.toList()..sort();
        for (final id in ids.skip(
          ids.length > _historyLimit ? ids.length - _historyLimit : 0,
        )) {
          _append(merged[id]!);
        }
      }
      _refreshConfigurations();
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
      if (widget.anchorLatestLog) {
        if (position.pixels != 0) position.jumpTo(0);
      } else if (position.pixels != position.maxScrollExtent) {
        position.jumpTo(position.maxScrollExtent);
        // Lazy, wrapped rows can change the estimated extent after a jump.
        _scrollToBottom();
      }
    });
  }

  void _setFilter(String value) {
    setState(() {
      _filter = value;
      _refilter();
    });
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
    setState(() {
      _autoScroll = value;
      if (widget.anchorLatestLog) {
        _pausedAtId = value ? null : (_entries.lastOrNull?.record.id ?? 0);
      }
    });
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
        setState(() {
          _category = _LogCategory.values.byName(value);
          _refilter();
        });
        _scrollToBottom();
      },
    );
    late final configuration = _filterMenu(
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
          _refilter();
        });
        _scrollToBottom();
      },
    );
    late final ports = _filterMenu(
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
        setState(() {
          _connectionId = value.isEmpty ? null : value;
          _refilter();
        });
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
    _displayCooldown?.cancel();
    if (_frameCallback case final id?) {
      WidgetsBinding.instance.cancelFrameCallbackWithId(id);
    }
    _scrollController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _copyAll() async {
    _flushPending();
    try {
      await SecureClipboard.copy(_entries.map((e) => e.raw).join('\n'));
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

  bool _matches(_LogLine line) {
    if (_category != _LogCategory.all && _lineCategory(line.raw) != _category) {
      return false;
    }
    if (_category == _LogCategory.socks5 && _configurationKey != null) {
      final context = line.socks5?.context;
      if (context?.configKey != _configurationKey) return false;
      if (_connectionId != null && context?.connectionId != _connectionId) {
        return false;
      }
    }
    return _filter.isEmpty ||
        line.display.toLowerCase().contains(_filter.toLowerCase());
  }

  void _refilter() {
    _visible.clear();
    _visible.addAll(_entries.where(_matches));
  }

  Future<void> _saveLogs() async {
    if (_savingLogs || _loadingInitial) return;
    final ownership = (_configurationKey, _connectionId);
    _flushPending();
    // If the last matching entry expired, avoid broadening an export to all
    // configurations just because its historical filter disappeared.
    if (_category == _LogCategory.socks5 &&
        ownership != (_configurationKey, _connectionId)) {
      return;
    }
    // Freeze the same filtered rows the viewer uses before opening the picker.
    // Preserve the raw, already-redacted records and their diagnostic fields.
    final snapshot = List<String>.unmodifiable(
      _visible.map((line) => line.raw),
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
    final visible = _visible;

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
            onPressed: _entries.isEmpty ? null : _copyAll,
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
                      _entries.isEmpty ? 'No logs yet' : 'No matching logs',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  )
                : widget.anchorLatestLog
                ? _anchoredLogList(scheme)
                : ListView.builder(
                    key: const ValueKey('logs_list'),
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: visible.length,
                    itemBuilder: (context, index) => _logRow(scheme, index),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _logRow(ColorScheme scheme, int index) {
    final line = _visible.elementAt(index).display;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text(
        line,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: _lineColor(scheme, line),
        ),
      ),
    );
  }

  int _rowsBeforeAnchor() {
    final id = _pausedAtId;
    if (id == null) return _visible.length;
    var first = 0;
    var end = _visible.length;
    while (first < end) {
      final middle = first + (end - first) ~/ 2;
      if (_visible.elementAt(middle).record.id <= id) {
        first = middle + 1;
      } else {
        end = middle;
      }
    }
    return first;
  }

  Widget _anchoredLogList(ColorScheme scheme) {
    const center = ValueKey('logs_after_anchor');
    const inset = 12.0;
    final before = _rowsBeforeAnchor();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: inset),
      child: CustomScrollView(
        key: const ValueKey('logs_list'),
        controller: _scrollController,
        anchor: _tailAnchor,
        center: center,
        semanticChildCount: _visible.length,
        slivers: [
          // Laid out after the older rows in the upward-growing half. Their
          // actual height lets a short history sit at the top of the viewport.
          SliverLayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.viewportMainAxisExtent;
              if (height > 0) {
                final anchor =
                    ((constraints.precedingScrollExtent + inset) / height)
                        .clamp(0.0, (1 - inset / height).clamp(0.0, 1.0));
                if (anchor != _tailAnchor) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && anchor != _tailAnchor) {
                      setState(() => _tailAnchor = anchor);
                    }
                  });
                }
              }
              return const SliverToBoxAdapter(child: SizedBox(height: inset));
            },
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _logRow(scheme, before - 1 - index),
              childCount: before,
              semanticIndexCallback: (_, index) => before - 1 - index,
            ),
          ),
          SliverList(
            key: center,
            delegate: SliverChildBuilderDelegate(
              (context, index) => _logRow(scheme, before + index),
              childCount: _visible.length - before,
              semanticIndexOffset: before,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: inset)),
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
  _LogLine(this.record) : socks5 = Socks5LogEntry.tryParse(record.line);

  final RuntimeLog record;
  String get raw => record.line;
  final Socks5LogEntry? socks5;
  late final String display = socks5?.displayLine ?? raw;
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
