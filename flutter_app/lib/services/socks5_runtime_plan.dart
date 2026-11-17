import 'dart:convert';
import 'dart:io';

import '../models/frp_config.dart';
import '../models/socks5_config.dart';
import 'socks5_log_entry.dart';

/// The local SOCKS protocol endpoint owned by frpc, distinct from the public
/// fixed business ports owned by Android's foreground service.
class Socks5VisitorEndpoint {
  final String host;
  final int port;
  final bool datagram;

  const Socks5VisitorEndpoint({
    this.host = '127.0.0.1',
    required this.port,
    required this.datagram,
  });
}

/// One deterministic plan drives both frpc TOML and the native port forwarder.
/// No sockets are opened while generating previews or validating a save.
class Socks5RuntimePlan {
  final List<Map<String, dynamic>> forwards;
  final Map<String, Socks5VisitorEndpoint> _endpoints;
  final Set<String> _suppressedConfigs;

  const Socks5RuntimePlan._(
    this.forwards,
    this._endpoints,
    this._suppressedConfigs,
  );

  static const maxListeners = 256;
  static const maxUpstreamsPerListener = 128;

  // Native starts use an Android Intent, whose strings are parcelled as UTF-16.
  // Leave room beneath Binder's transaction limit for the rest of the Intent.
  static const maxRuntimePayloadBytes = 384 * 1024;

  void requirePayloadFits(String configContent) {
    if (forwards.isEmpty) return;
    final payload = jsonEncode({
      'androidRuntimeVersion': 1,
      'configContent': configContent,
      'socks5Forwards': forwards,
    });
    if (utf8.encode(payload).length > maxRuntimePayloadBytes) {
      throw const FormatException(
        'SOCKS5 configuration is too large. Reduce the number of ports or visitors.',
      );
    }
  }

  Socks5VisitorEndpoint? endpointFor(FrpConfig config) =>
      _endpoints[config.name];

  /// Autonomous XUDP keeps sessions through its own relay path. A legacy
  /// external SUDP fallback has a different provider session store. Retain its
  /// saved settings, but do not start that unused block while SOCKS is active.
  bool emitsConfig(FrpConfig config) =>
      !_suppressedConfigs.contains(_configKey(config, config.name));

  /// Form visitors only; linked fallback blocks belong to their primary and
  /// must not create additional SOCKS listeners or duplicate upstream routes.
  /// Enabled state is intentionally ignored so disabled groups remain editable.
  static List<FrpConfig> supportedVisitors(Iterable<FrpConfig> configs) {
    final all = configs.toList(growable: false);
    final fallbackKeys = <String>{
      for (final config in all)
        if (config.isVisitor() &&
            config.useFallback &&
            config.fallbackTo.isNotEmpty)
          _configKey(config, config.fallbackTo),
    };
    return all
        .where(
          (config) =>
              config.isVisitor() &&
              config.needsSecretKey() &&
              (config.manualToml == null ||
                  config.manualToml!.trim().isEmpty) &&
              !fallbackKeys.contains(_configKey(config, config.name)),
        )
        .toList(growable: false);
  }

  static String _configKey(FrpConfig config, String name) =>
      '${config.serverId}/${config.groupId}/$name';

