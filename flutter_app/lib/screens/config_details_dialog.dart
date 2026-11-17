import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/frp_config.dart';
import '../services/toml_generator.dart';
import '../widgets/frosted_dialog.dart';

/// Redacts complete TOML values, including multiline strings and inline tables.
/// Comments are omitted because a handwritten configuration may contain copied
/// credentials in comments as well as in its actual assignments.
String redactConfigurationToml(String source) {
  final output = <String>[];
  var sensitiveTable = false;
  final sensitive = RegExp(
    r'key|password|passwd|secret|token|authorization|credential|cookie',
    caseSensitive: false,
  );
  final assignments = RegExp(r'''(?:"([^"]+)"|'([^']+)'|([\w.-]+))\s*=''');
  for (final statement in _tomlStatements(source)) {
    final text = statement.text.trim();
    if (text.isEmpty) continue;
    if (!statement.complete) {
      output.add('# Unparsed configuration value hidden');
      continue;
    }
    final decodedKeys = text.replaceAllMapped(
      RegExp(r'\\(?:u([0-9a-fA-F]{4})|U([0-9a-fA-F]{8}))'),
      (match) {
        final rune = int.parse(match[1] ?? match[2]!, radix: 16);
        return rune <= 0x10ffff ? String.fromCharCode(rune) : '';
      },
    );
    if (text.startsWith('[')) {
      sensitiveTable = sensitive.hasMatch(decodedKeys);
      output.add(text);
      continue;
    }
    final equals = _assignmentIndex(text);
    if (equals < 0) {
      // Fail closed on an unknown statement rather than showing a partial
      // secret after an invalid multiline assignment.
      output.add('# Unparsed configuration value hidden');
      continue;
    }
    final hasSensitiveKey =
        sensitiveTable ||
        sensitive.hasMatch(text.substring(0, equals)) ||
        assignments
            .allMatches(decodedKeys)
            .any(
              (match) => sensitive.hasMatch(match[1] ?? match[2] ?? match[3]!),
            );
    output.add(
      hasSensitiveKey
          ? '${text.substring(0, equals).trimRight()} = "***"'
          : text,
    );
  }
  return output.join('\n');
}

int _assignmentIndex(String text) {
  String? quote;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (quote == '"' && char == r'\') {
        escaped = true;
      } else if (char == quote) {
        quote = null;
      }
    } else if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '=') {
      return i;
    }
  }
  return -1;
}

Iterable<({String text, bool complete})> _tomlStatements(String source) sync* {
  var buffer = StringBuffer();
  String? quote;
  var triple = false;
  var escaped = false;
  var comment = false;
  var depth = 0;
  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    if (comment) {
      if (char != '\n') continue;
      comment = false;
    }
    if (quote != null) {
      buffer.write(char);
      if (escaped) {
        escaped = false;
      } else if (quote == '"' && char == r'\') {
        escaped = true;
      } else if (char == quote) {
        if (!triple) {
          quote = null;
        } else if (i + 2 < source.length &&
            source[i + 1] == quote &&
            source[i + 2] == quote) {
          buffer.write(source.substring(i + 1, i + 3));
          i += 2;
          quote = null;
          triple = false;
        }
      }
      continue;
    }
    if (char == '#') {
      comment = true;
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      triple =
          i + 2 < source.length &&
          source[i + 1] == char &&
          source[i + 2] == char;
      buffer.write(char);
      if (triple) {
        buffer.write(source.substring(i + 1, i + 3));
        i += 2;
      }
      continue;
    }
    if (char == '[' || char == '{') depth++;
    if (char == ']' || char == '}') depth--;
    if (char == '\n' && depth <= 0) {
      yield (text: buffer.toString(), complete: depth == 0);
      buffer = StringBuffer();
      depth = 0;
    } else {
      buffer.write(char);
    }
  }
  if (buffer.isNotEmpty) {
    yield (text: buffer.toString(), complete: quote == null && depth == 0);
  }
}

class ConfigDetailsDialog extends StatefulWidget {
  final String title;
  final List<FrpConfig> configs;
  final Future<void> Function() onEdit;

  const ConfigDetailsDialog({
    super.key,
    required this.title,
    required this.configs,
    required this.onEdit,
  });

  @override
  State<ConfigDetailsDialog> createState() => _ConfigDetailsDialogState();
}

class _ConfigDetailsDialogState extends State<ConfigDetailsDialog> {
  late List<FrpConfig> _configs;
  bool _openingEditor = false;

  @override
  void initState() {
    super.initState();
    _configs = List.of(widget.configs);
  }

  @override
  void didUpdateWidget(covariant ConfigDetailsDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configs != widget.configs) {
      _configs = List.of(widget.configs);
    }
  }

  Future<void> _openEditor() async {
    if (_openingEditor) return;
    setState(() => _openingEditor = true);
    try {
      await widget.onEdit();
    } finally {
      if (mounted) setState(() => _openingEditor = false);
    }
  }

  String _configurationText(FrpConfig config) {
    try {
      // Show the user's visitor fields. Internal loopback ports are selected
      // across the complete runtime configuration and are not editable here.
      return redactConfigurationToml(
        configBlock(config.copyWith(socks5: null)),
      );
    } catch (_) {
      return 'Configuration preview is unavailable. Use Edit to review it.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = math.min(
      media.size.height * 0.6,
      math.max(
        0.0,
        media.size.height -
            media.viewInsets.bottom -
            media.padding.vertical -
            32,
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, media.viewInsets.bottom + 16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: FrostedCard(
          key: const ValueKey('config_details_dialog'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.description_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  key: const ValueKey('config_details_scroll'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final config in _configs) ...[
                        Text(
                          _configurationText(config),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              SizedBox(
                key: const ValueKey('config_details_actions'),
                height: math.max(48.0, media.size.height * 0.05),
                child: Row(
                  children: [
                    TextButton(
                      key: const ValueKey('config_details_edit'),
                      onPressed: _openingEditor ? null : _openEditor,
                      child: const Text('Edit'),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const ValueKey('config_details_close'),
                      onPressed: _openingEditor
                          ? null
                          : () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
