import 'dart:convert';
import 'dart:io';
import 'dart:math';

enum Socks5ConnectionMode { immediate, onDemand }

/// One independently enabled set of local forwards through the parent visitor.
class Socks5Connection {
  final String id;
  final String name;
  final bool enabled;
  final Socks5ConnectionMode mode;

  /// Empty means inherit the containing [Socks5Config.targetIp].
  final String targetIp;
  final List<int> tcpPorts;
  final List<int> udpPorts;

  Socks5Connection({
    required this.id,
    required this.name,
    this.enabled = true,
    this.mode = Socks5ConnectionMode.onDemand,
    this.targetIp = '',
    List<int> tcpPorts = const [],
    List<int> udpPorts = const [],
  }) : tcpPorts = List<int>.unmodifiable(tcpPorts),
       udpPorts = List<int>.unmodifiable(udpPorts);

  String effectiveTargetIp(String parentTargetIp) =>
      targetIp.isEmpty ? parentTargetIp : targetIp;

  static String generateId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  String? validationError() {
    if (id.isEmpty ||
        id.trim() != id ||
        id.length > 128 ||
        _hasControlCharacters(id)) {
      return 'SOCKS5 connection ID must contain at most 128 valid characters';
    }
    if (name.trim().isEmpty ||
        name.length > 128 ||
        _hasControlCharacters(name)) {
      return 'Connection name must contain 1 to 128 valid characters';
    }
    if (targetIp.isNotEmpty &&
        (targetIp.trim() != targetIp ||
            targetIp.contains('%') ||
            InternetAddress.tryParse(targetIp) == null)) {
      return 'Connection target IP must be a valid IPv4 or IPv6 address';
    }
    if (tcpPorts.isEmpty && udpPorts.isEmpty) {
      return 'Add at least one TCP or UDP port';
    }
    if (tcpPorts.length + udpPorts.length > Socks5Config.maxPorts) {
      return 'At most 128 SOCKS5 ports are allowed';
    }
    for (final ports in [tcpPorts, udpPorts]) {
      if (ports.any((port) => port < 1 || port > 65535)) {
        return 'SOCKS5 ports must be between 1 and 65535';
      }
      if (ports.toSet().length != ports.length) {
        return 'SOCKS5 ports must not contain duplicates';
      }
    }
    return null;
  }

  Socks5Connection copyWith({
    String? id,
    String? name,
    bool? enabled,
    Socks5ConnectionMode? mode,
    String? targetIp,
    List<int>? tcpPorts,
    List<int>? udpPorts,
  }) => Socks5Connection(
    id: id ?? this.id,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    targetIp: targetIp ?? this.targetIp,
    tcpPorts: tcpPorts ?? this.tcpPorts,
    udpPorts: udpPorts ?? this.udpPorts,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'mode': mode.name,
    'targetIp': targetIp,
    'tcpPorts': tcpPorts,
    'udpPorts': udpPorts,
  };

  factory Socks5Connection.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    if (enabled != null && enabled is! bool) {
      throw const FormatException(
        'socks5 connection enabled must be true or false',
      );
    }
    final mode = switch (json['mode']) {
      'immediate' => Socks5ConnectionMode.immediate,
      'onDemand' => Socks5ConnectionMode.onDemand,
      null when !json.containsKey('mode') => Socks5ConnectionMode.onDemand,
      _ => throw const FormatException(
        'socks5 connection mode must be immediate or onDemand',
      ),
    };
    return Socks5Connection(
      id: _readText(json, 'id', required: true),
      name: _readText(json, 'name', required: true),
      enabled: enabled as bool? ?? true,
      mode: mode,
      targetIp: _readText(json, 'targetIp'),
      tcpPorts: _readPorts(json, 'tcpPorts'),
      udpPorts: _readPorts(json, 'udpPorts'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Socks5Connection &&
      id == other.id &&
      name == other.name &&
      enabled == other.enabled &&
      mode == other.mode &&
      targetIp == other.targetIp &&
      _sameItems(tcpPorts, other.tcpPorts) &&
      _sameItems(udpPorts, other.udpPorts);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    enabled,
    mode,
    targetIp,
    Object.hashAll(tcpPorts),
    Object.hashAll(udpPorts),
  );
}

/// Local fixed-port forwards through a visitor's remote SOCKS5 service.
///
/// The target is inherited unless a named connection overrides it. Credentials
/// are shared and authenticate to the remote SOCKS service; they must not be
/// emitted into frpc TOML.
class Socks5Config {
  final String targetIp;
  final String username;
  final String password;
  final List<Socks5Connection>? _connections;
  final List<int> _legacyTcpPorts;
  final List<int> _legacyUdpPorts;

