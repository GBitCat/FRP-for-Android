import 'package:flutter_test/flutter_test.dart';

import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/config_import_export.dart';
import 'package:archive/archive.dart';

void main() {
  test('export zip -> import round trip', () {
    final c = FrpConfig(
      name: 'xtcp_ssh',
      protocol: 'xtcp',
      role: 'visitor',
      secretKey: 'sk',
      serverName: 'xtcp_ssh',
      bindPort: 39522,
    );
    const server = ServerConfig(
      serverAddr: '1.2.3.4',
      serverPort: 7000,
      token: 't',
    );
    final zip = ConfigImportExport.buildExportZip(
      [c],
      [server],
      server.serverId,
      {server.serverId: 'serverAddr = "1.2.3.4"'},
    );
    final data = ConfigImportExport.parseImportBytes(zip);
    expect(data, isNotNull);
    expect(data!.configs.length, 1);
    expect(data.configs.first.name, 'xtcp_ssh');
    expect(data.configs.first.secretKey, 'sk');
    expect(data.server!.serverAddr, '1.2.3.4');
    expect(data.server!.token, 't');
  });

  test('multi-server export preserves selected server and all servers', () {
    const first = ServerConfig(serverId: 'SERVER01', serverAddr: '1.1.1.1');
    const second = ServerConfig(serverId: 'SERVER02', serverAddr: '2.2.2.2');
    final zip = ConfigImportExport.buildExportZip(
      const [],
      [first, second],
      second.serverId,
      {
        first.serverId: 'serverAddr = "1.1.1.1"',
        second.serverId: 'serverAddr = "2.2.2.2"',
      },
    );
    final data = ConfigImportExport.parseImportBytes(zip)!;
    expect(data.version, 2);
    expect(data.servers.map((e) => e.serverId), ['SERVER01', 'SERVER02']);
    expect(data.selectedServerId, 'SERVER02');
  });

  test('v1 single-server JSON remains importable', () {
    const json = '''
      {"version":1,"server":{"serverId":"LEGACY01","serverAddr":"old"},"configs":[]}
    ''';
    final data = ConfigImportExport.parseJson(json)!;
    expect(data.servers.single.serverId, 'LEGACY01');
    expect(data.selectedServerId, 'LEGACY01');
  });

  test('legacy config array remains importable', () {
    const json = '[{"name":"legacy","protocol":"tcp","localPort":22}]';
    final data = ConfigImportExport.parseJson(json)!;
    expect(data.version, 2);
    expect(data.configs.single.name, 'legacy');
  });

  test('multi-server ZIP contains a TOML for every server', () {
    const first = ServerConfig(serverId: 'SERVER01');
    const second = ServerConfig(serverId: 'SERVER02');
    final bytes = ConfigImportExport.buildExportZip(
      const [],
      [first, second],
      first.serverId,
      const {'SERVER01': 'one', 'SERVER02': 'two'},
    );
    final names = ZipDecoder().decodeBytes(bytes).files.map((e) => e.name);
    expect(
      names,
      containsAll(['servers/SERVER01.toml', 'servers/SERVER02.toml']),
    );
  });

  test('frp config json round trip', () {
    final c = FrpConfig(
      name: 'linux-ssh-xtcp',
      protocol: 'xtcp',
      role: 'visitor',
      secretKey: 'sk',
      serverName: 'linux-ssh-xtcp',
      bindPort: 39522,
    );
    final c2 = FrpConfig.fromJson(c.toJson());
    expect(c2.name, c.name);
    expect(c2.protocol, 'xtcp');
    expect(c2.secretKey, 'sk');
  });
}
