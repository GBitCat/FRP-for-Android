import 'package:flutter_test/flutter_test.dart';

import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/config_import_export.dart';

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
    final zip = ConfigImportExport.buildExportZip([c], server, 'serverAddr = "1.2.3.4"');
    final data = ConfigImportExport.parseImportBytes(zip);
    expect(data, isNotNull);
    expect(data!.configs.length, 1);
    expect(data.configs.first.name, 'xtcp_ssh');
    expect(data.configs.first.secretKey, 'sk');
    expect(data.server!.serverAddr, '1.2.3.4');
    expect(data.server!.token, 't');
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
