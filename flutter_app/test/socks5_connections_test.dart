import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/models/socks5_config.dart';
import 'package:frp_app/services/config_import_export.dart';
import 'package:frp_app/services/config_store.dart';
import 'package:frp_app/services/socks5_runtime_plan.dart';
import 'package:frp_app/services/toml_generator.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = ServerConfig(serverId: 'SERVER01', serverAddr: '127.0.0.1');
const _legacy = Socks5Config(
  targetIp: '192.0.2.10',
  username: 'alice',
  password: 'upstream-password',
  tcpPorts: [18080],
  udpPorts: [15353],
);

Socks5Connection _connection(
  String id, {
  bool enabled = true,
  Socks5ConnectionMode mode = Socks5ConnectionMode.onDemand,
  String targetIp = '',
  List<int> tcp = const [],
  List<int> udp = const [],
}) => Socks5Connection(
  id: id,
  name: 'Connection $id',
  enabled: enabled,
  mode: mode,
  targetIp: targetIp,
  tcpPorts: tcp,
  udpPorts: udp,
);

FrpConfig _visitor(
  int id,
  String protocol,
  Socks5Config? settings, {
  int groupId = 1,
}) => FrpConfig(
  id: id,
  name: 'visitor-$id',
  protocol: protocol,
  role: 'visitor',
  serverId: _server.serverId,
  serverName: 'provider-$id',
  secretKey: 'visitor-secret',
  bindAddr: '127.0.0.1',
  bindPort: 11080 + id,
  groupId: groupId,
  groupName: 'Example',
  isGroupPrimary: id == 1,
  socks5: settings,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy JSON migrates to one stable enabled Default connection', () {
    final legacyJson = {
      'targetIp': _legacy.targetIp,
      'username': _legacy.username,
      'password': _legacy.password,
      'tcpPorts': [18080],
      'udpPorts': [15353],
    };
    final migrated = Socks5Config.fromJson(legacyJson);
    final entry = migrated.connections.single;
    expect(entry.id, 'default');
    expect(entry.name, 'Default');
    expect(entry.enabled, isTrue);
    expect(entry.mode, Socks5ConnectionMode.onDemand);
    expect(entry.targetIp, isEmpty);
    expect(entry.effectiveTargetIp(migrated.targetIp), migrated.targetIp);
    expect(migrated, _legacy);
    expect(migrated.hashCode, _legacy.hashCode);
    final restored = Socks5Config.fromJson(
      jsonDecode(jsonEncode(migrated.toJson())) as Map<String, dynamic>,
    );
    expect(restored, migrated);
    expect(restored.connections.single.id, entry.id);
    expect(migrated.toJson(), isNot(contains('tcpPorts')));
  });

  test('mode defaults for old rows and roundtrips explicit choices', () {
    final oldJson = {
      'id': 'legacy-row',
      'name': 'Saved connection',
      'tcpPorts': [18080],
    };
    final old = Socks5Connection.fromJson(oldJson);
    expect(old.mode, Socks5ConnectionMode.onDemand);
    final immediate = old.copyWith(mode: Socks5ConnectionMode.immediate);
    expect(immediate, isNot(old));
    expect(immediate.toJson()['mode'], 'immediate');
    expect(Socks5Connection.fromJson(immediate.toJson()), immediate);
    expect(immediate.copyWith(name: 'Renamed').mode, immediate.mode);
    expect(
      Socks5Connection.fromJson(immediate.toJson()).hashCode,
      immediate.hashCode,
    );
    for (final invalid in [null, true, 1, 'eager', '', []]) {
      expect(
        () => Socks5Connection.fromJson({...oldJson, 'mode': invalid}),
        throwsFormatException,
      );
    }
  });

  test('connection ports are immutable and copied independently', () {
    final input = [18080];
    final entry = _connection('stable', tcp: input);
    input.add(18443);
    expect(entry.tcpPorts, [18080]);
    expect(() => entry.tcpPorts.add(18443), throwsUnsupportedError);
    final disabled = entry.copyWith(name: 'Renamed', enabled: false);
    expect(entry.enabled, isTrue);
    expect(disabled.id, entry.id);
    expect(disabled.name, 'Renamed');
    expect(disabled.enabled, isFalse);
    expect(Socks5Connection.fromJson(disabled.toJson()), disabled);
    expect(
      Socks5Connection.fromJson(disabled.toJson()).hashCode,
      disabled.hashCode,
    );
    expect(Socks5Connection.generateId(), isNot(Socks5Connection.generateId()));
  });

  test('row target overrides roundtrip and clearing restores inheritance', () {
    final oldJson = {
      'id': 'old-row',
      'name': 'Old connection',
      'tcpPorts': [18080],
    };
    final inherited = Socks5Connection.fromJson(oldJson);
    expect(inherited.targetIp, isEmpty);
    expect(inherited.effectiveTargetIp('192.0.2.10'), '192.0.2.10');
    expect(inherited.effectiveTargetIp('192.0.2.20'), '192.0.2.20');
    final overridden = inherited.copyWith(targetIp: '2001:db8::10');
    expect(overridden, isNot(inherited));
    expect(overridden.effectiveTargetIp('192.0.2.20'), '2001:db8::10');
    expect(overridden.copyWith(name: 'Renamed').targetIp, '2001:db8::10');
    final restored = Socks5Connection.fromJson(
      jsonDecode(jsonEncode(overridden.toJson())) as Map<String, dynamic>,
    );
    expect(restored, overridden);
    expect(restored.hashCode, overridden.hashCode);
    expect(restored.copyWith(targetIp: ''), inherited);
    expect(
      restored.copyWith(targetIp: '').effectiveTargetIp('192.0.2.20'),
      '192.0.2.20',
    );
    expect(
      Socks5Connection.fromJson({...oldJson, 'targetIp': null}).targetIp,
      isEmpty,
    );
    for (final invalid in [true, 123, [], {}, 'x' * 1025]) {
      expect(
        () => Socks5Connection.fromJson({...oldJson, 'targetIp': invalid}),
        throwsFormatException,
      );
    }
  });

  test('row overrides validate numeric IPs even while disabled', () {
    final row = _connection('target', enabled: false, tcp: [18080]);
    for (final valid in ['', '192.0.2.20', '2001:db8::20', '::1']) {
      expect(row.copyWith(targetIp: valid).validationError(), isNull);
    }
    for (final invalid in [
      'example.com',
      ' ',
      ' 192.0.2.20',
      '192.0.2.20 ',
      '127.0.0.1:80',
      'fe80::1%eth0',
      '999.1.1.1',
    ]) {
      final settings = _legacy.copyWith(
        connections: [row.copyWith(targetIp: invalid)],
      );
      expect(settings.validationError(), contains('Connection target IP'));
    }
    expect(
      _legacy
          .copyWith(
            targetIp: '',
            connections: [row.copyWith(targetIp: '192.0.2.20')],
          )
          .validationError(),
      isNotNull,
      reason: 'A row override does not relax the existing parent requirement',
    );
  });

  test('aggregates retain row order and exclude only disabled rows', () {
    final settings = _legacy.copyWith(
      connections: [
        _connection('first', tcp: [18080], udp: [15353]),
        _connection('disabled', enabled: false, tcp: [19090], udp: [19091]),
        _connection('last', tcp: [18443]),
      ],
    );
    expect(settings.validationError(), isNull);
    expect(settings.tcpPorts, [18080, 18443]);
    expect(settings.udpPorts, [15353]);
    expect(settings.allTcpPorts, [18080, 19090, 18443]);
    expect(settings.allUdpPorts, [15353, 19091]);
    expect(settings.copyWith(password: '').connections, settings.connections);
    expect(settings.copyWith(password: '').username, _legacy.username);
    expect(
      Socks5Config.fromJson(settings.toJson()).connections,
      settings.connections,
    );
  });

  test('only enabled rows must use distinct ports within each protocol', () {
    final first = _connection('first', tcp: [18080], udp: [18080]);
    final second = _connection('second', enabled: false, tcp: [18080]);
    final settings = _legacy.copyWith(connections: [first, second]);
    expect(settings.validationError(), isNull);
    expect(
      settings
          .copyWith(connections: [first, second.copyWith(enabled: true)])
          .validationError(),
      contains('TCP port 18080'),
    );
    final udpConflict = second.copyWith(
      enabled: true,
      tcpPorts: [],
      udpPorts: [18080],
    );
    expect(
      settings.copyWith(connections: [first, udpConflict]).validationError(),
      contains('UDP port 18080'),
    );
    expect(
      settings
          .copyWith(connections: [first, first.copyWith(enabled: false)])
          .validationError(),
      contains('IDs must be unique'),
    );
  });

  test('disabled rows still validate names, ports and total limits', () {
    final entry = _connection('disabled', enabled: false, tcp: [18080]);
    expect(entry.copyWith(name: ' ').validationError(), isNotNull);
    expect(entry.copyWith(id: '').validationError(), isNotNull);
    expect(entry.copyWith(tcpPorts: []).validationError(), isNotNull);
    expect(entry.copyWith(tcpPorts: [0]).validationError(), isNotNull);
    expect(
      entry.copyWith(tcpPorts: [18080, 18080]).validationError(),
      isNotNull,
    );
    final settings = _legacy.copyWith(
      connections: [
        entry.copyWith(tcpPorts: List.generate(128, (index) => index + 1)),
        _connection('extra', enabled: false, tcp: [500]),
      ],
    );
    expect(settings.validationError(), contains('128 SOCKS5 ports'));
  });

  test('empty or disabled settings retain credentials without listeners', () {
    final empty = _legacy.copyWith(connections: []);
    expect(empty.validationError(), isNull);
    expect(empty.copyWith(targetIp: '').validationError(), isNull);
    expect(
      empty.copyWith(targetIp: 'example.com').validationError(),
      isNotNull,
    );
    expect(empty.username, _legacy.username);
    expect(empty.password, _legacy.password);
    final disabled = _legacy.copyWith(
      connections: [
        _connection('saved', enabled: false, udp: [15353]),
      ],
    );
    expect(disabled.validationError(), isNull);
    expect(disabled.copyWith(targetIp: '').validationError(), isNotNull);
    for (final settings in [empty, disabled]) {
      final config = _visitor(1, 'xudp', settings);
      final plan = Socks5RuntimePlan.build([config]);
      expect(plan.forwards, isEmpty);
      expect(plan.endpointFor(config), isNull);
      expect(
        generateServerPreview(_server, [config]),
        isNot(contains('type = "socks5_udp"')),
      );
      final restored = Socks5Config.fromJson(settings.toJson());
      expect(restored, settings);
      expect(restored.password, _legacy.password);
    }
  });

  test(
    'removing parent protocols preserves surviving row identity and state',
    () {
      final both = _connection(
        'both',
        enabled: false,
        mode: Socks5ConnectionMode.immediate,
        targetIp: '2001:db8::20',
        tcp: [18080],
        udp: [15353],
      );
      final tcp = _connection('tcp', tcp: [18443]);
      final udp = _connection('udp', udp: [18053]);
      final settings = _legacy.copyWith(connections: [both, tcp, udp]);
      final tcpOnly = settings.retainProtocols(tcp: true, udp: false);
      expect(tcpOnly.connections.map((entry) => entry.id), ['both', 'tcp']);
      expect(tcpOnly.connections.first.name, both.name);
      expect(tcpOnly.connections.first.enabled, isFalse);
      expect(tcpOnly.connections.first.mode, Socks5ConnectionMode.immediate);
      expect(tcpOnly.connections.first.targetIp, '2001:db8::20');
      expect(tcpOnly.connections.first.tcpPorts, both.tcpPorts);
      expect(tcpOnly.allUdpPorts, isEmpty);
      expect(tcpOnly.password, _legacy.password);
      final cleared = settings.retainProtocols(tcp: false, udp: false);
      expect(cleared.connections, isEmpty);
      expect(cleared.password, _legacy.password);
      expect(cleared.validationError(), isNull);
    },
  );

  test('only active rows generate forwards and UDP visitor plugins', () {
    final active = _connection('active', tcp: [18080], udp: [15353]);
    final inactive = _connection(
      'inactive',
      enabled: false,
      tcp: [18443],
      udp: [18053],
    );
    final settings = _legacy.copyWith(connections: [active, inactive]);
    final tcp = _visitor(1, 'xtcp', settings);
    final anotherTcp = _visitor(2, 'stcp', settings);
    final udp = _visitor(3, 'xudp', settings);
    final plan = Socks5RuntimePlan.build([tcp, anotherTcp, udp]);
    expect(plan.forwards.map((entry) => entry['listenPort']), [18080, 15353]);
    expect(plan.forwards.first['upstreams'], hasLength(2));
    for (final route in plan.forwards) {
      for (final upstream in route['upstreams'] as List) {
        expect((upstream as Map)['username'], _legacy.username);
        expect(upstream['password'], _legacy.password);
      }
    }
    expect(
      generateServerPreview(_server, [tcp, anotherTcp, udp]),
      contains('type = "socks5_udp"'),
    );
    final tcpOnly = settings.copyWith(
      connections: [
        active.copyWith(udpPorts: []),
        inactive,
      ],
    );
    final ordinaryUdp = udp.copyWith(socks5: tcpOnly);
    final tcpOnlyPlan = Socks5RuntimePlan.build([
      tcp.copyWith(socks5: tcpOnly),
      ordinaryUdp,
    ]);
    expect(tcpOnlyPlan.forwards.single['protocol'], 'tcp');
    expect(tcpOnlyPlan.endpointFor(ordinaryUdp), isNull);
  });

  test('backup roundtrip preserves rows while redacting only the password', () {
    final settings = _legacy.copyWith(
      connections: [
        _connection(
          'work',
          tcp: [18080],
          mode: Socks5ConnectionMode.immediate,
          targetIp: '192.0.2.20',
        ),
        _connection(
          'saved',
          enabled: false,
          tcp: [18443],
          targetIp: '2001:db8::20',
        ),
      ],
    );
    for (final secrets in [false, true]) {
      final bytes = ConfigImportExport.buildExportZip(
        [_visitor(1, 'stcp', settings)],
        const [_server],
        _server.serverId,
        const {'SERVER01': 'serverAddr = "127.0.0.1"\n'},
        includeSecrets: secrets,
      );
      final imported = ConfigImportExport.parseImportBytes(bytes)!;
      final restored = imported.configs.single.socks5!;
      expect(restored.connections, settings.connections);
      expect(restored.targetIp, settings.targetIp);
      expect(restored.username, settings.username);
      expect(restored.password, secrets ? settings.password : '');
    }
  });

  test(
    'named JSON rejects malformed rows and preserves deliberate emptiness',
    () {
      for (final connections in [
        'invalid',
        [1],
        [
          {'id': 'one', 'name': 'One', 'enabled': 'false'},
        ],
        [
          {
            'id': 'one',
            'name': 'One',
            'tcpPorts': ['80'],
          },
        ],
        [
          {
            'name': 'Missing ID',
            'tcpPorts': [80],
          },
        ],
      ]) {
        expect(
          () => Socks5Config.fromJson({
            ..._legacy.toJson(),
            'connections': connections,
          }),
          throwsFormatException,
        );
      }
      final cleared = Socks5Config.fromJson({
        ..._legacy.toJson(),
        'tcpPorts': [18080],
        'connections': [],
      });
      expect(cleared.connections, isEmpty);
      expect(cleared.tcpPorts, isEmpty);
    },
  );

  group('persisting row changes', () {
    const engine = MethodChannel('com.frp.app/engine');
    const secure = MethodChannel('com.frp.app/secure_store');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late AppState state;
    late List<MethodCall> calls;
    var failSave = false;

    setUp(() async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      calls = [];
      failSave = false;
      messenger.setMockMethodCallHandler(secure, (call) async {
        if (failSave && call.method == 'encrypt') {
          throw PlatformException(code: 'SAVE_FAILED');
        }
        return (call.arguments as Map)['value'];
      });
      messenger.setMockMethodCallHandler(engine, (call) async {
        calls.add(call);
        return switch (call.method) {
          'start' || 'stop' => true,
          'isRunRequested' => false,
          'getMemoryMb' || 'getTotalMemoryMb' => 0.0,
          _ => null,
        };
      });
      state = AppState()..pausePolling();
      await state.ready;
      state.servers = const [_server];
      await state.selectServer(_server.serverId);
      calls.clear();
    });

    tearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(engine, null);
      messenger.setMockMethodCallHandler(secure, null);
    });

    test(
      'toggling a row updates all visitors and removes only its listeners',
      () async {
        final tcp = _connection('tcp', tcp: [18080]);
        final udp = _connection('udp', udp: [15353]);
        final settings = _legacy.copyWith(connections: [tcp, udp]);
        state.configs = [
          _visitor(1, 'stcp', settings),
          _visitor(2, 'xudp', settings),
        ];
        await state.start();
        final disabled = settings.copyWith(
          connections: [tcp, udp.copyWith(enabled: false)],
        );
        await state.setSocks5ForConfig(1, disabled);
        expect(
          state.configs.every((config) => config.socks5 == disabled),
          isTrue,
        );
        final start =
            calls.lastWhere((call) => call.method == 'start').arguments as Map;
        final forwards = (start['socks5Forwards'] as List).cast<Map>();
        expect(forwards.single['listenPort'], 18080);
        expect(start['configContent'], isNot(contains('type = "socks5_udp"')));
        final saved = await ConfigStore().loadConfigurationSnapshot();
        expect(saved!.configs.first.socks5!.connections.last.enabled, isFalse);
        expect(saved.configs.first.socks5!.password, settings.password);
      },
    );

    test(
      'changing only mode persists and restarts with the selected policy',
      () async {
        final row = _connection('tcp', tcp: [18080]);
        final settings = _legacy.copyWith(connections: [row]);
        state.configs = [_visitor(1, 'stcp', settings)];
        await state.start();
        calls.clear();
        final updated = settings.copyWith(
          connections: [row.copyWith(mode: Socks5ConnectionMode.immediate)],
        );
        await state.setSocks5ForConfig(1, updated);
        expect(state.configs.single.socks5, updated);
        expect(calls.where((call) => call.method == 'stop'), hasLength(1));
        final start = calls.singleWhere((call) => call.method == 'start');
        final forwards = ((start.arguments as Map)['socks5Forwards'] as List)
            .cast<Map>();
        expect(forwards.single['mode'], 'immediate');
        final saved = await ConfigStore().loadConfigurationSnapshot();
        expect(
          saved!.configs.single.socks5!.connections.single.mode,
          Socks5ConnectionMode.immediate,
        );
      },
    );

    test(
      'row target changes restart the group and clearing restores parent',
      () async {
        final row = _connection('both', tcp: [18080], udp: [15353]);
        final sibling = _connection('inherited', tcp: [18443]);
        final settings = _legacy.copyWith(connections: [row, sibling]);
        state.configs = [
          _visitor(1, 'stcp', settings),
          _visitor(2, 'xudp', settings),
        ];
        await state.start();
        calls.clear();
        final updated = settings.copyWith(
          connections: [
            row.copyWith(targetIp: '2001:db8::20'),
            sibling,
          ],
        );
        await state.setSocks5ForConfig(1, updated);
        expect(
          state.configs.every((config) => config.socks5 == updated),
          isTrue,
        );
        expect(calls.where((call) => call.method == 'stop'), hasLength(1));
        final start = calls.singleWhere((call) => call.method == 'start');
        final forwards = ((start.arguments as Map)['socks5Forwards'] as List)
            .cast<Map>();
        expect(forwards, hasLength(3));
        for (final forward in forwards) {
          expect(
            forward['targetIp'],
            forward['listenPort'] == 18443 ? settings.targetIp : '2001:db8::20',
          );
        }
        final saved = await ConfigStore().loadConfigurationSnapshot();
        expect(
          saved!.configs.every((config) => config.socks5 == updated),
          isTrue,
        );

        calls.clear();
        await state.setSocks5ForConfig(1, settings);
        final reset = calls.singleWhere((call) => call.method == 'start');
        final resetForwards =
            ((reset.arguments as Map)['socks5Forwards'] as List).cast<Map>();
        expect(
          resetForwards.every(
            (forward) => forward['targetIp'] == settings.targetIp,
          ),
          isTrue,
        );
        final cleared = await ConfigStore().loadConfigurationSnapshot();
        expect(
          cleared!.configs.every(
            (config) => config.socks5!.connections.first.targetIp.isEmpty,
          ),
          isTrue,
        );
      },
    );

    test(
      'disabled unsupported protocols are rejected before persistence',
      () async {
        state.configs = [_visitor(1, 'stcp', null)];
        final settings = _legacy.copyWith(
          connections: [
            _connection('udp', enabled: false, udp: [15353]),
          ],
        );
        await expectLater(
          state.setSocks5ForConfig(1, settings),
          throwsFormatException,
        );
        expect(state.configs.single.socks5, isNull);
      },
    );

    test(
      'failed row save retains previous settings and running runtime',
      () async {
        final row = _connection('saved', tcp: [18080]);
        final settings = _legacy.copyWith(connections: [row]);
        state.configs = [_visitor(1, 'stcp', settings)];
        await state.start();
        failSave = true;
        await expectLater(
          state.setSocks5ForConfig(
            1,
            settings.copyWith(connections: [row.copyWith(enabled: false)]),
          ),
          throwsA(anything),
        );
        expect(state.configs.single.socks5, settings);
        expect(state.running, isTrue);
        expect(state.runRequested, isTrue);
      },
    );
  });
}
