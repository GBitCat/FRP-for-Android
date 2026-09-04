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
import '../services/config_validator.dart';
import '../services/certificates/certificate_binding_resolver.dart';
import '../services/certificates/certificate_engine.dart';
import '../services/certificates/certificate_models.dart';
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

class _RuntimeMutationTicket {
  const _RuntimeMutationTicket({
    required this.baselineGeneration,
    required this.affectsRuntime,
    required this.hadRunIntent,
    this.pauseGeneration,
  });

  final int baselineGeneration;
  final bool affectsRuntime;
  final bool hadRunIntent;
  final int? pauseGeneration;

  int get observedGeneration => pauseGeneration ?? baselineGeneration;
}

class _CertificateBindingResolution {
  const _CertificateBindingResolution({
    required this.servers,
    required this.inventoryAvailable,
  });

  final List<ServerConfig> servers;
  final bool inventoryAvailable;
}

class AppState extends ChangeNotifier {
  void notify() => notifyListeners();

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  final ConfigStore _store = ConfigStore();
  final FrpEngine engine = FrpEngine.instance;
  final CertificateBackend _certificateBackend;

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
  bool _nativeIntentReconcileInProgress = false;
  bool _nativeIntentReconcileAgain = false;
  bool _runRequested = false;
  int _lifecycleGeneration = 0;
  final Set<String> _invalidatedCertificateIdentityIds = {};
  final Set<String> _certificateIdentityRollbackCandidates = {};
  bool _disposed = false;
  Future<void> _mutationTail = Future<void>.value();
  bool initialized = false;
  String? initializationError;
  late Future<void> _initialization;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  Future<void> get ready => _initialization;