  factory Socks5RuntimePlan.build(List<FrpConfig> configs) {
    final supported = supportedVisitors(configs);
    final sources = <FrpConfig>[];
    for (final config in configs.where((config) => config.enabled)) {
      final settings = config.socks5;
      if (settings == null) continue;
      final error = settings.validationError();
      if (error != null) throw FormatException(error);
      if (!supported.contains(config)) {
        throw const FormatException(
          'SOCKS5 forwarding requires a supported visitor configuration',
        );
      }
      final udp = _isUdp(config);
      // Aggregated ports include enabled connection rows only. An empty set
      // keeps shared settings saved without enabling a SOCKS visitor plugin.
      if ((udp ? settings.udpPorts : settings.tcpPorts).isNotEmpty) {
        if (udp && (config.secretKey ?? '').isEmpty) {
          throw const FormatException(
            'A secret key is required for autonomous SOCKS5 UDP',
          );
        }
        sources.add(config);
      }
    }
    if (sources.isEmpty) return const Socks5RuntimePlan._([], {}, {});

    final autonomousXudp = sources
        .where((config) => config.protocol == 'xudp')
        .toSet();
    final suppressed = <String>{};
    for (final candidate in configs) {
      if (!candidate.isVisitor() ||
          candidate.protocol != 'sudp' ||
          (candidate.manualToml?.trim().isNotEmpty ?? false)) {
        continue;
      }
      final references = configs
          .where(
            (primary) =>
                primary.enabled &&
                primary.useFallback &&
                primary.fallbackTo == candidate.name &&
                primary.serverId == candidate.serverId &&
                primary.groupId == candidate.groupId,
          )
          .toList();
      if (references.isNotEmpty && references.every(autonomousXudp.contains)) {
        suppressed.add(_configKey(candidate, candidate.name));
      }
    }

    final ordinarySockets = <_SocketBinding>[];
    final reservedTcpPorts = <int>{};
    for (final config in configs.where((config) => config.enabled)) {
      if (sources.contains(config)) continue;
      if (suppressed.contains(_configKey(config, config.name))) continue;
      if (config.manualToml?.trim().isNotEmpty ?? false) {
        // Reserve conventional manual bindPort declarations as well. Exact
        // address/protocol validation of arbitrary TOML remains frpc's job.
        for (final match in RegExp(
          r'^\s*(?:bindPort|plugin\.bindPort)\s*=\s*(\d+)\s*(?:#.*)?$',
          multiLine: true,
        ).allMatches(config.manualToml!)) {
          final port = int.tryParse(match.group(1)!);
          if (port != null && port > 0 && port <= 65535) {
            reservedTcpPorts.add(port);
          }
        }
        continue;
      }
      if (config.isVisitor() &&
          config.needsSecretKey() &&
          config.bindPort > 0) {
        final protocol = _isUdp(config) ? 'udp' : 'tcp';
        ordinarySockets.add(
          _SocketBinding(
            protocol,
            _bindAddress(config.bindAddr),
            config.bindPort,
          ),
        );
        if (protocol == 'tcp') reservedTcpPorts.add(config.bindPort);
      }
    }

    final listeners = <_Listener>[];
    for (final config in sources) {
      final settings = config.socks5!;
      final protocol = _isUdp(config) ? 'udp' : 'tcp';
      final address = _bindAddress(config.bindAddr);
      final ports = _isUdp(config) ? settings.udpPorts : settings.tcpPorts;
      for (final port in ports) {
        final connection = settings.connections.firstWhere(
          (connection) =>
              connection.enabled &&
              (_isUdp(config) ? connection.udpPorts : connection.tcpPorts)
                  .contains(port),
        );
        final mode = connection.mode;
        final targetIp = connection.effectiveTargetIp(settings.targetIp);
        final logContext = Socks5LogContext.fromConfig(config, connection);
        final socket = _SocketBinding(protocol, address, port);
        if (ordinarySockets.any(socket.overlaps)) {
          throw FormatException(
            '${protocol.toUpperCase()} $address:$port is already used by a visitor',
          );
        }
        _Listener? existing;
        for (final listener in listeners) {
          if (!socket.overlaps(listener.socket)) continue;
          if (listener.logContext.configKey != logContext.configKey ||
              listener.socket.address != address ||
              listener.targetIp != targetIp) {
            throw FormatException(
              '${protocol.toUpperCase()} $address:$port conflicts with another SOCKS5 listener',
            );
          }
          if (listener.mode != mode) {
            throw FormatException(
              '${protocol.toUpperCase()} $address:$port has conflicting SOCKS5 connection modes',
            );
          }
          if (listener.logContext.connectionId != logContext.connectionId) {
            throw FormatException(
              '${protocol.toUpperCase()} $address:$port belongs to different SOCKS5 connection entries',
            );
          }
          existing = listener;
          break;
        }
        if (existing == null) {
          if (listeners.length >= maxListeners) {
            throw const FormatException(
              'At most 256 SOCKS5 listeners are allowed',
            );
          }
          existing = _Listener(socket, logContext, targetIp, mode);
          listeners.add(existing);
        }
        if (existing.sources.length >= maxUpstreamsPerListener) {
          throw const FormatException(
            'At most 128 visitors can share a SOCKS5 listener',
          );
        }
        existing.sources.add(config);
        if (protocol == 'tcp') reservedTcpPorts.add(port);
      }
    }

    // Both ordinary TCP SOCKS and the autonomous UDP plugin expose their
    // SOCKS negotiation endpoint over local TCP. Prefer the configured port,
    // then allocate another local-only port if TCP and UDP used the same one.
    final endpoints = <String, Socks5VisitorEndpoint>{};
    var nextInternalPort = 49152;
    for (final config in sources) {
      if (endpoints.containsKey(config.name)) {
        throw const FormatException('SOCKS5 visitor names must be unique');
      }
      var port = config.bindPort;
      if (port <= 0 || port > 65535 || reservedTcpPorts.contains(port)) {
        while (nextInternalPort <= 65535 &&
            reservedTcpPorts.contains(nextInternalPort)) {
          nextInternalPort++;
        }
        if (nextInternalPort > 65535) {
          throw const FormatException('No local port is available for SOCKS5');
        }
        port = nextInternalPort++;
      }
      reservedTcpPorts.add(port);
      endpoints[config.name] = Socks5VisitorEndpoint(
        port: port,
        datagram: _isUdp(config),
      );
    }

    return Socks5RuntimePlan._(
      List<Map<String, dynamic>>.unmodifiable([
        for (final listener in listeners)
          {
            'protocol': listener.socket.protocol,
            'bindAddress': listener.socket.address,
            'listenPort': listener.socket.port,
            'targetIp': listener.targetIp,
            'targetPort': listener.socket.port,
            'mode': listener.mode.name,
            'logContext': listener.logContext.toJson(),
            'upstreams': [
              for (final config in listener.sources)
                {
                  'id': '${config.serverId}:${config.id}:${config.name}',
                  'name': config.name,
                  'host': endpoints[config.name]!.host,
                  'port': endpoints[config.name]!.port,
                  'username': config.socks5!.username,
                  'password': config.socks5!.password,
                },
            ],
          },
      ]),
      Map<String, Socks5VisitorEndpoint>.unmodifiable(endpoints),
      Set<String>.unmodifiable(suppressed),
    );
  }

