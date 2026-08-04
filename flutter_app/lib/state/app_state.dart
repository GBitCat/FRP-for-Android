import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:path_provider/path_provider.dart';

import '../models/connection_status.dart';
import '../models/frp_config.dart';
import '../models/server_config.dart';
import '../services/config_import_export.dart';
import '../services/config_store.dart';
import '../services/frp_engine.dart';
import '../services/toml_generator.dart' as toml;

/// 主题设置
class ThemeSettings {
  final ThemeMode mode; // system / light / dark
  final int accentIndex;
  const ThemeSettings({this.mode = ThemeMode.system, this.accentIndex = 0});
  ThemeSettings copyWith({ThemeMode? mode, int? accentIndex}) =>
      ThemeSettings(mode: mode ?? this.mode, accentIndex: accentIndex ?? this.accentIndex);
}

class AppState extends ChangeNotifier {
  void notify() => notifyListeners();

  final ConfigStore _store = ConfigStore();
  final FrpEngine engine = FrpEngine.instance;

  List<FrpConfig> configs = [];
  List<ServerConfig> servers = [];
  String _selectedServerId = '';
  bool trafficEnabled = false;
  ThemeSettings theme = const ThemeSettings();

  // 运行状态
  bool running = false;
  ConnectionStatus serverStatus = const ConnectionStatus();
  Map<String, ConnectionType> appStatuses = {};
  double memoryMb = 0;
  String ipv4 = '';
  String ipv6 = '';
  double uploadSpeed = 0;
  double downloadSpeed = 0;
  double totalBytes = 0;

  AppState() {
    engine.statusStream.listen((s) {
      serverStatus = s;
      // connecting/connected → 运行中；unknown(断开) → 停止
      if (s.type == ConnectionType.connecting ||
          s.type == ConnectionType.connected) {
        running = true;
      } else if (s.type == ConnectionType.unknown) {
        running = false;
      }
      notifyListeners();
    });
    engine.appStatusesStream.listen((m) {
      appStatuses = m;
      notifyListeners();
    });
    _load();
    _startPolling();
  }

  Future<void> _load() async {
    configs = await _store.loadConfigs();
    servers = await _store.loadServers();
    if (servers.isEmpty) {
      // 迁移旧单 server 数据
      final old = await _store.loadServer();
      servers = [old ?? const ServerConfig(serverId: '')];
      await _store.saveServers(servers);
    }
    _selectedServerId = servers.first.serverId;
    notifyListeners();
  }

  void _startPolling() {
    Timer.periodic(const Duration(seconds: 2), (_) async {
      memoryMb = await engine.getMemoryMb();
      ipv4 = await engine.getIpv4();
      ipv6 = await engine.getIpv6();
      if (running) {
        // 流量统计暂为演示值；后续接入 /proc/net 真实统计
        uploadSpeed = 0.8 * (uploadSpeed + 1.2) % 900;
        downloadSpeed = 1.6 * (downloadSpeed + 3.1) % 2400;
        totalBytes += uploadSpeed + downloadSpeed;
      }
      notifyListeners();
    });
  }

