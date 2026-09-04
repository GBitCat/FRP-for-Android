import 'dart:math';

class ServerConfig {
  static const List<String> supportedProtocols = [
    'tcp',
    'kcp',
    'quic',
    'websocket',
    'wss',
  ];
  static const List<int> intervalPresets = [10, 20, 30, 45, 60, 90, 120];

  final int id;
  final String name;
  final String serverId;
  final String serverAddr;
  final int serverPort;
  final String token;
  final int updatedAt;

  // 连接 frps 的 transport 配置
  final String protocol;
  final bool tcpMux;
  final int heartbeatInterval;
  final int heartbeatTimeout;
  final int tcpMuxKeepaliveInterval;

  // frpc 与 frps 之间的双向 TLS 验证配置
  final bool tlsEnabled;
  final String tlsServerName;
  final String tlsIdentityId;
  final String tlsCertFile;
  final String tlsKeyFile;
  final String tlsTrustedCaFile;

  const ServerConfig({
    this.id = 1,
    this.name = 'FRPS Server',
    this.serverId = '',
    this.serverAddr = '',
    this.serverPort = 7000,
    this.token = '',
    this.updatedAt = 0,
    this.protocol = 'tcp',
    this.tcpMux = true,
    this.heartbeatInterval = 30,
    this.heartbeatTimeout = 90,
    this.tcpMuxKeepaliveInterval = 30,
    this.tlsEnabled = false,
    this.tlsServerName = '',
    this.tlsIdentityId = '',
    this.tlsCertFile = '',
    this.tlsKeyFile = '',
    this.tlsTrustedCaFile = '',
  });

  bool isValid() => runtimeValidationError() == null;

  String? runtimeValidationError() {
    final storageError = storageValidationError();
    if (storageError != null) return storageError;
    if (serverAddr.trim().isEmpty) return 'Server address is required';
    if (tlsEnabled && tlsIdentityId.trim().isEmpty) {
      return 'Select a ready TLS identity before starting frpc';
    }
    return null;
  }

  /// Validates values that are persisted or imported. An empty address and an
  /// unbound TLS identity are allowed so an unfinished server can be edited,
  /// but values that would crash controls or produce invalid frpc TOML are not.
  String? storageValidationError({bool requireServerId = true}) {
    if (id < 0 || updatedAt < 0) {
      return 'Server identifiers and timestamps must not be negative';
    }
    if (name.trim().isEmpty ||
        name.length > 128 ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(name)) {
      return 'Server name must contain 1 to 128 valid characters';
    }
    if (requireServerId && !RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(serverId)) {
      return 'Server ID must contain exactly 8 letters or digits';
    }
    if (serverAddr.length > 255 ||
        RegExp(r'[\u0000-\u0020\u007f]').hasMatch(serverAddr)) {
      return 'Server address contains invalid characters';
    }
    if (serverPort < 1 || serverPort > 65535) {
      return 'Server port must be between 1 and 65535';
    }
    if (!supportedProtocols.contains(protocol)) {
      return 'Unsupported server transport protocol';
    }
    if (!_validInterval(heartbeatInterval) ||
        !_validInterval(heartbeatTimeout) ||
        !_validInterval(tcpMuxKeepaliveInterval)) {
      return 'Transport intervals must be -1 or between 1 and 86400 seconds';
    }
    if (heartbeatInterval > 0 &&
        heartbeatTimeout > 0 &&
        heartbeatTimeout < heartbeatInterval) {
      return 'Heartbeat timeout must not be shorter than its interval';
    }
    if (tlsServerName.length > 255 ||
        RegExp(r'[\u0000-\u0020\u007f]').hasMatch(tlsServerName)) {
      return 'TLS server name contains invalid characters';
    }
    if (tlsIdentityId.length > 128 ||
        (tlsIdentityId.isNotEmpty &&
            !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(tlsIdentityId))) {
      return 'TLS identity ID contains invalid characters';
    }
    if (token.length > 16384 ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(token)) {
      return 'Server token is too long or contains invalid characters';
    }
    return null;
  }

  static bool _validInterval(int value) =>
      value == -1 || (value >= 1 && value <= 86400);

  bool get hasResolvedTlsCredentials =>
      tlsIdentityId.trim().isNotEmpty &&
      tlsCertFile.trim().isNotEmpty &&
      tlsKeyFile.trim().isNotEmpty &&
      tlsTrustedCaFile.trim().isNotEmpty;

  bool get hasCompleteTlsCredentials => hasResolvedTlsCredentials;

