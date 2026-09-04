import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/connection_status.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/services/config_domain_service.dart';
import 'package:frp_app/services/config_validator.dart';

void main() {
  test('status aggregation uses error, P2P, relay priority', () {
    expect(
      ConfigDomainService.aggregateStatuses([
        ConnectionType.relay,
        ConnectionType.error,
        ConnectionType.p2p,
      ]),
      ConnectionType.error,
    );
    expect(
      ConfigDomainService.aggregateStatuses([
        ConnectionType.relay,
        ConnectionType.p2p,
      ]),
      ConnectionType.p2p,
    );
  });

  test('group and manual names aggregate into one application row', () {
    const xtcp = FrpConfig(
      name: 'ssh-xtcp',
      protocol: 'xtcp',
      groupId: 7,
      groupName: 'SSH',
      isGroupPrimary: true,
    );
    const stcp = FrpConfig(
      name: 'ssh-stcp',
      protocol: 'stcp',
      groupId: 7,
      groupName: 'SSH',
    );
    const manual = FrpConfig(
      name: 'Manual group',
      manualToml: '[[visitors]]\nname = "one"\n[[visitors]]\nname = "two"',
    );
    final rows = ConfigDomainService.buildAppRows(
      [xtcp, stcp, manual],
      {
        'ssh-xtcp': ConnectionType.p2p,
        'ssh-stcp': ConnectionType.relay,
        'two': ConnectionType.error,
      },
    );
    expect(rows, hasLength(2));
    expect(rows.first.name, 'SSH');
    expect(rows.first.status, ConnectionType.p2p);
    expect(rows.last.status, ConnectionType.error);
  });

  test('multi-port proxy names aggregate into one application row', () {
    const config = FrpConfig(
      name: 'services',
      protocol: 'udp',
      localPort: 5000,
      remotePort: 15000,
      portMappings: [
        PortMapping(localPort: 5000, remotePort: 15000),
        PortMapping(localPort: 5001, remotePort: 15001),
      ],
    );

    expect(config.configuredNames, ['services-5000', 'services-5001']);
    expect(config.runtimeNames, ['services', 'services-5000', 'services-5001']);
    final rows = ConfigDomainService.buildAppRows(
      const [config],
      const {'services-5001': ConnectionType.error},
    );
    expect(rows.single.name, 'services');
    expect(rows.single.status, ConnectionType.error);
  });

  test('single configs use their group name as the application name', () {
    const config = FrpConfig(
      name: 'ssh-xtcp',
      groupName: 'Office SSH',
      protocol: 'xtcp',
    );

    final rows = ConfigDomainService.buildAppRows(const [config], const {});
    final groups = ConfigDomainService.buildGroups(const [config]);

    expect(rows.single.name, 'Office SSH');
    expect(groups.single.groupName, 'Office SSH');
    expect(groups.single.isGroup, isFalse);
  });

  test(
    'dashboard rows include only the selected server and legacy configs',
    () {
      final rows = ConfigDomainService.buildAppRowsForServer(
        const [
          FrpConfig(name: 'selected', serverId: 'SERVER01'),
          FrpConfig(name: 'other', serverId: 'SERVER02'),
          FrpConfig(name: 'legacy'),
        ],
        const {
          'selected': ConnectionType.connected,
          'other': ConnectionType.error,
          'legacy': ConnectionType.relay,
        },
        'SERVER01',
      );

      expect(rows.map((row) => row.name), ['selected', 'legacy']);
      expect(rows.map((row) => row.status), [
        ConnectionType.connected,
        ConnectionType.relay,
      ]);
    },
  );

  test('multi-port generated names detect same-server collisions', () {
    const candidate = FrpConfig(
      name: 'services',
      protocol: 'tcp',
      portMappings: [
        PortMapping(localPort: 22, remotePort: 10022),
        PortMapping(localPort: 80, remotePort: 10080),
      ],
      serverId: 'SERVER01',
    );
    expect(
      ConfigDomainService.findMultiPortNameCollision(candidate, const [
        FrpConfig(
          id: 7,
          name: 'services-80',
          protocol: 'tcp',
          localPort: 8080,
          remotePort: 18080,
          serverId: 'SERVER01',
        ),
      ]),
      'services-80',
    );
    expect(
      ConfigDomainService.findMultiPortNameCollision(candidate, const [
        FrpConfig(
          id: 8,
          name: 'services-80',
          protocol: 'tcp',
          localPort: 8080,
          remotePort: 18080,
          serverId: 'SERVER02',
        ),
      ]),
      isNull,
    );
  });

  test('validator and linked STCP derivation are deterministic', () {
    const xtcp = FrpConfig(
      name: 'ssh-xtcp',
      protocol: 'xtcp',
      role: 'visitor',
      serverName: 'ssh-xtcp',
      secretKey: 'secret',
      bindPort: -1,
      serverId: 'SERVER01',
    );
    expect(ConfigValidator.validate(xtcp), isNull);
    final stcp = ConfigDomainService.createLinkedStcpConfig(xtcp);
    expect(stcp.name, 'ssh-stcp');
    expect(stcp.serverName, 'ssh-stcp');
    expect(stcp.serverId, 'SERVER01');
  });

  test('linked XUDP fallback derives an independent SUDP visitor', () {
    const xudp = FrpConfig(
      name: 'game-xudp',
      protocol: 'xudp',
      role: 'visitor',
      serverName: 'remote-xudp',
      secretKey: 'udp-secret',
      bindPort: 2000,
      serverId: 'SERVER01',
    );

    final sudp = ConfigDomainService.createLinkedFallbackConfig(xudp);
    expect(xudp.supportsFallback(), isTrue);
    expect(sudp.name, 'game-sudp');
    expect(sudp.protocol, 'sudp');
    expect(sudp.serverName, 'remote-sudp');
    expect(sudp.secretKey, 'udp-secret');
    expect(sudp.bindPort, 2001);
    expect(sudp.bindAddr, '127.0.0.1');
    expect(sudp.serverId, 'SERVER01');
    expect(
      ConfigDomainService.fallbackServerNameFor(
        'remote',
        protocol: 'xudp',
        fallbackProtocol: 'sudp',
      ),
      'remote-sudp',
    );
  });

  test('fallback names preserve generated multi-port suffixes', () {
    expect(
      ConfigDomainService.fallbackNameFor(
        'MuMuDev-ADB-xtcp-39001',
        protocol: 'xtcp',
      ),
      'MuMuDev-ADB-stcp-39001',
    );
    expect(
      ConfigDomainService.fallbackNameFor(
        'MuMuDev-ADB-xudp-39002',
        protocol: 'xudp',
      ),
      'MuMuDev-ADB-sudp-39002',
    );
    expect(
      ConfigDomainService.fallbackServerNameFor(
        'service-xtcp-label-xtcp-39001',
        protocol: 'xtcp',
        fallbackProtocol: 'stcp',
      ),
      'service-xtcp-label-stcp-39001',
    );
  });

  test('effective XTCP naming is idempotent', () {
    expect(
      ConfigDomainService.effectiveName(
        'ssh',
        protocol: 'xtcp',
        useNamingRule: true,
      ),
      'ssh-xtcp',
    );
    expect(
      ConfigDomainService.effectiveName(
        'ssh-xtcp',
        protocol: 'xtcp',
        useNamingRule: true,
      ),
      'ssh-xtcp',
    );
  });

  test('XUDP is validated as a secret proxy and visitor protocol', () {
    expect(
      ConfigValidator.validate(
        const FrpConfig(
          name: 'game',
          protocol: 'xudp',
          role: 'server',
          localPort: 2000,
          secretKey: 'secret',
        ),
      ),
      isNull,
    );
    expect(
      ConfigValidator.validate(
        const FrpConfig(
          name: 'game-client',
          protocol: 'xudp',
          role: 'visitor',
          serverName: 'game',
          bindPort: 2000,
          secretKey: 'secret',
        ),
      ),
      isNull,
    );
    expect(
      ConfigValidator.validate(
        const FrpConfig(
          name: 'relay-client',
          protocol: 'sudp',
          role: 'visitor',
          serverName: 'relay-server',
          bindPort: -1,
          secretKey: 'secret',
        ),
      ),
      'Bind port must be between 1 and 65535 for SUDP',
    );
  });

  test(
    'validator rejects unsupported protocols, roles, and oversized ports',
    () {
      expect(
        ConfigValidator.validate(
          const FrpConfig(
            name: 'bad',
            protocol: 'shell',
            localPort: 22,
            remotePort: 10022,
          ),
        ),
        'Unsupported proxy protocol',
      );
      expect(
        ConfigValidator.validate(
          const FrpConfig(
            name: 'bad-role',
            protocol: 'xtcp',
            role: 'admin',
            secretKey: 'secret',
            localPort: 22,
          ),
        ),
        'Role must be server or visitor',
      );
      expect(
        ConfigValidator.validate(
          const FrpConfig(
            name: 'bad-port',
            protocol: 'stcp',
            role: 'server',
            secretKey: 'secret',
            localPort: 70000,
          ),
        ),
        'Local port is required',
      );
    },
  );

  test('HTTP form configs require a custom domain instead of remote port', () {
    expect(
      ConfigValidator.validate(
        const FrpConfig(
          name: 'web',
          protocol: 'http',
          localPort: 8080,
          customDomains: ['web.example.com'],
        ),
      ),
      isNull,
    );
    expect(
      ConfigValidator.validate(
        const FrpConfig(name: 'web', protocol: 'https', localPort: 8443),
      ),
      'At least one custom domain is required',
    );
  });

  test('TCP and UDP multi-port mappings are validated as a unit', () {
    expect(
      ConfigValidator.validate(
        const FrpConfig(
          name: 'services',
          protocol: 'tcp',
          portMappings: [
            PortMapping(localPort: 22, remotePort: 10022),
            PortMapping(localPort: 80, remotePort: 10080),
          ],
        ),
      ),
      isNull,
    );
    expect(
      ConfigValidator.validate(
        const FrpConfig(
          name: 'services',
          protocol: 'udp',
          portMappings: [
            PortMapping(localPort: 53, remotePort: 10053),
            PortMapping(localPort: 54, remotePort: 10053),
          ],
        ),
      ),
      'Remote ports must not contain duplicates',
    );
  });
}
