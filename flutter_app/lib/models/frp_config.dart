class PortMapping {
  final int localPort;
  final int remotePort;

  const PortMapping({required this.localPort, required this.remotePort});

  Map<String, dynamic> toJson() => {
    'localPort': localPort,
    'remotePort': remotePort,
  };

  factory PortMapping.fromJson(Map<String, dynamic> json) => PortMapping(
    localPort: _jsonInt(json, 'localPort', 0),
    remotePort: _jsonInt(json, 'remotePort', 0),
  );

  @override
  bool operator ==(Object other) =>
      other is PortMapping &&
      other.localPort == localPort &&
      other.remotePort == remotePort;

  @override
  int get hashCode => Object.hash(localPort, remotePort);
}

class FrpConfig {
  final int id;
  final String name;

  // 已废弃：服务器连接配置独立为 ServerConfig，仅为兼容保留
  final String serverAddr;
  final int serverPort;
  final String? token;

  final String localIp;
  final int localPort;
  final int remotePort;
  final List<PortMapping> portMappings;
  final String protocol;

  // HTTP/HTTPS 特有
  final List<String> customDomains;

  // STCP/XTCP 特有
  final String role; // visitor / server
  final String? secretKey;
  final String? serverName;
  final int bindPort;
  final String bindAddr;

  // 传输加密/压缩
  final bool useEncryption;
  final bool useCompression;

  // XTCP/XUDP 回落
  final bool useFallback;
  final String fallbackTo;
  final int fallbackTimeoutMs;
  final bool useCustomStcp;

  // Fallback 自定义配置（字段名保留 STCP 以兼容已有备份）
  final String stcpName;
  final String stcpSecretKey;
  final String stcpServerName;
  final int stcpBindPort;
  final String stcpBindAddr;

  // 分组
  final int groupId;
  final String groupName;
  final bool isGroupPrimary;
  final int linkedConfigId;

  final bool enabled;
  final String serverId;
  final bool running;

  // 手动编写配置：非空时使用该原始 TOML，忽略表单字段
  final String? manualToml;

  final int createdAt;
  final int updatedAt;

