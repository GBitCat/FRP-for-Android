import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';

import '../models/connection_status.dart';

/// frpc 引擎：通过 MethodChannel 调用原生 frpc 进程，并接收状态/日志事件
class FrpEngine {
  FrpEngine._() {
    _channel.setMethodCallHandler(_onNativeCall);
  }
  static final FrpEngine instance = FrpEngine._();

  static const _channel = MethodChannel('com.frp.app/engine');

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get statusStream => _statusController.stream;

  final _appStatusesController =
      StreamController<Map<String, ConnectionType>>.broadcast();
  Stream<Map<String, ConnectionType>> get appStatusesStream =>
      _appStatusesController.stream;

  final _logController = StreamController<String>.broadcast();
  Stream<String> get logStream => _logController.stream;

  ConnectionStatus _serverStatus = const ConnectionStatus();
  ConnectionStatus get serverStatus => _serverStatus;

  Map<String, ConnectionType> _appStatuses = {};
  Map<String, ConnectionType> get appStatuses => _appStatuses;

  final ListQueue<String> _logs = ListQueue<String>();
  List<String> get logs => List.unmodifiable(_logs);

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
        final line = call.arguments as String? ?? '';
        _logs.add(line);
        if (_logs.length > 2000) _logs.removeFirst();
        _logController.add(line);
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

  /// 启动 frpc。TOML 只在原生服务内短暂落盘，避免 Dart 层留下明文文件。
  Future<bool> start(String configContent) async {
    try {
      final ok =
          await _channel.invokeMethod<bool>('start', {
            'configContent': configContent,
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

  Future<String> readLogs() async {
    try {
      final v = await _channel.invokeMethod<String>('readLogs');
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return _logs.join('\n');
  }
}
