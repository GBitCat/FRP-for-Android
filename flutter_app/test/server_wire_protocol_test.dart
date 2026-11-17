import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/config_import_export.dart';
import 'package:frp_app/services/toml_generator.dart';

void main() {
  const server = ServerConfig(
    serverId: 'SERVER01',
    serverAddr: 'frps.example.com',
  );

  test('new and legacy servers use v2 wire protocol', () {
    expect(server.wireProtocol, 'v2');
    final legacy = ServerConfig.fromJson({
      'serverId': 'SERVER01',
      'serverAddr': 'frps.example.com',
    });
    expect(legacy.wireProtocol, 'v2');
    expect(legacy.runtimeValidationError(), isNull);
    expect(globalBlock(legacy), contains('transport.wireProtocol = "v2"'));
  });

  test('wire protocol survives copying and JSON persistence', () {
    final v1 = server.copyWith(wireProtocol: 'v1');
    expect(v1.copyWith(name: 'Renamed').wireProtocol, 'v1');
    expect(ServerConfig.fromJson(v1.toJson()).wireProtocol, 'v1');
    expect(v1.copyWith(wireProtocol: 'v2').wireProtocol, 'v2');
    expect(server.wireProtocol, 'v2');
  });

  test('unsupported wire protocol is rejected by domain validation', () {
    for (final value in ['', 'v3', 'V2', 'tcp']) {
      final invalid = server.copyWith(wireProtocol: value);
      expect(invalid.storageValidationError(), contains('wire protocol'));
      expect(invalid.runtimeValidationError(), contains('wire protocol'));
    }
    expect(
      () => ServerConfig.fromJson({...server.toJson(), 'wireProtocol': 2}),
      throwsFormatException,
    );
  });

  for (final version in ServerConfig.supportedWireProtocols) {
    test('$version is explicitly generated and preserved by backup', () {
      final selected = server.copyWith(wireProtocol: version);
      expect(selected.runtimeValidationError(), isNull);
      final toml = generateServerPreview(selected, const []);
      expect(toml, contains('transport.protocol = "tcp"'));
      expect(toml, contains('transport.wireProtocol = "$version"'));
      expect(
        RegExp(
          r'^transport\.wireProtocol = ',
          multiLine: true,
        ).allMatches(toml),
        hasLength(1),
      );

      final zip = ConfigImportExport.buildExportZip(
        const [],
        [selected],
        selected.serverId,
        {selected.serverId: toml},
      );
      final imported = ConfigImportExport.parseImportBytes(zip)!;
      expect(imported.servers.single.wireProtocol, version);
      expect(
        globalBlock(imported.servers.single),
        contains('transport.wireProtocol = "$version"'),
      );
    });
  }

  test(
    'backup import defaults missing wire protocol and rejects invalid values',
    () {
      final legacyServer = server.toJson()..remove('wireProtocol');
      Map<String, dynamic> backup(Map<String, dynamic> serverJson) => {
        'version': 4,
        'redacted': false,
        'servers': [serverJson],
        'selectedServerId': 'SERVER01',
        'configs': [],
      };

      final legacy = ConfigImportExport.parseJson(
        jsonEncode(backup(legacyServer)),
      );
      expect(legacy!.servers.single.wireProtocol, 'v2');
      for (final value in <Object>['v3', '', 2]) {
        expect(
          ConfigImportExport.parseJson(
            jsonEncode(backup({...legacyServer, 'wireProtocol': value})),
          ),
          isNull,
        );
      }
    },
  );
}
