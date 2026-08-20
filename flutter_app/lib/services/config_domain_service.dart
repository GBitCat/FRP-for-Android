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

  static FrpConfig createLinkedStcpConfig(FrpConfig xtcp) {
    final base = xtcp.name.endsWith('-xtcp')
        ? xtcp.name.substring(0, xtcp.name.length - 5)
        : xtcp.name;
    return FrpConfig(
      name: '$base-stcp',
      localIp: xtcp.localIp,
      localPort: xtcp.localPort,
      protocol: 'stcp',
      role: 'visitor',
      secretKey: xtcp.secretKey,
      serverName: xtcp.stcpServerName.isNotEmpty
          ? xtcp.stcpServerName
          : (xtcp.serverName ?? '').replaceAll('xtcp', 'stcp'),
      bindPort: -1,
      bindAddr: '',
      useEncryption: xtcp.useEncryption,
      useCompression: xtcp.useCompression,
      serverId: xtcp.serverId,
    );
  }

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
        members.map((e) => appStatuses[e.name]).whereType<ConnectionType>(),
      );
      rows.add(
        AppRow(
          primary.groupName.isNotEmpty ? primary.groupName : primary.name,
          ConnectionStatus(status).label,
          status,
        ),
      );
    }
    for (final config in configs.where((e) => !e.isInGroup())) {
      final names = <String>{config.name, ...config.manualNames};
      final status = aggregateStatuses(
        names.map((name) => appStatuses[name]).whereType<ConnectionType>(),
      );
      rows.add(AppRow(config.name, ConnectionStatus(status).label, status));
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
          groupName: primary.groupName.isNotEmpty
              ? primary.groupName
              : primary.name,
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
              groupName: config.name,
              primary: config,
              members: const [],
              enabled: config.enabled,
            ),
          ),
    );
    return result;
  }
}
