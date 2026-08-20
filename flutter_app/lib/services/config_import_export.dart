import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';

/// 导出数据：Server 配置 + 应用配置列表（与原有 ExportData 格式一致）
class ExportData {
  final int version;
  final List<ServerConfig> servers;
  final String selectedServerId;
  final List<FrpConfig> configs;

  const ExportData({
    this.version = 2,
    this.servers = const [],
    this.selectedServerId = '',
    this.configs = const [],
  });

  /// 兼容旧调用方：单 Server 备份取第一条。
  ServerConfig? get server => servers.firstOrNull;

  Map<String, dynamic> toJson() => {
    'version': version,
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
  /// 构建导出 zip
  static Uint8List buildExportZip(
    List<FrpConfig> configs,
    List<ServerConfig> servers,
    String selectedServerId,
    Map<String, String> serverTomls,
  ) {
    final jsonBytes = utf8.encode(
      jsonEncode(
        ExportData(
          configs: configs,
          servers: servers,
          selectedServerId: selectedServerId,
        ).toJson(),
      ),
    );
    final archive = Archive()
      ..addFile(ArchiveFile('frp_configs.json', jsonBytes.length, jsonBytes));
    for (var i = 0; i < servers.length; i++) {
      final server = servers[i];
      final safeId = server.serverId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final name = safeId.isEmpty ? 'server_${i + 1}' : safeId;
      final tomlBytes = utf8.encode(serverTomls[server.serverId] ?? '');
      archive.addFile(
        ArchiveFile('servers/$name.toml', tomlBytes.length, tomlBytes),
      );
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// 解析导入内容：zip（取其中 .json）或纯 JSON 文本
  static ExportData? parseImportBytes(Uint8List bytes) {
    try {
      // ZIP 魔数 PK
      if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final f in archive.files) {
          if (f.name.endsWith('.json')) {
            final content = f.content;
            final json = content is String
                ? content as String
                : utf8.decode(content as List<int>);
            return parseJson(json);
          }
        }
        return null;
      }
      return parseJson(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  static ExportData? parseJson(String json) {
    try {
      final trimmed = json.trim();
      if (trimmed.startsWith('{')) {
        return ExportData.fromJson(
          (jsonDecode(trimmed) as Map).cast<String, dynamic>(),
        );
      }
      // 旧格式：纯数组
      final list = jsonDecode(trimmed) as List<dynamic>;
      return ExportData(
        configs: list
            .map((e) => FrpConfig.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }
}
