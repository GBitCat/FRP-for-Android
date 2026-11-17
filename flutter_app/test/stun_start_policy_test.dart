import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/connection_status.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/stun_server_selector.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const engineChannel = MethodChannel('com.frp.app/engine');
  const secureStoreChannel = MethodChannel('com.frp.app/secure_store');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final startedConfigs = <String>[];
  var stopCalls = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    startedConfigs.clear();
    stopCalls = 0;
    messenger.setMockMethodCallHandler(
      secureStoreChannel,
      (call) async => (call.arguments as Map<Object?, Object?>)['value'],
    );
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      switch (call.method) {
        case 'start':
          startedConfigs.add(
            (call.arguments as Map)['configContent'] as String,
          );
          return true;
        case 'stop':
          stopCalls++;
          return true;
        case 'getTotalMemoryMb':
        case 'getMemoryMb':
          return 0.0;
        case 'getIpv4':
        case 'getIpv6':
          return '';
        case 'isRunRequested':
          return false;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(engineChannel, null);
    messenger.setMockMethodCallHandler(secureStoreChannel, null);
  });

  Future<AppState> stateWith(
    StunServerSelector selector, {
    String protocol = 'xtcp',
  }) async {
    final state = AppState(stunSelector: selector)..pausePolling();
    addTearDown(state.dispose);
    await state.ready;
    state.servers = const [
      ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
    ];
    state.configs = [
      FrpConfig(
        id: 1,
        name: 'test-visitor',
        serverId: 'SERVER01',
        protocol: protocol,
        role: 'visitor',
        serverName: 'test-proxy',
        secretKey: 'test-fixture-only',
        bindPort: 6000,
      ),
    ];
    return state;
  }

  test(
    'P2P starts serialize only successful STUN candidates in round-robin order',
    () async {
      final selector = StunServerSelector(
        lookup: (_) async => [
          InternetAddress('192.0.2.1'),
          InternetAddress('192.0.2.2'),
          InternetAddress('192.0.2.3'),
        ],
        probe: (endpoint) async => endpoint == '192.0.2.1:3478'
            ? const StunProbeResult(StunProbeStatus.timeout, exitCode: 1)
            : const StunProbeResult(StunProbeStatus.reachable, exitCode: 0),
      );
      final state = await stateWith(selector);
      await state.start();
      await state.stop();
      await state.start();
      await state.stop();
      await state.start();

      expect(startedConfigs, hasLength(3));
      expect(
        startedConfigs[0],
        contains('natHoleStunServer = "192.0.2.2:3478"'),
      );
      expect(
        startedConfigs[1],
        contains('natHoleStunServer = "192.0.2.3:3478"'),
      );
      expect(
        startedConfigs[2],
        contains('natHoleStunServer = "192.0.2.2:3478"'),
      );
      expect(
        startedConfigs.every((config) => !config.contains('192.0.2.1')),
        isTrue,
      );
      expect(state.stunCandidates.map((candidate) => candidate.weight), [
        0,
        1,
        1,
      ]);
    },
  );

  test('Stop during a STUN probe prevents the delayed start from reaching native frpc', () async {
    final entered = Completer<void>();
    final release = Completer<StunProbeResult>();
    final selector = StunServerSelector(
      lookup: (_) async => [InternetAddress('192.0.2.1')],
      probe: (_) {
        if (!entered.isCompleted) entered.complete();
        return release.future;
      },
    );
    final state = await stateWith(selector);
    final start = state.start();
    await entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(state.serverStatus.message, 'Checking STUN addresses...');
    expect(startedConfigs, isEmpty);
    await state.stop();
    release.complete(
      const StunProbeResult(StunProbeStatus.reachable, exitCode: 0),
    );
    await start;

    expect(startedConfigs, isEmpty);
    expect(stopCalls, 1);
    expect(state.running, isFalse);
  });

  test(
    'no passing STUN address blocks P2P startup with an actionable error',
    () async {
      final selector = StunServerSelector(
        lookup: (_) async => [InternetAddress('192.0.2.1')],
        probe: (_) async =>
            const StunProbeResult(StunProbeStatus.timeout, exitCode: 1),
      );
      final state = await stateWith(selector, protocol: 'xudp');
      await state.start();

      expect(startedConfigs, isEmpty);
      expect(state.running, isFalse);
      expect(state.serverStatus.type, ConnectionType.error);
      expect(state.serverStatus.message, contains('No STUN address passed'));
      expect(state.stunCandidates.single.weight, 0);
    },
  );

  test(
    'superseded concurrent Start does not consume a successful candidate',
    () async {
      final entered = Completer<void>();
      final release = Completer<StunProbeResult>();
      final selector = StunServerSelector(
        lookup: (_) async => [
          InternetAddress('192.0.2.1'),
          InternetAddress('192.0.2.2'),
        ],
        probe: (endpoint) async {
          if (endpoint == '192.0.2.1:3478') {
            if (!entered.isCompleted) entered.complete();
            return release.future;
          }
          return const StunProbeResult(StunProbeStatus.reachable, exitCode: 0);
        },
      );
      final state = await stateWith(selector);
      final first = state.start();
      await entered.future;
      await Future<void>.delayed(Duration.zero);
      expect(state.serverStatus.message, 'Checking STUN addresses...');
      final replacement = state.start();
      await Future<void>.delayed(Duration.zero);
      expect(startedConfigs, isEmpty);
      release.complete(
        const StunProbeResult(StunProbeStatus.reachable, exitCode: 0),
      );
      await Future.wait([first, replacement]);

      expect(startedConfigs, hasLength(1));
      expect(
        startedConfigs.single,
        contains('natHoleStunServer = "192.0.2.1:3478"'),
      );
      await state.stop();
      await state.start();
      expect(startedConfigs, hasLength(2));
      expect(
        startedConfigs.last,
        contains('natHoleStunServer = "192.0.2.2:3478"'),
      );
    },
  );

  test('manual TOML quoted type keys and multiline XTCP values require a successful probe', () async {
    final selector = StunServerSelector(
      lookup: (_) async => [InternetAddress('192.0.2.1')],
      probe: (_) async =>
          const StunProbeResult(StunProbeStatus.timeout, exitCode: 1),
    );
    final state = await stateWith(selector, protocol: 'tcp');
    final original = state.configs.single;
    final declarations = <String>[
      '"type" = "xtcp"',
      "'type' = '''\nxtcp'''",
      '"type" = """\nxtcp"""',
    ];
    for (final declaration in declarations) {
      state.configs = [
        original.copyWith(
          manualToml:
              '[[visitors]]\n'
              'name = "manual-visitor"\n'
              '$declaration\n'
              'serverName = "test-proxy"\n'
              'secretKey = "test-fixture-only"\n'
              'bindPort = 6000\n',
        ),
      ];
      await state.start();
      expect(startedConfigs, isEmpty, reason: declaration);
      expect(
        state.serverStatus.type,
        ConnectionType.error,
        reason: declaration,
      );
      expect(
        state.serverStatus.message,
        contains('No STUN address passed'),
        reason: declaration,
      );
      expect(state.stunCandidates.single.weight, 0);
    }
  });

  test('relay-only startup does not wait for a pending STUN probe', () async {
    final release = Completer<StunProbeResult>();
    final selector = StunServerSelector(
      lookup: (_) async => [InternetAddress('192.0.2.1')],
      probe: (_) => release.future,
    );
    final state = await stateWith(selector, protocol: 'stcp');
    await state.start().timeout(const Duration(seconds: 1));

    expect(startedConfigs, hasLength(1));
    expect(startedConfigs.single, contains('type = "stcp"'));
    expect(state.running, isTrue);
    release.complete(
      const StunProbeResult(StunProbeStatus.timeout, exitCode: 1),
    );
    await selector.prepare();
  });
}