  bool get hasLegacyTlsPaths =>
      tlsCertFile.trim().isNotEmpty ||
      tlsKeyFile.trim().isNotEmpty ||
      tlsTrustedCaFile.trim().isNotEmpty;

  ServerConfig withoutRuntimeTlsPaths() =>
      copyWith(tlsCertFile: '', tlsKeyFile: '', tlsTrustedCaFile: '');

  static String generateId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random.secure();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static String normalizeProtocol(String value) {
    final normalized = value.toLowerCase();
    return normalized == 'ws' ? 'websocket' : normalized;
  }

  ServerConfig copyWith({
    int? id,
    String? name,
    String? serverId,
    String? serverAddr,
    int? serverPort,
    String? token,
    int? updatedAt,
    String? protocol,
    bool? tcpMux,
    int? heartbeatInterval,
    int? heartbeatTimeout,
    int? tcpMuxKeepaliveInterval,
    bool? tlsEnabled,
    String? tlsServerName,
    String? tlsIdentityId,
    String? tlsCertFile,
    String? tlsKeyFile,
    String? tlsTrustedCaFile,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      serverId: serverId ?? this.serverId,
      serverAddr: serverAddr ?? this.serverAddr,
      serverPort: serverPort ?? this.serverPort,
      token: token ?? this.token,
      updatedAt: updatedAt ?? this.updatedAt,
      protocol: protocol ?? this.protocol,
      tcpMux: tcpMux ?? this.tcpMux,
      heartbeatInterval: heartbeatInterval ?? this.heartbeatInterval,
      heartbeatTimeout: heartbeatTimeout ?? this.heartbeatTimeout,
      tcpMuxKeepaliveInterval:
          tcpMuxKeepaliveInterval ?? this.tcpMuxKeepaliveInterval,
      tlsEnabled: tlsEnabled ?? this.tlsEnabled,
      tlsServerName: tlsServerName ?? this.tlsServerName,
      tlsIdentityId: tlsIdentityId ?? this.tlsIdentityId,
      tlsCertFile: tlsCertFile ?? this.tlsCertFile,
      tlsKeyFile: tlsKeyFile ?? this.tlsKeyFile,
      tlsTrustedCaFile: tlsTrustedCaFile ?? this.tlsTrustedCaFile,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'serverId': serverId,
    'serverAddr': serverAddr,
    'serverPort': serverPort,
    'token': token,
    'updatedAt': updatedAt,
    'protocol': protocol,
    'tcpMux': tcpMux,
    'heartbeatInterval': heartbeatInterval,
    'heartbeatTimeout': heartbeatTimeout,
    'tcpMuxKeepaliveInterval': tcpMuxKeepaliveInterval,
    'tlsEnabled': tlsEnabled,
    'tlsServerName': tlsServerName,
    'tlsIdentityId': tlsIdentityId,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> j) => ServerConfig(
    id: _jsonInt(j, 'id', 1),
    name: _jsonString(j, 'name', 'FRPS Server'),
    serverId: _jsonString(j, 'serverId', ''),
    serverAddr: _jsonString(j, 'serverAddr', ''),
    serverPort: _jsonInt(j, 'serverPort', 7000),
    token: _jsonString(j, 'token', ''),
    updatedAt: _jsonInt(j, 'updatedAt', 0),
    protocol: normalizeProtocol(_jsonString(j, 'protocol', 'tcp')),
    tcpMux: _jsonBool(j, 'tcpMux', true),
    heartbeatInterval: _jsonInt(j, 'heartbeatInterval', 30),
    heartbeatTimeout: _jsonInt(j, 'heartbeatTimeout', 90),
    tcpMuxKeepaliveInterval: _jsonInt(j, 'tcpMuxKeepaliveInterval', 30),
    tlsEnabled: _jsonBool(j, 'tlsEnabled', false),
    tlsServerName: _jsonString(j, 'tlsServerName', ''),
    tlsIdentityId: _jsonString(j, 'tlsIdentityId', ''),
    tlsCertFile: _jsonString(j, 'tlsCertFile', ''),
    tlsKeyFile: _jsonString(j, 'tlsKeyFile', ''),
    tlsTrustedCaFile: _jsonString(j, 'tlsTrustedCaFile', ''),
  );
}

int _jsonInt(Map<String, dynamic> json, String key, int fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw FormatException('$key must be an integer');
}

String _jsonString(Map<String, dynamic> json, String key, String fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is String) return value;
  throw FormatException('$key must be a string');
}

bool _jsonBool(Map<String, dynamic> json, String key, bool fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}
