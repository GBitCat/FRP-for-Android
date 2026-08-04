/// 连接类型：与原有 ConnectionType 对应
enum ConnectionType { p2p, relay, error, connected, connecting, unknown }

class ConnectionStatus {
  final ConnectionType type;
  final String message;
  const ConnectionStatus([this.type = ConnectionType.unknown, this.message = '']);

  String get label => switch (type) {
        ConnectionType.p2p => 'XTCP',
        ConnectionType.relay => 'STCP',
        ConnectionType.error => 'Error',
        ConnectionType.connected => 'Connected',
        ConnectionType.connecting => 'Connecting...',
        ConnectionType.unknown => '未连接',
      };
}
