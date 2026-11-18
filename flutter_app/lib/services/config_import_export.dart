import 'dart:convert';
import 'dart:typed_data';

import '../models/frp_config.dart';
import '../models/server_config.dart';
import '../models/socks5_config.dart';
import 'config_validator.dart';
import 'limited_zip_reader.dart';
import 'toml_redaction.dart';
import 'wipeable_zip_builder.dart';

/// 导出数据：Server 配置 + 应用配置列表（与原有 ExportData 格式一致）
class ExportData {
  static const currentVersion = 4;

  final int version;
  final bool redacted;
  final List<ServerConfig> servers;
  final String selectedServerId;
  final List<FrpConfig> configs;

  const ExportData({
    this.version = currentVersion,
    this.redacted = false,
    this.servers = const [],
    this.selectedServerId = '',
    this.configs = const [],
  });

  /// 兼容旧调用方：单 Server 备份取第一条。
  ServerConfig? get server => servers.firstOrNull;

  Map<String, dynamic> toJson() => {
    'version': version,
    'redacted': redacted,
    'servers': servers.map((e) => e.toJson()).toList(),
    'selectedServerId': selectedServerId,
    'configs': configs.map((e) => e.toJson()).toList(),
  };

  factory ExportData.fromJson(Map<String, dynamic> j) {
    final version = (j['version'] as num?)?.toInt() ?? 1;
    final redacted = j['redacted'] as bool? ?? false;
    final rawServers = j['servers'] as List<dynamic>? ?? const [];
    if (rawServers.length > 256) {
      throw const FormatException('Too many server records');
    }
    if (rawServers.any((entry) => entry is! Map)) {
      throw const FormatException('Servers must be a list of objects');
    }
    final serverList = rawServers
        .map(
          (e) =>
              ServerConfig.fromJson((e as Map).cast<String, dynamic>())
                  .withoutRuntimeTlsPaths(),
        )
        .toList();
    // v1 备份只有 server 字段。
    if (serverList.isEmpty && j['server'] is Map) {
      serverList.add(
        ServerConfig.fromJson((j['server'] as Map).cast<String, dynamic>())
            .withoutRuntimeTlsPaths(),
      );
    }
    if (version == 1 &&
        serverList.length == 1 &&
        !RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(serverList.single.serverId)) {
      serverList[0] = serverList.single.copyWith(
        serverId: ServerConfig.generateId(),
      );
    }
    final serverIds = <String>{};
    for (final server in serverList) {
      final error = server.storageValidationError();
      if (error != null || !serverIds.add(server.serverId)) {
        throw FormatException(error ?? 'Duplicate Server ID');
      }
    }

    final rawConfigs = j['configs'] as List<dynamic>? ?? const [];
    if (rawConfigs.length > 4096) {
      throw const FormatException('Too many proxy records');
    }
    if (rawConfigs.any((entry) => entry is! Map)) {
      throw const FormatException('Configs must be a list of objects');
    }
    final configs = rawConfigs
        .map((e) => FrpConfig.fromJson((e as Map).cast<String, dynamic>()))
        .toList(growable: false);
    final configIds = <int>{};
    for (final config in configs) {
      if (version >= 2 && (config.id <= 0 || !configIds.add(config.id))) {
        throw const FormatException(
          'Modern backups require unique positive proxy IDs',
        );
      }
      final error = ConfigValidator.validateStored(
        config,
        redacted: redacted,
        legacy: version == 1,
      );
      if (error != null) throw FormatException(error);
      if (config.serverId.isNotEmpty && !serverIds.contains(config.serverId)) {
        throw const FormatException('Proxy references an unknown Server ID');
      }
    }
    final selected = j['selectedServerId'] as String? ?? '';
    return ExportData(
      version: version,
      redacted: redacted,
      servers: serverList,
      selectedServerId: serverList.any((e) => e.serverId == selected)
          ? selected
          : (serverList.firstOrNull?.serverId ?? ''),
      configs: configs,
    );
  }
}

