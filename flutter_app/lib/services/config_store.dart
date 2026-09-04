import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';
import 'config_validator.dart';

enum ConfigStoreFailure { decrypt, corrupt, migrate }

class ConfigStoreException implements Exception {
  const ConfigStoreException(this.failure, this.key, this.cause);

  final ConfigStoreFailure failure;
  final String key;
  final Object? cause;

  String get userMessage => switch (failure) {
    ConfigStoreFailure.decrypt => 'Saved configuration could not be decrypted. Original data was preserved.',
    ConfigStoreFailure.corrupt => 'Saved configuration is damaged or unsupported. Original data was preserved.',
    ConfigStoreFailure.migrate => 'Saved configuration could not be secured with Android Keystore. Original data was preserved.',
  };

  @override
  String toString() => 'ConfigStoreException($failure, $key)';
}

/// The configuration domain is persisted as one encrypted value so a crash or
/// failed write cannot leave servers, proxies, and the selected server out of
/// sync with each other.
class ConfigurationSnapshot {
  static const currentVersion = 1;

  const ConfigurationSnapshot({
    this.version = currentVersion,
    required this.servers,
    required this.selectedServerId,
    required this.configs,
  });

  final int version;
  final List<ServerConfig> servers;
  final String selectedServerId;
  final List<FrpConfig> configs;

  Map<String, dynamic> toJson() => {
    'version': version,
    'servers': servers.map((server) => server.toJson()).toList(),
    'selectedServerId': selectedServerId,
    'configs': configs.map((config) => config.toJson()).toList(),
  };

  factory ConfigurationSnapshot.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! int || version != currentVersion) {
      throw const FormatException('unsupported configuration snapshot');
    }
    final rawServers = json['servers'];
    final rawConfigs = json['configs'];
    final selectedServerId = json['selectedServerId'];
    if (rawServers is! List<dynamic> ||
        rawConfigs is! List<dynamic> ||
        selectedServerId is! String) {
      throw const FormatException('invalid configuration snapshot shape');
    }
    if (rawServers.isEmpty || rawServers.length > 256) {
      throw const FormatException(
        'configuration must contain between 1 and 256 servers',
      );
    }
    if (rawConfigs.length > 4096) {
      throw const FormatException('too many proxy records');
    }
    if (rawServers.any((entry) => entry is! Map) ||
        rawConfigs.any((entry) => entry is! Map)) {
      throw const FormatException('invalid configuration snapshot shape');
    }
    return ConfigurationSnapshot(
      version: version,
      servers: rawServers
          .map(
            (entry) =>
                ServerConfig.fromJson((entry as Map).cast<String, dynamic>()),
          )
          .toList(growable: false),
      selectedServerId: selectedServerId,
      configs: rawConfigs
          .map(
            (entry) =>
                FrpConfig.fromJson((entry as Map).cast<String, dynamic>()),
          )
          .toList(growable: false),
    );
  }
}

class _SensitiveValue {
  const _SensitiveValue(this.value, {required this.isLegacyPlaintext});

  final String value;
  final bool isLegacyPlaintext;
}

/// Sensitive JSON is encrypted by an Android Keystore-backed key before it is
/// placed in SharedPreferences. Existing plaintext values migrate on read.
class ConfigStore {
  static const _secureChannel = MethodChannel('com.frp.app/secure_store');
  static const _encryptedPrefix = 'enc:v1:';
  static const _maxSensitivePlaintextBytes = 5 * 1024 * 1024;
  static const _maxEncryptedValueCharacters = 7 * 1024 * 1024;
  static const _kConfigs = 'frp_configs_v2';
  static const _kServer = 'server_config_v2';
  static const _kServers = 'server_configs_v2';
  static const _kSelectedServerId = 'selected_server_id_v2';
  static const _kConfigurationSnapshot = 'configuration_snapshot_v1';
  static const _kHideFromRecents = 'hide_from_recents';
  static const _kThemeMode = 'theme_mode';
  static const _kThemeAccent = 'theme_accent';
  static const _kBatteryHintShown = 'battery_hint_shown';

