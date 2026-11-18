import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/frp_config.dart';
import '../services/toml_generator.dart';
import '../services/toml_redaction.dart';
import '../widgets/frosted_dialog.dart';

export '../services/toml_redaction.dart' show redactConfigurationToml;

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