/// 导入导出：zip（frp_configs.json + frpc_all.toml）/ 纯 JSON，兼容旧格式
class ConfigImportExport {
  static const maxImportBytes = 5 * 1024 * 1024;
  static const maxJsonBytes = 2 * 1024 * 1024;
  static const maxArchiveEntries = 64;
  static const maxArchiveExpandedBytes = 32 * 1024 * 1024;

  /// Preserve manual proxy/visitor structure while clearing recognized
  /// credential assignments. Comments are omitted because free-form comment
  /// text cannot be reliably classified as non-sensitive.
  static String _redactManualToml(String toml) {
    for (final line in toml.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) {
        continue;
      }

      // Keep the portable redacted format's existing restrictions. The shared
      // TOML redactor below parses accepted documents and strips comments.
      if (_containsTomlMultilineDelimiter(line)) {
        throw StateError(
          'Redacted export cannot safely process multiline TOML strings. '
          'Use single-line strings or encrypted export.',
        );
      }

      final separator = _findTomlAssignmentSeparator(line);
      if (separator > 0 && line.substring(0, separator).contains(r'\')) {
        throw StateError(
          'Redacted export cannot safely process escaped TOML keys. '
          'Use a plain key or encrypted export.',
        );
      }
    }
    return redactConfigurationToml(toml, forExport: true);
  }

  static bool _containsTomlMultilineDelimiter(String line) {
    var inBasicString = false;
    var inLiteralString = false;
    var escaped = false;
    for (var i = 0; i < line.length; i++) {
      final character = line[i];
      if (inBasicString) {
        if (escaped) {
          escaped = false;
        } else if (character == '\\') {
          escaped = true;
        } else if (character == '"') {
          inBasicString = false;
        }
      } else if (inLiteralString) {
        if (character == "'") inLiteralString = false;
      } else {
        if (character == '#') return false;
        if (i + 2 < line.length) {
          final candidate = line.substring(i, i + 3);
          if (candidate == '"""' || candidate == "'''") return true;
        }
        if (character == '"') {
          inBasicString = true;
        } else if (character == "'") {
          inLiteralString = true;
        }
      }
    }
    return false;
  }

  static int _findTomlAssignmentSeparator(String line) {
    var inBasicString = false;
    var inLiteralString = false;
    var escaped = false;
    for (var i = 0; i < line.length; i++) {
      final character = line[i];
      if (inBasicString) {
        if (escaped) {
          escaped = false;
        } else if (character == '\\') {
          escaped = true;
        } else if (character == '"') {
          inBasicString = false;
        }
      } else if (inLiteralString) {
        if (character == "'") inLiteralString = false;
      } else if (character == '"') {
        inBasicString = true;
      } else if (character == "'") {
        inLiteralString = true;
      } else if (character == '#') {
        return -1;
      } else if (character == '=') {
        return i;
      }
    }
    return -1;
  }

