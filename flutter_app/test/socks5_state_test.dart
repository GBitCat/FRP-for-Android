import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/models/socks5_config.dart';
import 'package:frp_app/services/config_import_export.dart';
import 'package:frp_app/services/config_store.dart';
import 'package:frp_app/services/config_validator.dart';
import 'package:frp_app/services/socks5_runtime_plan.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = ServerConfig(serverId: 'SERVER01', serverAddr: '127.0.0.1');
const _settings = Socks5Config(
  targetIp: '192.0.2.10',
  username: 'alice',
  password: 'upstream-password',
  tcpPorts: [18080],
  udpPorts: [15353],
);

FrpConfig _visitor(int id, String protocol, int port, {int group = 1}) =>
    FrpConfig(
      id: id,
      name: 'visitor-$id',
      protocol: protocol,
      serverId: _server.serverId,
      serverName: 'provider-$id',
      secretKey: 'shared-secret',
      bindPort: port,
      groupId: group,
      groupName: 'Example',
      isGroupPrimary: id == 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const engine = MethodChannel('com.frp.app/engine');
  const secure = MethodChannel('com.frp.app/secure_store');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppState state;
  late List<MethodCall> calls;
  var failSave = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
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
    'group save persists every protocol member but excludes linked fallback',
    () async {
      state.configs = [
        _visitor(
          1,
          'xtcp',
          11080,
        ).copyWith(useFallback: true, fallbackTo: 'visitor-4'),
        _visitor(2, 'xudp', 11081),
        _visitor(3, 'xtcp', 11082),
        _visitor(4, 'stcp', -1),
        _visitor(5, 'stcp', 11083, group: 2),
      ];
      await state.setSocks5ForConfig(1, _settings);
      expect(
        state.configs.take(3).every((config) => config.socks5 == _settings),
        isTrue,
      );
      expect(state.configs[3].socks5, isNull);
      expect(state.configs[4].socks5, isNull);
      final saved = await ConfigStore().loadConfigurationSnapshot();
      expect(saved!.configs[1].socks5, _settings);

      await state.start();
      final arguments =
          calls.lastWhere((call) => call.method == 'start').arguments as Map;
      final forwards = (arguments['socks5Forwards'] as List).cast<Map>();
      final tcp = forwards.singleWhere((route) => route['protocol'] == 'tcp');
      expect(tcp['upstreams'], hasLength(2));
      expect(
        forwards.singleWhere(
          (route) => route['protocol'] == 'udp',
        )['upstreams'],
        hasLength(1),
      );
      expect(arguments['configContent'], contains('type = "socks5_udp"'));
      expect(arguments['configContent'], isNot(contains(_settings.password)));
    },
  );

  test(
    'failed persistence retains previous SOCKS settings and running intent',
    () async {
      state.configs = [
        _visitor(
          1,
          'stcp',
          11080,
        ).copyWith(socks5: _settings.copyWith(udpPorts: [])),
      ];
      await state.start();
      failSave = true;
      await expectLater(
        state.setSocks5ForConfig(
          1,
          _settings.copyWith(udpPorts: [], targetIp: '192.0.2.20'),
        ),
        throwsA(anything),
      );
      expect(state.configs.single.socks5!.targetIp, '192.0.2.10');
      expect(state.runRequested, isTrue);
      expect(state.running, isTrue);
    },
  );

  test(
    'disable removes listeners from runtime and clearing settings persists',
    () async {
      state.configs = [
        _visitor(
          1,
          'stcp',
          11080,
        ).copyWith(socks5: _settings.copyWith(udpPorts: [])),
      ];
      await state.start();
      await state.setGroupEnabled(1, false);
      final arguments =
          calls.lastWhere((call) => call.method == 'start').arguments as Map;
      expect(arguments.containsKey('socks5Forwards'), isFalse);
      await state.setSocks5ForConfig(1, null);
      expect(state.configs.single.socks5, isNull);
    },
  );

  test('conflicting listeners fail before stopping or persisting', () async {
    state.configs = [
      _visitor(
        1,
        'stcp',
        11080,
      ).copyWith(socks5: _settings.copyWith(udpPorts: [])),
      _visitor(2, 'stcp', 11081, group: 2),
    ];
    await state.start();
    calls.clear();
    await expectLater(
      state.setSocks5ForConfig(2, _settings.copyWith(udpPorts: [])),
      throwsFormatException,
    );
    expect(calls.where((call) => call.method == 'stop'), isEmpty);
    expect(state.configs[1].socks5, isNull);
  });

  test('backup preserves SOCKS credentials only when secrets are included', () {
    final configs = [
      _visitor(
        1,
        'stcp',
        11080,
      ).copyWith(socks5: _settings.copyWith(udpPorts: [])),
    ];
    for (final includeSecrets in [false, true]) {
      final zip = ConfigImportExport.buildExportZip(
        configs,
        const [_server],
        _server.serverId,
        const {'SERVER01': 'serverAddr = "127.0.0.1"\n'},
        includeSecrets: includeSecrets,
      );
      final restored = ConfigImportExport.parseImportBytes(zip)!;
      final socks = restored.configs.single.socks5!;
      expect(socks.targetIp, _settings.targetIp);
      expect(socks.password, includeSecrets ? _settings.password : '');
      expect(socks.username, _settings.username);
    }
  });

  test(
    'SOCKS settings cannot be attached to manual or provider configurations',
    () {
      final config = _visitor(1, 'stcp', 11080).copyWith(socks5: _settings);
      expect(
        ConfigValidator.validate(
          config.copyWith(manualToml: '[[visitors]]\nname="manual"'),
        ),
        isNotNull,
      );
      expect(
        ConfigValidator.validate(config.copyWith(role: 'server')),
        isNotNull,
      );
    },
  );

  test('oversized runtime envelope is rejected before the Android Intent', () {
    final plan = Socks5RuntimePlan.build([
      _visitor(
        1,
        'stcp',
        11080,
      ).copyWith(socks5: _settings.copyWith(udpPorts: [])),
    ]);
    expect(
      () => plan.requirePayloadFits('serverAddr = "localhost"'),
      returnsNormally,
    );
    final largeConfig = List.filled(384 * 1024, 'a').join();
    expect(() => plan.requirePayloadFits(largeConfig), throwsFormatException);
    expect(
      () => Socks5RuntimePlan.build([]).requirePayloadFits(largeConfig),
      returnsNormally,
    );
  });
}
