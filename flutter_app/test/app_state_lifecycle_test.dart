import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/connection_status.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/certificates/certificate_binding_resolver.dart';
import 'package:frp_app/services/certificates/certificate_engine.dart';
import 'package:frp_app/services/certificates/certificate_models.dart';
import 'package:frp_app/services/config_import_export.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const engineChannel = MethodChannel('com.frp.app/engine');
  const secureStoreChannel = MethodChannel('com.frp.app/secure_store');

  test('STUN endpoints bracket IPv6 literals', () {
    expect(
      AppState.formatStunEndpoint(InternetAddress('2001:db8::1')),
      '[2001:db8::1]:3478',
    );
    expect(
      AppState.formatStunEndpoint(InternetAddress('192.0.2.1'), port: 3479),
      '192.0.2.1:3479',
    );
  });

  test('a delayed start cannot revive frpc after an explicit stop', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    final startEntered = Completer<void>();
    final releaseStart = Completer<void>();
    var engineRunning = false;
    var stopCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      switch (call.method) {
        case 'start':
          if (!startEntered.isCompleted) startEntered.complete();
          await releaseStart.future;
          engineRunning = true;
          return true;
        case 'stop':
          stopCalls++;
          engineRunning = false;
          return true;
        case 'getTotalMemoryMb':
        case 'getMemoryMb':
          return 0.0;
        case 'getIpv4':
        case 'getIpv6':
          return '';
        default:
          return null;
      }
    });

    final state = AppState()..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(engineChannel, null);
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;
    state.servers = const [
      ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
    ];

    final start = state.start();
    await startEntered.future;
    await state.stop();
    releaseStart.complete();
    await start;

    expect(state.running, isFalse);
    expect(engineRunning, isFalse);
    expect(stopCalls, 2);
  });

  test(
    'start claims intent before initialization await so later stop wins',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      var startCalls = 0;
      var stopCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'start':
            startCalls++;
            return true;
          case 'stop':
            stopCalls++;
            return true;
          default:
            return null;
        }
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ];

      final start = state.start();
      await state.stop();
      await start;

      expect(startCalls, 0);
      expect(stopCalls, 1);
      expect(state.running, isFalse);
    },
  );

  test('a native stop failure keeps the running state visible', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    var rejectStop = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      switch (call.method) {
        case 'start':
          return true;
        case 'stop':
          if (rejectStop) {
            throw PlatformException(code: 'STOP_REJECTED');
          }
          return true;
        default:
          return null;
      }
    });
    final state = AppState()..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(engineChannel, null);
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;
    state.servers = const [
      ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
    ];
    await state.start();
    rejectStop = true;

    await expectLater(state.stop(), throwsA(anything));

    expect(state.running, isTrue);
    expect(state.runRequested, isTrue);
    expect(state.serverStatus.message, 'Failed to stop frpc');
  });

  test('disconnect keeps run intent available for an explicit Stop', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    var stopCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      switch (call.method) {
        case 'start':
          return true;
        case 'stop':
          stopCalls++;
          return true;
        default:
          return null;
      }
    });
    final state = AppState()..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(engineChannel, null);
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;
    state.servers = const [
      ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
    ];
    await state.start();
    await messenger.handlePlatformMessage(
      engineChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onStatus', {
          'scope': 'server',
          'type': 'disconnected',
          'detail': 'network lost',
        }),
      ),
      (_) {},
    );

    expect(state.running, isFalse);
    expect(state.runRequested, isTrue);
    await state.stop();
    expect(state.runRequested, isFalse);
    expect(stopCalls, 1);
  });

  test('native worker start failure clears the queued UI intent', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    var nativeRunRequested = false;
    var startAccepted = false;
    final reconcileQueried = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      switch (call.method) {
        case 'isRunRequested':
          if (startAccepted && !reconcileQueried.isCompleted) {
            reconcileQueried.complete();
          }
          return nativeRunRequested;
        case 'start':
          startAccepted = true;
          nativeRunRequested = true;
          return true;
        default:
          return null;
      }
    });

    final state = AppState()..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(engineChannel, null);
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;
    state.servers = const [
      ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
    ];
    await state.start();
    expect(state.runRequested, isTrue);

    // MethodChannel Start only queued the request. The native worker then
    // failed and durably abandoned it before publishing/handling the error.
    nativeRunRequested = false;
    await messenger.handlePlatformMessage(
      engineChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onStatus', {
          'scope': 'server',
          'type': 'error',
          'detail': 'Failed to start frpc',
        }),
      ),
      (_) {},
    );
    await reconcileQueried.future;
    await Future<void>.delayed(Duration.zero);

    expect(state.runRequested, isFalse);
    expect(state.running, isFalse);
    expect(state.serverStatus.type, ConnectionType.error);
  });

  test('transient native errors preserve a durable run intent', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    var nativeRunRequested = false;
    var startAccepted = false;
    final reconcileQueried = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      switch (call.method) {
        case 'isRunRequested':
          if (startAccepted && !reconcileQueried.isCompleted) {
            reconcileQueried.complete();
          }
          return nativeRunRequested;
        case 'start':
          startAccepted = true;
          nativeRunRequested = true;
          return true;
        default:
          return null;
      }
    });

    final state = AppState()..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(engineChannel, null);
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;
    state.servers = const [
      ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
    ];
    await state.start();

    await messenger.handlePlatformMessage(
      engineChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onStatus', {
          'scope': 'server',
          'type': 'error',
          'detail': 'Server connection failed',
        }),
      ),
      (_) {},
    );
    await reconcileQueried.future;
    await Future<void>.delayed(Duration.zero);

    expect(state.runRequested, isTrue);
    expect(state.running, isFalse);
    expect(state.serverStatus.type, ConnectionType.error);
  });

  test('stale native intent query cannot override a newer Start', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    var startCalls = 0;
    var blockIntentQuery = false;
    final queryEntered = Completer<void>();
    final releaseQuery = Completer<bool>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      switch (call.method) {
        case 'isRunRequested':
          if (blockIntentQuery) {
            if (!queryEntered.isCompleted) queryEntered.complete();
            return releaseQuery.future;
          }
          return false;
        case 'start':
          startCalls++;
          return true;
        default:
          return null;
      }
    });

    final state = AppState()..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(engineChannel, null);
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;
    state.servers = const [
      ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
    ];
    await state.start();
    blockIntentQuery = true;
    await messenger.handlePlatformMessage(
      engineChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onStatus', {
          'scope': 'server',
          'type': 'error',
          'detail': 'old worker failed',
        }),
      ),
      (_) {},
    );
    await queryEntered.future;

    await state.start();
    releaseQuery.complete(false);
    await Future<void>.delayed(Duration.zero);

    expect(startCalls, 2);
    expect(state.runRequested, isTrue);
    expect(state.running, isTrue);
  });

  test(
    'a failed snapshot write leaves in-memory configuration unchanged',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      var rejectWrites = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        if (rejectWrites && call.method == 'encrypt') {
          throw PlatformException(code: 'WRITE_FAILED');
        }
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      final original = state.selectedServer;
      rejectWrites = true;

      await expectLater(
        state.saveServerConfig(
          original.copyWith(serverAddr: 'new.example.com'),
          originalServerId: original.serverId,
        ),
        throwsA(anything),
      );
      expect(state.selectedServer.serverAddr, original.serverAddr);
      expect(state.selectedServer.serverId, original.serverId);
    },
  );

  test('failed recent-app visibility update is not persisted', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      if (call.method == 'setExcludeFromRecents') {
        throw PlatformException(code: 'RECENTS_UPDATE_FAILED');
      }
      return null;
    });
    final state = AppState()..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(engineChannel, null);
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;

    await expectLater(state.setHideFromRecents(true), throwsA(anything));

    expect(state.hideFromRecents, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool('hide_from_recents'),
      isNot(true),
    );
  });

  test(
    'TLS import resolves bindings before one durable snapshot write',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      var snapshotWrites = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        final value =
            (call.arguments as Map<Object?, Object?>)['value'] as String?;
        if (call.method == 'encrypt') {
          snapshotWrites++;
        }
        return value;
      });
      final backend = _InventoryCertificateBackend(
        const CertificateInventory(),
      );
      final state = AppState(certificateBackend: backend)..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      snapshotWrites = 0;

      await state.applyImport(
        const ExportData(
          servers: [
            ServerConfig(
              serverId: 'SERVER01',
              tlsEnabled: true,
              tlsIdentityId: 'missing-identity',
            ),
          ],
          selectedServerId: 'SERVER01',
        ),
      );

      expect(snapshotWrites, 1);
      expect(backend.listCalls, 1);
      expect(state.servers.single.tlsIdentityId, isEmpty);
      expect(state.servers.single.hasLegacyTlsPaths, isFalse);
    },
  );

  test('a stale deleted certificate identity cannot be saved again', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    final state = AppState(
      certificateBackend: _InventoryCertificateBackend(
        const CertificateInventory(),
      ),
    )..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;
    state.servers = const [
      ServerConfig(serverId: 'SERVER01', serverAddr: 'old.example.com'),
    ];

    await expectLater(
      state.saveServerConfig(
        const ServerConfig(
          serverId: 'SERVER01',
          serverAddr: 'new.example.com',
          tlsEnabled: true,
          tlsIdentityId: 'deleted-identity',
        ),
        originalServerId: 'SERVER01',
      ),
      throwsA(isA<CertificateBindingException>()),
    );
    expect(state.servers.single.serverAddr, 'old.example.com');
    expect(state.servers.single.tlsIdentityId, isEmpty);
  });

  test(
    'legacy TLS paths survive an inventory outage and migrate on retry',
    () async {
      const legacy =
          '[{"serverId":"SERVER01","tlsEnabled":true,'
          '"tlsCertFile":"/private/client.crt",'
          '"tlsKeyFile":"/private/client.key",'
          '"tlsTrustedCaFile":"/private/ca.crt"}]';
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
        'server_configs_v2': legacy,
        'selected_server_id_v2': 'SERVER01',
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      final backend = _InventoryCertificateBackend(
        CertificateInventory(
          identities: [
            ManagedIdentityRecord(
              id: 'identity-0123456789abcdef',
              name: 'Phone',
              commonName: 'phone.example.com',
              algorithm: 'ecdsa-p256',
              dnsNames: const [],
              ipAddresses: const [],
              createdAt: DateTime.utc(2026),
              privateKeyPath: '/private/client.key',
              csrPath: '/private/client.csr',
              certificatePath: '/private/client.crt',
              trustedCaPath: '/private/ca.crt',
              trustedCaStatus: 'valid',
              trustedCAs: const [],
              issuer: 'Test CA',
              notAfter: DateTime.utc(2030),
              fingerprint: 'AA:BB',
              status: 'ready',
            ),
          ],
        ),
        unavailable: true,
      );
      final state = AppState(certificateBackend: backend)..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });

      await state.ready;
      expect(state.initializationError, isNotNull);
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('configuration_snapshot_v1'), isNull);
      expect(
        prefs.getString('server_configs_v2'),
        allOf(startsWith('enc:v1:'), contains('/private/client.key')),
      );

      backend.unavailable = false;
      await state.retryInitialization();
      prefs = await SharedPreferences.getInstance();
      expect(state.initializationError, isNull);
      expect(
        state.servers.single.tlsIdentityId,
        backend.inventory.identities.single.id,
      );
      expect(state.servers.single.hasResolvedTlsCredentials, isTrue);
      expect(prefs.getString('configuration_snapshot_v1'), isNotNull);
    },
  );

  test(
    'plaintext snapshot TLS paths survive inventory outage until retry',
    () async {
      const rawSnapshot =
          '{"version":1,"servers":[{"serverId":"SERVER01",'
          '"tlsEnabled":true,"tlsCertFile":"/private/client.crt",'
          '"tlsKeyFile":"/private/client.key",'
          '"tlsTrustedCaFile":"/private/ca.crt"}],'
          '"selectedServerId":"SERVER01","configs":[]}';
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
        'configuration_snapshot_v1': rawSnapshot,
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      final backend = _InventoryCertificateBackend(
        CertificateInventory(
          identities: [
            ManagedIdentityRecord(
              id: 'identity-0123456789abcdef',
              name: 'Phone',
              commonName: 'phone.example.com',
              algorithm: 'ecdsa-p256',
              dnsNames: const [],
              ipAddresses: const [],
              createdAt: DateTime.utc(2026),
              privateKeyPath: '/private/client.key',
              csrPath: '/private/client.csr',
              certificatePath: '/private/client.crt',
              trustedCaPath: '/private/ca.crt',
              trustedCaStatus: 'valid',
              trustedCAs: const [],
              issuer: 'Test CA',
              notAfter: DateTime.utc(2030),
              fingerprint: 'AA:BB',
              status: 'ready',
            ),
          ],
        ),
        unavailable: true,
      );
      final state = AppState(certificateBackend: backend)..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });

      await state.ready;
      expect(state.initializationError, isNotNull);
      var stored = (await SharedPreferences.getInstance()).getString(
        'configuration_snapshot_v1',
      );
      expect(
        stored,
        allOf(startsWith('enc:v1:'), contains('/private/client.key')),
      );

      backend.unavailable = false;
      await state.retryInitialization();
      stored = (await SharedPreferences.getInstance()).getString(
        'configuration_snapshot_v1',
      );
      expect(state.initializationError, isNull);
      expect(state.servers.single.tlsIdentityId, isNotEmpty);
      expect(state.servers.single.hasResolvedTlsCredentials, isTrue);
      expect(stored, isNot(contains('/private/client.key')));
    },
  );

  test('legacy unbound proxies belong only to the selected server', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    final state = AppState()..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;
    await state.applyImport(
      const ExportData(
        servers: [
          ServerConfig(serverId: 'SERVER01', serverAddr: 'one.example.com'),
          ServerConfig(serverId: 'SERVER02', serverAddr: 'two.example.com'),
        ],
        selectedServerId: 'SERVER01',
        configs: [
          FrpConfig(
            id: 1,
            name: 'legacy-ssh',
            localPort: 22,
            remotePort: 10022,
          ),
        ],
      ),
    );

    final tomls = state.buildAllServerTomls();
    expect(tomls['SERVER01'], contains('legacy-ssh'));
    expect(tomls['SERVER02'], isNot(contains('legacy-ssh')));
  });

  test(
    'a Start racing TLS import is rebuilt from the imported snapshot',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      final inventoryEntered = Completer<void>();
      final releaseInventory = Completer<void>();
      final firstStartEntered = Completer<void>();
      final startPayloads = <String>[];
      var stopCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'start':
            startPayloads.add(
              (call.arguments as Map<Object?, Object?>)['configContent']
                  as String,
            );
            if (!firstStartEntered.isCompleted) firstStartEntered.complete();
            return true;
          case 'stop':
            stopCalls++;
            return true;
          default:
            return null;
        }
      });
      final identity = ManagedIdentityRecord(
        id: 'identity-0123456789abcdef',
        name: 'Phone',
        commonName: 'phone.example.com',
        algorithm: 'ecdsa-p256',
        dnsNames: const [],
        ipAddresses: const [],
        createdAt: DateTime.utc(2026),
        privateKeyPath: '/private/client.key',
        csrPath: '/private/client.csr',
        certificatePath: '/private/client.crt',
        trustedCaPath: '/private/ca.crt',
        trustedCaStatus: 'valid',
        trustedCAs: const [],
        issuer: 'Test CA',
        notAfter: DateTime.utc(2030),
        fingerprint: 'AA:BB',
        status: 'ready',
      );
      final backend = _InventoryCertificateBackend(
        CertificateInventory(identities: [identity]),
        listEntered: inventoryEntered,
        releaseList: releaseInventory,
      );
      final state = AppState(certificateBackend: backend)..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'old.example.com'),
      ];

      final importing = state.applyImport(
        ExportData(
          servers: [
            ServerConfig(
              serverId: 'SERVER02',
              serverAddr: 'new.example.com',
              tlsEnabled: true,
              tlsIdentityId: identity.id,
            ),
          ],
          selectedServerId: 'SERVER02',
        ),
      );
      await inventoryEntered.future;
      final racingStart = state.start();
      await firstStartEntered.future;
      releaseInventory.complete();
      await Future.wait([importing, racingStart]);

      expect(startPayloads, hasLength(2));
      expect(startPayloads.first, contains('old.example.com'));
      expect(startPayloads.last, contains('new.example.com'));
      expect(startPayloads.last, contains('/private/client.crt'));
      expect(stopCalls, 1);
      expect(state.running, isTrue);
    },
  );

  test(
    'concurrent proxy mutations are serialized and keep unique IDs',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;

      await Future.wait([
        state.addConfig(
          const FrpConfig(name: 'ssh-a', localPort: 22, remotePort: 10022),
        ),
        state.addConfig(
          const FrpConfig(name: 'ssh-b', localPort: 23, remotePort: 10023),
        ),
      ]);

      expect(state.configs.map((config) => config.id).toSet(), {1, 2});
      expect(state.configs.map((config) => config.name).toSet(), {
        'ssh-a',
        'ssh-b',
      });
    },
  );

  test('invalid default server is rejected before invoking frpc', () async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    var startCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      if (call.method == 'start') startCalls++;
      return null;
    });

    final state = AppState()..pausePolling();
    addTearDown(() {
      state.dispose();
      messenger.setMockMethodCallHandler(engineChannel, null);
      messenger.setMockMethodCallHandler(secureStoreChannel, null);
    });
    await state.ready;
    await state.start();

    expect(startCalls, 0);
    expect(state.running, isFalse);
    expect(state.serverStatus.message, 'Server address is required');
  });

  test(
    'legacy duplicate IDs and stale server references are normalized',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
        'server_configs_v2':
            '[{"serverId":"SERVER01","serverAddr":"frps.example.com"}]',
        'selected_server_id_v2': 'SERVER01',
        'frp_configs_v2': '[{"id":4,"name":"a","localPort":22,"remotePort":10022,"serverId":"UNKNOWN1"},{"id":4,"name":"b","localPort":23,"remotePort":10023,"serverId":"UNKNOWN1"}]',
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;

      expect(state.initializationError, isNull);
      expect(state.configs.map((config) => config.id).toSet().length, 2);
      expect(state.configs.every((config) => config.id > 0), isTrue);
      expect(
        state.configs.every((config) => config.serverId == 'SERVER01'),
        isTrue,
      );
    },
  );

  test(
    'editing the active proxy set restarts frpc with the new snapshot',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      var startCalls = 0;
      var stopCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'start':
            startCalls++;
            return true;
          case 'stop':
            stopCalls++;
            return true;
          default:
            return null;
        }
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ];
      await state.start();
      await state.addConfig(
        const FrpConfig(name: 'ssh', localPort: 22, remotePort: 10022),
      );

      expect(startCalls, 2);
      expect(stopCalls, 1);
      expect(state.running, isTrue);
      expect(state.configs.single.id, 1);
    },
  );

  test(
    'an explicit stop racing a config write prevents automatic restart',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      final writeEntered = Completer<void>();
      final releaseWrite = Completer<void>();
      var blockWrite = false;
      var startCalls = 0;
      var stopCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        if (blockWrite && call.method == 'encrypt') {
          if (!writeEntered.isCompleted) writeEntered.complete();
          await releaseWrite.future;
        }
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'start':
            startCalls++;
            return true;
          case 'stop':
            stopCalls++;
            return true;
          default:
            return null;
        }
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ];
      await state.start();

      blockWrite = true;
      final mutation = state.addConfig(
        const FrpConfig(name: 'ssh', localPort: 22, remotePort: 10022),
      );
      await writeEntered.future;
      await state.stop();
      releaseWrite.complete();
      await mutation;

      expect(startCalls, 1);
      expect(stopCalls, 2);
      expect(state.running, isFalse);
      expect(state.configs.single.name, 'ssh');
    },
  );

  test(
    'an explicit stop racing the mutation pause is never auto-restarted',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      final pauseStopEntered = Completer<void>();
      final releasePauseStop = Completer<void>();
      var startCalls = 0;
      var stopCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'start':
            startCalls++;
            return true;
          case 'stop':
            stopCalls++;
            if (stopCalls == 1) {
              pauseStopEntered.complete();
              await releasePauseStop.future;
            }
            return true;
          default:
            return null;
        }
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ];
      await state.start();

      final mutation = state.addConfig(
        const FrpConfig(name: 'ssh', localPort: 22, remotePort: 10022),
      );
      await pauseStopEntered.future;
      await state.stop();
      releasePauseStop.complete();
      await mutation;

      expect(startCalls, 1);
      expect(stopCalls, 2);
      expect(state.running, isFalse);
      expect(state.configs.single.name, 'ssh');
    },
  );

  test(
    'a start racing a stopped-state write is rebuilt from committed TOML',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      final writeEntered = Completer<void>();
      final releaseWrite = Completer<void>();
      var blockWrite = false;
      var stopCalls = 0;
      final startPayloads = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        if (blockWrite && call.method == 'encrypt') {
          writeEntered.complete();
          await releaseWrite.future;
        }
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'start':
            startPayloads.add(
              (call.arguments as Map<Object?, Object?>)['configContent']
                  as String,
            );
            return true;
          case 'stop':
            stopCalls++;
            return true;
          default:
            return null;
        }
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ];

      blockWrite = true;
      final mutation = state.addConfig(
        const FrpConfig(name: 'ssh', localPort: 22, remotePort: 10022),
      );
      await writeEntered.future;
      await state.start();
      releaseWrite.complete();
      await mutation;

      expect(startPayloads, hasLength(2));
      expect(startPayloads.first, isNot(contains('name = "ssh"')));
      expect(startPayloads.last, contains('name = "ssh"'));
      expect(stopCalls, 1);
      expect(state.running, isTrue);
    },
  );

  test(
    'an edit during native recovery replaces the recoverable payload',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      var stopCalls = 0;
      final startPayloads = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'start':
            startPayloads.add(
              (call.arguments as Map<Object?, Object?>)['configContent']
                  as String,
            );
            return true;
          case 'stop':
            stopCalls++;
            return true;
          default:
            return null;
        }
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ];
      await state.start();
      await messenger.handlePlatformMessage(
        engineChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onStatus', {
            'scope': 'server',
            'type': 'disconnected',
            'detail': 'frpc exited',
          }),
        ),
        (_) {},
      );
      expect(state.running, isFalse);

      await state.addConfig(
        const FrpConfig(name: 'ssh', localPort: 22, remotePort: 10022),
      );

      expect(startPayloads, hasLength(2));
      expect(startPayloads.last, contains('name = "ssh"'));
      expect(stopCalls, 1);
      expect(state.running, isTrue);
    },
  );

  test(
    'native status replay during a stopped-state write is superseded',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      final writeEntered = Completer<void>();
      final releaseWrite = Completer<void>();
      var blockWrite = false;
      var stopCalls = 0;
      final startPayloads = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        if (blockWrite && call.method == 'encrypt') {
          writeEntered.complete();
          await releaseWrite.future;
        }
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'start':
            startPayloads.add(
              (call.arguments as Map<Object?, Object?>)['configContent']
                  as String,
            );
            return true;
          case 'stop':
            stopCalls++;
            return true;
          default:
            return null;
        }
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ];

      blockWrite = true;
      final mutation = state.addConfig(
        const FrpConfig(name: 'ssh', localPort: 22, remotePort: 10022),
      );
      await writeEntered.future;
      await messenger.handlePlatformMessage(
        engineChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onStatus', {
            'scope': 'server',
            'type': 'connecting',
            'detail': 'native status replay',
          }),
        ),
        (_) {},
      );
      releaseWrite.complete();
      await mutation;

      expect(startPayloads, hasLength(1));
      expect(startPayloads.single, contains('name = "ssh"'));
      expect(stopCalls, 1);
      expect(state.running, isTrue);
    },
  );

  test(
    'persisted native run intent is restarted with a committed edit',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      var stopCalls = 0;
      final startPayloads = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'isRunRequested':
            return true;
          case 'start':
            startPayloads.add(
              (call.arguments as Map<Object?, Object?>)['configContent']
                  as String,
            );
            return true;
          case 'stop':
            stopCalls++;
            return true;
          default:
            return null;
        }
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ];

      await state.addConfig(
        const FrpConfig(name: 'ssh', localPort: 22, remotePort: 10022),
      );

      expect(stopCalls, 1);
      expect(startPayloads, hasLength(1));
      expect(startPayloads.single, contains('name = "ssh"'));
      expect(state.running, isTrue);
    },
  );

  test(
    'runtime reconcile failure does not turn a committed save into failure',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      final writeEntered = Completer<void>();
      final releaseWrite = Completer<void>();
      var blockWrite = false;
      var startCalls = 0;
      var stopCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        if (blockWrite && call.method == 'encrypt') {
          if (!writeEntered.isCompleted) writeEntered.complete();
          await releaseWrite.future;
        }
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      messenger.setMockMethodCallHandler(engineChannel, (call) async {
        switch (call.method) {
          case 'start':
            startCalls++;
            return true;
          case 'stop':
            stopCalls++;
            return false;
          default:
            return null;
        }
      });

      final state = AppState()..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(engineChannel, null);
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      state.servers = const [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ];

      blockWrite = true;
      final mutation = state.addConfig(
        const FrpConfig(name: 'ssh', localPort: 22, remotePort: 10022),
      );
      await writeEntered.future;
      await state.start();
      releaseWrite.complete();

      await expectLater(mutation, completes);
      expect(state.configs.single.name, 'ssh');
      expect(startCalls, 1);
      expect(stopCalls, 1);
      expect(state.runRequested, isTrue);
      expect(state.running, isFalse);
      expect(
        state.serverStatus.message,
        'Configuration saved, but frpc could not apply the runtime update',
      );
    },
  );

  test(
    'delete failure inventory outage can recover tombstone on a later save',
    () async {
      SharedPreferences.setMockInitialValues(const {
        'battery_hint_shown': true,
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        return (call.arguments as Map<Object?, Object?>)['value'] as String?;
      });
      final identity = ManagedIdentityRecord(
        id: 'identity-0123456789abcdef',
        name: 'Phone',
        commonName: 'phone.example.com',
        algorithm: 'ecdsa-p256',
        dnsNames: const [],
        ipAddresses: const [],
        createdAt: DateTime.utc(2026),
        privateKeyPath: '/private/client.key',
        csrPath: '/private/client.csr',
        certificatePath: '/private/client.crt',
        trustedCaPath: '/private/ca.crt',
        trustedCaStatus: 'valid',
        trustedCAs: const [],
        issuer: 'Test CA',
        notAfter: DateTime.utc(2030),
        fingerprint: 'AA:BB',
        status: 'ready',
      );
      final backend = _InventoryCertificateBackend(
        CertificateInventory(identities: [identity]),
      );
      final state = AppState(certificateBackend: backend)..pausePolling();
      addTearDown(() {
        state.dispose();
        messenger.setMockMethodCallHandler(secureStoreChannel, null);
      });
      await state.ready;
      final serverId = state.selectedServerId;
      final bound = ServerConfig(
        serverId: serverId,
        serverAddr: 'frps.example.com',
        tlsEnabled: true,
        tlsIdentityId: identity.id,
        tlsCertFile: identity.certificatePath,
        tlsKeyFile: identity.privateKeyPath,
        tlsTrustedCaFile: identity.trustedCaPath,
      );
      state.servers = [bound];

      await state.invalidateCertificateIdentity(identity.id);
      backend.unavailable = true;
      await expectLater(
        state.rollbackCertificateIdentityInvalidation(identity.id),
        throwsA(anything),
      );

      backend.unavailable = false;
      await state.saveServerConfig(bound, originalServerId: serverId);

      expect(state.servers.single.tlsIdentityId, identity.id);
      expect(state.servers.single.hasResolvedTlsCredentials, isTrue);
    },
  );
}

final class _InventoryCertificateBackend implements CertificateBackend {
  _InventoryCertificateBackend(
    this.inventory, {
    this.unavailable = false,
    this.listEntered,
    this.releaseList,
  });

  CertificateInventory inventory;
  bool unavailable;
  final Completer<void>? listEntered;
  final Completer<void>? releaseList;
  int listCalls = 0;

  @override
  Future<CertificateInventory> listInventory() async {
    listCalls++;
    if (unavailable) throw StateError('inventory unavailable');
    if (listEntered != null && !listEntered!.isCompleted) {
      listEntered!.complete();
    }
    await releaseList?.future;
    return inventory;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected certificate operation');
}
