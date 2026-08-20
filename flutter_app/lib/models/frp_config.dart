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
  final String protocol;

  // STCP/XTCP 特有
  final String role; // visitor / server
  final String? secretKey;
  final String? serverName;
  final int bindPort;
  final String bindAddr;

  // 传输加密/压缩
  final bool useEncryption;
  final bool useCompression;

  // XTCP 回落
  final bool useFallback;
  final String fallbackTo;
  final int fallbackTimeoutMs;
  final bool useCustomStcp;

  // STCP Fallback 自定义配置
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
    this.protocol = 'tcp',
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
  ];
  static const List<String> secretProtocols = ['stcp', 'sudp', 'xtcp'];

  bool needsSecretKey() => secretProtocols.contains(protocol.toLowerCase());
  bool isVisitor() => role == 'visitor';
  bool supportsFallback() => protocol.toLowerCase() == 'xtcp';
  bool isInGroup() => groupId > 0;

  /// 手动配置：识别所有未被注释的 name = "..."（frpc 日志中的 visitor 名）
  List<String> get manualNames {
    if (manualToml == null) return const [];
    final result = <String>[];
    for (final line in manualToml!.split('\n')) {
      if (line.trimLeft().startsWith('#')) continue;
      final m = RegExp(r'''name\s*=\s*"([^"]+)"''').firstMatch(line);
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
      final m = RegExp(r'''type\s*=\s*"([^"]+)"''').firstMatch(line);
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
    String? protocol,
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
      protocol: protocol ?? this.protocol,
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
    'protocol': protocol,
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
    id: (j['id'] as num?)?.toInt() ?? 0,
    name: j['name'] as String? ?? '',
    serverAddr: j['serverAddr'] as String? ?? '',
    serverPort: (j['serverPort'] as num?)?.toInt() ?? 7000,
    token: j['token'] as String?,
    localIp: j['localIp'] as String? ?? '127.0.0.1',
    localPort: (j['localPort'] as num?)?.toInt() ?? 0,
    remotePort: (j['remotePort'] as num?)?.toInt() ?? 0,
    protocol: j['protocol'] as String? ?? 'tcp',
    role: j['role'] as String? ?? 'visitor',
    secretKey: j['secretKey'] as String?,
    serverName: j['serverName'] as String?,
    bindPort: (j['bindPort'] as num?)?.toInt() ?? 0,
    bindAddr: j['bindAddr'] as String? ?? '127.0.0.1',
    useEncryption: j['useEncryption'] as bool? ?? false,
    useCompression: j['useCompression'] as bool? ?? false,
    useFallback: j['useFallback'] as bool? ?? false,
    fallbackTo: j['fallbackTo'] as String? ?? '',
    fallbackTimeoutMs: (j['fallbackTimeoutMs'] as num?)?.toInt() ?? 3000,
    useCustomStcp: j['useCustomStcp'] as bool? ?? false,
    stcpName: j['stcpName'] as String? ?? '',
    stcpSecretKey: j['stcpSecretKey'] as String? ?? '',
    stcpServerName: j['stcpServerName'] as String? ?? '',
    stcpBindPort: (j['stcpBindPort'] as num?)?.toInt() ?? -1,
    stcpBindAddr: j['stcpBindAddr'] as String? ?? '127.0.0.1',
    groupId: (j['groupId'] as num?)?.toInt() ?? 0,
    groupName: j['groupName'] as String? ?? '',
    isGroupPrimary: j['isGroupPrimary'] as bool? ?? false,
    linkedConfigId: (j['linkedConfigId'] as num?)?.toInt() ?? 0,
    enabled: j['enabled'] as bool? ?? true,
    serverId: j['serverId'] as String? ?? '',
    running: j['running'] as bool? ?? false,
    manualToml: j['manualToml'] as String?,
    createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
    updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
  );
}
