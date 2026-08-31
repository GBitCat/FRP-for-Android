import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';

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
    final serverList = (j['servers'] as List<dynamic>? ?? [])
        .map((e) => ServerConfig.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    // v1 备份只有 server 字段。
    if (serverList.isEmpty && j['server'] is Map) {
      serverList.add(
        ServerConfig.fromJson((j['server'] as Map).cast<String, dynamic>()),
      );
    }
    final selected = j['selectedServerId'] as String? ?? '';
    return ExportData(
      version: (j['version'] as num?)?.toInt() ?? 1,
      redacted: j['redacted'] as bool? ?? false,
      servers: serverList,
      selectedServerId: serverList.any((e) => e.serverId == selected)
          ? selected
          : (serverList.firstOrNull?.serverId ?? ''),
      configs: (j['configs'] as List<dynamic>? ?? [])
          .map((e) => FrpConfig.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}

/// 导入导出：zip（frp_configs.json + frpc_all.toml）/ 纯 JSON，兼容旧格式
class ConfigImportExport {
  static const maxImportBytes = 5 * 1024 * 1024;
  static const maxJsonBytes = 2 * 1024 * 1024;
  static const maxArchiveEntries = 64;

  /// Preserve manual proxy/visitor structure while clearing recognized
  /// credential assignments. Comments are omitted because free-form comment
  /// text cannot be reliably classified as non-sensitive.
  static String _redactManualToml(String toml) {
    final redacted = <String>[];
    String? skippedMultilineDelimiter;

    for (final line in toml.split('\n')) {
      if (skippedMultilineDelimiter != null) {
        if (line.contains(skippedMultilineDelimiter)) {
          skippedMultilineDelimiter = null;
        }
        continue;
      }

      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) {
        redacted.add(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        continue;
      }

      final separator = line.indexOf('=');
      if (separator <= 0 ||
          !_isSensitiveTomlKey(line.substring(0, separator))) {
        redacted.add(_stripInlineTomlComment(line));
        continue;
      }

      final value = line.substring(separator + 1).trimLeft();
      final multilineDelimiter = value.startsWith('"""')
          ? '"""'
          : value.startsWith("'''")
          ? "'''"
          : null;
      final closesOnSameLine =
          multilineDelimiter != null &&
          value.indexOf(multilineDelimiter, multilineDelimiter.length) >= 0;

      redacted.add(
        '${line.substring(0, separator + 1)} "" # Redacted credential; re-enter after import.',
      );
      if (multilineDelimiter != null && !closesOnSameLine) {
        skippedMultilineDelimiter = multilineDelimiter;
      }
    }

    return redacted.join('\n');
  }

  static String _stripInlineTomlComment(String line) {
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
        return line.substring(0, i).trimRight();
      }
    }
    return line;
  }

  static bool _isSensitiveTomlKey(String rawKey) {
    final key = rawKey.trim();
    // Reject section headers and other non-key syntax before applying the
    // intentionally broad credential-name matching below.
    if (key.isEmpty || RegExp(r'[\[\]{}#]').hasMatch(key)) return false;

    var segment = key.split('.').last.trim();
    if (segment.length >= 2 &&
        ((segment.startsWith('"') && segment.endsWith('"')) ||
            (segment.startsWith("'") && segment.endsWith("'")))) {
      segment = segment.substring(1, segment.length - 1);
    }
    final normalized = segment.replaceAll(RegExp(r'[\s_-]'), '').toLowerCase();

    return normalized == 'sk' ||
        normalized == 'token' ||
        normalized.endsWith('token') ||
        normalized.contains('secret') ||
        normalized.contains('password') ||
        normalized.contains('passwd') ||
        normalized.contains('credential') ||
        normalized.endsWith('authorization') ||
        normalized.endsWith('cookie') ||
        normalized.contains('apikey') ||
        normalized.contains('privatekey') ||
        normalized.contains('accesskey');
  }

  /// 构建导出 zip
  static Uint8List buildExportZip(
    List<FrpConfig> configs,
    List<ServerConfig> servers,
    String selectedServerId,
    Map<String, String> serverTomls, {
    bool includeSecrets = false,
  }) {
    final exportedConfigs = includeSecrets
        ? configs
        : configs
              .map(
                (config) => config.copyWith(
                  token: null,
                  secretKey: null,
                  stcpSecretKey: '',
                  manualToml: config.manualToml == null
                      ? null
                      : _redactManualToml(config.manualToml!),
                ),
              )
              .toList();
    final exportedServers = includeSecrets
        ? servers
        : servers.map((server) => server.copyWith(token: '')).toList();
    final jsonBytes = utf8.encode(
      jsonEncode(
        ExportData(
          configs: exportedConfigs,
          servers: exportedServers,
          selectedServerId: selectedServerId,
          redacted: !includeSecrets,
        ).toJson(),
      ),
    );
    if (jsonBytes.length > maxJsonBytes) {
      throw StateError('Backup configuration exceeds the 2 MiB JSON limit');
    }
    final archive = Archive()
      ..addFile(ArchiveFile('frp_configs.json', jsonBytes.length, jsonBytes));
    if (includeSecrets) {
      for (var i = 0; i < servers.length; i++) {
        final server = servers[i];
        final safeId = server.serverId.replaceAll(
          RegExp(r'[^A-Za-z0-9_-]'),
          '_',
        );
        final name = safeId.isEmpty ? 'server_${i + 1}' : safeId;
        final tomlBytes = utf8.encode(serverTomls[server.serverId] ?? '');
        archive.addFile(
          ArchiveFile('servers/$name.toml', tomlBytes.length, tomlBytes),
        );
      }
    } else {
      const notice =
          'Recognized credential assignments were cleared and manual TOML comments were removed while structure was preserved.\n'
          'Re-enter credentials after import, and review custom TOML field values before sharing this archive.\n';
      archive.addFile(
        ArchiveFile('REDACTED.txt', notice.length, utf8.encode(notice)),
      );
    }
    final encoded = Uint8List.fromList(ZipEncoder().encode(archive));
    if (encoded.length > maxImportBytes) {
      throw StateError('Backup archive exceeds the 5 MiB import limit');
    }
    return encoded;
  }

  /// 解析导入内容：zip（取其中 .json）或纯 JSON 文本
  static ExportData? parseImportBytes(Uint8List bytes) {
    try {
      if (bytes.isEmpty || bytes.length > maxImportBytes) return null;
      // ZIP 魔数 PK
      if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
        final archive = ZipDecoder().decodeBytes(bytes);
        if (archive.files.length > maxArchiveEntries) return null;
        final manifest = archive.files
            .where((file) => file.name == 'frp_configs.json')
            .firstOrNull;
        if (manifest == null || manifest.size > maxJsonBytes) return null;
        final content = manifest.content;
        final json = content is String
            ? content as String
            : utf8.decode(content as List<int>);
        if (utf8.encode(json).length > maxJsonBytes) return null;
        return parseJson(json);
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
      if (decoded is! List<dynamic> || decoded.any((e) => e is! Map)) {
        return null;
      }
      return ExportData(
        configs: decoded
            .map((e) => FrpConfig.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
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
    if (configs is! List || configs.any((e) => e is! Map)) return false;

    if (version == 1) {
      final server = json['server'];
      return server == null || server is Map;
    }

    final servers = json['servers'];
    if (servers is! List || servers.any((e) => e is! Map)) return false;
    if (json['selectedServerId'] is! String) return false;
    return version < 3 || json['redacted'] is bool;
  }
}