  Future<void> start() async {
    running = true;
    serverStatus = const ConnectionStatus(
        ConnectionType.unknown, 'Starting...');
    notifyListeners();
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/frpc_all.toml')
        ..writeAsStringSync(buildFullToml());
      final ok = await engine.start(file.path);
      if (!ok) {
        running = false;
        serverStatus = const ConnectionStatus(
            ConnectionType.error, 'Failed to start frpc');
        notifyListeners();
      }
    } catch (_) {
      running = false;
      serverStatus = const ConnectionStatus(
          ConnectionType.error, 'Failed to start frpc');
      notifyListeners();
    }
  }

  Future<void> stop() async {
    running = false;
    appStatuses = {};
    await engine.stop();
    serverStatus = const ConnectionStatus();
    notifyListeners();
  }

  ServerConfig get selectedServer {
    if (servers.isEmpty) return const ServerConfig(serverId: '');
    return servers.firstWhere(
      (e) => e.serverId == _selectedServerId,
      orElse: () => servers.first,
    );
  }

  ServerConfig get effectiveServer => selectedServer;

  ServerConfig? get server => servers.isEmpty ? null : selectedServer;

  bool isServerSelected(String id) => id == _selectedServerId;

  Future<void> selectServer(String id) async {
    if (servers.any((e) => e.serverId == id)) {
      _selectedServerId = id;
      notifyListeners();
    }
  }

  Future<void> deleteServer(String id) async {
    servers.removeWhere((e) => e.serverId == id);
    if (_selectedServerId == id) {
      _selectedServerId = servers.isNotEmpty ? servers.first.serverId : '';
    }
    await _store.saveServers(servers);
    notifyListeners();
  }

  /// 完整 frpc TOML（导出用）：全局段 + 已启用的应用配置
  String buildFullToml() {
    final s = effectiveServer;
    final apps = configs
        .where((c) => c.enabled && (c.serverId.isEmpty || c.serverId == s.serverId))
        .toList();
    return toml.generateServerPreview(s, apps);
  }

  /// 应用导入结果：覆盖 server（如有）与 configs，返回导入数量
  Future<int> applyImport(ExportData? data) async {
    if (data == null) return 0;
    if (data.server != null) {
      await saveServerConfig(data.server!);
    }
    configs = data.configs;
    await _store.saveConfigs(configs);
    notifyListeners();
    return configs.length;
  }

  /// Server 配置预览：全局段 + 隶属于该 server 且已启用的应用配置
  String generateServerPreview() {
    final s = effectiveServer;
    final apps = configs
        .where((c) => c.enabled && (c.serverId.isEmpty || c.serverId == s.serverId))
        .toList();
    return toml.generateServerPreview(s, apps);
  }

  // ---- 配置 CRUD ----
  Future<void> saveServerConfig(ServerConfig s) async {
    final i = servers.indexWhere((e) => e.serverId == s.serverId);
    if (i >= 0) {
      servers[i] = s;
    } else {
      servers.add(s);
    }
    _selectedServerId = s.serverId;
    await _store.saveServers(servers);
    notifyListeners();
  }

  Future<void> addServerConfig(ServerConfig s) async {
    servers.add(s);
    _selectedServerId = s.serverId;
    await _store.saveServers(servers);
    notifyListeners();
  }

  Future<void> addConfig(FrpConfig config) async {
    final maxId = configs.fold<int>(0, (m, e) => e.id > m ? e.id : m);
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = config.copyWith(id: maxId + 1, createdAt: now, updatedAt: now);
    configs.add(c);
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> updateConfig(FrpConfig config) async {
    final i = configs.indexWhere((e) => e.id == config.id);
    if (i < 0) return;
    configs[i] = config.copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch);
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> deleteConfig(int id) async {
    configs.removeWhere((e) => e.id == id);
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> setConfigEnabled(int id, bool enabled) async {
    final i = configs.indexWhere((e) => e.id == id);
    if (i < 0) return;
    configs[i] = configs[i].copyWith(enabled: enabled);
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> setGroupEnabled(int groupId, bool enabled) async {
    configs = configs
        .map((e) => e.groupId == groupId ? e.copyWith(enabled: enabled) : e)
        .toList();
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> deleteGroup(int groupId) async {
    configs.removeWhere((e) => e.groupId == groupId);
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> renameGroup(int groupId, String name) async {
    configs = configs
        .map((e) => e.groupId == groupId ? e.copyWith(groupName: name) : e)
        .toList();
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> syncLinkedStcp(FrpConfig primary) async {
    // 与原有 createLinkedStcpConfig 一致：更新同组 STCP 子配置字段
    if (!primary.useFallback || primary.fallbackTo.isEmpty) return;
    final stcp = configs.where((e) => e.groupId == primary.groupId && e.protocol == 'stcp').toList();
    final derived = createLinkedStcpConfig(primary);
    for (final e in stcp) {
      final i = configs.indexOf(e);
      configs[i] = e.copyWith(
        serverName: derived.serverName,
        secretKey: derived.secretKey,
        useEncryption: derived.useEncryption,
        useCompression: derived.useCompression,
      );
    }
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  FrpConfig createLinkedStcpConfig(FrpConfig xtcp) {
    final stcpName = '${xtcp.name.endsWith('-xtcp') ? xtcp.name.substring(0, xtcp.name.length - 5) : xtcp.name}-stcp';
    return FrpConfig(
      name: stcpName,
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

  /// 分组聚合：用于仪表盘 Applications 列表
  /// 状态优先级：Error > P2P(XTCP) > RELAY(STCP) > 未连接
  List<AppRow> buildAppRows() {
    final rows = <AppRow>[];
    ConnectionType aggregate(Iterable<ConnectionType> types) {
      if (types.contains(ConnectionType.error)) return ConnectionType.error;
      if (types.contains(ConnectionType.p2p)) return ConnectionType.p2p;
      if (types.contains(ConnectionType.relay)) return ConnectionType.relay;
      if (types.isNotEmpty) return ConnectionType.unknown;
      return ConnectionType.unknown;
    }

    // 分组
    final grouped = configs.where((e) => e.isInGroup()).toList();
    final groupIds = grouped.map((e) => e.groupId).toSet();
    for (final gid in groupIds) {
      final members = grouped.where((e) => e.groupId == gid).toList();
      final primary = members.firstWhere((e) => e.isGroupPrimary, orElse: () => members.first);
      final name = primary.groupName.isNotEmpty ? primary.groupName : primary.name;
      final types = members
          .map((e) => appStatuses[e.name])
          .whereType<ConnectionType>()
          .toList();
      final status = aggregate(types);
      rows.add(AppRow(name, ConnectionStatus(status).label, status));
    }
    for (final c in configs.where((e) => !e.isInGroup())) {
      // 手动配置：显示名可能是分组名，实际 visitor 名在 TOML 里（可能有多个块），聚合全部
      final names = <String>{c.name, ...c.manualNames};
      final types = names
          .map((n) => appStatuses[n])
          .whereType<ConnectionType>()
          .toList();
      final status = aggregate(types);
      rows.add(AppRow(c.name, ConnectionStatus(status).label, status));
    }
    return rows;
  }
}

class AppRow {
  final String name;
  final String label;
  final ConnectionType status;
  AppRow(this.name, this.label, this.status);
}

/// 配置分组：groupId > 0 为真实分组（主 XTCP + 子 STCP），groupId == 0 为单条配置
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

extension AppStateGroups on AppState {
  /// 构建分组列表：分组在前（主配置在前），无分组配置单条在后
  List<ConfigGroup> buildGroups() {
    final result = <ConfigGroup>[];
    final grouped = configs.where((e) => e.isInGroup()).toList();
    final groupIds = grouped.map((e) => e.groupId).toSet().toList()..sort();
    for (final gid in groupIds) {
      final members = grouped.where((e) => e.groupId == gid).toList();
      final primary =
          members.firstWhere((e) => e.isGroupPrimary, orElse: () => members.first);
      result.add(ConfigGroup(
        groupId: gid,
        groupName: primary.groupName.isNotEmpty ? primary.groupName : primary.name,
        primary: primary,
        members: members,
        enabled: members.every((e) => e.enabled),
      ));
    }
    for (final c in configs.where((e) => !e.isInGroup())) {
      result.add(ConfigGroup(
        groupId: 0,
        groupName: c.name,
        primary: c,
        members: const [],
        enabled: c.enabled,
      ));
    }
    return result;
  }
}

/// 全局应用状态
final AppState appState = AppState();
