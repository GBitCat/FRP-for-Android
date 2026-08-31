import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/config_import_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('complete export zip -> import preserves every modeled field', () {
    final c = FrpConfig(
      name: 'xtcp_ssh',
      protocol: 'xtcp',
      role: 'visitor',
      secretKey: 'sk',
      serverName: 'xtcp_ssh',
      bindPort: 39522,
      customDomains: const ['preserved.example.com'],
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
      includeSecrets: true,
    );
    final data = ConfigImportExport.parseImportBytes(zip);
    expect(data, isNotNull);
    expect(data!.configs.length, 1);
    expect(data.configs.first.toJson(), c.toJson());
    expect(data.server!.toJson(), server.toJson());
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
      includeSecrets: true,
    );
    final data = ConfigImportExport.parseImportBytes(zip)!;
    expect(data.version, 4);
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

  test('v2 multi-server JSON remains importable', () {
    const json = '''
      {"version":2,"servers":[{"serverId":"FIRST001"},{"serverId":"SECOND02"}],"selectedServerId":"SECOND02","configs":[]}
    ''';
    final data = ConfigImportExport.parseJson(json)!;
    expect(data.servers.map((server) => server.serverId), [
      'FIRST001',
      'SECOND02',
    ]);
    expect(data.selectedServerId, 'SECOND02');
  });

  test('v3 redacted backups remain importable', () {
    const json = '''
      {"version":3,"redacted":true,"servers":[],"selectedServerId":"","configs":[]}
    ''';
    final data = ConfigImportExport.parseJson(json)!;
    expect(data.version, 3);
    expect(data.redacted, isTrue);
  });

  test('legacy config array remains importable', () {
    const json = '[{"name":"legacy","protocol":"tcp","localPort":22}]';
    final data = ConfigImportExport.parseJson(json)!;
    expect(data.version, 4);
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
      includeSecrets: true,
    );
    final names = ZipDecoder().decodeBytes(bytes).files.map((e) => e.name);
    expect(
      names,
      containsAll(['servers/SERVER01.toml', 'servers/SERVER02.toml']),
    );
  });

  test('redacted export supports a server-only backup', () {
    const server = ServerConfig(
      serverId: 'SERVER01',
      serverAddr: 'frps.example.com',
      token: 'server-secret',
    );
    final bytes = ConfigImportExport.buildExportZip(
      const [],
      const [server],
      server.serverId,
      const {'SERVER01': 'auth.token = "server-secret"'},
    );

    final data = ConfigImportExport.parseImportBytes(bytes)!;
    expect(data.configs, isEmpty);
    expect(data.servers, hasLength(1));
    expect(data.servers.single.serverAddr, server.serverAddr);
    expect(data.servers.single.token, isEmpty);
    expect(data.selectedServerId, server.serverId);
  });

  test('redacted export preserves HTTP form fields', () {
    const config = FrpConfig(
      name: 'web',
      protocol: 'http',
      localIp: '127.0.0.1',
      localPort: 8080,
      customDomains: ['web.example.com', 'api.example.com'],
      secretKey: 'stale-secret',
      serverId: 'SERVER01',
    );
    const server = ServerConfig(serverId: 'SERVER01');
    final bytes = ConfigImportExport.buildExportZip(
      const [config],
      const [server],
      server.serverId,
      const {},
    );

    final imported = ConfigImportExport.parseImportBytes(bytes)!.configs.single;
    expect(imported.name, config.name);
    expect(imported.protocol, config.protocol);
    expect(imported.localIp, config.localIp);
    expect(imported.localPort, config.localPort);
    expect(imported.customDomains, config.customDomains);
    expect(imported.secretKey, isNull);
  });

  test('redacted export preserves form multi-port mappings', () {
    const config = FrpConfig(
      name: 'services',
      protocol: 'tcp',
      localPort: 22,
      remotePort: 10022,
      portMappings: [
        PortMapping(localPort: 22, remotePort: 10022),
        PortMapping(localPort: 8000, remotePort: 9000),
      ],
      serverId: 'SERVER01',
    );
    const server = ServerConfig(serverId: 'SERVER01');

    final bytes = ConfigImportExport.buildExportZip(
      const [config],
      const [server],
      server.serverId,
      const {},
    );
    final imported = ConfigImportExport.parseImportBytes(bytes)!.configs.single;

    expect(imported.portMappings, config.portMappings);
    expect(imported.effectivePortMappings, config.portMappings);
  });

  test('redacted export preserves a multi-protocol form group', () {
    const configs = [
      FrpConfig(
        id: 1,
        name: 'combo-xtcp',
        protocol: 'xtcp',
        role: 'visitor',
        secretKey: 'xtcp-secret',
        serverName: 'combo-xtcp',
        bindPort: 9002,
        serverId: 'SERVER01',
        groupId: 77,
        groupName: 'Dual P2P',
        isGroupPrimary: true,
      ),
      FrpConfig(
        id: 2,
        name: 'combo-xudp',
        protocol: 'xudp',
        role: 'visitor',
        secretKey: 'xudp-secret',
        serverName: 'combo-xudp',
        bindPort: 9003,
        serverId: 'SERVER01',
        groupId: 77,
        groupName: 'Dual P2P',
      ),
    ];
    const server = ServerConfig(serverId: 'SERVER01');

    final bytes = ConfigImportExport.buildExportZip(
      configs,
      const [server],
      server.serverId,
      const {},
    );
    final imported = ConfigImportExport.parseImportBytes(bytes)!.configs;

    expect(imported.map((config) => config.protocol), ['xtcp', 'xudp']);
    expect(imported.map((config) => config.groupId).toSet(), {77});
    expect(imported.map((config) => config.groupName).toSet(), {'Dual P2P'});
    expect(imported.first.isGroupPrimary, isTrue);
    expect(imported.every((config) => config.secretKey == null), isTrue);
  });

  test('redacted export preserves duplicate XUDP fallback members', () {
    const configs = [
      FrpConfig(
        id: 1,
        name: 'alpha-xudp',
        protocol: 'xudp',
        role: 'visitor',
        secretKey: 'alpha-secret',
        serverName: 'alpha-xudp',
        bindPort: 9101,
        useFallback: true,
        fallbackTo: 'alpha-sudp',
        stcpName: 'alpha-sudp',
        stcpSecretKey: 'alpha-secret',
        stcpServerName: 'alpha-sudp',
        groupId: 88,
        groupName: 'Two UDP Tunnels',
        isGroupPrimary: true,
      ),
      FrpConfig(
        id: 2,
        name: 'beta-xudp',
        protocol: 'xudp',
        role: 'visitor',
        secretKey: 'beta-secret',
        serverName: 'beta-xudp',
        bindPort: 9102,
        useFallback: true,
        fallbackTo: 'beta-sudp',
        stcpName: 'beta-sudp',
        stcpSecretKey: 'beta-secret',
        stcpServerName: 'beta-sudp',
        groupId: 88,
        groupName: 'Two UDP Tunnels',
      ),
      FrpConfig(
        id: 3,
        name: 'alpha-sudp',
        protocol: 'sudp',
        role: 'visitor',
        secretKey: 'alpha-secret',
        serverName: 'alpha-sudp',
        bindPort: -1,
        groupId: 88,
        groupName: 'Two UDP Tunnels',
      ),
      FrpConfig(
        id: 4,
        name: 'beta-sudp',
        protocol: 'sudp',
        role: 'visitor',
        secretKey: 'beta-secret',
        serverName: 'beta-sudp',
        bindPort: -1,
        groupId: 88,
        groupName: 'Two UDP Tunnels',
      ),
    ];
    const server = ServerConfig(serverId: 'SERVER01');

    final bytes = ConfigImportExport.buildExportZip(
      configs,
      const [server],
      server.serverId,
      const {},
    );
    final imported = ConfigImportExport.parseImportBytes(bytes)!.configs;

    expect(imported, hasLength(4));
    expect(imported.where((config) => config.protocol == 'xudp'), hasLength(2));
    expect(imported.where((config) => config.protocol == 'sudp'), hasLength(2));
    expect(
      imported
          .where((config) => config.protocol == 'xudp')
          .map((config) => config.fallbackTo)
          .toSet(),
      {'alpha-sudp', 'beta-sudp'},
    );
    expect(imported.map((config) => config.groupId).toSet(), {88});
    expect(imported.every((config) => config.secretKey == null), isTrue);
    expect(
      imported
          .where((config) => config.protocol == 'xudp')
          .every((config) => config.stcpSecretKey.isEmpty),
      isTrue,
    );
  });

  test('redacted export preserves manual visitors and clears credentials', () {
    const config = FrpConfig(
      name: 'manual',
      protocol: 'xudp',
      secretKey: 'proxy-secret',
      stcpSecretKey: 'fallback-secret',
      manualToml: '''[[visitors]]
name = "visitor-one"
type = "xtcp"
serverName = "peer-one"
secretKey = "manual-secret"
bindPort = 39522

[visitors.transport]
useEncryption = true
useCompression = true

[[visitors]]
name = "visitor-two"
type = "stcp"
serverName = "peer-two"
secretKey = "manual-secret-two"
bindPort = 39523''',
    );
    const server = ServerConfig(serverId: 'SERVER01', token: 'server-secret');
    final bytes = ConfigImportExport.buildExportZip(
      [config],
      [server],
      server.serverId,
      const {'SERVER01': 'auth.token = "toml-secret"'},
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.files.map((file) => file.name), contains('REDACTED.txt'));
    expect(
      archive.files.map((file) => file.name),
      isNot(contains('servers/SERVER01.toml')),
    );
    final data = ConfigImportExport.parseImportBytes(bytes)!;
    expect(data.redacted, isTrue);
    expect(data.servers.single.token, isEmpty);
    expect(data.configs.single.secretKey, isNull);
    expect(data.configs.single.stcpSecretKey, isEmpty);
    final manualToml = data.configs.single.manualToml!;
    expect(manualToml, contains('[[visitors]]'));
    expect(manualToml, contains('name = "visitor-one"'));
    expect(manualToml, contains('type = "xtcp"'));
    expect(manualToml, contains('serverName = "peer-one"'));
    expect(manualToml, contains('bindPort = 39522'));
    expect(manualToml, contains('[visitors.transport]'));
    expect(manualToml, contains('useEncryption = true'));
    expect(manualToml, contains('secretKey = ""'));
    expect(manualToml, isNot(contains('manual-secret')));
    expect(manualToml, isNot(contains('manual-secret-two')));
    expect(data.configs.single.manualNames, ['visitor-one', 'visitor-two']);
    expect(data.configs.single.manualTypes, ['xtcp', 'stcp']);
  });

  test(
    'redacted manual TOML clears common credentials without losing blocks',
    () {
      const config = FrpConfig(
        name: 'manual-secrets',
        manualToml: '''auth.token = "server-token"
[[visitors]]
name = "visitor-two"
type = "stcp"
serverName = "peer-two"
secretKey = 'visitor-secret'
bindPort = 2222
plugin.httpPassword = "plugin-password"
auth.oidc.clientSecret = "oidc-secret"
requestHeaders.set.Authorization = "Bearer auth-secret"
requestHeaders.set.Cookie = "session-cookie"
api_key = "api-secret"
private-key = "private-secret"
password = """
multiline-secret
still-secret
"""
fallbackTimeoutMs = 3000''',
      );
      const server = ServerConfig(serverId: 'SERVER01', token: 'server-secret');

      final bytes = ConfigImportExport.buildExportZip(
        const [config],
        const [server],
        server.serverId,
        const {},
      );
      final data = ConfigImportExport.parseImportBytes(bytes)!;
      final manualToml = data.configs.single.manualToml!;

      expect(
        RegExp(r'^\[\[visitors\]\]$', multiLine: true).hasMatch(manualToml),
        isTrue,
      );
      expect(manualToml, contains('name = "visitor-two"'));
      expect(manualToml, contains('type = "stcp"'));
      expect(manualToml, contains('serverName = "peer-two"'));
      expect(manualToml, contains('bindPort = 2222'));
      expect(manualToml, contains('fallbackTimeoutMs = 3000'));
      expect(
        RegExp(r'^secretKey\s*=\s*""', multiLine: true).hasMatch(manualToml),
        isTrue,
      );
      expect(
        RegExp(r'^password\s*=\s*""', multiLine: true).hasMatch(manualToml),
        isTrue,
      );
      for (final secret in const [
        'server-token',
        'visitor-secret',
        'plugin-password',
        'oidc-secret',
        'auth-secret',
        'session-cookie',
        'api-secret',
        'private-secret',
        'multiline-secret',
        'still-secret',
      ]) {
        expect(manualToml, isNot(contains(secret)));
      }
    },
  );

  test('frp config json round trip', () {
    final c = FrpConfig(
      name: 'linux-ssh-xtcp',
      protocol: 'xtcp',
      role: 'visitor',
      secretKey: 'sk',
      serverName: 'linux-ssh-xtcp',
      bindPort: 39522,
      customDomains: const ['preserved.example.com'],
      portMappings: const [
        PortMapping(localPort: 22, remotePort: 10022),
        PortMapping(localPort: 80, remotePort: 10080),
      ],
    );
    final c2 = FrpConfig.fromJson(c.toJson());
    expect(c2.name, c.name);
    expect(c2.protocol, 'xtcp');
    expect(c2.secretKey, 'sk');
    expect(c2.customDomains, ['preserved.example.com']);
    expect(c2.portMappings, c.portMappings);
  });

  test('oversized imports are rejected before parsing', () {
    final bytes = Uint8List(ConfigImportExport.maxImportBytes + 1);
    expect(ConfigImportExport.parseImportBytes(bytes), isNull);
  });

  test('archives with too many entries are rejected', () {
    final archive = Archive();
    for (var i = 0; i <= ConfigImportExport.maxArchiveEntries; i++) {
      archive.addFile(ArchiveFile('entry-$i.txt', 1, const [0]));
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    expect(ConfigImportExport.parseImportBytes(bytes), isNull);
  });

  test('unrelated or unsupported JSON is not treated as a backup', () {
    expect(ConfigImportExport.parseJson('{}'), isNull);
    expect(
      ConfigImportExport.parseJson(
        '{"version":5,"redacted":false,"servers":[],"selectedServerId":"","configs":[]}',
      ),
      isNull,
    );

    const validManifest =
        '{"version":3,"redacted":true,"servers":[],"selectedServerId":"","configs":[]}';
    final unrelatedArchive = Archive()
      ..addFile(
        ArchiveFile(
          'unrelated.json',
          validManifest.length,
          validManifest.codeUnits,
        ),
      );
    final bytes = Uint8List.fromList(ZipEncoder().encode(unrelatedArchive));
    expect(ConfigImportExport.parseImportBytes(bytes), isNull);
  });
}