  static Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<_SensitiveValue?> _readSensitive(String key) async {
    final prefs = await _prefs();
    final Object? stored;
    try {
      stored = prefs.get(key);
    } catch (error) {
      throw ConfigStoreException(ConfigStoreFailure.corrupt, key, error);
    }
    if (stored == null) return null;
    if (stored is! String || stored.isEmpty) {
      throw ConfigStoreException(
        ConfigStoreFailure.corrupt,
        key,
        const FormatException(
          'stored configuration must be a non-empty string',
        ),
      );
    }
    final raw = stored;
    if (!raw.startsWith(_encryptedPrefix)) {
      try {
        _requireBoundedSensitivePlaintext(raw);
      } catch (error) {
        throw ConfigStoreException(ConfigStoreFailure.corrupt, key, error);
      }
      return _SensitiveValue(raw, isLegacyPlaintext: true);
    }
    if (raw.length > _maxEncryptedValueCharacters) {
      throw ConfigStoreException(
        ConfigStoreFailure.corrupt,
        key,
        const FormatException('encrypted configuration is too large'),
      );
    }
    try {
      final decrypted = await _secureChannel.invokeMethod<String>('decrypt', {
        'value': raw.substring(_encryptedPrefix.length),
      });
      if (decrypted == null || decrypted.isEmpty) {
        throw StateError('Android Keystore decryption returned no data');
      }
      _requireBoundedSensitivePlaintext(decrypted);
      return _SensitiveValue(decrypted, isLegacyPlaintext: false);
    } catch (error) {
      throw ConfigStoreException(ConfigStoreFailure.decrypt, key, error);
    }
  }

  Future<void> _writeSensitive(String key, String value) async {
    _requireBoundedSensitivePlaintext(value);
    final encrypted = await _secureChannel.invokeMethod<String>('encrypt', {
      'value': value,
    });
    if (encrypted == null || encrypted.isEmpty) {
      throw StateError('Android Keystore encryption returned no data');
    }
    if (encrypted.length > _maxEncryptedValueCharacters) {
      throw const FormatException('encrypted configuration is too large');
    }
    final saved = await (await _prefs()).setString(
      key,
      '$_encryptedPrefix$encrypted',
    );
    if (!saved) {
      throw StateError('SharedPreferences refused the encrypted data');
    }
  }

  static void _requireBoundedSensitivePlaintext(String value) {
    // UTF-8 uses at least one byte per Dart code unit. Reject an obviously
    // oversized persisted value before allocating a second multi-megabyte
    // buffer solely to measure it.
    if (value.isEmpty || value.length > _maxSensitivePlaintextBytes) {
      throw const FormatException('configuration payload size is invalid');
    }
    final encoded = utf8.encode(value);
    try {
      if (encoded.length > _maxSensitivePlaintextBytes) {
        throw const FormatException('configuration payload size is invalid');
      }
    } finally {
      encoded.fillRange(0, encoded.length, 0);
    }
  }

  Future<void> _requireSaved(Future<bool> operation) async {
    if (!await operation) {
      throw StateError('SharedPreferences refused the setting update');
    }
  }

  Future<void> _migratePlaintext(
    String key,
    _SensitiveValue value,
    Future<void> Function() save,
  ) async {
    if (!value.isLegacyPlaintext) return;
    try {
      await save();
    } catch (error) {
      throw ConfigStoreException(ConfigStoreFailure.migrate, key, error);
    }
  }