  /// 构建导出 zip
  static Uint8List buildExportZip(
    List<FrpConfig> configs,
    List<ServerConfig> servers,
    String selectedServerId,
    Map<String, String> serverTomls, {
    bool includeSecrets = false,
  }) {
    // Bound caller-owned collections before building sets, validating models,
    // or encoding any sensitive strings. Import parsing applies the same
    // domain limits before model construction.
    if (servers.length > 256) {
      throw StateError('Backup contains too many server records');
    }
    if (configs.length > 4096) {
      throw StateError('Backup contains too many proxy records');
    }
    if (serverTomls.length > 256) {
      throw StateError('Backup contains too many server TOML records');
    }
    final expectedEntries = includeSecrets ? 1 + servers.length : 2;
    if (expectedEntries > maxArchiveEntries) {
      throw StateError('Backup contains too many archive entries');
    }

    var declaredJsonTextUnits = selectedServerId.length;
    void addJsonText(String? value) {
      declaredJsonTextUnits += value?.length ?? 0;
      if (declaredJsonTextUnits > maxJsonBytes) {
        throw StateError('Backup configuration exceeds the 2 MiB JSON limit');
      }
    }

    final serverIds = <String>{};
    for (final server in servers) {
      for (final value in <String?>[
        server.name,
        server.serverId,
        server.serverAddr,
        includeSecrets ? server.token : null,
        server.protocol,
        server.wireProtocol,
        server.tlsServerName,
        server.tlsIdentityId,
      ]) {
        addJsonText(value);
      }
      if (server.storageValidationError() != null ||
          !serverIds.add(server.serverId)) {
        throw StateError(
          'Every server must be valid and have a unique 8-character ID',
        );
      }
    }
    if ((servers.isEmpty && selectedServerId.isNotEmpty) ||
        (servers.isNotEmpty && !serverIds.contains(selectedServerId))) {
      throw StateError('Selected Server ID is not present in the backup');
    }
    var declaredTomlBytes = 0;
    for (final entry in serverTomls.entries) {
      if (!RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(entry.key) ||
          !serverIds.contains(entry.key)) {
        throw StateError('Server TOML references an unknown Server ID');
      }
      if (entry.value.length > maxImportBytes) {
        throw StateError('Server TOML exceeds the 5 MiB entry limit');
      }
      final encoded = utf8.encode(entry.value);
      try {
        if (encoded.length > maxImportBytes) {
          throw StateError('Server TOML exceeds the 5 MiB entry limit');
        }
        declaredTomlBytes += encoded.length;
        if (declaredTomlBytes > maxArchiveExpandedBytes) {
          throw StateError('Server TOML data exceeds the expanded-size limit');
        }
      } finally {
        encoded.fillRange(0, encoded.length, 0);
      }
    }
    final configIds = <int>{};
    for (final config in configs) {
      if (config.customDomains.length > FrpConfig.maxCustomDomains ||
          config.portMappings.length > FrpConfig.maxPortMappings) {
        throw StateError('Proxy contains too many nested records');
      }
      for (final value in <String?>[
        config.name,
        config.serverAddr,
        includeSecrets ? config.token : null,
        config.localIp,
        config.protocol,
        config.role,
        includeSecrets ? config.secretKey : null,
        config.serverName,
        config.bindAddr,
        config.fallbackTo,
        config.stcpName,
        includeSecrets ? config.stcpSecretKey : null,
        config.stcpServerName,
        config.stcpBindAddr,
        config.groupName,
        config.serverId,
        config.manualToml,
        config.socks5?.targetIp,
        config.socks5?.username,
        includeSecrets ? config.socks5?.password : null,
      ]) {
        addJsonText(value);
      }
      for (final connection
          in config.socks5?.connections ?? const <Socks5Connection>[]) {
        addJsonText(connection.id);
        addJsonText(connection.name);
        addJsonText(connection.targetIp);
        addJsonText(connection.mode.name);
      }
      for (final domain in config.customDomains) {
        addJsonText(domain);
      }
      if (config.id <= 0 || !configIds.add(config.id)) {
        throw StateError(
          'Every proxy must have a unique positive configuration ID',
        );
      }
      final error = ConfigValidator.validateStored(config);
      if (error != null ||
          (config.serverId.isNotEmpty &&
              !serverIds.contains(config.serverId))) {
        throw StateError(error ?? 'Proxy references an unknown Server ID');
      }
    }
    final exportedConfigs = includeSecrets
        ? configs
        : configs
              .map(
                (config) => config.copyWith(
                  token: null,
                  secretKey: null,
                  stcpSecretKey: '',
                  socks5: config.socks5?.copyWith(password: ''),
                  manualToml: config.manualToml == null
                      ? null
                      : _redactManualToml(config.manualToml!),
                ),
              )
              .toList();
    final exportedServers = includeSecrets
        ? servers
        : servers.map((server) => server.copyWith(token: '')).toList();
    final intermediateBytes = <List<int>>[];
    try {
      final jsonBytes = _encodeBoundedJson(
        ExportData(
          configs: exportedConfigs,
          servers: exportedServers,
          selectedServerId: selectedServerId,
          redacted: !includeSecrets,
        ).toJson(),
      );
      intermediateBytes.add(jsonBytes);
      var expandedBytes = 0;
      final entries = <WipeableZipEntry>[];
      final archiveNames = <String>{};
      void addBoundedFile(String name, List<int> bytes) {
        if (!archiveNames.add(name)) {
          throw StateError('Backup contains a duplicate archive entry');
        }
        if (bytes.length > maxImportBytes) {
          throw StateError('Backup entry $name exceeds the 5 MiB limit');
        }
        expandedBytes += bytes.length;
        if (expandedBytes > maxArchiveExpandedBytes) {
          throw StateError('Backup expanded size exceeds the 32 MiB limit');
        }
        entries.add(WipeableZipEntry(name, bytes));
      }

      addBoundedFile('frp_configs.json', jsonBytes);
      if (includeSecrets) {
        for (var i = 0; i < servers.length; i++) {
          final server = servers[i];
          final safeId = server.serverId.replaceAll(
            RegExp(r'[^A-Za-z0-9_-]'),
            '_',
          );
          final safeLength = safeId.length > 64 ? 64 : safeId.length;
          final baseName = safeId.isEmpty
              ? 'server_${i + 1}'
              : safeId.substring(0, safeLength);
          var entryName = 'servers/$baseName.toml';
          var suffix = 2;
          while (archiveNames.contains(entryName)) {
            entryName = 'servers/${baseName}_$suffix.toml';
            suffix++;
          }
          final tomlBytes = utf8.encode(
            _removeDeviceTlsPaths(serverTomls[server.serverId] ?? ''),
          );
          intermediateBytes.add(tomlBytes);
          addBoundedFile(entryName, tomlBytes);
        }
      } else {
        const notice =
            'Recognized credential assignments were cleared and manual TOML comments were removed while structure was preserved.\n'
            'Re-enter credentials after import, and review custom TOML field values before sharing this archive.\n';
        final noticeBytes = utf8.encode(notice);
        intermediateBytes.add(noticeBytes);
        addBoundedFile('REDACTED.txt', noticeBytes);
      }
      try {
        return WipeableStoredZipBuilder.build(
          entries,
          maxOutputBytes: maxImportBytes,
        );
      } on FormatException catch (error) {
        throw StateError('Backup archive is invalid: ${error.message}');
      }
    } finally {
      for (final bytes in intermediateBytes) {
        bytes.fillRange(0, bytes.length, 0);
      }
    }
  }

