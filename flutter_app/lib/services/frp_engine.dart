import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/connection_status.dart';
import 'stun_server_selector.dart';

typedef RuntimeLog = ({int id, String line});

/// frpc 引擎：通过 MethodChannel 调用原生 frpc 进程，并接收状态/日志事件
class FrpEngine {
  FrpEngine._()
    : this.withChannel(
        const MethodChannel('com.frp.app/engine'),
        nativeLogHistory: kReleaseMode,
      );

  @visibleForTesting
  FrpEngine.withChannel(this._channel, {required bool nativeLogHistory})
    : _logs = nativeLogHistory ? null : ListQueue<RuntimeLog>() {
    _channel.setMethodCallHandler(_onNativeCall);
    if (nativeLogHistory) {
      _logController.onListen = () => unawaited(_setLogSubscription(true));
      _logController.onCancel = () => unawaited(_setLogSubscription(false));
    }
  }
  static final FrpEngine instance = FrpEngine._();

  final MethodChannel _channel;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  final _appStatusesController =
      StreamController<Map<String, ConnectionType>>.broadcast();
  Stream<Map<String, ConnectionType>> get appStatusesStream =>
      _appStatusesController.stream;

  final _logController = StreamController<RuntimeLog>.broadcast();
  Stream<RuntimeLog> get logStream => _logController.stream;

  ConnectionStatus _serverStatus = const ConnectionStatus();
  ConnectionStatus get serverStatus => _serverStatus;

  Map<String, ConnectionType> _appStatuses = {};
  Map<String, ConnectionType> get appStatuses => _appStatuses;

  final ListQueue<RuntimeLog>? _logs;
  List<RuntimeLog> get logs =>
      _logs == null ? const [] : List.unmodifiable(_logs);