  /// Legacy port arguments remain available for existing configurations. New
  /// callers use [connections]; older settings normalize to one Default row.
  const Socks5Config({
    required this.targetIp,
    this.username = '',
    this.password = '',
    List<int> tcpPorts = const [],
    List<int> udpPorts = const [],
    this._connections,
  }) : _legacyTcpPorts = tcpPorts,
       _legacyUdpPorts = udpPorts;

  static const maxPorts = 128;
  static const maxConnections = 128;

  List<Socks5Connection> get connections {
    if (_connections case final entries?) {
      return List<Socks5Connection>.unmodifiable(entries);
    }
    if (_legacyTcpPorts.isEmpty && _legacyUdpPorts.isEmpty) return const [];
    return List<Socks5Connection>.unmodifiable([
      Socks5Connection(
        id: 'default',
        name: 'Default',
        tcpPorts: _legacyTcpPorts,
        udpPorts: _legacyUdpPorts,
      ),
    ]);
  }

  /// Only enabled rows contribute business listeners to the runtime plan.
  List<int> get tcpPorts => _ports(tcp: true, enabledOnly: true);
  List<int> get udpPorts => _ports(tcp: false, enabledOnly: true);
  List<int> get allTcpPorts => _ports(tcp: true, enabledOnly: false);
  List<int> get allUdpPorts => _ports(tcp: false, enabledOnly: false);

  List<int> _ports({required bool tcp, required bool enabledOnly}) =>
      List<int>.unmodifiable([
        for (final connection in connections)
          if (!enabledOnly || connection.enabled)
            ...(tcp ? connection.tcpPorts : connection.udpPorts),
      ]);

  bool get requiresAuthentication => username.isNotEmpty || password.isNotEmpty;

  /// Empty input disables this transport. Whitespace is allowed around comma
  /// separators; duplicate ports are kept only once, in the user's order.
  static List<int> parsePorts(String text) {
    if (text.trim().isEmpty) return const [];
    final fields = text.split(',');
    if (fields.length > maxPorts) {
      throw const FormatException('At most 128 ports are allowed');
    }
    final result = <int>{};
    for (final field in fields) {
      final value = field.trim();
      final port = int.tryParse(value);
      if (!RegExp(r'^\d+$').hasMatch(value) ||
          port == null ||
          port < 1 ||
          port > 65535) {
        throw const FormatException(
          'Use ports from 1 to 65535, separated by commas',
        );
      }
      result.add(port);
    }
    return result.toList(growable: false);
  }

  String? validationError() {
    final entries = connections;
    if ((targetIp.isNotEmpty || entries.isNotEmpty) &&
        (targetIp.trim() != targetIp ||
            targetIp.contains('%') ||
            InternetAddress.tryParse(targetIp) == null)) {
      return 'Target IP must be a valid IPv4 or IPv6 address';
    }
    if (utf8.encode(username).length > 255 ||
        utf8.encode(password).length > 255) {
      return 'SOCKS5 username and password must each fit in 255 UTF-8 bytes';
    }
    if (entries.length > maxConnections) {
      return 'At most 128 SOCKS5 connections are allowed';
    }
    final ids = <String>{};
    final enabledTcp = <int>{};
    final enabledUdp = <int>{};
    var totalPorts = 0;
    for (final connection in entries) {
      final error = connection.validationError();
      if (error != null) return error;
      if (!ids.add(connection.id)) {
        return 'SOCKS5 connection IDs must be unique';
      }
      totalPorts += connection.tcpPorts.length + connection.udpPorts.length;
      if (totalPorts > maxPorts) {
        return 'At most 128 SOCKS5 ports are allowed';
      }
      if (!connection.enabled) continue;
      for (final port in connection.tcpPorts) {
        if (!enabledTcp.add(port)) {
          return 'Enabled SOCKS5 connections cannot share TCP port $port';
        }
      }
      for (final port in connection.udpPorts) {
        if (!enabledUdp.add(port)) {
          return 'Enabled SOCKS5 connections cannot share UDP port $port';
        }
      }
    }
    return null;
  }

