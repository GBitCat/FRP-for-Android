import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:path_provider/path_provider.dart';

import '../models/connection_status.dart';
import '../models/frp_config.dart';
import '../models/server_config.dart';
import '../services/config_import_export.dart';
import '../services/config_domain_service.dart';
import '../services/config_store.dart';
import '../services/frp_engine.dart';
import '../services/sensitive_file_cache.dart';
import '../services/toml_generator.dart' as toml;

/// 主题设置
class ThemeSettings {
  final ThemeMode mode; // system / light / dark
  final int accentIndex;
  const ThemeSettings({this.mode = ThemeMode.system, this.accentIndex = 0});
  ThemeSettings copyWith({ThemeMode? mode, int? accentIndex}) => ThemeSettings(
    mode: mode ?? this.mode,
    accentIndex: accentIndex ?? this.accentIndex,
  );
}

class AppState extends ChangeNotifier {
  void notify() => notifyListeners();

  final ConfigStore _store = ConfigStore();
  final FrpEngine engine = FrpEngine.instance;

  List<FrpConfig> configs = [];
  List<ServerConfig> servers = [];
  String _selectedServerId = '';
  String _stunServer = 'stun.easyvoip.com:3478';
  bool hideFromRecents = false;

  /// 首次启动待弹出的省电策略提醒
  bool batteryHintPending = false;
  ThemeSettings theme = const ThemeSettings();

  // 运行状态
  bool running = false;
  ConnectionStatus serverStatus = const ConnectionStatus();
  Map<String, ConnectionType> appStatuses = {};
  double memoryMb = 0;

  /// 设备实际物理内存（MB），作为 RSS 进度条上限
  double totalMemoryMb = 0;
  String ipv4 = '';
  String ipv6 = '';
  Timer? _pollTimer;
  bool _pollInProgress = false;
  bool _pollingEnabled = true;
  bool _disposed = false;
  bool initialized = false;
  String? initializationError;
  late Future<void> _initialization;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  Future<void> get ready => _initialization;

