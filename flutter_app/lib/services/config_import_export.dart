import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/frp_config.dart';
import '../models/server_config.dart';

/// 导出数据：Server 配置 + 应用配置列表（与原有 ExportData 格式一致）
class ExportData {
  final int version;
  final ServerConfig? server;
  final List<FrpConfig> configs;

  const ExportData({this.version = 1, this.server, this.configs = const []});

  Map<String, dynamic> toJson() => {
        'version': version,
        'server': server?.toJson(),
        'configs': configs.map((e) => e.toJson()).toList(),
      };

  factory ExportData.fromJson(Map<String, dynamic> j) => ExportData(
        version: (j['version'] as num?)?.toInt() ?? 1,
        server: j['server'] == null
            ? null
            : ServerConfig.fromJson((j['server'] as Map).cast<String, dynamic>()),
        configs: (j['configs'] as List<dynamic>? ?? [])
            .map((e) => FrpConfig.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// 导入导出：zip（frp_configs.json + frpc_all.toml）/ 纯 JSON，兼容旧格式
class ConfigImportExport {
  /// 构建导出 zip
  static Uint8List buildExportZip(
      List<FrpConfig> configs, ServerConfig? server, String toml) {
    final json = jsonEncode(ExportData(configs: configs, server: server).toJson());
    final tomlBytes = utf8.encode(toml);
    final archive = Archive()
      ..addFile(ArchiveFile('frp_configs.json', utf8.encode(json).length, utf8.encode(json)))
      ..addFile(ArchiveFile('frpc_all.toml', tomlBytes.length, tomlBytes));
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
            final json = content is String ? content as String : utf8.decode(content as List<int>);
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
            (jsonDecode(trimmed) as Map).cast<String, dynamic>());
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
