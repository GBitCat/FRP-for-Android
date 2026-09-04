import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/config_import_export.dart';
import 'package:frp_app/services/config_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('complete export zip -> import preserves every modeled field', () {
    final c = FrpConfig(
      id: 1,
      name: 'xtcp_ssh',
      protocol: 'xtcp',
      role: 'visitor',
      secretKey: 'sk',
      serverName: 'xtcp_ssh',
      bindPort: 39522,
      customDomains: const ['preserved.example.com'],
    );
    const server = ServerConfig(
      serverId: 'SERVER01',
      serverAddr: '1.2.3.4',
      serverPort: 7000,
      token: 't',
      tlsEnabled: true,
      tlsServerName: 'frps.example.com',
      tlsIdentityId: 'id-0123456789abcdef01234567',
      tlsCertFile: '/certs/client.crt',
      tlsKeyFile: '/certs/client.key',
      tlsTrustedCaFile: '/certs/ca.crt',
    );
    final zip = ConfigImportExport.buildExportZip(
      [c],
      [server],
      server.serverId,
      {
        server.serverId: '''serverAddr = "1.2.3.4"
transport.tls.certFile = "/certs/client.crt"
transport.tls.keyFile = "/certs/client.key"
transport.tls.trustedCaFile = "/certs/ca.crt"''',
      },
      includeSecrets: true,
    );
    final data = ConfigImportExport.parseImportBytes(zip);
    expect(data, isNotNull);
    expect(data!.configs.length, 1);
    expect(data.configs.first.toJson(), c.toJson());
    expect(data.server!.toJson(), server.toJson());
    expect(data.server!.tlsIdentityId, server.tlsIdentityId);
    expect(data.server!.tlsCertFile, isEmpty);
    expect(data.server!.tlsKeyFile, isEmpty);
    expect(data.server!.tlsTrustedCaFile, isEmpty);
    expect(server.toJson(), isNot(contains('tlsCertFile')));

    final archive = ZipDecoder().decodeBytes(zip);
    expect(
      archive.files,
      everyElement(
        predicate<ArchiveFile>(
          (file) => file.compression == CompressionType.none,
          'is stored without compression',
        ),
      ),
    );
    final toml = utf8.decode(
      archive.files
              .singleWhere((file) => file.name.startsWith('servers/'))
              .content
          as List<int>,
    );
    expect(toml, isNot(contains('/certs/')));
    expect(RegExp('Device TLS path omitted').allMatches(toml).length, 3);
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
    expect(data.servers.single.tlsEnabled, isFalse);
    expect(data.servers.single.tlsIdentityId, isEmpty);
    expect(data.servers.single.tlsCertFile, isEmpty);
  });

  test('v1 server without an ID receives a valid local ID', () {
    const json = '''
      {"version":1,"server":{"serverAddr":"old"},"configs":[]}
    ''';
    final data = ConfigImportExport.parseJson(json)!;
    expect(data.servers.single.serverId, hasLength(8));
    expect(data.selectedServerId, data.servers.single.serverId);
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
    expect(data.version, 1);
    expect(data.configs.single.name, 'legacy');
  });

  test('export rejects proxy records outside the persisted domain', () {
    const server = ServerConfig(serverId: 'SERVER01');
    expect(
      () => ConfigImportExport.buildExportZip(
        const [
          FrpConfig(
            id: 1,
            name: 'bad',
            protocol: 'tcp',
            localPort: 22,
            remotePort: 10022,
            serverId: 'MISSING1',
          ),
        ],
        const [server],
        server.serverId,
        const {},
      ),
      throwsStateError,
    );
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

  test('exports reject Server IDs outside the UI domain', () {
    const first = ServerConfig(serverId: 'ABC/DEF1');
    const second = ServerConfig(serverId: 'ABC?DEF1');
    expect(
      () => ConfigImportExport.buildExportZip(
        const [],
        const [first, second],
        first.serverId,
        const {'ABC/DEF1': 'one', 'ABC?DEF1': 'two'},
        includeSecrets: true,
      ),
      throwsStateError,
    );
  });

  test('v2+ backups reject duplicate or malformed Server IDs', () {
    for (final json in [
      '''{"version":4,"redacted":false,"servers":[{"serverId":"SERVER01"},{"serverId":"SERVER01"}],"selectedServerId":"SERVER01","configs":[]}''',
      '''{"version":4,"redacted":false,"servers":[{"serverId":"short"}],"selectedServerId":"short","configs":[]}''',
      '''{"version":4,"redacted":false,"servers":[{"serverId":"SERVER01"}],"selectedServerId":"MISSING1","configs":[]}''',
    ]) {
      expect(ConfigImportExport.parseJson(json), isNull);
    }
  });

  test('v2+ backups require unique positive proxy IDs', () {
    Map<String, dynamic> proxy(int id, {String name = 'proxy'}) => {
      'id': id,
      'name': name,
      'protocol': 'tcp',
      'localPort': 22,
      'remotePort': 10022,
      'serverId': 'SERVER01',
    };

    for (final configs in [
      [proxy(0)],
      [proxy(-1)],
      [proxy(1), proxy(1, name: 'duplicate')],
    ]) {
      final json = jsonEncode({
        'version': 4,
        'redacted': false,
        'servers': [
          {'serverId': 'SERVER01'},
        ],
        'selectedServerId': 'SERVER01',
        'configs': configs,
      });
      expect(ConfigImportExport.parseJson(json), isNull, reason: json);
    }

    expect(
      () => ConfigImportExport.buildExportZip(
        [
          const FrpConfig(
            id: 1,
            name: 'first',
            protocol: 'tcp',
            localPort: 22,
            remotePort: 10022,
            serverId: 'SERVER01',
          ),
          const FrpConfig(
            id: 1,
            name: 'second',
            protocol: 'tcp',
            localPort: 23,
            remotePort: 10023,
            serverId: 'SERVER01',
          ),
        ],
        const [ServerConfig(serverId: 'SERVER01')],
        'SERVER01',
        const {},
      ),
      throwsStateError,
    );
  });

  test('blank manual TOML does not bypass form validation', () {
    final json = jsonEncode({
      'version': 4,
      'redacted': false,
      'servers': [
        {'serverId': 'SERVER01'},
      ],
      'selectedServerId': 'SERVER01',
      'configs': [
        {
          'id': 1,
          'name': 'invalid-blank-manual',
          'protocol': 'tcp',
          'localPort': 0,
          'remotePort': 0,
          'manualToml': ' \n\t ',
          'serverId': 'SERVER01',
        },
      ],
    });

    expect(ConfigImportExport.parseJson(json), isNull);
  });

  test('credentials reject C0 controls and DEL', () {
    for (final character in ['\u0001', '\t', '\n', '\u001f', '\u007f']) {
      expect(
        const ServerConfig(serverId: 'SERVER01')
            .copyWith(token: 'before${character}after')
            .storageValidationError(),
        isNotNull,
      );
      expect(
        ConfigValidator.validate(
          FrpConfig(
            id: 1,
            name: 'proxy',
            protocol: 'tcp',
            localPort: 22,
            remotePort: 10022,
            secretKey: 'before${character}after',
          ),
        ),
        isNotNull,
      );
    }
  });

  test('manual TOML rejects forbidden raw control characters', () {
    for (final character in ['\u0001', '\u000b', '\u001f', '\u007f']) {
      expect(
        ConfigValidator.validate(
          FrpConfig(
            id: 1,
            name: 'manual',
            manualToml: '[[proxies]]\nname = "bad${character}value"',
          ),
        ),
        isNotNull,
      );
    }
    expect(
      ConfigValidator.validate(
        const FrpConfig(
          id: 1,
          name: 'manual',
          manualToml: '[[proxies]]\nname = "line"\n\tlocalPort = 22\r\n',
        ),
      ),
      isNull,
    );
  });

  test('legacy ws transport migrates to the frpc websocket value', () {
    const json = '''
      {"version":4,"redacted":false,"servers":[{"serverId":"SERVER01","protocol":"ws"}],"selectedServerId":"SERVER01","configs":[]}
    ''';
    final data = ConfigImportExport.parseJson(json);
    expect(data, isNotNull);
    expect(data!.servers.single.protocol, 'websocket');
  });

  test('imports reject invalid transport domains and fractional integers', () {
    for (final json in [
      '''{"version":4,"redacted":false,"servers":[{"serverId":"SERVER01","protocol":"ssh"}],"selectedServerId":"SERVER01","configs":[]}''',
      '''{"version":4,"redacted":false,"servers":[{"serverId":"SERVER01","heartbeatInterval":90,"heartbeatTimeout":30}],"selectedServerId":"SERVER01","configs":[]}''',
      '''{"version":4,"redacted":false,"servers":[{"serverId":"SERVER01","heartbeatInterval":1.5}],"selectedServerId":"SERVER01","configs":[]}''',
      '''{"version":4,"redacted":false,"servers":[{"serverId":"SERVER01"}],"selectedServerId":"SERVER01","configs":[{"id":1,"name":"bad","protocol":"shell","localPort":1,"remotePort":2}]}''',
      '''{"version":4,"redacted":false,"servers":[{"serverId":"SERVER01"}],"selectedServerId":"SERVER01","configs":[{"id":1,"name":"bad","protocol":"tcp","localPort":1,"remotePort":70000}]}''',
    ]) {
      expect(ConfigImportExport.parseJson(json), isNull, reason: json);
    }
  });

  test('imports reject oversized or invalid dormant proxy fields', () {
    final oversizedName = List.filled(129, 'x').join();
    final oversizedAddress = List.filled(256, 'a').join();
    for (final config in [
      {'id': 1, 'name': 'bad', 'serverName': oversizedName},
      {'id': 1, 'name': 'bad', 'fallbackTo': 'unsafe\nname'},
      {'id': 1, 'name': 'bad', 'serverAddr': oversizedAddress},
      {'id': 1, 'name': 'bad', 'serverPort': 70000},
      {
        'id': 1,
        'name': 'bad',
        'customDomains': List.filled(129, 'unused.example.com'),
      },
      {
        'id': 1,
        'name': 'bad',
        'portMappings': List.filled(129, const {
          'localPort': 1,
          'remotePort': 2,
        }),
      },
      {'id': 1, 'name': 'bad', 'fallbackTimeoutMs': 86400001},
    ]) {
      final json = jsonEncode({
        'version': 4,
        'redacted': false,
        'servers': [
          {'serverId': 'SERVER01'},
        ],
        'selectedServerId': 'SERVER01',
        'configs': [config],
      });
      expect(ConfigImportExport.parseJson(json), isNull, reason: json);
    }
  });

  test('backup record limits are checked before model decoding', () {
    expect(
      () => ExportData.fromJson({
        'version': 4,
        'redacted': false,
        'servers': List<Object?>.filled(257, {'serverId': 42}),
        'selectedServerId': 'SERVER01',
        'configs': const [],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Too many server records'),
        ),
      ),
    );

    expect(
      () => ExportData.fromJson({
        'version': 4,
        'redacted': false,
        'servers': const [
          {'serverId': 'SERVER01'},
        ],
        'selectedServerId': 'SERVER01',
        'configs': List<Object?>.filled(4097, {'id': 'invalid'}),
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Too many proxy records'),
        ),
      ),
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
      id: 1,
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
      id: 1,
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
        bindPort: 9201,
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
        bindPort: 9202,
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
      id: 1,
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

  test('manual TOML metadata only recognizes exact name and type keys', () {
    const config = FrpConfig(
      name: 'manual',
      protocol: 'tcp',
      manualToml: '''username = "not-a-proxy-name"
prototype = "udp"
name = "actual-proxy"
type = "tcp"''',
    );

    expect(config.manualNames, ['actual-proxy']);
    expect(config.manualTypes, ['tcp']);
  });

  test(
    'redacted manual TOML clears common credentials without losing blocks',
    () {
      const config = FrpConfig(
        id: 1,
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
# token = "comment-token"
description = "preserved" # apiKey = "inline-comment-secret"
password = "password-secret"
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
      expect(manualToml, isNot(contains('# token')));
      expect(manualToml, contains('description = "preserved"'));
      expect(manualToml, isNot(contains('# apiKey')));
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
        'comment-token',
        'inline-comment-secret',
        'password-secret',
      ]) {
        expect(manualToml, isNot(contains(secret)));
      }
    },
  );

  test('redacted manual TOML handles a fully quoted dotted secret key', () {
    const server = ServerConfig(serverId: 'SERVER01');
    const config = FrpConfig(
      id: 1,
      name: 'quoted-key',
      manualToml: '''"auth.token" = "quoted-secret"
name = "preserved"''',
    );

    final bytes = ConfigImportExport.buildExportZip(
      const [config],
      const [server],
      server.serverId,
      const {},
    );
    final manualToml = ConfigImportExport.parseImportBytes(bytes)!
        .configs
        .single
        .manualToml!;

    expect(manualToml, contains('"auth.token" = ""'));
    expect(manualToml, isNot(contains('quoted-secret')));
    expect(manualToml, contains('name = "preserved"'));
  });

  test('redacted manual TOML clears nested sk credential keys', () {
    const server = ServerConfig(serverId: 'SERVER01');
    const config = FrpConfig(
      id: 1,
      name: 'nested-sk',
      manualToml: '''plugin.sk = "plugin-secret"
"auth.sk" = "auth-secret"
name = "preserved"''',
    );

    final bytes = ConfigImportExport.buildExportZip(
      const [config],
      const [server],
      server.serverId,
      const {},
    );
    final manualToml = ConfigImportExport.parseImportBytes(bytes)!
        .configs
        .single
        .manualToml!;

    expect(manualToml, contains('plugin.sk = ""'));
    expect(manualToml, contains('"auth.sk" = ""'));
    expect(manualToml, isNot(contains('plugin-secret')));
    expect(manualToml, isNot(contains('auth-secret')));
  });

  test('redacted export rejects nested credentials in inline TOML tables', () {
    const server = ServerConfig(serverId: 'SERVER01');
    const config = FrpConfig(
      id: 1,
      name: 'inline-table',
      manualToml: 'auth = { token = "inline-secret" }',
    );

    expect(
      () => ConfigImportExport.buildExportZip(
        const [config],
        const [server],
        server.serverId,
        const {},
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('inline TOML tables'),
        ),
      ),
    );
  });

  test(
    'redacted export rejects escaped and safely parses quoted TOML keys',
    () {
      const server = ServerConfig(serverId: 'SERVER01');
      const escaped = FrpConfig(
        id: 1,
        name: 'escaped-key',
        manualToml: r'''"to\u006ben" = "escaped-secret"''',
      );
      expect(
        () => ConfigImportExport.buildExportZip(
          const [escaped],
          const [server],
          server.serverId,
          const {},
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('escaped TOML keys'),
          ),
        ),
      );

      const quotedEquals = FrpConfig(
        id: 1,
        name: 'quoted-equals',
        manualToml: '''"auth=token" = "quoted-secret"
name = "preserved"''',
      );
      final bytes = ConfigImportExport.buildExportZip(
        const [quotedEquals],
        const [server],
        server.serverId,
        const {},
      );
      final manualToml = ConfigImportExport.parseImportBytes(bytes)!
          .configs
          .single
          .manualToml!;
      expect(manualToml, contains('"auth=token" = ""'));
      expect(manualToml, isNot(contains('quoted-secret')));
    },
  );

  test('redacted export rejects multiline credential values', () {
    const server = ServerConfig(serverId: 'SERVER01');
    const config = FrpConfig(
      id: 1,
      name: 'multiline-secret',
      manualToml: r'''password = """
\"""
must-not-leak
"""''',
    );

    expect(
      () => ConfigImportExport.buildExportZip(
        const [config],
        const [server],
        server.serverId,
        const {},
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('multiline TOML strings'),
        ),
      ),
    );
  });

  test('redacted export rejects non-credential multiline TOML strings', () {
    const server = ServerConfig(serverId: 'SERVER01');
    for (final delimiter in const ['"""', "'''"]) {
      final config = FrpConfig(
        id: 1,
        name: 'multiline-description',
        manualToml:
            'description = $delimiter\n'
            '# this is string content, not a comment\n'
            'token = "also string content"\n'
            '$delimiter',
      );

      expect(
        () => ConfigImportExport.buildExportZip(
          [config],
          const [server],
          server.serverId,
          const {},
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('multiline TOML strings'),
          ),
        ),
      );
    }
  });

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

  test('export refuses archives that its bounded importer cannot accept', () {
    final server = ServerConfig(
      serverId: 'SERVER01',
      serverAddr: 'one.example.com',
    );
    expect(
      () => ConfigImportExport.buildExportZip(
        const [],
        [server],
        server.serverId,
        {
          server.serverId: List.filled(
            ConfigImportExport.maxImportBytes + 1,
            'A',
          ).join(),
        },
        includeSecrets: true,
      ),
      throwsStateError,
    );

    final tooManyServers = List.generate(
      ConfigImportExport.maxArchiveEntries,
      (index) => ServerConfig(
        serverId: 'S${index.toString().padLeft(7, '0')}',
        serverAddr: 'one.example.com',
      ),
    );
    expect(
      () => ConfigImportExport.buildExportZip(
        const [],
        tooManyServers,
        tooManyServers.first.serverId,
        const {},
        includeSecrets: true,
      ),
      throwsStateError,
    );
  });

  test('export bounds caller collections before model or TOML processing', () {
    expect(
      () => ConfigImportExport.buildExportZip(
        List<FrpConfig>.filled(4097, const FrpConfig()),
        const [],
        '',
        const {},
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('too many proxy records'),
        ),
      ),
    );
    expect(
      () => ConfigImportExport.buildExportZip(
        const [],
        List<ServerConfig>.filled(257, const ServerConfig()),
        '',
        const {},
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('too many server records'),
        ),
      ),
    );
    final tooManyTomls = <String, String>{
      for (var index = 0; index < 257; index++)
        'T${index.toString().padLeft(7, '0')}': '',
    };
    expect(
      () => ConfigImportExport.buildExportZip(
        const [],
        const [],
        '',
        tooManyTomls,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('too many server TOML records'),
        ),
      ),
    );
  });

  test('export stops JSON encoding at the byte boundary', () {
    final configs = List<FrpConfig>.generate(
      4096,
      (index) => FrpConfig(
        id: index + 1,
        name: 'proxy-$index',
        localPort: 22,
        remotePort: 10022,
      ),
      growable: false,
    );

    expect(
      () => ConfigImportExport.buildExportZip(configs, const [], '', const {}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('2 MiB JSON limit'),
        ),
      ),
    );
  });

  test('export validates server TOML keys and UTF-8 byte length', () {
    const server = ServerConfig(serverId: 'SERVER01');
    expect(
      () => ConfigImportExport.buildExportZip(
        const [],
        const [server],
        server.serverId,
        const {'UNKNOWN1': 'serverAddr = "example.com"'},
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('unknown Server ID'),
        ),
      ),
    );
    final oversized = List<String>.filled(
      (ConfigImportExport.maxImportBytes ~/ 3) + 1,
      '中',
    ).join();
    expect(oversized.length, lessThan(ConfigImportExport.maxImportBytes));
    expect(
      () => ConfigImportExport.buildExportZip(
        const [],
        const [server],
        server.serverId,
        {server.serverId: oversized},
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('5 MiB entry limit'),
        ),
      ),
    );
  });

  test('redacted export keeps the existing empty-server backup semantics', () {
    final bytes = ConfigImportExport.buildExportZip(
      const [],
      const [],
      '',
      const {},
    );
    final data = ConfigImportExport.parseImportBytes(bytes);

    expect(data, isNotNull);
    expect(data!.servers, isEmpty);
    expect(data.configs, isEmpty);
    expect(data.selectedServerId, isEmpty);
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