  const FrpConfig({
    this.id = 0,
    this.name = '',
    this.serverAddr = '',
    this.serverPort = 7000,
    this.token,
    this.localIp = '127.0.0.1',
    this.localPort = 0,
    this.remotePort = 0,
    this.portMappings = const [],
    this.protocol = 'tcp',
    this.customDomains = const [],
    this.role = 'visitor',
    this.secretKey,
    this.serverName,
    this.bindPort = 0,
    this.bindAddr = '127.0.0.1',
    this.useEncryption = false,
    this.useCompression = false,
    this.useFallback = false,
    this.fallbackTo = '',
    this.fallbackTimeoutMs = 3000,
    this.useCustomStcp = false,
    this.stcpName = '',
    this.stcpSecretKey = '',
    this.stcpServerName = '',
    this.stcpBindPort = -1,
    this.stcpBindAddr = '127.0.0.1',
    this.groupId = 0,
    this.groupName = '',
    this.isGroupPrimary = false,
    this.linkedConfigId = 0,
    this.enabled = true,
    this.serverId = '',
    this.running = false,
    this.manualToml,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  static const List<String> protocols = [
    'tcp',
    'udp',
    'http',
    'https',
    'stcp',
    'sudp',
    'xtcp',
    'xudp',
  ];
  static const List<String> secretProtocols = ['stcp', 'sudp', 'xtcp', 'xudp'];
  static const int maxPortMappings = 128;
  static const int maxCustomDomains = 128;

  bool needsSecretKey() => secretProtocols.contains(protocol.toLowerCase());
  bool isVisitor() => role == 'visitor';
  bool supportsFallback() {
    final type = protocol.toLowerCase();
    return type == 'xtcp' || type == 'xudp';
  }

  bool isInGroup() => groupId > 0;
  bool supportsMultiplePorts() {
    final type = protocol.toLowerCase();
    return type == 'tcp' || type == 'udp';
  }

  /// Complete mappings used by TCP/UDP. Legacy records without the new list
  /// transparently expose their original scalar port pair.
  List<PortMapping> get effectivePortMappings {
    if (supportsMultiplePorts() && portMappings.isNotEmpty) {
      return portMappings;
    }
    return [PortMapping(localPort: localPort, remotePort: remotePort)];
  }

  bool get isMultiPort =>
      supportsMultiplePorts() && effectivePortMappings.length > 1;

  String proxyNameForMapping(PortMapping mapping) =>
      isMultiPort ? '$name-${mapping.localPort}' : name;

  List<String> get generatedProxyNames => [
    for (final mapping in effectivePortMappings) proxyNameForMapping(mapping),
  ];

  List<String> get configuredNames {
    if (manualToml != null) {
      return manualNames.isEmpty ? [name] : manualNames;
    }
    return generatedProxyNames;
  }

  List<String> get runtimeNames => <String>{
    name,
    ...configuredNames,
  }.where((value) => value.isNotEmpty).toList();

  /// 手动配置：识别所有未被注释的 name = "..."（frpc 日志中的 visitor 名）
  List<String> get manualNames {
    if (manualToml == null) return const [];
    final result = <String>[];
    for (final line in manualToml!.split('\n')) {
      if (line.trimLeft().startsWith('#')) continue;
      final m = RegExp(r'''^\s*name\s*=\s*"([^"]+)"''').firstMatch(line);
      if (m != null && m.group(1)!.isNotEmpty) {
        final n = m.group(1)!;
        if (!result.contains(n)) result.add(n);
      }
    }
    return result;
  }

  /// 手动配置：识别所有未被注释的 type = "..."（按出现顺序、去重）
  List<String> get manualTypes {
    if (manualToml == null) return const [];
    final result = <String>[];
    for (final line in manualToml!.split('\n')) {
      if (line.trimLeft().startsWith('#')) continue;
      final m = RegExp(r'''^\s*type\s*=\s*"([^"]+)"''').firstMatch(line);
      if (m != null && m.group(1)!.isNotEmpty) {
        final t = m.group(1)!.toLowerCase();
        if (!result.contains(t)) result.add(t);
      }
    }
    return result;
  }

  static const _unset = Object();

  FrpConfig copyWith({
    int? id,
    String? name,
    String? serverAddr,
    int? serverPort,
    Object? token = _unset,
    String? localIp,
    int? localPort,
    int? remotePort,
    List<PortMapping>? portMappings,
    String? protocol,
    List<String>? customDomains,
    String? role,
    Object? secretKey = _unset,
    Object? serverName = _unset,
    int? bindPort,
    String? bindAddr,
    bool? useEncryption,
    bool? useCompression,
    bool? useFallback,
    String? fallbackTo,
    int? fallbackTimeoutMs,
    bool? useCustomStcp,
    String? stcpName,
    String? stcpSecretKey,
    String? stcpServerName,
    int? stcpBindPort,
    String? stcpBindAddr,
    int? groupId,
    String? groupName,
    bool? isGroupPrimary,
    int? linkedConfigId,
    bool? enabled,
    String? serverId,
    bool? running,
    Object? manualToml = _unset,
    int? createdAt,
    int? updatedAt,
  }) {
    return FrpConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      serverAddr: serverAddr ?? this.serverAddr,
      serverPort: serverPort ?? this.serverPort,
      token: identical(token, _unset) ? this.token : token as String?,
      localIp: localIp ?? this.localIp,
      localPort: localPort ?? this.localPort,
      remotePort: remotePort ?? this.remotePort,
      portMappings: portMappings ?? this.portMappings,
      protocol: protocol ?? this.protocol,
      customDomains: customDomains ?? this.customDomains,
      role: role ?? this.role,
      secretKey: identical(secretKey, _unset)
          ? this.secretKey
          : secretKey as String?,
      serverName: identical(serverName, _unset)
          ? this.serverName
          : serverName as String?,
      bindPort: bindPort ?? this.bindPort,
      bindAddr: bindAddr ?? this.bindAddr,
      useEncryption: useEncryption ?? this.useEncryption,
      useCompression: useCompression ?? this.useCompression,
      useFallback: useFallback ?? this.useFallback,
      fallbackTo: fallbackTo ?? this.fallbackTo,
      fallbackTimeoutMs: fallbackTimeoutMs ?? this.fallbackTimeoutMs,
      useCustomStcp: useCustomStcp ?? this.useCustomStcp,
      stcpName: stcpName ?? this.stcpName,
      stcpSecretKey: stcpSecretKey ?? this.stcpSecretKey,
      stcpServerName: stcpServerName ?? this.stcpServerName,
      stcpBindPort: stcpBindPort ?? this.stcpBindPort,
      stcpBindAddr: stcpBindAddr ?? this.stcpBindAddr,
      groupId: groupId ?? this.groupId,
      groupName: groupName ?? this.groupName,
      isGroupPrimary: isGroupPrimary ?? this.isGroupPrimary,
      linkedConfigId: linkedConfigId ?? this.linkedConfigId,
      enabled: enabled ?? this.enabled,
      serverId: serverId ?? this.serverId,
      running: running ?? this.running,
      manualToml: identical(manualToml, _unset)
          ? this.manualToml
          : manualToml as String?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'serverAddr': serverAddr,
    'serverPort': serverPort,
    'token': token,
    'localIp': localIp,
    'localPort': localPort,
    'remotePort': remotePort,
    'portMappings': portMappings.map((mapping) => mapping.toJson()).toList(),
    'protocol': protocol,
    'customDomains': customDomains,
    'role': role,
    'secretKey': secretKey,
    'serverName': serverName,
    'bindPort': bindPort,
    'bindAddr': bindAddr,
    'useEncryption': useEncryption,
    'useCompression': useCompression,
    'useFallback': useFallback,
    'fallbackTo': fallbackTo,
    'fallbackTimeoutMs': fallbackTimeoutMs,
    'useCustomStcp': useCustomStcp,
    'stcpName': stcpName,
    'stcpSecretKey': stcpSecretKey,
    'stcpServerName': stcpServerName,
    'stcpBindPort': stcpBindPort,
    'stcpBindAddr': stcpBindAddr,
    'groupId': groupId,
    'groupName': groupName,
    'isGroupPrimary': isGroupPrimary,
    'linkedConfigId': linkedConfigId,
    'enabled': enabled,
    'serverId': serverId,
    'running': running,
    'manualToml': manualToml,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  factory FrpConfig.fromJson(Map<String, dynamic> j) => FrpConfig(
    id: _jsonInt(j, 'id', 0),
    name: _jsonString(j, 'name', ''),
    serverAddr: _jsonString(j, 'serverAddr', ''),
    serverPort: _jsonInt(j, 'serverPort', 7000),
    token: _jsonNullableString(j, 'token'),
    localIp: _jsonString(j, 'localIp', '127.0.0.1'),
    localPort: _jsonInt(j, 'localPort', 0),
    remotePort: _jsonInt(j, 'remotePort', 0),
    portMappings: _portMappingsFromJson(j['portMappings']),
    protocol: _jsonString(j, 'protocol', 'tcp').toLowerCase(),
    customDomains: _jsonStringList(
      j,
      'customDomains',
      maxItems: maxCustomDomains,
    ),
    role: _jsonString(j, 'role', 'visitor').toLowerCase(),
    secretKey: _jsonNullableString(j, 'secretKey'),
    serverName: _jsonNullableString(j, 'serverName'),
    bindPort: _jsonInt(j, 'bindPort', 0),
    bindAddr: _jsonString(j, 'bindAddr', '127.0.0.1'),
    useEncryption: _jsonBool(j, 'useEncryption', false),
    useCompression: _jsonBool(j, 'useCompression', false),
    useFallback: _jsonBool(j, 'useFallback', false),
    fallbackTo: _jsonString(j, 'fallbackTo', ''),
    fallbackTimeoutMs: _jsonInt(j, 'fallbackTimeoutMs', 3000),
    useCustomStcp: _jsonBool(j, 'useCustomStcp', false),
    stcpName: _jsonString(j, 'stcpName', ''),
    stcpSecretKey: _jsonString(j, 'stcpSecretKey', ''),
    stcpServerName: _jsonString(j, 'stcpServerName', ''),
    stcpBindPort: _jsonInt(j, 'stcpBindPort', -1),
    stcpBindAddr: _jsonString(j, 'stcpBindAddr', '127.0.0.1'),
    groupId: _jsonInt(j, 'groupId', 0),
    groupName: _jsonString(j, 'groupName', ''),
    isGroupPrimary: _jsonBool(j, 'isGroupPrimary', false),
    linkedConfigId: _jsonInt(j, 'linkedConfigId', 0),
    enabled: _jsonBool(j, 'enabled', true),
    serverId: _jsonString(j, 'serverId', ''),
    running: _jsonBool(j, 'running', false),
    manualToml: _jsonNullableString(j, 'manualToml'),
    createdAt: _jsonInt(j, 'createdAt', 0),
    updatedAt: _jsonInt(j, 'updatedAt', 0),
  );

  static List<PortMapping> _portMappingsFromJson(Object? value) {
    if (value == null) return const [];
    if (value is! List<dynamic>) {
      throw const FormatException('portMappings must be a list of objects');
    }
    if (value.length > maxPortMappings) {
      throw const FormatException('too many portMappings');
    }
    if (value.any((mapping) => mapping is! Map)) {
      throw const FormatException('portMappings must be a list of objects');
    }
    return value
        .cast<Map>()
        .map((mapping) => PortMapping.fromJson(mapping.cast<String, dynamic>()))
        .toList(growable: false);
  }
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

String? _jsonNullableString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('$key must be a string or null');
}

bool _jsonBool(Map<String, dynamic> json, String key, bool fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}

List<String> _jsonStringList(
  Map<String, dynamic> json,
  String key, {
  required int maxItems,
}) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List<dynamic>) {
    throw FormatException('$key must be a list of strings');
  }
  if (value.length > maxItems) {
    throw FormatException('too many $key entries');
  }
  if (value.any((element) => element is! String)) {
    throw FormatException('$key must be a list of strings');
  }
  return value.cast<String>().toList(growable: false);
}
