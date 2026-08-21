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
  });
}