  Future<ConfigurationSnapshot?> loadConfigurationSnapshot() async {
    final raw = await _readSensitive(_kConfigurationSnapshot);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw.value);
      if (decoded is! Map) {
        throw const FormatException('configuration snapshot must be an object');
      }
      final snapshot = ConfigurationSnapshot.fromJson(
        decoded.cast<String, dynamic>(),
      );
      _validateConfigurationSnapshot(snapshot);
      await _migratePlaintext(
        _kConfigurationSnapshot,
        raw,
        () => _writeSensitive(
          _kConfigurationSnapshot,
          jsonEncode(_legacySnapshotRecoveryJson(snapshot)),
        ),
      );
      return snapshot;
    } on ConfigStoreException {
      rethrow;
    } catch (error) {
      throw ConfigStoreException(
        ConfigStoreFailure.corrupt,
        _kConfigurationSnapshot,
        error,
      );
    }
  }

  Future<void> saveConfigurationSnapshot(ConfigurationSnapshot snapshot) async {
    _validateConfigurationSnapshot(snapshot);
    await _writeSensitive(
      _kConfigurationSnapshot,
      jsonEncode(snapshot.toJson()),
    );
  }

  void _validateConfigurationSnapshot(ConfigurationSnapshot snapshot) {
    if (snapshot.version != ConfigurationSnapshot.currentVersion) {
      throw const FormatException('unsupported configuration snapshot');
    }
    if (snapshot.servers.isEmpty || snapshot.servers.length > 256) {
      throw const FormatException(
        'configuration must contain between 1 and 256 servers',
      );
    }
    if (snapshot.configs.length > 4096) {
      throw const FormatException('too many proxy records');
    }

    final serverIds = <String>{};
    for (final server in snapshot.servers) {
      final error = server.storageValidationError();
      if (error != null || !serverIds.add(server.serverId)) {
        throw FormatException(error ?? 'duplicate Server ID');
      }
    }
    if (!serverIds.contains(snapshot.selectedServerId)) {
      throw const FormatException('selected Server ID is not present');
    }

    final configIds = <int>{};
    for (final config in snapshot.configs) {
      final error = ConfigValidator.validate(
        config,
        allowMissingSecrets: !config.enabled,
        allowIncompleteLegacy: !config.enabled,
      );
      if (error != null) throw FormatException(error);
      if (config.id <= 0 || !configIds.add(config.id)) {
        throw const FormatException('proxy IDs must be positive and unique');
      }
      if (config.serverId.isNotEmpty && !serverIds.contains(config.serverId)) {
        throw const FormatException('Proxy references an unknown Server ID');
      }
    }
  }

  Future<List<FrpConfig>> loadConfigs() async {
    final raw = await _readSensitive(_kConfigs);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw.value);
      if (decoded is! List<dynamic> || decoded.any((entry) => entry is! Map)) {
        throw const FormatException('configs must be a list of objects');
      }
      final list = decoded;
      if (list.length > 4096) {
        throw const FormatException('too many proxy records');
      }
      final result = list
          .map((e) => FrpConfig.fromJson((e as Map).cast<String, dynamic>()))
          .toList(growable: false);
      for (final config in result) {
        final error = ConfigValidator.validate(
          config,
          allowMissingSecrets: !config.enabled,
          allowIncompleteLegacy: !config.enabled,
        );
        if (error != null) throw FormatException(error);
      }
      await _migratePlaintext(_kConfigs, raw, () => saveConfigs(result));
      return result;
    } on ConfigStoreException {
      rethrow;
    } catch (error) {
      throw ConfigStoreException(ConfigStoreFailure.corrupt, _kConfigs, error);
    }
  }

  Future<void> saveConfigs(List<FrpConfig> configs) async {
    if (configs.length > 4096) {
      throw const FormatException('too many proxy records');
    }
    for (final config in configs) {
      final error = ConfigValidator.validate(
        config,
        allowMissingSecrets: !config.enabled,
        allowIncompleteLegacy: !config.enabled,
      );
      if (error != null) throw FormatException(error);
    }
    await _writeSensitive(
      _kConfigs,
      jsonEncode(configs.map((e) => e.toJson()).toList()),
    );
  }

  Future<ServerConfig?> loadServer() async {
    final raw = await _readSensitive(_kServer);
    if (raw == null) return null;
    try {
      final result = ServerConfig.fromJson(
        (jsonDecode(raw.value) as Map).cast<String, dynamic>(),
      );
      final validationError = result.storageValidationError(
        requireServerId: false,
      );
      if (validationError != null) throw FormatException(validationError);
      await _migratePlaintext(
        _kServer,
        raw,
        () => _writeSensitive(
          _kServer,
          jsonEncode(_legacyServerRecoveryJson(result)),
        ),
      );
      return result;
    } on ConfigStoreException {
      rethrow;
    } catch (error) {
      throw ConfigStoreException(ConfigStoreFailure.corrupt, _kServer, error);
    }
  }

  Future<void> saveServer(ServerConfig server) async {
    final error = server.storageValidationError(requireServerId: false);
    if (error != null) throw FormatException(error);
    await _writeSensitive(_kServer, jsonEncode(server.toJson()));
  }

  Future<List<ServerConfig>> loadServers() async {
    final raw = await _readSensitive(_kServers);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw.value);
      if (decoded is! List<dynamic> || decoded.any((entry) => entry is! Map)) {
        throw const FormatException('servers must be a list of objects');
      }
      final list = decoded;
      if (list.length > 256) {
        throw const FormatException('too many server records');
      }
      final result = list
          .map((e) => ServerConfig.fromJson((e as Map).cast<String, dynamic>()))
          .toList(growable: false);
      final serverIDs = <String>{};
      for (final server in result) {
        final error = server.storageValidationError();
        if (error != null || !serverIDs.add(server.serverId)) {
          throw FormatException(error ?? 'duplicate Server ID');
        }
      }
      await _migratePlaintext(
        _kServers,
        raw,
        () => _writeSensitive(
          _kServers,
          jsonEncode(result.map(_legacyServerRecoveryJson).toList()),
        ),
      );
      return result;
    } on ConfigStoreException {
      rethrow;
    } catch (error) {
      throw ConfigStoreException(ConfigStoreFailure.corrupt, _kServers, error);
    }
  }

  Future<void> saveServers(List<ServerConfig> servers) async {
    if (servers.length > 256) {
      throw const FormatException('too many server records');
    }
    final serverIDs = <String>{};
    for (final server in servers) {
      final error = server.storageValidationError();
      if (error != null || !serverIDs.add(server.serverId)) {
        throw FormatException(error ?? 'duplicate Server ID');
      }
    }
    await _writeSensitive(
      _kServers,
      jsonEncode(servers.map((e) => e.toJson()).toList()),
    );
  }

  /// Plaintext-to-encrypted legacy migration must preserve the former TLS
  /// paths until AppState has resolved them to a managed identity and committed
  /// the new atomic snapshot. Normal saves intentionally never persist paths.
  static Map<String, dynamic> _legacyServerRecoveryJson(ServerConfig server) {
    final json = server.toJson();
    if (server.tlsCertFile.isNotEmpty) {
      json['tlsCertFile'] = server.tlsCertFile;
    }
    if (server.tlsKeyFile.isNotEmpty) {
      json['tlsKeyFile'] = server.tlsKeyFile;
    }
    if (server.tlsTrustedCaFile.isNotEmpty) {
      json['tlsTrustedCaFile'] = server.tlsTrustedCaFile;
    }
    return json;
  }

  static Map<String, dynamic> _legacySnapshotRecoveryJson(
    ConfigurationSnapshot snapshot,
  ) => {
    'version': snapshot.version,
    'servers': snapshot.servers.map(_legacyServerRecoveryJson).toList(),
    'selectedServerId': snapshot.selectedServerId,
    'configs': snapshot.configs.map((config) => config.toJson()).toList(),
  };

  Future<String> loadSelectedServerId() async =>
      (await _prefs()).getString(_kSelectedServerId) ?? '';

  Future<void> saveSelectedServerId(String id) async {
    if (id.isNotEmpty && !RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(id)) {
      throw const FormatException('Selected Server ID is invalid');
    }
    await _requireSaved((await _prefs()).setString(_kSelectedServerId, id));
  }

  Future<bool> loadHideFromRecents() async =>
      (await _prefs()).getBool(_kHideFromRecents) ?? false;

  Future<void> saveHideFromRecents(bool v) async =>
      _requireSaved((await _prefs()).setBool(_kHideFromRecents, v));

  Future<ThemeMode> loadThemeMode() async {
    final v = (await _prefs()).getString(_kThemeMode);
    return switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    await _requireSaved(
      (await _prefs()).setString(_kThemeMode, switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      }),
    );
  }

  Future<bool> loadBatteryHintShown() async =>
      (await _prefs()).getBool(_kBatteryHintShown) ?? false;

  Future<void> saveBatteryHintShown(bool v) async =>
      _requireSaved((await _prefs()).setBool(_kBatteryHintShown, v));

  Future<int> loadThemeAccent() async {
    final accent = (await _prefs()).getInt(_kThemeAccent);
    return accent != null && accent >= 0 && accent <= 6 ? accent : 0;
  }

  Future<void> saveThemeAccent(int accent) async {
    if (accent < 0 || accent > 6) {
      throw const FormatException('Theme accent is invalid');
    }
    await _requireSaved((await _prefs()).setInt(_kThemeAccent, accent));
  }
}