  AppState({CertificateBackend? certificateBackend})
    : _certificateBackend = certificateBackend ?? CertificateEngine.instance {
    _subscriptions.add(
      engine.statusStream.listen((s) {
        if (_disposed) return;
        serverStatus = s;
        // connecting/connected → 运行中；unknown(断开) → 停止
        if (s.type == ConnectionType.connecting ||
            s.type == ConnectionType.connected) {
          // A newly-created Activity can attach to a service which was already
          // running. Infer that persisted native intent only until the first
          // local lifecycle action, so a stale status cannot undo user Stop.
          if (_runRequested || _lifecycleGeneration == 0) {
            running = true;
            if (_lifecycleGeneration == 0 && !_runRequested) {
              _lifecycleGeneration++;
              _runRequested = true;
            }
          }
        } else if (s.type == ConnectionType.unknown ||
            s.type == ConnectionType.error) {
          running = false;
        }
        notifyListeners();
        if (s.type == ConnectionType.error && _runRequested) {
          unawaited(_reconcileNativeRunIntent(_lifecycleGeneration));
        }
      }),
    );
    _subscriptions.add(
      engine.appStatusesStream.listen((m) {
        if (_disposed) return;
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
      initializationError = error is ConfigStoreException
          ? error.userMessage
          : 'Unable to decrypt or load saved configuration';
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
      try {
        await engine.setExcludeFromRecents(true);
      } catch (_) {
        // Keep the persisted preference for a future retry, but do not claim in
        // the current UI that the OS operation succeeded.
        hideFromRecents = false;
      }
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
    final intentGeneration = _lifecycleGeneration;
    final nativeRunRequested = await engine.getRunRequested();
    if (nativeRunRequested && _lifecycleGeneration == intentGeneration) {
      _runRequested = true;
    }
    final snapshot = await _store.loadConfigurationSnapshot();
    if (snapshot != null) {
      _commitConfiguration(snapshot);
      await _hydrateCertificateBindings(allowLegacyPathMigration: true);
    } else {
      final legacyConfigs = await _store.loadConfigs();
      var legacyServers = await _store.loadServers();
      if (legacyServers.isEmpty) {
        // Migrate the former single-server representation.
        final old = await _store.loadServer();
        final migrated = old ?? const ServerConfig();
        legacyServers = [
          migrated.serverId.length == 8
              ? migrated
              : migrated.copyWith(serverId: ServerConfig.generateId()),
        ];
      } else if (legacyServers.length == 1 &&
          legacyServers.first.serverId.length != 8) {
        legacyServers = [
          legacyServers.first.copyWith(serverId: ServerConfig.generateId()),
        ];
      }
      final savedSelectedId = await _store.loadSelectedServerId();
      final selectedServerId =
          legacyServers.any((server) => server.serverId == savedSelectedId)
          ? savedSelectedId
          : legacyServers.first.serverId;
      final resolution = await _resolveCertificateBindings(
        legacyServers,
        allowLegacyPathMigration: true,
      );
      if (_needsLegacyPathMigration(legacyServers) &&
          !resolution.inventoryAvailable) {
        // Do not create an authoritative pathless snapshot while the native
        // inventory is only temporarily unavailable. Keeping the legacy keys
        // intact allows Retry to complete their one-time identity migration.
        throw StateError(
          'Certificate inventory is unavailable during TLS migration',
        );
      }
      final migratedSnapshot = ConfigurationSnapshot(
        servers: resolution.servers,
        selectedServerId: selectedServerId,
        configs: _normalizeLegacyConfigs(
          legacyConfigs,
          legacyServers,
          selectedServerId,
        ),
      );
      // This is the migration commit point. The former values are deliberately
      // retained as recovery material, but are no longer written by AppState.
      await _store.saveConfigurationSnapshot(migratedSnapshot);
      _commitConfiguration(migratedSnapshot);
    }
    notifyListeners();
  }

  static List<FrpConfig> _normalizeLegacyConfigs(
    List<FrpConfig> legacy,
    List<ServerConfig> availableServers,
    String selectedServerId,
  ) {
    final serverIds = availableServers.map((server) => server.serverId).toSet();
    final usedIds = <int>{};
    final firstReplacementByOldId = <int, int>{};
    var nextId = legacy.fold<int>(
      0,
      (maximum, config) => config.id > maximum ? config.id : maximum,
    );
    final assigned = <FrpConfig>[];
    for (final config in legacy) {
      var id = config.id;
      if (id <= 0 || !usedIds.add(id)) {
        do {
          nextId++;
        } while (!usedIds.add(nextId));
        id = nextId;
      }
      if (config.id > 0) {
        firstReplacementByOldId.putIfAbsent(config.id, () => id);
      }
      assigned.add(config.copyWith(id: id));
    }
    return assigned
        .map(
          (config) => config.copyWith(
            serverId:
                config.serverId.isEmpty || serverIds.contains(config.serverId)
                ? config.serverId
                : selectedServerId,
            linkedConfigId: config.linkedConfigId <= 0
                ? 0
                : (firstReplacementByOldId[config.linkedConfigId] ?? 0),
          ),
        )
        .toList(growable: false);
  }

  ConfigurationSnapshot _configuration({
    List<ServerConfig>? servers,
    String? selectedServerId,
    List<FrpConfig>? configs,
  }) {
    final nextServers = List<ServerConfig>.of(servers ?? this.servers);
    var nextSelectedId = selectedServerId ?? _selectedServerId;
    if (nextServers.isNotEmpty &&
        !nextServers.any((server) => server.serverId == nextSelectedId)) {
      nextSelectedId = nextServers.first.serverId;
    }
    return ConfigurationSnapshot(
      servers: nextServers,
      selectedServerId: nextSelectedId,
      configs: List<FrpConfig>.of(configs ?? this.configs),
    );
  }

  void _commitConfiguration(ConfigurationSnapshot snapshot) {
    servers = List<ServerConfig>.of(snapshot.servers);
    _selectedServerId = snapshot.selectedServerId;
    configs = List<FrpConfig>.of(snapshot.configs);
  }

  Future<void> _persistAndCommit(ConfigurationSnapshot snapshot) async {
    await _store.saveConfigurationSnapshot(snapshot);
    _commitConfiguration(snapshot);
  }

  Future<T> _serializeMutation<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
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
    if (_disposed) throw StateError('AppState has been disposed');
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
      if (_runRequested &&
          !running &&
          serverStatus.type == ConnectionType.error) {
        await _reconcileNativeRunIntent(_lifecycleGeneration);
      }
      if (_disposed) return;
      if (totalMemoryMb <= 0) {
        totalMemoryMb = await engine.getTotalMemoryMb();
      }
      if (_disposed) return;
      memoryMb = await engine.getMemoryMb();
      if (_disposed) return;
      ipv4 = await engine.getIpv4();
      if (_disposed) return;
      ipv6 = await engine.getIpv6();
      if (_disposed) return;
      notifyListeners();
    } finally {
      _pollInProgress = false;
      if (!_disposed && _pollingEnabled) {
        _pollTimer = Timer(const Duration(seconds: 2), _poll);
      }
    }
  }

  Future<void> _reconcileNativeRunIntent(int observedGeneration) async {
    if (_disposed ||
        !_runRequested ||
        serverStatus.type != ConnectionType.error) {
      return;
    }
    if (_nativeIntentReconcileInProgress) {
      _nativeIntentReconcileAgain = true;
      return;
    }
    _nativeIntentReconcileInProgress = true;
    try {
      final nativeRunRequested = await engine.queryRunRequested();
      if (_disposed ||
          nativeRunRequested != false ||
          observedGeneration != _lifecycleGeneration ||
          !_runRequested ||
          serverStatus.type != ConnectionType.error) {
        return;
      }
      // Native accepted Start synchronously but can still fail on its worker
      // and abandon the durable request. Advance the epoch so no older async
      // Start/mutation continuation can revive the rejected intent.
      _lifecycleGeneration++;
      _runRequested = false;
      running = false;
      appStatuses = {};
      notifyListeners();
    } finally {
      _nativeIntentReconcileInProgress = false;
      if (_nativeIntentReconcileAgain) {
        _nativeIntentReconcileAgain = false;
        unawaited(_reconcileNativeRunIntent(_lifecycleGeneration));
      }
    }
  }

  Future<void> start() {
    // Claim user intent synchronously. A later Stop must win even while this
    // start is waiting for initialization or certificate inventory I/O.
    final generation = ++_lifecycleGeneration;
    _runRequested = true;
    return _startClaimed(generation);
  }

  Future<void> _startClaimed(int generation) async {
    try {
      await _ensureInitialized();
    } catch (_) {
      if (generation == _lifecycleGeneration) {
        _runRequested = false;
        running = false;
        notifyListeners();
      }
      rethrow;
    }
    if (generation != _lifecycleGeneration || !_runRequested) return;
    final validationError = effectiveServer.runtimeValidationError();
    if (validationError != null) {
      _runRequested = false;
      running = false;
      serverStatus = ConnectionStatus(ConnectionType.error, validationError);
      notifyListeners();
      return;
    }
    final server = effectiveServer;
    running = true;
    serverStatus = const ConnectionStatus(
      ConnectionType.unknown,
      'Starting...',
    );
    notifyListeners();
    try {
      var runtimeServer = server.withoutRuntimeTlsPaths();
      if (server.tlsEnabled) {
        final inventory = await _certificateBackend.listInventory();
        runtimeServer = CertificateBindingResolver.requireReady(
          server,
          inventory,
        );
      }
      if (generation != _lifecycleGeneration || !_runRequested) return;
      final ok = await engine.start(buildFullTomlFor(runtimeServer));
      if (generation != _lifecycleGeneration) {
        if (!_runRequested) await engine.stop();
        return;
      }
      if (!ok) {
        _runRequested = false;
        running = false;
        serverStatus = const ConnectionStatus(
          ConnectionType.error,
          'Failed to start frpc',
        );
        notifyListeners();
      }
    } catch (error) {
      if (generation != _lifecycleGeneration) return;
      _runRequested = false;
      running = false;
      serverStatus = ConnectionStatus(
        ConnectionType.error,
        error is CertificateBindingException
            ? error.message
            : 'Failed to start frpc',
      );
      notifyListeners();
    }
  }

  Future<int> _stopRuntime() async {
    final wasRunning = running;
    final hadRunIntent = _runRequested;
    final generation = ++_lifecycleGeneration;
    _runRequested = false;
    try {
      await engine.stop();
    } catch (_) {
      if (generation == _lifecycleGeneration) {
        _runRequested = hadRunIntent;
        running = wasRunning;
        serverStatus = const ConnectionStatus(
          ConnectionType.error,
          'Failed to stop frpc',
        );
        notifyListeners();
      }
      rethrow;
    }
    if (generation == _lifecycleGeneration) {
      running = false;
      appStatuses = {};
      serverStatus = const ConnectionStatus();
      notifyListeners();
    }
    return generation;
  }

  Future<void> stop() async {
    await _stopRuntime();
  }

  Future<_RuntimeMutationTicket> _pauseRuntimeForMutation(
    bool affectsRuntime,
  ) async {
    final baselineGeneration = _lifecycleGeneration;
    final hadRunIntent = running || _runRequested;
    if (!affectsRuntime || !hadRunIntent) {
      return _RuntimeMutationTicket(
        baselineGeneration: baselineGeneration,
        affectsRuntime: affectsRuntime,
        hadRunIntent: hadRunIntent,
      );
    }
    // Return this mutation's own ticket. Reading the global generation after
    // await would mistake a racing explicit Stop for our pause and revive it.
    final pauseGeneration = await _stopRuntime();
    return _RuntimeMutationTicket(
      baselineGeneration: baselineGeneration,
      affectsRuntime: true,
      hadRunIntent: true,
      pauseGeneration: pauseGeneration,
    );
  }

  Future<void> _resumeRuntimeAfterMutation(
    _RuntimeMutationTicket ticket, {
    required bool configurationChanged,
    required bool resumePreviousIntent,
  }) async {
    if (!ticket.affectsRuntime || _disposed) return;
    try {
      if (ticket.pauseGeneration != null &&
          _lifecycleGeneration == ticket.pauseGeneration) {
        if (!resumePreviousIntent || !ticket.hadRunIntent) return;
        await start();
        return;
      }
      if (configurationChanged &&
          _lifecycleGeneration != ticket.observedGeneration &&
          _runRequested) {
        await _supersedeRacingStart();
      }
    } catch (_) {
      // Persistence and runtime reconciliation have different commit points.
      // Once a snapshot write succeeds, a later native stop/restart failure
      // must not make callers retry an already-committed add/import operation.
      // Likewise, a failed write must preserve its original storage exception
      // even if restoring the former runtime also fails.
      if (!_disposed && _runRequested) {
        running = false;
        serverStatus = ConnectionStatus(
          ConnectionType.error,
          configurationChanged
              ? 'Configuration saved, but frpc could not apply the runtime update'
              : 'Configuration was not saved, and frpc could not be restored',
        );
        notifyListeners();
      }
    }
  }

  Future<void> _supersedeRacingStart() async {
    if (_disposed || !_runRequested) return;
    // Claim the replacement before the first await. Any older Start still
    // waiting on initialization/TLS can no longer submit its stale payload.
    final requestedGeneration = ++_lifecycleGeneration;
    _runRequested = true;
    // A Start issued during the durable write used the pre-commit snapshot.
    // Stop it first even when the committed replacement is now invalid; this
    // prevents the old native payload from remaining active or recoverable.
    running = false;
    appStatuses = {};
    notifyListeners();
    await _restartClaimed(requestedGeneration);
  }

  Future<void> _restartClaimed(int requestedGeneration) async {
    await engine.stop();
    if (_disposed ||
        _lifecycleGeneration != requestedGeneration ||
        !_runRequested) {
      return;
    }
    await _startClaimed(requestedGeneration);
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

  /// User/native desired service state, distinct from the latest connection
  /// status. A disconnected frpc can still be awaiting automatic recovery.
  bool get runRequested => _runRequested;

  Future<void> setThemeMode(ThemeMode mode) => _serializeMutation(() async {
    await _ensureInitialized();
    await _store.saveThemeMode(mode);
    theme = theme.copyWith(mode: mode);
    notifyListeners();
  });

  Future<void> setThemeAccent(int accentIndex) => _serializeMutation(() async {
    await _ensureInitialized();
    if (accentIndex < 0 || accentIndex > 6) {
      throw const FormatException('Theme accent is invalid');
    }
    await _store.saveThemeAccent(accentIndex);
    theme = theme.copyWith(accentIndex: accentIndex);
    notifyListeners();
  });

  /// 隐藏/恢复最近任务卡片（设置页开关）
  Future<void> setHideFromRecents(bool v) => _serializeMutation(() async {
    await _ensureInitialized();
    final previous = hideFromRecents;
    await engine.setExcludeFromRecents(v);
    try {
      await _store.saveHideFromRecents(v);
    } catch (_) {
      try {
        await engine.setExcludeFromRecents(previous);
      } catch (_) {}
      rethrow;
    }
    hideFromRecents = v;
    notifyListeners();
  });

  Future<void> selectServer(String id) => _serializeMutation(() async {
    await _ensureInitialized();
    if (id == _selectedServerId || !servers.any((e) => e.serverId == id)) {
      return;
    }
    final runtimeTicket = await _pauseRuntimeForMutation(true);
    try {
      await _persistAndCommit(_configuration(selectedServerId: id));
      notifyListeners();
    } catch (_) {
      await _resumeRuntimeAfterMutation(
        runtimeTicket,
        configurationChanged: false,
        resumePreviousIntent: true,
      );
      rethrow;
    }
    await _resumeRuntimeAfterMutation(
      runtimeTicket,
      configurationChanged: true,
      resumePreviousIntent: true,
    );
  });

  Future<void> deleteServer(String id) => _serializeMutation(() async {
    await _ensureInitialized();
    if (!servers.any((server) => server.serverId == id)) return;
    final runtimeTicket = await _pauseRuntimeForMutation(
      id == _selectedServerId,
    );
    try {
      final nextServers = servers
          .where((server) => server.serverId != id)
          .toList(growable: true);
      if (nextServers.isEmpty) {
        nextServers.add(ServerConfig(serverId: ServerConfig.generateId()));
      }
      final nextConfigs = configs
          .where((config) => config.serverId != id)
          .toList(growable: false);
      final nextSelectedId = _selectedServerId == id
          ? nextServers.first.serverId
          : _selectedServerId;
      await _persistAndCommit(
        _configuration(
          servers: nextServers,
          selectedServerId: nextSelectedId,
          configs: nextConfigs,
        ),
      );
      notifyListeners();
    } catch (_) {
      await _resumeRuntimeAfterMutation(
        runtimeTicket,
        configurationChanged: false,
        resumePreviousIntent: true,
      );
      rethrow;
    }
    await _resumeRuntimeAfterMutation(
      runtimeTicket,
      configurationChanged: true,
      resumePreviousIntent: true,
    );
  });

  /// 解析 STUN 域名到 IP（release 下原生 InetAddress 补丁可能失效，改在 Dart 层解析）
  Future<void> _resolveStun() async {
    try {
      final list = await InternetAddress.lookup('stun.easyvoip.com');
      if (!_disposed && list.isNotEmpty) {
        _stunServer = formatStunEndpoint(list.first);
      }
    } catch (_) {}
  }

  @visibleForTesting
  static String formatStunEndpoint(InternetAddress address, {int port = 3478}) {
    final host = address.type == InternetAddressType.IPv6
        ? '[${address.address}]'
        : address.address;
    return '$host:$port';
  }

  /// 完整 frpc TOML（导出用）：全局段 + 已启用的应用配置
  String buildFullToml() {
    return buildFullTomlFor(effectiveServer);
  }

  String buildFullTomlFor(ServerConfig s) {
    final apps = configs
        .where((config) => config.enabled && _belongsToServer(config, s))
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
  Future<int> applyImport(ExportData? data) => _serializeMutation(() async {
    await _ensureInitialized();
    if (data == null) return 0;

    final nextServers = data.servers.isEmpty
        ? List<ServerConfig>.of(servers)
        : List<ServerConfig>.of(data.servers);
    final importedServerIds = <String>{};
    for (final server in nextServers) {
      _requireValidServer(server);
      if (!importedServerIds.add(server.serverId)) {
        throw const FormatException('Server IDs must be unique');
      }
    }
    final nextSelectedServerId = data.servers.isEmpty
        ? _selectedServerId
        : nextServers.any((server) => server.serverId == data.selectedServerId)
        ? data.selectedServerId
        : nextServers.first.serverId;

    var importedConfigs = data.configs
        .map((config) {
          final allowIncomplete = data.version == 1;
          final error = ConfigValidator.validate(
            config,
            allowMissingSecrets: data.redacted,
            allowIncompleteLegacy: allowIncomplete,
          );
          if (error != null) throw FormatException(error);
          var serverId = config.serverId;
          if (serverId.isNotEmpty && !importedServerIds.contains(serverId)) {
            if (!allowIncomplete) {
              throw const FormatException(
                'Proxy references an unknown Server ID',
              );
            }
            serverId = nextSelectedServerId;
          }
          // Redacted and incomplete legacy records must be reviewed before they
          // are allowed to reach the native frpc process.
          return config.copyWith(
            serverId: serverId,
            enabled: (data.redacted || allowIncomplete)
                ? false
                : config.enabled,
          );
        })
        .toList(growable: false);
    if (data.version == 1) {
      importedConfigs = _normalizeLegacyConfigs(
        importedConfigs,
        nextServers,
        nextSelectedServerId,
      );
    } else {
      final ids = <int>{};
      if (importedConfigs.any(
        (config) => config.id <= 0 || !ids.add(config.id),
      )) {
        throw const FormatException('Proxy IDs must be positive and unique');
      }
    }

    final runtimeTicket = await _pauseRuntimeForMutation(true);
    try {
      // Claim the runtime mutation before certificate inventory I/O. A Start
      // arriving while that read is in flight must later be superseded with
      // the imported snapshot, not mistaken for intent that import may drop.
      final resolution = await _resolveCertificateBindings(nextServers);
      final importedSnapshot = _configuration(
        servers: resolution.servers,
        selectedServerId: nextSelectedServerId,
        configs: importedConfigs,
      );
      // Resolve managed certificate IDs before the only durable commit. This
      // avoids a second hydration write that could fail after the imported
      // configuration had already replaced the previous snapshot.
      await _persistAndCommit(importedSnapshot);
      notifyListeners();
    } catch (_) {
      await _resumeRuntimeAfterMutation(
        runtimeTicket,
        configurationChanged: false,
        resumePreviousIntent: true,
      );
      rethrow;
    }
    // Import normally leaves frpc stopped. A Start which raced the import is
    // rebuilt from the committed snapshot instead of retaining old TOML.
    await _resumeRuntimeAfterMutation(
      runtimeTicket,
      configurationChanged: true,
      resumePreviousIntent: false,
    );
    return configs.length;
  });

  /// Server 配置预览：全局段 + 隶属于该 server 且已启用的应用配置
  String generateServerPreview() {
    final s = effectiveServer;
    final apps = configs
        .where((config) => config.enabled && _belongsToServer(config, s))
        .toList();
    return toml.generateServerPreview(s, apps);
  }

  // ---- 配置 CRUD ----
  Future<void> saveServerConfig(ServerConfig s, {String? originalServerId}) =>
      _serializeMutation(() async {
        await _ensureInitialized();
        _requireValidServer(s);
        final oldId = originalServerId ?? s.serverId;
        if (servers.any(
          (server) => server.serverId == s.serverId && server.serverId != oldId,
        )) {
          throw StateError('Server ID must be unique');
        }
        final selectsSavedServer =
            _selectedServerId == oldId || originalServerId == null;
        final runtimeTicket = await _pauseRuntimeForMutation(
          selectsSavedServer,
        );
        try {
          final verifiedServer = await _verifyServerBindingForSave(s);
          final nextServers = List<ServerConfig>.of(servers);
          final i = nextServers.indexWhere((e) => e.serverId == oldId);
          if (i >= 0) {
            nextServers[i] = verifiedServer;
          } else {
            nextServers.add(verifiedServer);
          }
          var nextConfigs = List<FrpConfig>.of(configs);
          if (oldId != verifiedServer.serverId) {
            nextConfigs = nextConfigs
                .map(
                  (e) => e.serverId == oldId
                      ? e.copyWith(serverId: verifiedServer.serverId)
                      : e,
                )
                .toList();
          }
          final nextSelectedId = selectsSavedServer
              ? verifiedServer.serverId
              : _selectedServerId;
          await _persistAndCommit(
            _configuration(
              servers: nextServers,
              selectedServerId: nextSelectedId,
              configs: nextConfigs,
            ),
          );
          notifyListeners();
        } catch (_) {
          await _resumeRuntimeAfterMutation(
            runtimeTicket,
            configurationChanged: false,
            resumePreviousIntent: true,
          );
          rethrow;
        }
        await _resumeRuntimeAfterMutation(
          runtimeTicket,
          configurationChanged: true,
          resumePreviousIntent: true,
        );
      });

  Future<void> addServerConfig(ServerConfig s) => _serializeMutation(() async {
    await _ensureInitialized();
    _requireValidServer(s);
    if (servers.any((server) => server.serverId == s.serverId)) {
      throw StateError('Server ID must be unique');
    }
    final runtimeTicket = await _pauseRuntimeForMutation(true);
    try {
      final verifiedServer = await _verifyServerBindingForSave(s);
      await _persistAndCommit(
        _configuration(
          servers: [...servers, verifiedServer],
          selectedServerId: verifiedServer.serverId,
        ),
      );
      notifyListeners();
    } catch (_) {
      await _resumeRuntimeAfterMutation(
        runtimeTicket,
        configurationChanged: false,
        resumePreviousIntent: true,
      );
      rethrow;
    }
    await _resumeRuntimeAfterMutation(
      runtimeTicket,
      configurationChanged: true,
      resumePreviousIntent: true,
    );
  });

  Future<void> invalidateCertificateIdentity(String identityId) =>
      _serializeMutation(() async {
        await _ensureInitialized();
        final runtimeTicket = await _pauseRuntimeForMutation(
          effectiveServer.tlsIdentityId == identityId,
        );
        final nextServers = servers
            .map(
              (server) =>
                  CertificateBindingResolver.invalidate(server, identityId),
            )
            .toList(growable: false);
        try {
          await _persistAndCommit(_configuration(servers: nextServers));
          _certificateIdentityRollbackCandidates.remove(identityId);
          _invalidatedCertificateIdentityIds.add(identityId);
          notifyListeners();
        } catch (_) {
          await _resumeRuntimeAfterMutation(
            runtimeTicket,
            configurationChanged: false,
            resumePreviousIntent: true,
          );
          rethrow;
        }
        await _resumeRuntimeAfterMutation(
          runtimeTicket,
          configurationChanged: true,
          resumePreviousIntent: false,
        );
      });

  /// Clears an in-process deletion tombstone only when the native inventory
  /// proves that the failed delete left a ready identity in place. Native
  /// deletion can report an error after its filesystem commit point, so callers
  /// must never clear this guard solely because an exception was received.
  Future<bool> rollbackCertificateIdentityInvalidation(String identityId) =>
      _serializeMutation(() async {
        await _ensureInitialized();
        // Mark this only after the caller has observed native deletion failure.
        // A stale form racing an in-progress (but ultimately successful) delete
        // must never be able to clear the ordinary deletion tombstone.
        _certificateIdentityRollbackCandidates.add(identityId);
        final inventory = await _certificateBackend.listInventory();
        final canRebind = inventory.identities.any(
          (identity) => identity.id == identityId && identity.isReady,
        );
        if (!canRebind) {
          _certificateIdentityRollbackCandidates.remove(identityId);
          return false;
        }
        final removed = _invalidatedCertificateIdentityIds.remove(identityId);
        _certificateIdentityRollbackCandidates.remove(identityId);
        if (removed) notifyListeners();
        return true;
      });

  /// Refreshes managed TLS paths after an identity certificate or trust bundle
  /// changes. frpc reads those files only at process start, so the active
  /// server is restarted after a successful certificate operation.
  Future<void> refreshCertificateIdentity(String identityId) =>
      _serializeMutation(() async {
        await _ensureInitialized();
        final runtimeTicket = await _pauseRuntimeForMutation(
          effectiveServer.tlsIdentityId == identityId,
        );
        try {
          await _hydrateCertificateBindings();
          _invalidatedCertificateIdentityIds.remove(identityId);
          notifyListeners();
        } finally {
          await _resumeRuntimeAfterMutation(
            runtimeTicket,
            configurationChanged: true,
            resumePreviousIntent: true,
          );
        }
      });

  Future<void> _hydrateCertificateBindings({
    bool allowLegacyPathMigration = false,
  }) async {
    final hadRuntimePaths = servers.any((server) => server.hasLegacyTlsPaths);
    final before = servers;
    final resolution = await _resolveCertificateBindings(
      before,
      allowLegacyPathMigration: allowLegacyPathMigration,
    );
    if (allowLegacyPathMigration &&
        _needsLegacyPathMigration(before) &&
        !resolution.inventoryAvailable) {
      throw StateError(
        'Certificate inventory is unavailable during TLS migration',
      );
    }
    final hydrated = resolution.servers;
    final migratedIdentity = List.generate(
      before.length,
      (index) => before[index].tlsIdentityId != hydrated[index].tlsIdentityId,
    ).any((changed) => changed);
    if (migratedIdentity ||
        (hadRuntimePaths && resolution.inventoryAvailable)) {
      // Do not catch this write. Swallowing a durable-storage failure would
      // make the in-memory binding diverge from the snapshot on disk.
      await _persistAndCommit(_configuration(servers: hydrated));
    } else {
      servers = hydrated;
    }
  }

  Future<_CertificateBindingResolution> _resolveCertificateBindings(
    List<ServerConfig> source, {
    bool allowLegacyPathMigration = false,
  }) async {
    if (!source.any((server) => server.tlsEnabled)) {
      return _CertificateBindingResolution(
        servers: source
            .map((server) => server.withoutRuntimeTlsPaths())
            .toList(growable: false),
        inventoryAvailable: true,
      );
    }
    late final CertificateInventory inventory;
    try {
      inventory = await _certificateBackend.listInventory();
    } catch (_) {
      // Native inventory failure is fail-closed: retain the opaque selection
      // for a later retry, but never keep usable file paths in memory.
      return _CertificateBindingResolution(
        servers: source
            .map((server) => server.withoutRuntimeTlsPaths())
            .toList(growable: false),
        inventoryAvailable: false,
      );
    }
    return _CertificateBindingResolution(
      servers: source
          .map(
            (server) => CertificateBindingResolver.resolve(
              server,
              inventory,
              allowLegacyPathMigration: allowLegacyPathMigration,
            ),
          )
          .toList(growable: false),
      inventoryAvailable: true,
    );
  }

  static bool _needsLegacyPathMigration(List<ServerConfig> source) =>
      source.any(
        (server) =>
            server.tlsEnabled &&
            server.tlsIdentityId.trim().isEmpty &&
            server.hasLegacyTlsPaths,
      );

  Future<ServerConfig> _verifyServerBindingForSave(ServerConfig server) async {
    if (!server.tlsEnabled || server.tlsIdentityId.trim().isEmpty) {
      return server.withoutRuntimeTlsPaths();
    }
    if (_invalidatedCertificateIdentityIds.contains(server.tlsIdentityId)) {
      if (!_certificateIdentityRollbackCandidates.contains(
        server.tlsIdentityId,
      )) {
        throw const CertificateBindingException(
          'The selected certificate identity was deleted.',
        );
      }
      final rollbackResolution = await _resolveCertificateBindings([server]);
      if (!rollbackResolution.inventoryAvailable) {
        throw const CertificateBindingException(
          'Certificate inventory is unavailable. Try saving again.',
        );
      }
      final restored = rollbackResolution.servers.single;
      if (restored.tlsIdentityId.isEmpty) {
        _certificateIdentityRollbackCandidates.remove(server.tlsIdentityId);
        throw const CertificateBindingException(
          'The selected certificate identity was deleted.',
        );
      }
      _invalidatedCertificateIdentityIds.remove(server.tlsIdentityId);
      _certificateIdentityRollbackCandidates.remove(server.tlsIdentityId);
      return restored;
    }
    // ServerEditDialog resolves ready identities immediately before saving.
    // Avoid a second native read while retaining the in-process deletion
    // tombstone above; unresolved persisted identities still require a fresh
    // inventory check.
    if (server.hasResolvedTlsCredentials) return server;
    final resolution = await _resolveCertificateBindings([server]);
    if (!resolution.inventoryAvailable) {
      throw const CertificateBindingException(
        'Certificate inventory is unavailable. Try saving again.',
      );
    }
    final verified = resolution.servers.single;
    if (verified.tlsIdentityId.isEmpty) {
      throw const CertificateBindingException(
        'The selected certificate identity no longer exists.',
      );
    }
    return verified;
  }

  bool _isRuntimeConfig(FrpConfig config) =>
      config.serverId.isEmpty || config.serverId == _selectedServerId;

  bool _belongsToServer(FrpConfig config, ServerConfig server) =>
      config.serverId == server.serverId ||
      (config.serverId.isEmpty && server.serverId == _selectedServerId);

  Future<void> _persistConfigs(
    List<FrpConfig> nextConfigs, {
    required bool restartRuntime,
  }) async {
    final runtimeTicket = await _pauseRuntimeForMutation(restartRuntime);
    try {
      await _persistAndCommit(_configuration(configs: nextConfigs));
      notifyListeners();
    } catch (_) {
      await _resumeRuntimeAfterMutation(
        runtimeTicket,
        configurationChanged: false,
        resumePreviousIntent: true,
      );
      rethrow;
    }
    await _resumeRuntimeAfterMutation(
      runtimeTicket,
      configurationChanged: true,
      resumePreviousIntent: true,
    );
  }

  Future<void> addConfig(FrpConfig config) => _serializeMutation(() async {
    await _ensureInitialized();
    _requireValidConfig(config);
    final maxId = configs.fold<int>(0, (m, e) => e.id > m ? e.id : m);
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = config.copyWith(id: maxId + 1, createdAt: now, updatedAt: now);
    await _persistConfigs([...configs, c], restartRuntime: _isRuntimeConfig(c));
  });

  Future<void> updateConfig(FrpConfig config) => _serializeMutation(() async {
    await _ensureInitialized();
    _requireValidConfig(config);
    final i = configs.indexWhere((e) => e.id == config.id);
    if (i < 0) return;
    final previous = configs[i];
    final nextConfigs = List<FrpConfig>.of(configs);
    nextConfigs[i] = config.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistConfigs(
      nextConfigs,
      restartRuntime:
          _isRuntimeConfig(previous) || _isRuntimeConfig(nextConfigs[i]),
    );
  });

  /// Atomically replaces a logical set of form configurations.
  ///
  /// Existing IDs retain their creation timestamps, while newly-added
  /// protocol members receive fresh IDs. This lets the form editor update an
  /// entire multi-protocol group without exposing a partially-written group
  /// between individual add/update operations.
  Future<void> replaceConfigSet({
    required Set<int> existingIds,
    required List<FrpConfig> replacements,
    int renameGroupId = 0,
    String? renameGroupName,
  }) => _serializeMutation(() async {
    await _ensureInitialized();

    for (final replacement in replacements) {
      _requireValidConfig(replacement);
    }

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
    var retained = configs
        .where((config) => !existingIds.contains(config.id))
        .toList();
    if (insertAt < 0 || insertAt > retained.length) insertAt = retained.length;
    retained.insertAll(insertAt, prepared);
    if (renameGroupId > 0 && renameGroupName != null) {
      retained = retained
          .map(
            (config) => config.groupId == renameGroupId
                ? config.copyWith(groupName: renameGroupName)
                : config,
          )
          .toList(growable: false);
    }
    await _persistConfigs(
      retained,
      restartRuntime:
          existingById.values.any(_isRuntimeConfig) ||
          prepared.any(_isRuntimeConfig),
    );
  });

  Future<void> deleteConfig(int id) => _serializeMutation(() async {
    await _ensureInitialized();
    final removed = configs.where((config) => config.id == id).toList();
    await _persistConfigs(
      configs.where((config) => config.id != id).toList(growable: false),
      restartRuntime: removed.any(_isRuntimeConfig),
    );
  });

  Future<void> setConfigEnabled(int id, bool enabled) =>
      _serializeMutation(() async {
        await _ensureInitialized();
        final i = configs.indexWhere((e) => e.id == id);
        if (i < 0) return;
        final restartRuntime = _isRuntimeConfig(configs[i]);
        final nextConfigs = List<FrpConfig>.of(configs);
        nextConfigs[i] = nextConfigs[i].copyWith(enabled: enabled);
        await _persistConfigs(nextConfigs, restartRuntime: restartRuntime);
      });

  Future<void> setGroupEnabled(int groupId, bool enabled) =>
      _serializeMutation(() async {
        await _ensureInitialized();
        final restartRuntime = configs.any(
          (config) => config.groupId == groupId && _isRuntimeConfig(config),
        );
        final nextConfigs = configs
            .map((e) => e.groupId == groupId ? e.copyWith(enabled: enabled) : e)
            .toList();
        await _persistConfigs(nextConfigs, restartRuntime: restartRuntime);
      });

  Future<void> deleteGroup(int groupId) => _serializeMutation(() async {
    await _ensureInitialized();
    final removed = configs.where((config) => config.groupId == groupId);
    await _persistConfigs(
      configs
          .where((config) => config.groupId != groupId)
          .toList(growable: false),
      restartRuntime: removed.any(_isRuntimeConfig),
    );
  });

  Future<void> renameGroup(int groupId, String name) =>
      _serializeMutation(() async {
        await _ensureInitialized();
        final restartRuntime = configs.any(
          (config) => config.groupId == groupId && _isRuntimeConfig(config),
        );
        final nextConfigs = configs
            .map((e) => e.groupId == groupId ? e.copyWith(groupName: name) : e)
            .toList();
        await _persistConfigs(nextConfigs, restartRuntime: restartRuntime);
      });

  Future<void> syncLinkedFallback(FrpConfig primary) =>
      _serializeMutation(() async {
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
        final nextConfigs = List<FrpConfig>.of(configs);
        for (final config in linked) {
          final i = nextConfigs.indexOf(config);
          nextConfigs[i] = config.copyWith(
            serverName: derived.serverName,
            secretKey: derived.secretKey,
            useEncryption: derived.useEncryption,
            useCompression: derived.useCompression,
          );
        }
        await _persistConfigs(
          nextConfigs,
          restartRuntime: linked.any(_isRuntimeConfig),
        );
      });

  Future<void> syncLinkedStcp(FrpConfig primary) => syncLinkedFallback(primary);

  FrpConfig createLinkedFallbackConfig(FrpConfig primary) {
    return ConfigDomainService.createLinkedFallbackConfig(primary);
  }

  FrpConfig createLinkedStcpConfig(FrpConfig xtcp) {
    return createLinkedFallbackConfig(xtcp);
  }

  void _requireValidServer(ServerConfig server) {
    final error = server.storageValidationError();
    if (error != null) throw FormatException(error);
  }

  void _requireValidConfig(FrpConfig config) {
    final error = ConfigValidator.validate(config);
    if (error != null) throw FormatException(error);
    if (config.serverId.isNotEmpty &&
        !servers.any((server) => server.serverId == config.serverId)) {
      throw const FormatException('Proxy references an unknown Server ID');
    }
  }

  /// 分组聚合：用于仪表盘 Applications 列表
  /// 状态优先级：Error > P2P(XTCP) > RELAY(STCP) > 未连接
  List<AppRow> buildAppRows() {
    return ConfigDomainService.buildAppRowsForServer(
      configs,
      appStatuses,
      _selectedServerId,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _runRequested = false;
    _lifecycleGeneration++;
    _pollingEnabled = false;
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
