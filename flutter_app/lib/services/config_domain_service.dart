import '../models/connection_status.dart';
import '../models/frp_config.dart';

class AppRow {
  final String name;
  final String label;
  final ConnectionType status;

  const AppRow(this.name, this.label, this.status);
}

class ConfigGroup {
  final int groupId;
  final String groupName;
  final FrpConfig primary;
  final List<FrpConfig> members;
  final bool enabled;

  const ConfigGroup({
    required this.groupId,
    required this.groupName,
    required this.primary,
    required this.members,
    required this.enabled,
  });

  bool get isGroup => groupId > 0;
}

/// Pure configuration-domain operations shared by state and editor layers.
class ConfigDomainService {
  const ConfigDomainService._();

  static String displayName(FrpConfig config) {
    final groupName = config.groupName.trim();
    return groupName.isEmpty ? config.name : groupName;
  }

  static String effectiveName(
    String value, {
    required String protocol,
    required bool useNamingRule,
  }) {
    final name = value.trim();
    if (protocol == 'xtcp' && useNamingRule && name.isNotEmpty) {
      return name.endsWith('-xtcp') ? name : '$name-xtcp';
    }
    return name;
  }

  static String? fallbackProtocolFor(String protocol) {
    return switch (protocol.toLowerCase()) {
      'xtcp' => 'stcp',
      'xudp' => 'sudp',
      _ => null,
    };
  }

  static String fallbackNameFor(String name, {required String protocol}) {
    final primaryProtocol = protocol.toLowerCase();
    final fallbackProtocol = fallbackProtocolFor(primaryProtocol) ?? 'stcp';
    final generatedSuffix = RegExp(
      '-${RegExp.escape(primaryProtocol)}(-\\d+)?\$',
      caseSensitive: false,
    ).firstMatch(name);
    if (generatedSuffix == null) return '$name-$fallbackProtocol';

    final base = name.substring(0, generatedSuffix.start);
    final portSuffix = generatedSuffix.group(1) ?? '';
    return '$base-$fallbackProtocol$portSuffix';
  }

  static String fallbackServerNameFor(
    String serverName, {
    required String protocol,
    required String fallbackProtocol,
  }) {
    if (serverName.isEmpty) return '';
    final generatedSuffix = RegExp(
      '-${RegExp.escape(protocol)}(-\\d+)?\$',
      caseSensitive: false,
    ).firstMatch(serverName);
    if (generatedSuffix == null) return '$serverName-$fallbackProtocol';

    final base = serverName.substring(0, generatedSuffix.start);
    final portSuffix = generatedSuffix.group(1) ?? '';
    return '$base-$fallbackProtocol$portSuffix';
  }

  static int defaultFallbackBindPortFor(FrpConfig primary) {
    if (fallbackProtocolFor(primary.protocol) != 'sudp') return -1;
    if (primary.bindPort > 0 && primary.bindPort < 65535) {
      return primary.bindPort + 1;
    }
    if (primary.bindPort == 65535) return 65534;
    return 9003;
  }

  static FrpConfig createLinkedFallbackConfig(FrpConfig primary) {
    final fallbackProtocol = fallbackProtocolFor(primary.protocol);
    if (fallbackProtocol == null) {
      throw ArgumentError.value(
        primary.protocol,
        'primary.protocol',
        'Only XTCP and XUDP support linked fallback visitors',
      );
    }
    final fallbackName = primary.stcpName.isNotEmpty
        ? primary.stcpName
        : fallbackNameFor(primary.name, protocol: primary.protocol);
    return FrpConfig(
      name: fallbackName,
      localIp: primary.localIp,
      localPort: primary.localPort,
      protocol: fallbackProtocol,
      role: 'visitor',
      secretKey: primary.stcpSecretKey.isNotEmpty
          ? primary.stcpSecretKey
          : primary.secretKey,
      serverName: primary.stcpServerName.isNotEmpty
          ? primary.stcpServerName
          : fallbackServerNameFor(
              primary.serverName ?? '',
              protocol: primary.protocol,
              fallbackProtocol: fallbackProtocol,
            ),
      bindPort: primary.useCustomStcp
          ? primary.stcpBindPort
          : defaultFallbackBindPortFor(primary),
      bindAddr: primary.useCustomStcp
          ? primary.stcpBindAddr
          : (fallbackProtocol == 'sudp' ? primary.bindAddr : ''),
      useEncryption: primary.useEncryption,
      useCompression: primary.useCompression,
      enabled: primary.enabled,
      serverId: primary.serverId,
    );
  }