  static String _removeDeviceTlsPaths(String toml) {
    const omitted =
        '# Device TLS path omitted; select the managed identity after import.';
    const keys = {
      'transport.tls.certFile',
      'transport.tls.keyFile',
      'transport.tls.trustedCaFile',
    };
    return toml
        .split('\n')
        .map((line) {
          final separator = line.indexOf('=');
          if (separator > 0 &&
              keys.contains(line.substring(0, separator).trim())) {
            return omitted;
          }
          return line;
        })
        .join('\n');
  }

  static Uint8List _encodeBoundedJson(Object? value) {
    final output = _BoundedBytesSink(maxJsonBytes);
    var retained = false;
    try {
      final input = JsonUtf8Encoder().startChunkedConversion(output);
      input.add(value);
      input.close();
      final bytes = output.bytes;
      retained = true;
      return bytes;
    } finally {
      if (!retained) output.erase();
    }
  }

  /// 解析导入内容：zip（取其中 .json）或纯 JSON 文本
  static ExportData? parseImportBytes(Uint8List bytes) {
    try {
      if (bytes.isEmpty || bytes.length > maxImportBytes) return null;
      // ZIP 魔数 PK
      if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
        final files = LimitedZipReader.readRequiredFiles(
          bytes,
          requiredFileNames: const {'frp_configs.json'},
          maxEntries: maxArchiveEntries,
          maxEntryBytes: maxImportBytes,
          maxTotalBytes: maxArchiveExpandedBytes,
        );
        try {
          final manifest = files['frp_configs.json']!;
          if (manifest.length > maxJsonBytes) return null;
          final json = utf8.decode(manifest);
          return parseJson(json);
        } finally {
          for (final contents in files.values) {
            contents.fillRange(0, contents.length, 0);
          }
        }
      }
      if (bytes.length > maxJsonBytes) return null;
      return parseJson(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  static ExportData? parseJson(String json) {
    try {
      final trimmed = json.trim();
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final map = decoded.cast<String, dynamic>();
        if (!_isSupportedExportMap(map)) return null;
        return ExportData.fromJson(map);
      }
      // 旧格式：纯数组
      if (decoded is! List<dynamic>) {
        return null;
      }
      if (decoded.length > 4096) return null;
      if (decoded.any((e) => e is! Map)) return null;
      final configs = decoded
          .map((e) => FrpConfig.fromJson((e as Map).cast<String, dynamic>()))
          .toList(growable: false);
      if (configs.any(
        (config) =>
            ConfigValidator.validate(config, allowIncompleteLegacy: true) !=
            null,
      )) {
        return null;
      }
      return ExportData(version: 1, configs: configs);
    } catch (_) {
      return null;
    }
  }

  static bool _isSupportedExportMap(Map<String, dynamic> json) {
    final rawVersion = json['version'];
    if (rawVersion is! num || !rawVersion.isFinite) return false;
    final version = rawVersion.toInt();
    if (rawVersion != version ||
        version < 1 ||
        version > ExportData.currentVersion) {
      return false;
    }

    final configs = json['configs'];
    if (configs is! List || configs.length > 4096) return false;
    if (configs.any((e) => e is! Map)) return false;

    if (version == 1) {
      final server = json['server'];
      return server == null || server is Map;
    }

    final servers = json['servers'];
    if (servers is! List || servers.length > 256) return false;
    if (servers.any((e) => e is! Map)) return false;
    final serverIds = <String>{};
    for (final rawServer in servers) {
      final serverId = (rawServer as Map)['serverId'];
      if (serverId is! String ||
          !RegExp(r'^[A-Za-z0-9]{8}$').hasMatch(serverId) ||
          !serverIds.add(serverId)) {
        return false;
      }
    }
    final selectedServerId = json['selectedServerId'];
    if (selectedServerId is! String ||
        (serverIds.isEmpty
            ? selectedServerId.isNotEmpty
            : !serverIds.contains(selectedServerId))) {
      return false;
    }
    return version < 3 || json['redacted'] is bool;
  }
}

/// Fixed-capacity JSON sink: encoder traversal stops at the archive boundary
/// instead of first materializing an arbitrarily large JSON String/list.
final class _BoundedBytesSink implements Sink<List<int>> {
  _BoundedBytesSink(int maxBytes) : _buffer = Uint8List(maxBytes);

  final Uint8List _buffer;
  int _length = 0;
  bool _closed = false;

  @override
  void add(List<int> data) {
    if (_closed) throw StateError('JSON byte sink is closed');
    if (data.length > _buffer.length - _length) {
      throw StateError('Backup configuration exceeds the 2 MiB JSON limit');
    }
    _buffer.setRange(_length, _length + data.length, data);
    _length += data.length;
  }

  @override
  void close() => _closed = true;

  Uint8List get bytes {
    if (!_closed) throw StateError('JSON byte sink is not closed');
    return Uint8List.sublistView(_buffer, 0, _length);
  }

  void erase() {
    _buffer.fillRange(0, _buffer.length, 0);
    _length = 0;
    _closed = true;
  }
}
