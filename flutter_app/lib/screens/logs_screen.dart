import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final _scrollController = ScrollController();
  final _filterController = TextEditingController();
  StreamSubscription<String>? _sub;
  List<String> _logs = [];
  String _filter = '';
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _loadInitial();
    _sub = appState.engine.logStream.listen((_) {
      if (!mounted) return;
      setState(() => _logs = appState.engine.logs);
      _scrollToBottom();
    });
  }

  Future<void> _loadInitial() async {
    final all = await appState.engine.readLogs();
    if (!mounted) return;
    setState(() {
      _logs = all.split('\n').where((e) => e.isNotEmpty).toList();
      if (_logs.isEmpty) _logs = appState.engine.logs;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    if (!_autoScroll || !_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  void _copyAll() {
    Clipboard.setData(ClipboardData(text: _logs.join('\n')));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Logs copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _filter.isEmpty
        ? _logs
        : _logs
              .where((e) => e.toLowerCase().contains(_filter.toLowerCase()))
              .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _filterController,
              onChanged: (v) => setState(() => _filter = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter logs',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _filter.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _filterController.clear();
                          setState(() => _filter = '');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 16),
              Icon(
                Icons.vertical_align_bottom,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                'Auto-scroll',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Switch(
                value: _autoScroll,
                onChanged: (v) => setState(() {
                  _autoScroll = v;
                  if (v) _scrollToBottom();
                }),
              ),
              const Spacer(),
              Text(
                '${visible.length} lines',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(width: 16),
            ],
          ),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      _logs.isEmpty ? 'No logs yet' : 'No matching logs',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final line = visible[index];
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