  static FrpConfig createLinkedStcpConfig(FrpConfig xtcp) =>
      createLinkedFallbackConfig(xtcp);

  static ConnectionType aggregateStatuses(Iterable<ConnectionType> statuses) {
    if (statuses.contains(ConnectionType.error)) return ConnectionType.error;
    if (statuses.contains(ConnectionType.p2p)) return ConnectionType.p2p;
    if (statuses.contains(ConnectionType.relay)) return ConnectionType.relay;
    if (statuses.contains(ConnectionType.connected)) {
      return ConnectionType.connected;
    }
    if (statuses.contains(ConnectionType.connecting)) {
      return ConnectionType.connecting;
    }
    return ConnectionType.unknown;
  }

  /// Returns the first emitted proxy-name collision introduced by a
  /// multi-port configuration. Existing single-port duplicate behavior is
  /// left unchanged for backwards compatibility.
  static String? findMultiPortNameCollision(
    FrpConfig candidate,
    Iterable<FrpConfig> configs,
  ) {
    final candidateNames = candidate.configuredNames.toSet();
    for (final existing in configs) {
      if ((!candidate.isMultiPort && !existing.isMultiPort) ||
          existing.id == candidate.id ||
          (existing.serverId.isNotEmpty &&
              existing.serverId != candidate.serverId)) {
        continue;
      }
      final collisions = candidateNames.intersection(
        existing.configuredNames.toSet(),
      );
      if (collisions.isNotEmpty) return collisions.first;
    }
    return null;
  }

  static List<AppRow> buildAppRows(
    List<FrpConfig> configs,
    Map<String, ConnectionType> appStatuses,
  ) {
    final rows = <AppRow>[];
    final grouped = configs.where((e) => e.isInGroup()).toList();
    for (final groupId in grouped.map((e) => e.groupId).toSet()) {
      final members = grouped.where((e) => e.groupId == groupId).toList();
      final primary = members.firstWhere(
        (e) => e.isGroupPrimary,
        orElse: () => members.first,
      );
      final status = aggregateStatuses(
        members
            .expand((config) => config.runtimeNames)
            .map((name) => appStatuses[name])
            .whereType<ConnectionType>(),
      );
      rows.add(
        AppRow(displayName(primary), ConnectionStatus(status).label, status),
      );
    }
    for (final config in configs.where((e) => !e.isInGroup())) {
      final status = aggregateStatuses(
        config.runtimeNames
            .map((name) => appStatuses[name])
            .whereType<ConnectionType>(),
      );
      rows.add(
        AppRow(displayName(config), ConnectionStatus(status).label, status),
      );
    }
    return rows;
  }

  static List<ConfigGroup> buildGroups(List<FrpConfig> configs) {
    final result = <ConfigGroup>[];
    final grouped = configs.where((e) => e.isInGroup()).toList();
    final ids = grouped.map((e) => e.groupId).toSet().toList()..sort();
    for (final id in ids) {
      final members = grouped.where((e) => e.groupId == id).toList();
      final primary = members.firstWhere(
        (e) => e.isGroupPrimary,
        orElse: () => members.first,
      );
      result.add(
        ConfigGroup(
          groupId: id,
          groupName: displayName(primary),
          primary: primary,
          members: members,
          enabled: members.every((e) => e.enabled),
        ),
      );
    }
    result.addAll(
      configs
          .where((e) => !e.isInGroup())
          .map(
            (config) => ConfigGroup(
              groupId: 0,
              groupName: displayName(config),
              primary: config,
              members: const [],
              enabled: config.enabled,
            ),
          ),
    );
    return result;
  }
}