  AppState() {
    _subscriptions.add(
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
      }),
    );
    _subscriptions.add(
      engine.appStatusesStream.listen((m) {
        appStatuses = m;
        notifyListeners();
      }),
    );
    _initialization = _load();
    _startPolling();
  }

  Future<void> _load() async {
    try {
      await _loadData();
      initializationError = null;
    } catch (error, stackTrace) {
      initializationError = 'Unable to decrypt or load saved configuration';
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'frp_app configuration initialization',
        ),
      );
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> _loadData() async {
    try {
      await SensitiveFileCache.cleanupStaleFiles(await getTemporaryDirectory());
    } catch (_) {
      // Temporary-file cleanup must never block encrypted config loading.
    }
    _resolveStun();
    hideFromRecents = await _store.loadHideFromRecents();
    if (hideFromRecents) {
      engine.setExcludeFromRecents(true);
    }
    // 首次启动：标记省电策略提醒（只提醒一次）
    if (!await _store.loadBatteryHintShown()) {
      await _store.saveBatteryHintShown(true);
      batteryHintPending = true;
    }
    theme = ThemeSettings(
      mode: await _store.loadThemeMode(),
      accentIndex: await _store.loadThemeAccent(),
    );
    configs = await _store.loadConfigs();
    servers = await _store.loadServers();
    if (servers.isEmpty) {
      // 迁移旧单 server 数据
      final old = await _store.loadServer();
      final migrated = old ?? const ServerConfig();
      servers = [
        migrated.serverId.length == 8
            ? migrated
            : migrated.copyWith(serverId: ServerConfig.generateId()),
      ];
      await _store.saveServers(servers);
    } else if (servers.length == 1 && servers.first.serverId.length != 8) {
      servers = [servers.first.copyWith(serverId: ServerConfig.generateId())];
      await _store.saveServers(servers);
    }
    final savedSelectedId = await _store.loadSelectedServerId();
    _selectedServerId = servers.any((e) => e.serverId == savedSelectedId)
        ? savedSelectedId
        : servers.first.serverId;
    await _store.saveSelectedServerId(_selectedServerId);
    notifyListeners();
  }

  Future<void> retryInitialization() async {
    initialized = false;
    initializationError = null;
    notifyListeners();
    _initialization = _load();
    await _initialization;
  }

  Future<void> _ensureInitialized() async {
    await _initialization;
    if (initializationError != null) {
      throw StateError(initializationError!);
    }
  }

  void _startPolling() {
    if (_disposed || !_pollingEnabled) return;
    _pollTimer?.cancel();
    _pollTimer = Timer(Duration.zero, _poll);
  }

  void pausePolling() {
    _pollingEnabled = false;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void resumePolling() {
    if (_disposed || _pollingEnabled) return;
    _pollingEnabled = true;
    _startPolling();
  }

  Future<void> _poll() async {
    if (_pollInProgress) return;
    _pollInProgress = true;
    try {
      if (totalMemoryMb <= 0) {
        totalMemoryMb = await engine.getTotalMemoryMb();
      }
      memoryMb = await engine.getMemoryMb();
      ipv4 = await engine.getIpv4();
      ipv6 = await engine.getIpv6();
      notifyListeners();
    } finally {
      _pollInProgress = false;
      if (!_disposed && _pollingEnabled) {
        _pollTimer = Timer(const Duration(seconds: 2), _poll);
      }
    }
  }

  Future<void> start() async {
    await _ensureInitialized();
    running = true;
    serverStatus = const ConnectionStatus(
      ConnectionType.unknown,
      'Starting...',
    );
    notifyListeners();
    try {
      final ok = await engine.start(buildFullToml());
      if (!ok) {
        running = false;
        serverStatus = const ConnectionStatus(
          ConnectionType.error,
          'Failed to start frpc',
        );
        notifyListeners();
      }
    } catch (_) {
      running = false;
      serverStatus = const ConnectionStatus(
        ConnectionType.error,
        'Failed to start frpc',
      );
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

  String get selectedServerId => _selectedServerId;

  /// 保存主题设置（模式 + 主色）
  Future<void> setTheme(ThemeSettings t) async {
    await _ensureInitialized();
    theme = t;
    await _store.saveThemeMode(t.mode);
    await _store.saveThemeAccent(t.accentIndex);
    notifyListeners();
  }

  /// 隐藏/恢复最近任务卡片（设置页开关）
  Future<void> setHideFromRecents(bool v) async {
    await _ensureInitialized();
    hideFromRecents = v;
    await _store.saveHideFromRecents(v);
    await engine.setExcludeFromRecents(v);
    notifyListeners();
  }

  Future<void> selectServer(String id) async {
    await _ensureInitialized();
    if (id == _selectedServerId || !servers.any((e) => e.serverId == id)) {
      return;
    }
    final restart = running;
    if (restart) await stop();
    _selectedServerId = id;
    await _store.saveSelectedServerId(id);
    notifyListeners();
    if (restart) await start();
  }

  Future<void> deleteServer(String id) async {
    await _ensureInitialized();
    if (id == _selectedServerId && running) await stop();
    servers.removeWhere((e) => e.serverId == id);
    configs.removeWhere((e) => e.serverId == id);
    if (_selectedServerId == id) {
      _selectedServerId = servers.isNotEmpty ? servers.first.serverId : '';
    }
    await _store.saveServers(servers);
    await _store.saveConfigs(configs);
    await _store.saveSelectedServerId(_selectedServerId);
    notifyListeners();
  }

  /// 解析 STUN 域名到 IP（release 下原生 InetAddress 补丁可能失效，改在 Dart 层解析）
  Future<void> _resolveStun() async {
    try {
      final list = await InternetAddress.lookup('stun.easyvoip.com');
      if (list.isNotEmpty) {
        _stunServer = '${list.first.address}:3478';
      }
    } catch (_) {}
  }

  /// 完整 frpc TOML（导出用）：全局段 + 已启用的应用配置
  String buildFullToml() {
    return buildFullTomlFor(effectiveServer);
  }

  String buildFullTomlFor(ServerConfig s) {
    final apps = configs
        .where(
          (c) => c.enabled && (c.serverId.isEmpty || c.serverId == s.serverId),
        )
        .toList();
    return toml
        .generateServerPreview(s, apps)
        .replaceAll(
          'natHoleStunServer = "stun.easyvoip.com:3478"',
          'natHoleStunServer = "$_stunServer"',
        );
  }

  Map<String, String> buildAllServerTomls() => {
    for (final server in servers) server.serverId: buildFullTomlFor(server),
  };

  /// 应用导入结果：覆盖 server（如有）与 configs，返回导入数量
  Future<int> applyImport(ExportData? data) async {
    await _ensureInitialized();
    if (data == null) return 0;
    if (running) await stop();
    if (data.servers.isNotEmpty) {
      servers = List.of(data.servers);
      _selectedServerId =
          servers.any((e) => e.serverId == data.selectedServerId)
          ? data.selectedServerId
          : servers.first.serverId;
      await _store.saveServers(servers);
      await _store.saveSelectedServerId(_selectedServerId);
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
        .where(
          (c) => c.enabled && (c.serverId.isEmpty || c.serverId == s.serverId),
        )
        .toList();
    return toml.generateServerPreview(s, apps);
  }

  // ---- 配置 CRUD ----
  Future<void> saveServerConfig(
    ServerConfig s, {
    String? originalServerId,
  }) async {
    await _ensureInitialized();
    final oldId = originalServerId ?? s.serverId;
    final i = servers.indexWhere((e) => e.serverId == oldId);
    final restart = running && oldId == _selectedServerId;
    if (restart) await stop();
    if (i >= 0) {
      servers[i] = s;
    } else {
      servers.add(s);
    }
    if (oldId != s.serverId) {
      configs = configs
          .map(
            (e) => e.serverId == oldId ? e.copyWith(serverId: s.serverId) : e,
          )
          .toList();
      await _store.saveConfigs(configs);
    }
    if (_selectedServerId == oldId || originalServerId == null) {
      _selectedServerId = s.serverId;
    }
    await _store.saveServers(servers);
    await _store.saveSelectedServerId(_selectedServerId);
    notifyListeners();
    if (restart) await start();
  }

  Future<void> addServerConfig(ServerConfig s) async {
    await _ensureInitialized();
    servers.add(s);
    _selectedServerId = s.serverId;
    await _store.saveServers(servers);
    await _store.saveSelectedServerId(_selectedServerId);
    notifyListeners();
  }

  Future<void> addConfig(FrpConfig config) async {
    await _ensureInitialized();
    final maxId = configs.fold<int>(0, (m, e) => e.id > m ? e.id : m);
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = config.copyWith(id: maxId + 1, createdAt: now, updatedAt: now);
    configs.add(c);
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> updateConfig(FrpConfig config) async {
    await _ensureInitialized();
    final i = configs.indexWhere((e) => e.id == config.id);
    if (i < 0) return;
    configs[i] = config.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  /// Atomically replaces a logical set of form configurations.
  ///
  /// Existing IDs retain their creation timestamps, while newly-added
  /// protocol members receive fresh IDs. This lets the form editor update an
  /// entire multi-protocol group without exposing a partially-written group
  /// between individual add/update operations.
  Future<void> replaceConfigSet({
    required Set<int> existingIds,
    required List<FrpConfig> replacements,
  }) async {
    await _ensureInitialized();

    final existingById = {
      for (final config in configs)
        if (existingIds.contains(config.id)) config.id: config,
    };
    var nextId = configs.fold<int>(0, (max, config) {
      return config.id > max ? config.id : max;
    });
    final now = DateTime.now().millisecondsSinceEpoch;
    final prepared = <FrpConfig>[];
    final usedIds = <int>{};

    for (final replacement in replacements) {
      final existing = existingById[replacement.id];
      if (existing != null && usedIds.add(existing.id)) {
        prepared.add(
          replacement.copyWith(createdAt: existing.createdAt, updatedAt: now),
        );
      } else {
        nextId += 1;
        usedIds.add(nextId);
        prepared.add(
          replacement.copyWith(id: nextId, createdAt: now, updatedAt: now),
        );
      }
    }

    var insertAt = configs.indexWhere(
      (config) => existingIds.contains(config.id),
    );
    final retained = configs
        .where((config) => !existingIds.contains(config.id))
        .toList();
    if (insertAt < 0 || insertAt > retained.length) insertAt = retained.length;
    retained.insertAll(insertAt, prepared);
    configs = retained;
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> deleteConfig(int id) async {
    await _ensureInitialized();
    configs.removeWhere((e) => e.id == id);
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> setConfigEnabled(int id, bool enabled) async {
    await _ensureInitialized();
    final i = configs.indexWhere((e) => e.id == id);
    if (i < 0) return;
    configs[i] = configs[i].copyWith(enabled: enabled);
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> setGroupEnabled(int groupId, bool enabled) async {
    await _ensureInitialized();
    configs = configs
        .map((e) => e.groupId == groupId ? e.copyWith(enabled: enabled) : e)
        .toList();
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> deleteGroup(int groupId) async {
    await _ensureInitialized();
    configs.removeWhere((e) => e.groupId == groupId);
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> renameGroup(int groupId, String name) async {
    await _ensureInitialized();
    configs = configs
        .map((e) => e.groupId == groupId ? e.copyWith(groupName: name) : e)
        .toList();
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> syncLinkedFallback(FrpConfig primary) async {
    await _ensureInitialized();
    if (!primary.useFallback || primary.fallbackTo.isEmpty) return;
    final fallbackProtocol = ConfigDomainService.fallbackProtocolFor(
      primary.protocol,
    );
    if (fallbackProtocol == null) return;
    final linked = configs
        .where(
          (config) =>
              config.groupId == primary.groupId &&
              config.protocol == fallbackProtocol &&
              config.name == primary.fallbackTo,
        )
        .toList();
    final derived = createLinkedFallbackConfig(primary);
    for (final config in linked) {
      final i = configs.indexOf(config);
      configs[i] = config.copyWith(
        serverName: derived.serverName,
        secretKey: derived.secretKey,
        useEncryption: derived.useEncryption,
        useCompression: derived.useCompression,
      );
    }
    await _store.saveConfigs(configs);
    notifyListeners();
  }

  Future<void> syncLinkedStcp(FrpConfig primary) => syncLinkedFallback(primary);

  FrpConfig createLinkedFallbackConfig(FrpConfig primary) {
    return ConfigDomainService.createLinkedFallbackConfig(primary);
  }

  FrpConfig createLinkedStcpConfig(FrpConfig xtcp) {
    return createLinkedFallbackConfig(xtcp);
  }

  /// 分组聚合：用于仪表盘 Applications 列表
  /// 状态优先级：Error > P2P(XTCP) > RELAY(STCP) > 未连接
  List<AppRow> buildAppRows() {
    return ConfigDomainService.buildAppRows(configs, appStatuses);
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }
}

extension AppStateGroups on AppState {
  /// 构建分组列表：分组在前（主配置在前），无分组配置单条在后
  List<ConfigGroup> buildGroups() {
    return ConfigDomainService.buildGroups(configs);
  }
}

/// 全局应用状态
final AppState appState = AppState();
