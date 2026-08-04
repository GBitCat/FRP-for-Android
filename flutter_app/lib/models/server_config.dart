import 'dart:math';

class ServerConfig {
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
  });

  bool isValid() => serverAddr.trim().isNotEmpty && serverPort >= 1 && serverPort <= 65535;

  static String generateId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
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
      };

  factory ServerConfig.fromJson(Map<String, dynamic> j) => ServerConfig(
        id: (j['id'] as num?)?.toInt() ?? 1,
        name: j['name'] as String? ?? 'FRPS Server',
        serverId: j['serverId'] as String? ?? '',
        serverAddr: j['serverAddr'] as String? ?? '',
        serverPort: (j['serverPort'] as num?)?.toInt() ?? 7000,
        token: j['token'] as String? ?? '',
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
        protocol: j['protocol'] as String? ?? 'tcp',
        tcpMux: j['tcpMux'] as bool? ?? true,
        heartbeatInterval: (j['heartbeatInterval'] as num?)?.toInt() ?? 30,
        heartbeatTimeout: (j['heartbeatTimeout'] as num?)?.toInt() ?? 90,
        tcpMuxKeepaliveInterval:
            (j['tcpMuxKeepaliveInterval'] as num?)?.toInt() ?? 30,
      );
}
