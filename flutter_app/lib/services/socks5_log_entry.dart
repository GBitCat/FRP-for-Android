import 'dart:convert';

import '../models/frp_config.dart';
import '../models/socks5_config.dart';

/// Stable ownership for a named Ports row, shared by all of its TCP/UDP ports.
/// Names are presentation snapshots; filtering uses the IDs so renames do not
/// split a saved configuration's history.
class Socks5LogContext {
  final String configKey;
  final String configName;
  final String connectionId;
  final String connectionName;

  const Socks5LogContext({
    required this.configKey,
    required this.configName,
    required this.connectionId,
    required this.connectionName,
  });

  factory Socks5LogContext.fromConfig(
    FrpConfig config,
    Socks5Connection connection,
  ) {
    final grouped = config.groupId > 0;
    final serverKey = config.serverId.length <= 64
        ? config.serverId
        : 'server-${_stableDigest(config.serverId)}';
    final key = grouped
        ? '$serverKey/group/${config.groupId}'
        : config.id > 0
        ? '$serverKey/config/${config.id}'
        // Unsaved previews have no durable ID. The name prevents unrelated
        // drafts from sharing an owner; saved configurations never use it.
        : '$serverKey/config/0/${_stableDigest(config.name)}';
    final groupName = grouped ? config.groupName.trim() : '';
    final name = groupName.isNotEmpty ? groupName : config.name.trim();
    return Socks5LogContext(
      configKey: key,
      configName: _displayName(name.isEmpty ? 'Configuration' : name),
      // Imported IDs can contain text that the log sanitizer would redact.
      // Keep saved IDs intact; only their log/filter identity is encoded.
      // Neither ':' nor '=' is safe here: both introduce secret-field values.
      connectionId: RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(connection.id)
          ? connection.id
          : 'encoded/${_stableDigest(connection.id)}',
      connectionName: _displayName(connection.name, fallback: 'Ports'),
    );
  }

  Map<String, String> toJson() => {
    'configKey': configKey,
    'configName': configName,
    'connectionId': connectionId,
    'connectionName': connectionName,
  };

  @override
  bool operator ==(Object other) =>
      other is Socks5LogContext &&
      configKey == other.configKey &&
      configName == other.configName &&
      connectionId == other.connectionId &&
      connectionName == other.connectionName;

  @override
  int get hashCode =>
      Object.hash(configKey, configName, connectionId, connectionName);

  static String _displayName(String name, {String fallback = 'Configuration'}) {
    name = name.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f]'), ' ');
    if (name.trim().isEmpty) return fallback;
    if (name.length <= 160) return name;
    var end = 160;
    final last = name.codeUnitAt(end - 1);
    if (last >= 0xd800 && last <= 0xdbff) end--;
    return name.substring(0, end);
  }

  // FNV-1a is deterministic across app processes, unlike String.hashCode.
  // Used for drafts, malformed preview server IDs and imported connection IDs
  // which cannot be carried through credential redaction unchanged.
  static String _stableDigest(String value) {
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.from(1099511628211);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final byte in utf8.encode(value)) {
      hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

/// Versioned native SOCKS events. Unstructured/older logs remain readable by
/// their existing UI path and deliberately have no guessed configuration owner.
class Socks5LogEntry {
  final String rawLine;
  final Socks5LogContext context;
  final String protocol;
  final int listenPort;
  final String event;
  final String message;
  final int? timestampMs;

  const Socks5LogEntry({
    required this.rawLine,
    required this.context,
    required this.protocol,
    required this.listenPort,
    required this.event,
    required this.message,
    this.timestampMs,
  });

  String get raw => rawLine;

  String get displayLine =>
      '${_timePrefix()}[SOCKS5] ${_singleLine(context.configName)} / '
      '${_singleLine(context.connectionName)} · '
      '${protocol.toUpperCase()} :$listenPort · ${_singleLine(message)}';

  static Socks5LogEntry? tryParse(String line) {
    // Native log history is bounded. Refuse unexpectedly large JSON before
    // decoding it; malformed or future records fall back to ordinary text.
    if (line.length > 65536) return null;
    final trimmed = line.trim();
    const prefix = '[SOCKS5]';
    if (!trimmed.startsWith(prefix)) return null;
    final body = trimmed.substring(prefix.length).trimLeft();
    if (!body.startsWith('{')) return null;
    try {
      final value = jsonDecode(body);
      if (value is! Map<String, dynamic> ||
          value['v'] is! int ||
          value['v'] != 1) {
        return null;
      }
      final configKey = _text(value['configKey']);
      final configName = _text(value['configName']);
      final connectionId = _text(value['connectionId']);
      final connectionName = _text(value['connectionName']);
      final protocol = _text(value['protocol']);
      final port = value['listenPort'];
      final event = _text(value['event']);
      final message = _text(value['message'], allowEmpty: true);
      if (configKey == null ||
          configName == null ||
          connectionId == null ||
          connectionName == null ||
          (protocol != 'tcp' && protocol != 'udp') ||
          port is! int ||
          port < 1 ||
          port > 65535 ||
          event == null ||
          message == null) {
        return null;
      }
      return Socks5LogEntry(
        rawLine: line,
        context: Socks5LogContext(
          configKey: configKey,
          configName: configName,
          connectionId: connectionId,
          connectionName: connectionName,
        ),
        protocol: protocol!,
        listenPort: port,
        event: event,
        message: message,
        timestampMs: _timestamp(value['timestampMs']),
      );
    } on FormatException {
      return null;
    }
  }

  static String? _text(Object? value, {bool allowEmpty = false}) {
    if (value is! String || value.length > 4096) return null;
    if (!allowEmpty && value.trim().isEmpty) return null;
    return value;
  }

  static String _singleLine(String value) =>
      value.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f]'), ' ');

  static int? _timestamp(Object? value) =>
      value is int && value >= -8640000000000000 && value <= 8640000000000000
      ? value
      : null;

  String _timePrefix() {
    final timestamp = _timestamp(timestampMs);
    if (timestamp == null) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)} ';
  }
}
