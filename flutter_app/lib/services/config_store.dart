import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';

/// 本地存储：使用 SharedPreferences 保存 JSON（与原有字段结构一致）
class ConfigStore {
  static const _kConfigs = 'frp_configs_v2';
  static const _kServer = 'server_config_v2';
  static const _kServers = 'server_configs_v2';
  static const _kHideFromRecents = 'hide_from_recents';
  static const _kThemeMode = 'theme_mode';
  static const _kThemeAccent = 'theme_accent';

  static Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<List<FrpConfig>> loadConfigs() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kConfigs);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => FrpConfig.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveConfigs(List<FrpConfig> configs) async {
    final prefs = await _prefs();
    await prefs.setString(
      _kConfigs,
      jsonEncode(configs.map((e) => e.toJson()).toList()),
    );
  }

  Future<ServerConfig?> loadServer() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kServer);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ServerConfig.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveServer(ServerConfig server) async {
    final prefs = await _prefs();
    await prefs.setString(_kServer, jsonEncode(server.toJson()));
  }

  Future<List<ServerConfig>> loadServers() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kServers);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => ServerConfig.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveServers(List<ServerConfig> servers) async {
    final prefs = await _prefs();
    await prefs.setString(
      _kServers,
      jsonEncode(servers.map((e) => e.toJson()).toList()),
    );
  }

  Future<bool> loadHideFromRecents() async =>
      (await _prefs()).getBool(_kHideFromRecents) ?? false;

  Future<void> saveHideFromRecents(bool v) async =>
      (await _prefs()).setBool(_kHideFromRecents, v);

  Future<ThemeMode> loadThemeMode() async {
    final v = (await _prefs()).getString(_kThemeMode);
    return switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    await (await _prefs()).setString(_kThemeMode, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    });
  }

  Future<int> loadThemeAccent() async =>
      (await _prefs()).getInt(_kThemeAccent) ?? 0;

  Future<void> saveThemeAccent(int accent) async =>
      (await _prefs()).setInt(_kThemeAccent, accent);
}