  static bool _isUdp(FrpConfig config) =>
      config.protocol == 'sudp' || config.protocol == 'xudp';

  static String _bindAddress(String value) {
    if (value.isEmpty || value == 'localhost') return '127.0.0.1';
    final ip = InternetAddress.tryParse(value);
    if (ip == null || value.contains('%')) {
      throw const FormatException(
        'SOCKS5 bind address must be an IPv4 or IPv6 address',
      );
    }
    return ip.address;
  }
}

class _SocketBinding {
  final String protocol;
  final String address;
  final int port;

  const _SocketBinding(this.protocol, this.address, this.port);

  bool overlaps(_SocketBinding other) {
    if (protocol != other.protocol || port != other.port) return false;
    if (address == other.address) return true;
    // Android's wildcard IPv6 sockets can also accept IPv4 connections.
    if (address == '::' || other.address == '::') return true;
    final first = InternetAddress.tryParse(address);
    final second = InternetAddress.tryParse(other.address);
    return first?.type == InternetAddressType.IPv4 &&
        second?.type == InternetAddressType.IPv4 &&
        (address == '0.0.0.0' || other.address == '0.0.0.0');
  }
}

class _Listener {
  final _SocketBinding socket;
  final Socks5LogContext logContext;
  final String targetIp;
  final Socks5ConnectionMode mode;
  final List<FrpConfig> sources = [];

  _Listener(this.socket, this.logContext, this.targetIp, this.mode);
}
