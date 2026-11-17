import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/models/socks5_config.dart';
import 'package:frp_app/services/socks5_log_entry.dart';
import 'package:frp_app/services/socks5_runtime_plan.dart';
import 'package:frp_app/services/toml_generator.dart';

const settings = Socks5Config(
  targetIp: '192.0.2.10',
  username: 'account',
  password: 'private-password',
  tcpPorts: [8080, 8443],
  udpPorts: [5353],
);

FrpConfig visitor(
  String name, {
  String protocol = 'stcp',
  int id = 1,
  int groupId = 1,
  int bindPort = 1080,
  String bindAddr = '127.0.0.1',
  Socks5Config? socks5 = settings,
}) => FrpConfig(
  id: id,
  name: name,
  serverId: 'SERVER01',
  groupId: groupId,
  protocol: protocol,
  role: 'visitor',
  serverName: 'provider-$name',
  secretKey: 'visitor-secret',
  bindAddr: bindAddr,
  bindPort: bindPort,
  socks5: socks5,
);

void main() {
  test('runtime and filter contexts encode imported IDs identically', () {
    final entries = [
      Socks5Connection(id: 'password=alpha', name: 'First', tcpPorts: [8080]),
      Socks5Connection(id: 'password=beta', name: 'Second', tcpPorts: [8443]),
    ];
    final selected = settings.copyWith(connections: entries);
    final config = visitor('tcp', socks5: selected);
    final plan = Socks5RuntimePlan.build([config]);
    for (var index = 0; index < entries.length; index++) {
      expect(
        plan.forwards[index]['logContext'],
        Socks5LogContext.fromConfig(config, entries[index]).toJson(),
      );
      expect(
        (plan.forwards[index]['logContext'] as Map)['connectionId'],
        startsWith('encoded/'),
      );
    }
    expect(selected.connections.map((row) => row.id), [
      'password=alpha',
      'password=beta',
    ]);
    expect(
      plan.forwards.first['logContext'],
      isNot(plan.forwards.last['logContext']),
    );
  });

  test('every port in a named row shares its stable log ownership', () {
    final row = Socks5Connection(
      id: 'media-stable',
      name: 'Video ["HD"]',
      tcpPorts: [8080, 8443],
      udpPorts: [5353, 8080],
    );
    final selected = settings.copyWith(connections: [row]);
    final tcp = visitor(
      'tcp',
      socks5: selected,
    ).copyWith(groupName: 'Group ["A"]');
    final anotherTcp = visitor(
      'another-tcp',
      id: 2,
      bindPort: 1081,
      socks5: selected,
    ).copyWith(groupName: tcp.groupName);
    final udp = visitor(
      'udp',
      id: 3,
      protocol: 'xudp',
      socks5: selected,
    ).copyWith(groupName: tcp.groupName);
    final context = Socks5LogContext.fromConfig(tcp, row);
    final plan = Socks5RuntimePlan.build([tcp, anotherTcp, udp]);
    expect(plan.forwards, hasLength(4));
    for (final forward in plan.forwards) {
      expect(forward['logContext'], context.toJson());
      expect(
        forward['upstreams'],
        hasLength(forward['protocol'] == 'tcp' ? 2 : 1),
      );
    }
    final renamed = selected.copyWith(
      connections: [row.copyWith(name: 'Renamed row')],
    );
    final changed = Socks5RuntimePlan.build([
      tcp.copyWith(
        name: 'renamed visitor',
        groupName: 'Renamed group',
        socks5: renamed,
      ),
    ]);
    for (final forward in changed.forwards) {
      final metadata = forward['logContext'] as Map;
      expect(metadata['configKey'], context.configKey);
      expect(metadata['connectionId'], context.connectionId);
      expect(metadata['configName'], 'Renamed group');
      expect(metadata['connectionName'], 'Renamed row');
    }
  });

  test(
    'same numeric ports on separate bindings retain different log owners',
    () {
      final selected = settings.copyWith(tcpPorts: [8080], udpPorts: []);
      final first = visitor('first', groupId: 0, socks5: selected);
      final second = visitor(
        'second',
        id: 2,
        groupId: 0,
        bindPort: 1081,
        bindAddr: '127.0.0.2',
        socks5: selected,
      );
      final plan = Socks5RuntimePlan.build([first, second]);
      expect(plan.forwards.map((forward) => forward['listenPort']), [
        8080,
        8080,
      ]);
      expect(
        plan.forwards.map(
          (forward) => (forward['logContext'] as Map)['configKey'],
        ),
        ['SERVER01/config/1', 'SERVER01/config/2'],
      );
    },
  );

  test(
    'shared listeners cannot ambiguously belong to different named rows',
    () {
      final first = visitor('first');
      final changedIdentity = settings.copyWith(
        connections: [settings.connections.single.copyWith(id: 'another-row')],
      );
      expect(
        () => Socks5RuntimePlan.build([
          first,
          visitor('second', id: 2, bindPort: 1081, socks5: changedIdentity),
        ]),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('different SOCKS5 connection entries'),
          ),
        ),
      );
    },
  );

  test('autonomous XUDP keeps its own relay and omits the old SUDP block', () {
    final primary = visitor(
      'primary',
      protocol: 'xudp',
    ).copyWith(useFallback: true, fallbackTo: 'old-sudp');
    // The legacy fallback's UDP port can be reused by the new business
    // listener because that fallback does not run in autonomous mode.
    final fallback = visitor(
      'old-sudp',
      protocol: 'sudp',
      id: 2,
      bindPort: 5353,
      socks5: null,
    );
    final plan = Socks5RuntimePlan.build([primary, fallback]);
    expect(plan.emitsConfig(primary), isTrue);
    expect(plan.emitsConfig(fallback), isFalse);
    final text = generateServerPreview(const ServerConfig(), [
      primary,
      fallback,
    ]);
    expect(text, contains('type = "xudp"'));
    expect(text, contains('type = "socks5_udp"'));
    expect(text, isNot(contains('fallbackTo')));
    expect(text, isNot(contains('old-sudp')));
    expect(
      generateToml(const ServerConfig(), primary, fallback),
      isNot(contains('old-sudp')),
    );
    final restored = generateServerPreview(const ServerConfig(), [
      primary.copyWith(socks5: null),
      fallback,
    ]);
    expect(restored, contains('fallbackTo = "old-sudp"'));
    expect(restored, contains('name = "old-sudp"'));
  });

  test('SOCKS5 settings roundtrip without changing legacy JSON', () {
    const legacy = FrpConfig(name: 'legacy');
    expect(legacy.toJson(), isNot(contains('socks5')));
    expect(FrpConfig.fromJson(legacy.toJson()).socks5, isNull);
    final config = visitor('configured');
    expect(FrpConfig.fromJson(config.toJson()).socks5, settings);
    expect(config.copyWith(name: 'renamed').socks5, settings);
    expect(config.copyWith(socks5: null).socks5, isNull);
    expect(
      () => FrpConfig.fromJson({...legacy.toJson(), 'socks5': 'bad'}),
      throwsFormatException,
    );
    expect(
      () => Socks5Config.fromJson({
        ...settings.toJson(),
        'tcpPorts': ['80'],
      }),
      throwsFormatException,
    );
    expect(
      () => Socks5Config.fromJson({...settings.toJson(), 'password': 123}),
      throwsFormatException,
    );
  });

  test(
    'port parsing accepts commas, deduplicates, and rejects partial input',
    () {
      expect(Socks5Config.parsePorts(' 80,443, 80 '), [80, 443]);
      expect(Socks5Config.parsePorts(''), isEmpty);
      for (final text in ['80,', ',80', '0', '-1', '65536', '80;443', '1.5']) {
        expect(() => Socks5Config.parsePorts(text), throwsFormatException);
      }
    },
  );

  test('credentials use UTF-8 byte limits and allow an empty password', () {
    expect(settings.copyWith(password: '').validationError(), isNull);
    expect(
      settings.copyWith(username: '', password: '').requiresAuthentication,
      isFalse,
    );
    expect(settings.copyWith(password: '').requiresAuthentication, isTrue);
    expect(settings.copyWith(password: '密' * 85).validationError(), isNull);
    expect(settings.copyWith(password: '密' * 86).validationError(), isNotNull);
    expect(settings.copyWith(targetIp: '::1').validationError(), isNull);
    expect(
      settings.copyWith(targetIp: 'example.com').validationError(),
      isNotNull,
    );
    expect(
      settings.copyWith(tcpPorts: [], udpPorts: []).validationError(),
      isNull,
    );
  });

  test(
    'TCP and UDP each get a private SOCKS endpoint when bind ports match',
    () {
      final tcp = visitor('tcp', bindAddr: '0.0.0.0');
      final udp = visitor('udp', id: 2, protocol: 'xudp', bindAddr: '0.0.0.0');
      final plan = Socks5RuntimePlan.build([tcp, udp]);
      expect(plan.endpointFor(tcp)!.port, 1080);
      expect(plan.endpointFor(udp)!.port, isNot(1080));
      expect(plan.endpointFor(udp)!.datagram, isTrue);
      expect(plan.forwards, hasLength(3));
      expect(plan.forwards.map((forward) => forward['listenPort']), [
        8080,
        8443,
        5353,
      ]);
      for (final forward in plan.forwards) {
        expect(forward['bindAddress'], '0.0.0.0');
        expect(forward['targetIp'], '192.0.2.10');
        expect(forward['targetPort'], forward['listenPort']);
        expect(forward['mode'], 'onDemand');
        final upstream = (forward['upstreams'] as List).single as Map;
        expect(upstream['host'], '127.0.0.1');
        expect(upstream['username'], 'account');
        expect(upstream['password'], 'private-password');
      }
      expect(Socks5RuntimePlan.build([tcp, udp]).forwards, plan.forwards);
    },
  );

  test('each enabled connection passes its mode to TCP and UDP forwards', () {
    final selected = settings.copyWith(
      connections: [
        Socks5Connection(
          id: 'now',
          name: 'Immediate',
          mode: Socks5ConnectionMode.immediate,
          tcpPorts: [8080, 8443],
          udpPorts: [5353],
        ),
        Socks5Connection(
          id: 'later',
          name: 'On demand',
          tcpPorts: [9000],
          udpPorts: [9000],
        ),
        Socks5Connection(
          id: 'disabled',
          name: 'Disabled',
          enabled: false,
          mode: Socks5ConnectionMode.immediate,
          udpPorts: [9001],
        ),
      ],
    );
    final plan = Socks5RuntimePlan.build([
      visitor('tcp', socks5: selected),
      visitor('another-tcp', id: 2, bindPort: 1081, socks5: selected),
      visitor('udp', id: 3, protocol: 'xudp', socks5: selected),
    ]);
    expect(plan.forwards, hasLength(5));
    for (final forward in plan.forwards) {
      expect(
        forward['mode'],
        forward['listenPort'] == 9000 ? 'onDemand' : 'immediate',
      );
      expect(
        forward['upstreams'],
        hasLength(forward['protocol'] == 'tcp' ? 2 : 1),
      );
    }
  });

  test('row targets resolve independently for every TCP and UDP listener', () {
    final inherited = Socks5Connection(
      id: 'inherited',
      name: 'Inherited',
      tcpPorts: [8080],
      udpPorts: [5353],
    );
    final override = Socks5Connection(
      id: 'override',
      name: 'Override',
      targetIp: '2001:db8::20',
      tcpPorts: [8443],
      udpPorts: [9000],
      mode: Socks5ConnectionMode.immediate,
    );
    final disabled = Socks5Connection(
      id: 'disabled',
      name: 'Disabled',
      targetIp: '192.0.2.99',
      enabled: false,
      tcpPorts: [9999],
      udpPorts: [9999],
    );
    final selected = settings.copyWith(
      connections: [inherited, override, disabled],
    );
    Socks5RuntimePlan plan(Socks5Config configuration) =>
        Socks5RuntimePlan.build([
          visitor('tcp', socks5: configuration),
          visitor('another-tcp', id: 2, bindPort: 1081, socks5: configuration),
          visitor('udp', id: 3, protocol: 'xudp', socks5: configuration),
        ]);
    for (final configuration in [
      selected,
      selected.copyWith(targetIp: '192.0.2.30'),
    ]) {
      final current = plan(configuration);
      expect(current.forwards, hasLength(4));
      for (final forward in current.forwards) {
        final isOverride = [8443, 9000].contains(forward['listenPort']);
        expect(
          forward['targetIp'],
          isOverride ? '2001:db8::20' : configuration.targetIp,
        );
        expect(forward['targetPort'], forward['listenPort']);
        expect(forward['mode'], isOverride ? 'immediate' : 'onDemand');
        final upstreams = forward['upstreams'] as List;
        expect(upstreams, hasLength(forward['protocol'] == 'tcp' ? 2 : 1));
        for (final upstream in upstreams.cast<Map>()) {
          expect(upstream['username'], settings.username);
          expect(upstream['password'], settings.password);
        }
      }
    }
    final cleared = selected.copyWith(
      targetIp: '192.0.2.30',
      connections: [
        inherited,
        override.copyWith(targetIp: ''),
        disabled,
      ],
    );
    expect(
      plan(cleared).forwards
          .every((forward) => forward['targetIp'] == '192.0.2.30'),
      isTrue,
    );
  });

  test('shared listeners compare resolved row targets rather than parents', () {
    final row = Socks5Connection(
      id: 'shared',
      name: 'Shared',
      tcpPorts: [8080],
      targetIp: '192.0.2.30',
    );
    final first = settings.copyWith(connections: [row]);
    final second = first.copyWith(
      targetIp: '192.0.2.30',
      connections: [row.copyWith(targetIp: '')],
    );
    final plan = Socks5RuntimePlan.build([
      visitor('first', socks5: first),
      visitor('second', id: 2, bindPort: 1081, socks5: second),
    ]);
    expect(plan.forwards.single['targetIp'], '192.0.2.30');
    expect(plan.forwards.single['upstreams'], hasLength(2));
  });

  test('shared TCP or UDP listeners reject conflicting effective targets', () {
    final row = Socks5Connection(
      id: 'shared',
      name: 'Shared',
      tcpPorts: [8080],
      udpPorts: [5353],
    );
    final first = settings.copyWith(connections: [row]);
    final second = first.copyWith(
      connections: [row.copyWith(targetIp: '192.0.2.30')],
    );
    for (final protocol in ['stcp', 'xudp']) {
      expect(
        () => Socks5RuntimePlan.build([
          visitor('first', protocol: protocol, socks5: first),
          visitor(
            'second',
            id: 2,
            bindPort: 1081,
            protocol: protocol,
            socks5: second,
          ),
        ]),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('conflicts with another SOCKS5 listener'),
          ),
        ),
      );
    }
  });

  test('sharing a listener requires matching connection modes', () {
    final immediate = settings.copyWith(
      connections: [
        settings.connections.single.copyWith(
          mode: Socks5ConnectionMode.immediate,
        ),
      ],
    );
    expect(
      () => Socks5RuntimePlan.build([
        visitor('first'),
        visitor('second', id: 2, bindPort: 1081, socks5: immediate),
      ]),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('conflicting SOCKS5 connection modes'),
        ),
      ),
    );
  });

  test(
    'all same-protocol visitors are retained on the shared business listener',
    () {
      final first = visitor('first');
      final second = visitor('second', id: 2, bindPort: 1081);
      final plan = Socks5RuntimePlan.build([first, second]);
      expect(plan.forwards, hasLength(2));
      for (final forward in plan.forwards) {
        final upstreams = forward['upstreams'] as List;
        expect(upstreams, hasLength(2));
        expect(upstreams.map((entry) => (entry as Map)['name']), [
          'first',
          'second',
        ]);
        expect(upstreams.map((entry) => (entry as Map)['port']), [1080, 1081]);
      }
    },
  );

  test('hidden fallbacks are excluded only within their server and group', () {
    final primary = visitor(
      'primary',
      protocol: 'xtcp',
    ).copyWith(useFallback: true, fallbackTo: 'fallback');
    final hidden = visitor('fallback', id: 2, bindPort: -1, socks5: null);
    final otherGroup = hidden.copyWith(id: 3, groupId: 2);
    final otherServer = hidden.copyWith(id: 4, serverId: 'SERVER02');
    final all = [primary, hidden, otherGroup, otherServer];
    expect(Socks5RuntimePlan.supportedVisitors(all), [
      primary,
      otherGroup,
      otherServer,
    ]);
    final plan = Socks5RuntimePlan.build([primary, hidden]);
    expect(plan.forwards, hasLength(2));
    expect(plan.endpointFor(hidden), isNull);
    final text = generateToml(const ServerConfig(), primary, hidden);
    expect(text, contains('fallbackTo = "fallback"'));
    expect(text, contains('bindPort = -1'));
  });

  test(
    'disabled visitors and protocols without selected ports do not forward',
    () {
      final disabled = visitor('disabled').copyWith(enabled: false);
      final udpOnly = visitor('tcp', socks5: settings.copyWith(tcpPorts: []));
      expect(Socks5RuntimePlan.supportedVisitors([disabled]), [disabled]);
      final plan = Socks5RuntimePlan.build([disabled, udpOnly]);
      expect(plan.forwards, isEmpty);
      expect(plan.endpointFor(udpOnly), isNull);
    },
  );

  test('TCP and UDP business listeners may share the same numeric port', () {
    final shared = settings.copyWith(tcpPorts: [9000], udpPorts: [9000]);
    final plan = Socks5RuntimePlan.build([
      visitor('tcp', socks5: shared),
      visitor('udp', protocol: 'sudp', id: 2, socks5: shared),
    ]);
    expect(plan.forwards.map((forward) => forward['protocol']), ['tcp', 'udp']);
    expect(plan.forwards.map((forward) => forward['listenPort']), [9000, 9000]);
  });

  test('wildcard overlap and cross-group port collisions fail visibly', () {
    final first = visitor('first', bindAddr: '0.0.0.0');
    for (final second in [
      visitor('other', id: 2, groupId: 2, bindPort: 1081),
      visitor('other', id: 2, bindPort: 1081),
      visitor('other', id: 2, bindPort: 1081, bindAddr: '::'),
    ]) {
      expect(
        () => Socks5RuntimePlan.build([first, second]),
        throwsFormatException,
      );
    }
  });

  test(
    'business listeners cannot replace another ordinary visitor listener',
    () {
      final source = visitor('socks');
      final ordinary = visitor('ordinary', id: 2, socks5: null, bindPort: 8080);
      expect(
        () => Socks5RuntimePlan.build([source, ordinary]),
        throwsFormatException,
      );
    },
  );

  test('internal allocation avoids raw visitor and business TCP ports', () {
    final source = visitor('socks', bindPort: 8080);
    final ordinary = visitor('ordinary', id: 2, socks5: null, bindPort: 49152);
    final plan = Socks5RuntimePlan.build([source, ordinary]);
    expect(plan.endpointFor(source)!.port, 49153);
    expect(plan.forwards.first['listenPort'], 8080);
  });

  test(
    'invalid SOCKS sources and empty autonomous UDP secrets are rejected',
    () {
      for (final source in [
        visitor('proxy').copyWith(role: 'server'),
        visitor('manual').copyWith(manualToml: '[[visitors]]\nname="manual"'),
        visitor('udp', protocol: 'sudp').copyWith(secretKey: ''),
      ]) {
        expect(() => Socks5RuntimePlan.build([source]), throwsFormatException);
      }
    },
  );

  test('listener and upstream limits report errors instead of truncating', () {
    final manyUpstreams = List.generate(
      129,
      (index) => visitor(
        'visitor-$index',
        id: index + 1,
        bindPort: 10000 + index,
        socks5: settings.copyWith(tcpPorts: [8080], udpPorts: []),
      ),
    );
    expect(() => Socks5RuntimePlan.build(manyUpstreams), throwsFormatException);
    final manyListeners = List.generate(
      3,
      (index) => visitor(
        'group-$index',
        id: index + 1,
        groupId: index + 1,
        bindPort: 10000 + index,
        socks5: settings.copyWith(
          tcpPorts: List.generate(
            128,
            (offset) => 20000 + index * 128 + offset,
          ),
          udpPorts: [],
        ),
      ),
    );
    expect(() => Socks5RuntimePlan.build(manyListeners), throwsFormatException);
  });

  test(
    'generated TOML uses autonomous UDP and never embeds SOCKS credentials',
    () {
      final tcp = visitor('tcp');
      final udp = visitor(
        'udp',
        id: 2,
        protocol: 'xudp',
      ).copyWith(useEncryption: true);
      final plan = Socks5RuntimePlan.build([tcp, udp]);
      final text = generateServerPreview(const ServerConfig(), [
        tcp,
        udp,
      ], socks5Plan: plan);
      final udpBlock = text.substring(text.indexOf('# Config: udp'));
      expect(udpBlock, contains('bindPort = -1'));
      expect(udpBlock, contains('[visitors.plugin]\ntype = "socks5_udp"'));
      expect(udpBlock, contains('bindAddr = "127.0.0.1"'));
      expect(udpBlock, contains('bindPort = ${plan.endpointFor(udp)!.port}'));
      expect(udpBlock, contains('[visitors.transport]\nuseEncryption = true'));
      expect(udpBlock, isNot(contains('udpVisitorAddr')));
      expect(udpBlock, isNot(contains('sessionMode')));
      expect(text, isNot(contains('private-password')));
      expect(text, isNot(contains('username')));
      expect(text, isNot(contains('password')));
      expect(generateServerPreview(const ServerConfig(), [tcp, udp]), text);
    },
  );
}