  /// Remove transports no longer present in the parent visitor group while
  /// preserving surviving row IDs, labels, enabled states and shared settings.
  Socks5Config retainProtocols({required bool tcp, required bool udp}) =>
      copyWith(
        connections: [
          for (final connection in connections)
            if ((tcp && connection.tcpPorts.isNotEmpty) ||
                (udp && connection.udpPorts.isNotEmpty))
              connection.copyWith(
                tcpPorts: tcp ? connection.tcpPorts : const [],
                udpPorts: udp ? connection.udpPorts : const [],
              ),
        ],
      );

  /// Explicit legacy port arguments replace the flat set with one Default row.
  /// Use [connections] or [retainProtocols] when editing named rows.
  Socks5Config copyWith({
    String? targetIp,
    String? username,
    String? password,
    List<int>? tcpPorts,
    List<int>? udpPorts,
    List<Socks5Connection>? connections,
  }) => Socks5Config(
    targetIp: targetIp ?? this.targetIp,
    username: username ?? this.username,
    password: password ?? this.password,
    tcpPorts: List<int>.unmodifiable(tcpPorts ?? this.tcpPorts),
    udpPorts: List<int>.unmodifiable(udpPorts ?? this.udpPorts),
    connections: connections != null
        ? List<Socks5Connection>.unmodifiable(connections)
        : (tcpPorts != null || udpPorts != null)
        ? null
        : this.connections,
  );

  Map<String, dynamic> toJson() => {
    'targetIp': targetIp,
    'username': username,
    'password': password,
    'connections': [for (final connection in connections) connection.toJson()],
  };

  factory Socks5Config.fromJson(Map<String, dynamic> json) {
    // Validate legacy fields even when a newer connections list is present.
    final tcpPorts = _readPorts(json, 'tcpPorts');
    final udpPorts = _readPorts(json, 'udpPorts');
    List<Socks5Connection>? connections;
    if (json.containsKey('connections')) {
      final value = json['connections'];
      if (value is! List || value.length > maxConnections) {
        throw const FormatException(
          'socks5.connections must be a list of at most 128 connections',
        );
      }
      connections = List<Socks5Connection>.unmodifiable([
        for (final item in value)
          if (item is Map<String, dynamic>)
            Socks5Connection.fromJson(item)
          else
            throw const FormatException('SOCKS5 connection must be an object'),
      ]);
    }
    return Socks5Config(
      targetIp: _readText(json, 'targetIp'),
      username: _readText(json, 'username'),
      password: _readText(json, 'password'),
      tcpPorts: tcpPorts,
      udpPorts: udpPorts,
      connections: connections,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Socks5Config &&
      targetIp == other.targetIp &&
      username == other.username &&
      password == other.password &&
      _sameItems(connections, other.connections);

  @override
  int get hashCode =>
      Object.hash(targetIp, username, password, Object.hashAll(connections));
}

bool _hasControlCharacters(String value) =>
    RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value);

String _readText(
  Map<String, dynamic> json,
  String key, {
  bool required = false,
}) {
  final value = json[key];
  if (value == null && !required) return '';
  if (value is! String) throw FormatException('socks5.$key must be text');
  if (value.length > 1024) throw FormatException('socks5.$key is too long');
  return value;
}

List<int> _readPorts(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List ||
      value.length > Socks5Config.maxPorts ||
      value.any((port) => port is! int)) {
    throw FormatException('socks5.$key must be a list of at most 128 ports');
  }
  return List<int>.unmodifiable(value.cast<int>());
}

bool _sameItems<T>(List<T> first, List<T> second) {
  if (first.length != second.length) return false;
  for (var i = 0; i < first.length; i++) {
    if (first[i] != second[i]) return false;
  }
  return true;
}
