import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';

/// Sensitive JSON is encrypted by an Android Keystore-backed key before it is
/// placed in SharedPreferences. Existing plaintext values migrate on read.
class ConfigStore {
  static const _secureChannel = MethodChannel('com.frp.app/secure_store');
  static const _encryptedPrefix = 'enc:v1:';
  static const _kConfigs = 'frp_configs_v2';
  static const _kServer = 'server_config_v2';
  static const _kServers = 'server_configs_v2';
  static const _kSelectedServerId = 'selected_server_id_v2';
  static const _kHideFromRecents = 'hide_from_recents';
  static const _kThemeMode = 'theme_mode';
  static const _kThemeAccent = 'theme_accent';
  static const _kBatteryHintShown = 'battery_hint_shown';

  static Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<String?> _readSensitive(String key) async {
    final prefs = await _prefs();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    if (!raw.startsWith(_encryptedPrefix)) return raw;
    return _secureChannel.invokeMethod<String>('decrypt', {
      'value': raw.substring(_encryptedPrefix.length),
    });
  }

  Future<void> _writeSensitive(String key, String value) async {
    final encrypted = await _secureChannel.invokeMethod<String>('encrypt', {
      'value': value,
    });
    if (encrypted == null || encrypted.isEmpty) {
      throw StateError('Android Keystore encryption returned no data');
    }
    await (await _prefs()).setString(key, '$_encryptedPrefix$encrypted');
  }

  Future<List<FrpConfig>> loadConfigs() async {
    final raw = await _readSensitive(_kConfigs);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final result = list
          .map((e) => FrpConfig.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      if (!(await _prefs())
          .getString(_kConfigs)!
          .startsWith(_encryptedPrefix)) {
        try {
          await saveConfigs(result);
        } catch (_) {
          // Preserve readable legacy data and retry migration on the next read.
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveConfigs(List<FrpConfig> configs) async {
    await _writeSensitive(
      _kConfigs,
      jsonEncode(configs.map((e) => e.toJson()).toList()),
    );
  }

  Future<ServerConfig?> loadServer() async {
    final raw = await _readSensitive(_kServer);
    if (raw == null || raw.isEmpty) return null;
    try {
      final result = ServerConfig.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
      if (!(await _prefs()).getString(_kServer)!.startsWith(_encryptedPrefix)) {
        try {
          await saveServer(result);
        } catch (_) {
          // Preserve readable legacy data and retry migration on the next read.
        }
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveServer(ServerConfig server) async {
    await _writeSensitive(_kServer, jsonEncode(server.toJson()));
  }

  Future<List<ServerConfig>> loadServers() async {
    final raw = await _readSensitive(_kServers);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final result = list
          .map((e) => ServerConfig.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      if (!(await _prefs())
          .getString(_kServers)!
          .startsWith(_encryptedPrefix)) {
        try {
          await saveServers(result);
        } catch (_) {
          // Preserve readable legacy data and retry migration on the next read.
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveServers(List<ServerConfig> servers) async {
    await _writeSensitive(
      _kServers,
      jsonEncode(servers.map((e) => e.toJson()).toList()),
    );
  }

  Future<String> loadSelectedServerId() async =>
      (await _prefs()).getString(_kSelectedServerId) ?? '';

  Future<void> saveSelectedServerId(String id) async =>
      (await _prefs()).setString(_kSelectedServerId, id);

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

  Future<bool> loadBatteryHintShown() async =>
      (await _prefs()).getBool(_kBatteryHintShown) ?? false;

  Future<void> saveBatteryHintShown(bool v) async =>
      (await _prefs()).setBool(_kBatteryHintShown, v);

  Future<int> loadThemeAccent() async =>
      (await _prefs()).getInt(_kThemeAccent) ?? 0;

  Future<void> saveThemeAccent(int accent) async =>
      (await _prefs()).setInt(_kThemeAccent, accent);
}
