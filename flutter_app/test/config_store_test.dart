import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/services/config_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.frp.app/secure_store');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('corrupt configuration is reported and preserved verbatim', () async {
    const raw = '{not valid json';
    SharedPreferences.setMockInitialValues(const {'frp_configs_v2': raw});

    await expectLater(
      ConfigStore().loadConfigs(),
      throwsA(
        isA<ConfigStoreException>().having(
          (error) => error.failure,
          'failure',
          ConfigStoreFailure.corrupt,
        ),
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('frp_configs_v2'), raw);
  });

  test(
    'an existing empty configuration is corrupt rather than absent',
    () async {
      SharedPreferences.setMockInitialValues(const {'frp_configs_v2': ''});

      await expectLater(
        ConfigStore().loadConfigs(),
        throwsA(
          isA<ConfigStoreException>().having(
            (error) => error.failure,
            'failure',
            ConfigStoreFailure.corrupt,
          ),
        ),
      );
      expect(
        (await SharedPreferences.getInstance()).getString('frp_configs_v2'),
        '',
      );
    },
  );

  test('oversized plaintext is reported as preserved corruption', () async {
    final raw = List<String>.filled(5 * 1024 * 1024 + 1, 'x').join();
    SharedPreferences.setMockInitialValues({'frp_configs_v2': raw});

    await expectLater(
      ConfigStore().loadConfigs(),
      throwsA(
        isA<ConfigStoreException>()
            .having(
              (error) => error.failure,
              'failure',
              ConfigStoreFailure.corrupt,
            )
            .having(
              (error) => error.userMessage,
              'message',
              contains('Original data was preserved'),
            ),
      ),
    );
    expect(
      (await SharedPreferences.getInstance()).getString('frp_configs_v2'),
      raw,
    );
  });

  test('invalid values are rejected before encrypted persistence', () async {
    SharedPreferences.setMockInitialValues(const {});
    var platformCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      platformCalls++;
      return 'ciphertext';
    });

    await expectLater(
      ConfigStore().saveServers(const [
        ServerConfig(
          serverId: 'SERVER01',
          heartbeatInterval: 90,
          heartbeatTimeout: 30,
        ),
      ]),
      throwsFormatException,
    );
    await expectLater(
      ConfigStore().saveConfigs(const [
        FrpConfig(name: 'unsafe\nname', localPort: 22, remotePort: 10022),
      ]),
      throwsFormatException,
    );
    expect(platformCalls, 0);
  });

  test('decrypted values still receive domain validation', () async {
    const encrypted = 'enc:v1:ciphertext';
    SharedPreferences.setMockInitialValues(const {
      'server_configs_v2': encrypted,
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'decrypt');
      return '[{"serverId":"SERVER01","protocol":"ssh"}]';
    });

    await expectLater(
      ConfigStore().loadServers(),
      throwsA(
        isA<ConfigStoreException>().having(
          (error) => error.failure,
          'failure',
          ConfigStoreFailure.corrupt,
        ),
      ),
    );
    expect(
      (await SharedPreferences.getInstance()).getString('server_configs_v2'),
      encrypted,
    );
  });

  test(
    'plaintext migration failure is visible and never overwrites data',
    () async {
      const raw = '[{"serverId":"SERVER01"}]';
      SharedPreferences.setMockInitialValues(const {'server_configs_v2': raw});
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'encrypt');
        throw PlatformException(code: 'KEYSTORE_UNAVAILABLE');
      });

      await expectLater(
        ConfigStore().loadServers(),
        throwsA(
          isA<ConfigStoreException>()
              .having(
                (error) => error.failure,
                'failure',
                ConfigStoreFailure.migrate,
              )
              .having(
                (error) => error.userMessage,
                'message',
                contains('Original data was preserved'),
              ),
        ),
      );
      expect(
        (await SharedPreferences.getInstance()).getString('server_configs_v2'),
        raw,
      );
    },
  );

  test(
    'successful plaintext migration replaces data only after encryption',
    () async {
      const raw = '[{"serverId":"SERVER01","protocol":"ws"}]';
      SharedPreferences.setMockInitialValues(const {'server_configs_v2': raw});
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'encrypt');
        final value =
            (call.arguments as Map<Object?, Object?>)['value'] as String;
        expect(value, contains('"protocol":"websocket"'));
        return 'authenticated-ciphertext';
      });

      final servers = await ConfigStore().loadServers();
      expect(servers.single.protocol, 'websocket');
      expect(
        (await SharedPreferences.getInstance()).getString('server_configs_v2'),
        'enc:v1:authenticated-ciphertext',
      );
    },
  );

  test(
    'legacy server encryption preserves TLS paths needed for migration',
    () async {
      const raw =
          '[{"serverId":"SERVER01","tlsEnabled":true,'
          '"tlsCertFile":"/private/client.crt",'
          '"tlsKeyFile":"/private/client.key",'
          '"tlsTrustedCaFile":"/private/ca.crt"}]';
      SharedPreferences.setMockInitialValues(const {'server_configs_v2': raw});
      String? plaintextPassedToEncryption;
      messenger.setMockMethodCallHandler(channel, (call) async {
        plaintextPassedToEncryption =
            (call.arguments as Map<Object?, Object?>)['value'] as String;
        return 'authenticated-ciphertext';
      });

      final servers = await ConfigStore().loadServers();

      expect(servers.single.tlsKeyFile, '/private/client.key');
      expect(plaintextPassedToEncryption, contains('/private/client.crt'));
      expect(plaintextPassedToEncryption, contains('/private/client.key'));
      expect(plaintextPassedToEncryption, contains('/private/ca.crt'));
      expect(
        (await SharedPreferences.getInstance()).getString('server_configs_v2'),
        'enc:v1:authenticated-ciphertext',
      );
    },
  );

  test('plaintext snapshot encryption preserves TLS migration paths', () async {
    const raw =
        '{"version":1,"servers":[{"serverId":"SERVER01",'
        '"tlsEnabled":true,"tlsCertFile":"/private/client.crt",'
        '"tlsKeyFile":"/private/client.key",'
        '"tlsTrustedCaFile":"/private/ca.crt"}],'
        '"selectedServerId":"SERVER01","configs":[]}';
    SharedPreferences.setMockInitialValues(const {
      'configuration_snapshot_v1': raw,
    });
    String? plaintextPassedToEncryption;
    messenger.setMockMethodCallHandler(channel, (call) async {
      plaintextPassedToEncryption =
          (call.arguments as Map<Object?, Object?>)['value'] as String;
      return 'authenticated-ciphertext';
    });

    final snapshot = await ConfigStore().loadConfigurationSnapshot();

    expect(snapshot!.servers.single.tlsKeyFile, '/private/client.key');
    expect(plaintextPassedToEncryption, contains('/private/client.crt'));
    expect(plaintextPassedToEncryption, contains('/private/client.key'));
    expect(plaintextPassedToEncryption, contains('/private/ca.crt'));
  });

  test('decryption failure is distinct from malformed plaintext', () async {
    const encrypted = 'enc:v1:ciphertext';
    SharedPreferences.setMockInitialValues(const {
      'server_configs_v2': encrypted,
    });
    messenger.setMockMethodCallHandler(channel, (call) async => null);

    await expectLater(
      ConfigStore().loadServers(),
      throwsA(
        isA<ConfigStoreException>().having(
          (error) => error.failure,
          'failure',
          ConfigStoreFailure.decrypt,
        ),
      ),
    );
    expect(
      (await SharedPreferences.getInstance()).getString('server_configs_v2'),
      encrypted,
    );
  });

  test('configuration snapshot round-trips as one encrypted value', () async {
    SharedPreferences.setMockInitialValues(const {});
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map<Object?, Object?>;
      return arguments['value'] as String;
    });
    const snapshot = ConfigurationSnapshot(
      servers: [
        ServerConfig(serverId: 'SERVER01', serverAddr: 'frps.example.com'),
      ],
      selectedServerId: 'SERVER01',
      configs: [
        FrpConfig(
          id: 1,
          name: 'ssh',
          serverId: 'SERVER01',
          localPort: 22,
          remotePort: 10022,
        ),
      ],
    );

    final store = ConfigStore();
    await store.saveConfigurationSnapshot(snapshot);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('configuration_snapshot_v1'), startsWith('enc:v1:'));

    final loaded = await store.loadConfigurationSnapshot();
    expect(loaded, isNotNull);
    expect(loaded!.selectedServerId, 'SERVER01');
    expect(loaded.servers.single.serverAddr, 'frps.example.com');
    expect(loaded.configs.single.name, 'ssh');
  });

  test('snapshot rejects duplicate proxy IDs before encryption', () async {
    SharedPreferences.setMockInitialValues(const {});
    var platformCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      platformCalls++;
      return 'ciphertext';
    });

    await expectLater(
      ConfigStore().saveConfigurationSnapshot(
        const ConfigurationSnapshot(
          servers: [ServerConfig(serverId: 'SERVER01')],
          selectedServerId: 'SERVER01',
          configs: [
            FrpConfig(id: 7, name: 'first', localPort: 22, remotePort: 10022),
            FrpConfig(id: 7, name: 'second', localPort: 23, remotePort: 10023),
          ],
        ),
      ),
      throwsFormatException,
    );
    expect(platformCalls, 0);
  });

  test('snapshot entry limits are checked before model decoding', () {
    expect(
      () => ConfigurationSnapshot.fromJson({
        'version': ConfigurationSnapshot.currentVersion,
        'servers': List<Object?>.filled(257, {'serverId': 42}),
        'selectedServerId': 'SERVER01',
        'configs': const [],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('between 1 and 256 servers'),
        ),
      ),
    );

    expect(
      () => ConfigurationSnapshot.fromJson({
        'version': ConfigurationSnapshot.currentVersion,
        'servers': const [
          {'serverId': 'SERVER01'},
        ],
        'selectedServerId': 'SERVER01',
        'configs': List<Object?>.filled(4097, {'id': 'not-an-integer'}),
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('too many proxy records'),
        ),
      ),
    );
  });

  test('legacy list limits are checked before model decoding', () async {
    SharedPreferences.setMockInitialValues({
      'server_configs_v2':
          '[${List<String>.filled(257, '{"serverId":42}').join(',')}]',
      'frp_configs_v2':
          '[${List<String>.filled(4097, '{"id":"bad"}').join(',')}]',
    });

    await expectLater(
      ConfigStore().loadServers(),
      throwsA(
        isA<ConfigStoreException>().having(
          (error) => (error.cause as FormatException).message,
          'cause',
          contains('too many server records'),
        ),
      ),
    );
    await expectLater(
      ConfigStore().loadConfigs(),
      throwsA(
        isA<ConfigStoreException>().having(
          (error) => (error.cause as FormatException).message,
          'cause',
          contains('too many proxy records'),
        ),
      ),
    );
  });

  test('nested proxy list limits are checked before entry decoding', () {
    expect(
      () => FrpConfig.fromJson({
        'portMappings': List<Object?>.filled(FrpConfig.maxPortMappings + 1, {
          'localPort': 'invalid',
        }),
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('too many portMappings'),
        ),
      ),
    );

    expect(
      () => FrpConfig.fromJson({
        'customDomains': List<Object?>.filled(
          FrpConfig.maxCustomDomains + 1,
          42,
        ),
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('too many customDomains entries'),
        ),
      ),
    );
  });

  test('exception text never includes decrypted parser details', () {
    const secret = 'token-super-secret';
    const error = ConfigStoreException(
      ConfigStoreFailure.corrupt,
      'configuration_snapshot_v1',
      FormatException(secret),
    );

    expect(error.toString(), isNot(contains(secret)));
    expect(error.toString(), contains('configuration_snapshot_v1'));
  });

  test('combined encrypted snapshot has a strict size ceiling', () async {
    SharedPreferences.setMockInitialValues(const {});
    var platformCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      platformCalls++;
      return 'ciphertext';
    });
    final largeToml = List<String>.filled(1024 * 1024, 'x').join();
    final configs = List<FrpConfig>.generate(
      6,
      (index) => FrpConfig(
        id: index + 1,
        name: 'manual-$index',
        manualToml: largeToml,
      ),
    );

    await expectLater(
      ConfigStore().saveConfigurationSnapshot(
        ConfigurationSnapshot(
          servers: const [ServerConfig(serverId: 'SERVER01')],
          selectedServerId: 'SERVER01',
          configs: configs,
        ),
      ),
      throwsFormatException,
    );
    expect(platformCalls, 0);
  });
}
