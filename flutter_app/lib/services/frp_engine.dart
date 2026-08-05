import 'dart:async';

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

  final List<String> _logs = [];
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
        if (_logs.length > 2000) _logs.removeAt(0);
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

  /// 启动 frpc，configPath 为 TOML 文件绝对路径
  Future<bool> start(String configPath) async {
    try {
      final ok = await _channel
              .invokeMethod<bool>('start', {'configPath': configPath}) ??
          false;
      return ok;
    } catch (_) {
      _serverStatus =
          const ConnectionStatus(ConnectionType.error, 'Engine unavailable');
      _statusController.add(_serverStatus);
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  /// 隐藏/恢复最近任务卡片
  Future<void> setExcludeFromRecents(bool exclude) async {
    try {
      await _channel
          .invokeMethod('setExcludeFromRecents', {'exclude': exclude});
    } catch (_) {}
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

  /// 应用自身内存（MB）：原生 PSS
  Future<double> getMemoryMb() async {
    try {
      final v = await _channel.invokeMethod<double>('getMemoryMb');
      if (v != null) return v;
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