  Future<void> _setLogSubscription(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setLogSubscription', enabled);
    } on MissingPluginException {
      // The activity can detach while the log route is closing.
    } on PlatformException {
      // The native service still owns the history for the next snapshot.
    }
  }

  Iterable<RuntimeLog> _rows(int firstId, List<Object?> lines) sync* {
    for (var i = 0; i < lines.length; i++) {
      yield (id: firstId + i, line: lines[i] as String);
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onStatus':
        final scope = (call.arguments as Map)['scope'] as String?;
        final type = (call.arguments as Map)['type'] as String? ?? '';
        final detail = (call.arguments as Map)['detail'] as String? ?? '';
        if (scope == 'server') {
          _serverStatus = ConnectionStatus(_mapType(type), detail);
          _statusController.add(_serverStatus);
        }
        break;
      case 'onAppStatus':
        final name = (call.arguments as Map)['name'] as String? ?? '';
        final type = (call.arguments as Map)['type'] as String? ?? '';
        if (type == 'reset') {
          _appStatuses = {};
        } else if (name.isNotEmpty) {
          _appStatuses = {..._appStatuses, name: _mapType(type)};
        }
        _appStatusesController.add(_appStatuses);
        break;
      case 'onLog':
        final [int id, String line] = call.arguments as List;
        final record = (id: id, line: line);
        final logs = _logs;
        if (logs != null) {
          logs.add(record);
          if (logs.length > 2000) logs.removeFirst();
        }
        _logController.add(record);
        break;
      case 'onLogBatch':
        if (!_logController.hasListener) break;
        if (call.arguments case {'firstId': int firstId, 'lines': List lines}) {
          for (final row in _rows(firstId, lines)) {
            _logController.add(row);
          }
        }
        break;
    }
  }

  ConnectionType _mapType(String type) => switch (type) {
    'connected' => ConnectionType.connected,
    'connecting' => ConnectionType.connecting,
    'p2p' => ConnectionType.p2p,
    'relay' => ConnectionType.relay,
    'error' => ConnectionType.error,
    _ => ConnectionType.unknown,
  };

  Future<void> requestTunnelPermissions() =>
      _channel.invokeMethod<void>('requestTunnelPermissions');

  /// 启动 frpc。TOML 只在原生服务内短暂落盘，避免 Dart 层留下明文文件。
  Future<bool> start(
    String configContent, {
    List<Map<String, dynamic>> socks5Forwards = const [],
  }) async {
    try {
      final ok =
          await _channel.invokeMethod<bool>('start', {
            'configContent': configContent,
            if (socks5Forwards.isNotEmpty) 'socks5Forwards': socks5Forwards,
          }) ??
          false;
      return ok;
    } catch (_) {
      _serverStatus = const ConnectionStatus(
        ConnectionType.error,
        'Engine unavailable',
      );
      _statusController.add(_serverStatus);
      return false;
    }
  }

  Future<StunProbeResult> probeStun(String endpoint) async {
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'probeStun',
      {'endpoint': endpoint},
    );
    return StunProbeResult.fromMap(response ?? const {});
  }

  Future<void> stop() async {
    final stopped = await _channel.invokeMethod<bool>('stop');
    if (stopped != true) throw StateError('frpc stop was not accepted');
  }

  /// Reads the persisted foreground-service intent after an Activity/Dart
  /// isolate recreation. This closes the gap before native status replay.
  Future<bool> getRunRequested() async {
    return await queryRunRequested() ?? false;
  }

  /// Reads native intent without treating an unavailable channel as Stop.
  ///
  /// Runtime status reconciliation must distinguish an authoritative `false`
  /// from a transient Activity/channel failure, otherwise a connection error
  /// could make the UI discard a still-recoverable native run intent.
  Future<bool?> queryRunRequested() async {
    try {
      return await _channel.invokeMethod<bool>('isRunRequested');
    } catch (_) {
      return null;
    }
  }

  /// 隐藏/恢复最近任务卡片
  Future<void> setExcludeFromRecents(bool exclude) async {
    final applied = await _channel.invokeMethod<bool>('setExcludeFromRecents', {
      'exclude': exclude,
    });
    if (applied != true) {
      throw StateError('Recent-app visibility was not applied');
    }
  }

  /// 读取应用版本号（设置页 About 显示）
  Future<String> getVersionName() async {
    try {
      final v = await _channel.invokeMethod<String>('getVersionName');
      return v ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 读取启动 Intent 的 initial_tab（测试/截图用）
  Future<int> getInitialTab() async {
    try {
      final v = await _channel.invokeMethod<int>('getInitialTab');
      return v ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// App-private, Android-backup-excluded storage used by the certificate
  /// engine. The native layer owns the path so Dart never guesses an Android
  /// package directory.
  Future<String> getTlsStorageRoot() async {
    final path = await _channel.invokeMethod<String>('getTlsStorageRoot');
    if (path == null || path.isEmpty) {
      throw StateError('Certificate storage is unavailable');
    }
    return path;
  }

  Future<String> getIpv4() async {
    try {
      final v = await _channel.invokeMethod<String>('getIpv4');
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return '';
  }

  Future<String> getIpv6() async {
    try {
      final v = await _channel.invokeMethod<String>('getIpv6');
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return '';
  }

  /// 应用内存占用（MB）：Flutter 进程 RSS + frpc 子进程 RSS（参考 FlClash）
  Future<double> getMemoryMb() async {
    try {
      final v = await _channel.invokeMethod<double>('getMemoryMb');
      if (v != null) return v;
    } catch (_) {}
    return 0;
  }

  /// 引导用户取消本应用的电池优化/省电策略
  Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// 设备实际物理内存（MB）
  Future<double> getTotalMemoryMb() async {
    try {
      final v = await _channel.invokeMethod<double>('getTotalMemoryMb');
      if (v != null && v > 0) return v;
    } catch (_) {}
    return 0;
  }

  Future<List<RuntimeLog>> readLogSnapshot() async {
    try {
      final snapshot = await _channel.invokeMapMethod<String, Object?>(
        'readLogSnapshot',
      );
      if (snapshot case {'firstId': int firstId, 'lines': List lines}) {
        return _rows(firstId, lines).toList(growable: false);
      }
    } on PlatformException {
      // The Dart buffer still holds logs delivered while the channel was attached.
    } on MissingPluginException {
      // The caller may run without an attached Android activity.
    }
    return logs;
  }
}
