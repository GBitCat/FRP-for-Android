import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/models/socks5_config.dart';
import 'package:frp_app/screens/config_edit_screen.dart';
import 'package:frp_app/screens/configs_screen.dart';
import 'package:frp_app/screens/main_shell.dart';
import 'package:frp_app/screens/manual_config_edit_screen.dart';
import 'package:frp_app/services/certificates/certificate_models.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:frp_app/theme.dart';
import 'package:frp_app/widgets/app_dropdown_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> _addProtocol(WidgetTester tester, String protocol) async {
  final dropdown = find.byKey(const ValueKey('protocol_dropdown'));
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(protocol.toUpperCase()).last);
  await tester.pumpAndSettle();
  final add = find.byKey(const ValueKey('add_protocol'));
  await tester.ensureVisible(add);
  await tester.tap(add);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  final saveButton = find.widgetWithText(TextButton, 'Save');
  await tester.runAsync(() async {
    final result = Function.apply(
      tester.widget<TextButton>(saveButton).onPressed!,
      const [],
    );
    if (result is Future<void>) await result;
  });
  await tester.pumpAndSettle();
}

Future<CertificateInventory> _loadReadyCertificateInventory() async =>
    const CertificateInventory(identities: [_readyIdentity]);

Future<Object?> _echoSecureStoreValue(MethodCall call) async =>
    (call.arguments as Map<Object?, Object?>?)?['value'];

const _readyIdentity = ManagedIdentityRecord(
  id: 'id-0123456789abcdef01234567',
  name: 'Android Client',
  commonName: 'android-client',
  algorithm: 'ecdsa-p256',
  dnsNames: [],
  ipAddresses: [],
  createdAt: null,
  privateKeyPath: '/certs/client.key',
  csrPath: '/certs/client.csr',
  certificatePath: '/certs/client.crt',
  trustedCaPath: '/certs/ca.crt',
  issuer: 'test-ca',
  notAfter: null,
  fingerprint: 'AA:BB:CC:DD',
  status: 'ready',
);

void main() {
  test('peer config escapes every TOML string field', () {
    final block = proxyBlockForPeer(
      'peer"name\\node',
      'xtcp',
      'secret"value\\tail',
      'host"name\\path',
      39001,
      useEncryption: true,
      useCompression: false,
    );

    expect(block, contains(r'name = "peer\"name\\node"'));
    expect(block, contains(r'type = "xtcp"'));
    expect(block, contains(r'localIP = "host\"name\\path"'));
    expect(block, contains(r'secretKey = "secret\"value\\tail"'));
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStoreChannel = MethodChannel('com.frp.app/secure_store');
  const engineChannel = MethodChannel('com.frp.app/engine');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(const {});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      secureStoreChannel,
      _echoSecureStoreValue,
    );
    messenger.setMockMethodCallHandler(engineChannel, (call) async {
      return switch (call.method) {
        'getInitialTab' => 1,
        'getTotalMemoryMb' => 8192.0,
        'getMemoryMb' => 0.0,
        'getIpv4' || 'getIpv6' => '',
        _ => null,
      };
    });
    appState.pausePolling();
    await appState.retryInitialization();
    appState.batteryHintPending = false;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    await appState.retryInitialization();
    appState.servers = [
      const ServerConfig(
        serverId: 'SERVER01',
        name: 'Primary',
        serverAddr: 'one.example.com',
      ),
    ];
    appState.configs = [];
  });

  tearDown(appState.pausePolling);

  tearDownAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, null);
    messenger.setMockMethodCallHandler(engineChannel, null);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'shared fields retain the same height in ${dark ? "dark" : "light"} mode',
      (tester) async {
        final theme = dark
            ? AppTheme.dark(Colors.blue)
            : AppTheme.light(Colors.blue);
        String? selected = 'tcp';
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Column(
                children: [
                  const TextField(
                    key: ValueKey('shared_plain_input'),
                    decoration: InputDecoration(labelText: 'Name'),
                  ),
                  TextField(
                    key: const ValueKey('shared_password_input'),
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.visibility_outlined),
                      ),
                    ),
                  ),
                  AppDropdownButtonFormField<String>(
                    key: const ValueKey('shared_dropdown'),
                    initialValue: selected,
                    decoration: const InputDecoration(labelText: 'Protocol'),
                    items: const [
                      DropdownMenuItem(value: 'tcp', child: Text('TCP')),
                      DropdownMenuItem(value: 'udp', child: Text('UDP')),
                    ],
                    onChanged: (value) => selected = value,
                  ),
                ],
              ),
            ),
          ),
        );
        for (final key in [
          'shared_plain_input',
          'shared_password_input',
          'shared_dropdown',
        ]) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            46,
            reason: key,
          );
        }
        final dropdown = tester.widget<DropdownButton<String>>(
          find.descendant(
            of: find.byKey(const ValueKey('shared_dropdown')),
            matching: find.byWidgetPredicate(
              (widget) => widget is DropdownButton<String>,
            ),
          ),
        );
        expect(dropdown.iconSize, 20);
        expect(dropdown.borderRadius, BorderRadius.circular(16));
        expect(theme.canvasColor, theme.colorScheme.surfaceContainerLow);
        await tester.tap(find.byKey(const ValueKey('shared_dropdown')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('UDP').last);
        await tester.pumpAndSettle();
        expect(selected, 'udp');
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('initialization permanently scrubs legacy runtime TLS paths', () async {
    final legacy = jsonEncode([
      {
        'serverId': 'SERVER01',
        'name': 'Legacy server',
        'serverAddr': 'frps.example.com',
        'tlsEnabled': false,
        'tlsCertFile': '/legacy/client.crt',
        'tlsKeyFile': '/legacy/client.key',
        'tlsTrustedCaFile': '/legacy/ca.crt',
      },
    ]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_configs_v2', 'enc:v1:$legacy');

    await appState.retryInitialization();

    final stored = (await SharedPreferences.getInstance()).getString(
      'configuration_snapshot_v1',
    );
    expect(stored, isNotNull);
    expect(stored, startsWith('enc:v1:'));
    final decoded = (jsonDecode(stored!.substring('enc:v1:'.length)) as Map)
        .cast<String, dynamic>();
    final servers = decoded['servers'] as List<dynamic>;
    final server = (servers.single as Map).cast<String, dynamic>();
    expect(server, isNot(contains('tlsCertFile')));
    expect(server, isNot(contains('tlsKeyFile')));
    expect(server, isNot(contains('tlsTrustedCaFile')));
    expect(appState.servers.single.hasLegacyTlsPaths, isFalse);
  });

  testWidgets('add menu opens the grouped form without changing Basic', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MainShell()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add config'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('visitor.FormConfig'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('form_config_card')), findsOneWidget);
    expect(find.text('Basic Information'), findsOneWidget);
    expect(find.byKey(const ValueKey('server_selector')), findsOneWidget);
    expect(find.byKey(const ValueKey('group_name')), findsOneWidget);
    expect(find.byKey(const ValueKey('config_name')), findsOneWidget);
    expect(find.byKey(const ValueKey('server_proxy_name')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('config_name')))
          .decoration
          ?.hintText,
      'Application-Name',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('server_proxy_name')))
          .decoration
          ?.hintText,
      'Server-Name',
    );
    expect(find.byKey(const ValueKey('protocol_dropdown')), findsOneWidget);
    expect(find.byKey(const ValueKey('protocol_card_xtcp')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('bind_address')))
          .controller!
          .text,
      '127.0.0.1',
    );
    expect(find.text('Compression'), findsOneWidget);
    expect(find.text('Configuration Preview'), findsOneWidget);
    final secretField = tester.widget<TextField>(
      find.byKey(const ValueKey('secret_key')),
    );
    expect(secretField.obscureText, isTrue);
    expect(secretField.enableSuggestions, isFalse);
    expect(secretField.autocorrect, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server tokens are hidden and suggestions stay disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ServerEditDialog(
            initial: ServerConfig(serverId: 'SERVER01', token: 'test-token'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tokenField = tester.widget<TextField>(
      find.byKey(const ValueKey('server_token')),
    );
    expect(tokenField.obscureText, isTrue);
    expect(tokenField.enableSuggestions, isFalse);
    expect(tokenField.autocorrect, isFalse);
  });

  testWidgets('server dialog cannot cancel or pop while save is pending', (
    tester,
  ) async {
    final saveStarted = Completer<void>();
    final allowWrite = Completer<void>();
    addTearDown(() {
      if (!allowWrite.isCompleted) allowWrite.complete();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(
                  child: ServerEditDialog(
                    initial: appState.servers.single,
                    certificateInventoryLoader: () async =>
                        const CertificateInventory(),
                    onSave: (_, _) {
                      saveStarted.complete();
                      return allowWrite.future;
                    },
                  ),
                ),
              ),
              child: const Text('Open server editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open server editor'));
    await tester.pumpAndSettle();

    final pendingSave = Function.apply(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed!,
      const [],
    ) as Future<void>;
    await tester.pump();
    expect(saveStarted.isCompleted, isTrue);
    await tester.pump();

    final dialogScope = find.descendant(
      of: find.byType(ServerEditDialog),
      matching: find.byWidgetPredicate((widget) => widget is PopScope),
    );
    expect(tester.widget<PopScope>(dialogScope).canPop, isFalse);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed,
      isNull,
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ServerEditDialog), findsOneWidget);

    allowWrite.complete();
    await tester.pumpAndSettle();
    await pendingSave;
    expect(find.byType(ServerEditDialog), findsNothing);
  });

  testWidgets('manual config page cannot pop while save is pending', (
    tester,
  ) async {
    final saveStarted = Completer<void>();
    final allowWrite = Completer<void>();
    addTearDown(() {
      if (!allowWrite.isCompleted) allowWrite.complete();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => ManualConfigEditScreen(
                    onSave: (_, _) {
                      saveStarted.complete();
                      return allowWrite.future;
                    },
                  ),
                ),
              ),
              child: const Text('Open manual editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open manual editor'));
    await tester.pumpAndSettle();
    final pendingSave = Function.apply(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
          .onPressed!,
      const [],
    ) as Future<void>;
    await tester.pump();
    expect(saveStarted.isCompleted, isTrue);
    await tester.pump();

    final pageScope = find.descendant(
      of: find.byType(ManualConfigEditScreen),
      matching: find.byWidgetPredicate((widget) => widget is PopScope),
    );
    expect(tester.widget<PopScope>(pageScope).canPop, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ManualConfigEditScreen), findsOneWidget);

    allowWrite.complete();
    await tester.pumpAndSettle();
    await pendingSave;
    expect(find.byType(ManualConfigEditScreen), findsNothing);
  });

  testWidgets('server preview uses the tapped row and is not selectable', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(
        serverId: 'SERVER01',
        name: 'First',
        serverAddr: 'one.example.com',
        token: 'first-token',
      ),
      ServerConfig(
        serverId: 'SERVER02',
        name: 'Second',
        serverAddr: 'two.example.com',
        token: 'second-token',
      ),
    ];
    appState.configs = const [
      FrpConfig(
        id: 1,
        name: 'first-proxy',
        protocol: 'tcp',
        localPort: 22,
        remotePort: 10022,
        serverId: 'SERVER01',
      ),
      FrpConfig(
        id: 2,
        name: 'second-proxy',
        protocol: 'tcp',
        localPort: 23,
        remotePort: 10023,
        serverId: 'SERVER02',
      ),
    ];
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ConfigsScreen())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Preview config').last);
    await tester.pumpAndSettle();

    final previewFinder = find.byKey(
      const ValueKey('server_config_preview_text'),
    );
    final preview = tester.widget<Text>(previewFinder).data!;
    expect(preview, contains('serverAddr = "two.example.com"'));
    expect(preview, contains('auth.token = "second-token"'));
    expect(preview, contains('name = "second-proxy"'));
    expect(preview, isNot(contains('first-token')));
    expect(preview, isNot(contains('first-proxy')));
    expect(find.byType(SelectableText), findsNothing);
    expect(
      find.byKey(const ValueKey('copy_server_config_preview')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('server config uses compact grouped rows on phones', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: ServerEditDialog(
              initial: ServerConfig(
                serverId: 'SERVER01',
                serverAddr: 'one.example.com',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final key in [
      'server_name',
      'server_id',
      'server_address',
      'server_port',
      'server_token',
    ]) {
      final field = tester.widget<TextField>(find.byKey(ValueKey(key)));
      expect(field.decoration?.isDense, isTrue, reason: '$key is compact');
      expect(field.style?.fontSize, 16, reason: '$key uses unified text size');
    }

    const controlKeys = [
      'server_name',
      'server_id',
      'server_address',
      'server_port',
      'server_token',
      'server_protocol',
      'server_wire_protocol',
      'server_tcp_mux',
      'server_heartbeat_interval',
      'server_heartbeat_timeout',
      'server_keepalive',
      'server_bidirectional_verification',
    ];
    for (final key in controlKeys) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        46,
        reason: '$key uses the unified control height',
      );
    }

    final protocol = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('server_protocol')),
        matching: find.byWidgetPredicate(
          (widget) => widget is DropdownButton<String>,
        ),
      ),
    );
    expect(protocol.style?.fontSize, 16);
    expect(protocol.iconSize, 20);
    expect(protocol.borderRadius, BorderRadius.circular(16));
    final wireProtocol = tester.widget<AppDropdownButtonFormField<String>>(
      find.byKey(const ValueKey('server_wire_protocol')),
    );
    expect(wireProtocol.initialValue, 'v2');
    final tcpMux = tester.widget<AppDropdownButtonFormField<bool>>(
      find.byKey(const ValueKey('server_tcp_mux')),
    );
    expect(tcpMux.initialValue, isTrue);
    final tcpMuxDropdown = tester.widget<DropdownButton<bool>>(
      find.descendant(
        of: find.byKey(const ValueKey('server_tcp_mux')),
        matching: find.byWidgetPredicate(
          (widget) => widget is DropdownButton<bool>,
        ),
      ),
    );
    expect(tcpMuxDropdown.style?.fontSize, 16);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('server_tcp_mux')),
        matching: find.byType(Switch),
      ),
      findsNothing,
    );
    for (final key in [
      'server_heartbeat_interval',
      'server_heartbeat_timeout',
      'server_keepalive',
    ]) {
      final field = tester.widget<DropdownButton<int>>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byWidgetPredicate(
            (widget) => widget is DropdownButton<int>,
          ),
        ),
      );
      expect(field.style?.fontSize, 16, reason: '$key uses unified text size');
      expect(field.iconSize, 20, reason: '$key uses the shared dropdown icon');
    }

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('server_address'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('server_port'))).dy,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('server_protocol'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('server_wire_protocol'))).dy,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('server_protocol'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('server_tcp_mux'))).dy,
    );
    final timeRowY = tester
        .getTopLeft(find.byKey(const ValueKey('server_heartbeat_interval')))
        .dy;
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('server_heartbeat_timeout')))
          .dy,
      timeRowY,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('server_keepalive'))).dy,
      timeRowY,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('server_id')),
        matching: find.byKey(const ValueKey('server_reset_id')),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('server_config_dialog'))).height,
      lessThan(650),
    );
    expect(find.byKey(const ValueKey('server_keepalive')), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('transport selections save and reload on a narrow phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> openEditor() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => Center(
                    child: ServerEditDialog(
                      initial: appState.servers.single,
                      certificateInventoryLoader: () async =>
                          const CertificateInventory(),
                    ),
                  ),
                ),
                child: const Text('Open server editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open server editor'));
      await tester.pumpAndSettle();
    }

    await openEditor();
    final wireField = find.byKey(const ValueKey('server_wire_protocol'));
    final tcpMuxField = find.byKey(const ValueKey('server_tcp_mux'));
    expect(
      tester.widget<AppDropdownButtonFormField<bool>>(tcpMuxField).initialValue,
      isTrue,
    );
    expect(
      tester.widget<AppDropdownButtonFormField<String>>(wireField).initialValue,
      'v2',
    );
    await tester.ensureVisible(wireField);
    await tester.tap(wireField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('v1').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(tcpMuxField);
    await tester.tap(tcpMuxField);
    await tester.pumpAndSettle();
    expect(find.text('Enabled'), findsWidgets);
    expect(find.text('Disabled'), findsOneWidget);
    await tester.tap(find.text('Disabled').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<FilledButton>(save).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();
    expect(appState.servers.single.wireProtocol, 'v1');
    expect(appState.servers.single.tcpMux, isFalse);

    await tester.runAsync(appState.retryInitialization);
    expect(appState.servers.single.wireProtocol, 'v1');
    expect(appState.servers.single.tcpMux, isFalse);
    await tester.tap(find.text('Open server editor'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AppDropdownButtonFormField<String>>(wireField).initialValue,
      'v1',
    );
    expect(
      tester.widget<AppDropdownButtonFormField<bool>>(tcpMuxField).initialValue,
      isFalse,
    );
    await tester.ensureVisible(tcpMuxField);
    await tester.tap(tcpMuxField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enabled').last);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<FilledButton>(save).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();
    expect(appState.servers.single.tcpMux, isTrue);
    expect(appState.servers.single.wireProtocol, 'v1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('bidirectional verification expands and saves mutual TLS', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ServerEditDialog(
              initial: appState.servers.single,
              certificateInventoryLoader: _loadReadyCertificateInventory,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final expansion = find.byKey(
      const ValueKey('server_bidirectional_verification'),
    );
    expect(find.text('Bidirectional Verification'), findsOneWidget);
    expect(tester.getSize(expansion).height, 46);
    expect(find.byKey(const ValueKey('server_tls_enabled')), findsNothing);
    expect(find.byKey(const ValueKey('server_tls_identity')), findsNothing);

    await tester.ensureVisible(expansion);
    await tester.tap(expansion);
    await tester.pumpAndSettle();

    final tlsSwitch = find.byKey(const ValueKey('server_tls_enabled'));
    expect(tlsSwitch, findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('server_tls_enabled_control')))
          .height,
      46,
    );
    await tester.ensureVisible(tlsSwitch);
    await tester.tap(tlsSwitch);
    await tester.pumpAndSettle();

    final serverName = find.byKey(const ValueKey('server_tls_server_name'));
    expect(serverName, findsOneWidget);
    expect(tester.getSize(serverName).height, 46);
    final serverNameField = tester.widget<TextField>(serverName);
    expect(serverNameField.style?.fontSize, 16);

    final identityDropdown = find.byKey(const ValueKey('server_tls_identity'));
    expect(identityDropdown, findsOneWidget);
    expect(tester.getSize(identityDropdown).height, 46);
    expect(find.text('Client Certificate'), findsNothing);
    expect(find.text('Client Private Key'), findsNothing);
    expect(find.text('Trusted CA Certificate'), findsNothing);

    await _enter(tester, 'server_tls_server_name', 'secure.example.com');
    await tester.ensureVisible(identityDropdown);
    await tester.tap(identityDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(_readyIdentity.selectionLabel).last);
    await tester.pumpAndSettle();

    final saveButton = find.widgetWithText(FilledButton, 'Save');
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<FilledButton>(saveButton).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();

    final saved = appState.servers.single;
    expect(saved.tlsEnabled, isTrue);
    expect(saved.tlsServerName, 'secure.example.com');
    expect(saved.tlsIdentityId, _readyIdentity.id);
    expect(saved.tlsCertFile, '/certs/client.crt');
    expect(saved.tlsKeyFile, '/certs/client.key');
    expect(saved.tlsTrustedCaFile, '/certs/ca.crt');
    expect(saved.hasCompleteTlsCredentials, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate identity names stay distinct in TLS selection', (
    tester,
  ) async {
    const secondIdentity = ManagedIdentityRecord(
      id: 'id-fedcba9876543210fedcba98',
      name: 'Android Client',
      commonName: 'android-client-2',
      algorithm: 'ecdsa-p256',
      dnsNames: [],
      ipAddresses: [],
      createdAt: null,
      privateKeyPath: '/certs/second/client.key',
      csrPath: '/certs/second/client.csr',
      certificatePath: '/certs/second/client.crt',
      trustedCaPath: '/certs/second/ca.crt',
      issuer: 'test-ca',
      notAfter: null,
      fingerprint: 'AA:BB:CC:DD',
      status: 'ready',
    );
    Future<CertificateInventory> loadDuplicates() async =>
        const CertificateInventory(
          identities: [_readyIdentity, secondIdentity],
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ServerEditDialog(
              initial: appState.servers.single,
              certificateInventoryLoader: loadDuplicates,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final expansion = find.byKey(
      const ValueKey('server_bidirectional_verification'),
    );
    await tester.ensureVisible(expansion);
    await tester.tap(expansion);
    await tester.pumpAndSettle();
    final tlsSwitch = find.byKey(const ValueKey('server_tls_enabled'));
    await tester.ensureVisible(tlsSwitch);
    await tester.tap(tlsSwitch);
    await tester.pumpAndSettle();

    final dropdown = find.byKey(const ValueKey('server_tls_identity'));
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();

    expect(find.text(_readyIdentity.selectionLabel), findsOneWidget);
    expect(find.text(secondIdentity.selectionLabel), findsOneWidget);
    expect(_readyIdentity.selectionLabel, isNot(secondIdentity.selectionLabel));
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy certificate paths resolve to a managed identity', (
    tester,
  ) async {
    final legacyServer = appState.servers.single.copyWith(
      tlsEnabled: true,
      tlsCertFile: _readyIdentity.certificatePath,
      tlsKeyFile: _readyIdentity.privateKeyPath,
      tlsTrustedCaFile: _readyIdentity.trustedCaPath,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerEditDialog(
            initial: legacyServer,
            certificateInventoryLoader: _loadReadyCertificateInventory,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dropdown = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('server_tls_identity')),
        matching: find.byWidgetPredicate(
          (widget) => widget is DropdownButton<String>,
        ),
      ),
    );
    expect(dropdown.value, _readyIdentity.id);

    final saveButton = find.widgetWithText(FilledButton, 'Save');
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<FilledButton>(saveButton).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();

    expect(appState.servers.single.tlsIdentityId, _readyIdentity.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('identity ID refreshes stale runtime certificate paths', (
    tester,
  ) async {
    final staleServer = appState.servers.single.copyWith(
      tlsEnabled: true,
      tlsIdentityId: _readyIdentity.id,
      tlsCertFile: '/old/client.crt',
      tlsKeyFile: '/old/client.key',
      tlsTrustedCaFile: '/old/ca.crt',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerEditDialog(
            initial: staleServer,
            certificateInventoryLoader: _loadReadyCertificateInventory,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final saveButton = find.widgetWithText(FilledButton, 'Save');
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<FilledButton>(saveButton).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();

    final saved = appState.servers.single;
    expect(saved.tlsIdentityId, _readyIdentity.id);
    expect(saved.tlsCertFile, _readyIdentity.certificatePath);
    expect(saved.tlsKeyFile, _readyIdentity.privateKeyPath);
    expect(saved.tlsTrustedCaFile, _readyIdentity.trustedCaPath);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding protocols reveals one multi-port field per protocol', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();

    await _addProtocol(tester, 'xtcp');
    await _addProtocol(tester, 'xudp');

    expect(find.byKey(const ValueKey('protocol_card_xtcp')), findsOneWidget);
    expect(find.byKey(const ValueKey('protocol_card_xudp')), findsOneWidget);
    expect(find.byKey(const ValueKey('bind_ports_xtcp')), findsOneWidget);
    expect(find.byKey(const ValueKey('bind_ports_xudp')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('protocol_count'))).data,
      '2',
    );

    await _addProtocol(tester, 'xudp');
    expect(find.byKey(const ValueKey('protocol_card_xudp')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('protocol_count'))).data,
      '2',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('multiple bind ports append port to generated names', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();
    await _enter(tester, 'config_name', 'MuMuDev-ADB');
    await _enter(tester, 'server_proxy_name', 'MuMuDev-ADB');
    await _enter(tester, 'secret_key', 'shared-secret');
    await _addProtocol(tester, 'xtcp');
    await _enter(tester, 'bind_ports_xtcp', '39001,39002');

    expect(find.textContaining('2 bind ports'), findsOneWidget);
    await tester.ensureVisible(find.text('Configuration Preview'));
    await tester.tap(find.text('Configuration Preview'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('name = "MuMuDev-ADB-xtcp-39001"'),
      findsOneWidget,
    );
    expect(
      find.textContaining('serverName = "MuMuDev-ADB-xtcp-39001"'),
      findsOneWidget,
    );
    expect(
      find.textContaining('name = "MuMuDev-ADB-xtcp-39002"'),
      findsOneWidget,
    );
    expect(find.textContaining('bindAddr = "127.0.0.1"'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single bind port keeps only the protocol suffix', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();
    await _enter(tester, 'config_name', 'MuMuDev-ADB');
    await _enter(tester, 'server_proxy_name', 'Peer-ADB');
    await _enter(tester, 'secret_key', 'shared-secret');
    await _addProtocol(tester, 'xtcp');
    await _enter(tester, 'bind_ports_xtcp', '39001');

    await tester.ensureVisible(find.text('Configuration Preview'));
    await tester.tap(find.text('Configuration Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('name = "MuMuDev-ADB-xtcp"'), findsOneWidget);
    expect(find.textContaining('serverName = "Peer-ADB-xtcp"'), findsOneWidget);
    expect(find.textContaining('MuMuDev-ADB-xtcp-39001'), findsNothing);
  });

  testWidgets(
    'peer config button is above preview and local ports match visitor ports',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
      await tester.pumpAndSettle();
      await _enter(tester, 'config_name', 'Application-Name');
      await _enter(tester, 'server_proxy_name', 'Server-Name');
      await _enter(tester, 'secret_key', 'shared-secret');
      await _addProtocol(tester, 'xtcp');
      await _enter(tester, 'bind_ports_xtcp', '39001,39002');
      await _addProtocol(tester, 'xudp');
      await _enter(tester, 'bind_ports_xudp', '39100');

      final fallback = find.text('Fallback');
      await tester.ensureVisible(fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();

      final deriveButton = find.byKey(const ValueKey('derive_peer_config'));
      final preview = find.byKey(const ValueKey('configuration_preview'));
      await tester.ensureVisible(deriveButton);
      expect(
        tester.getTopLeft(deriveButton).dy,
        lessThan(tester.getTopLeft(preview).dy),
      );
      expect(
        find.ancestor(of: deriveButton, matching: find.byType(ExpansionTile)),
        findsNothing,
      );

      await tester.tap(deriveButton);
      await tester.pumpAndSettle();
      final peerText = tester
          .widget<Text>(find.byKey(const ValueKey('peer_config_text')))
          .data!;
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('peer_config_text')),
          matching: find.byType(SelectableText),
        ),
        findsNothing,
      );
      expect(RegExp(r'localPort = 39001').allMatches(peerText), hasLength(2));
      expect(RegExp(r'localPort = 39002').allMatches(peerText), hasLength(2));
      expect(RegExp(r'localPort = 39100').allMatches(peerText), hasLength(2));
      expect(peerText, isNot(contains('localPort = 39101')));
      expect(peerText, isNot(contains('localPort = 22')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saving expands shared fields into a multi-protocol group', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();
    await _enter(tester, 'group_name', 'MuMu ADB');
    await _enter(tester, 'config_name', 'MuMuDev-ADB');
    await _enter(tester, 'server_proxy_name', 'Peer-ADB');
    await _enter(tester, 'secret_key', 'shared-secret');
    await _addProtocol(tester, 'xtcp');
    await _enter(tester, 'bind_ports_xtcp', '39001');
    await _addProtocol(tester, 'xudp');
    await _enter(tester, 'bind_ports_xudp', '39002-39003');

    await _save(tester);

    expect(appState.configs, hasLength(3));
    expect(appState.configs.map((config) => config.name).toSet(), {
      'MuMuDev-ADB-xtcp',
      'MuMuDev-ADB-xudp-39002',
      'MuMuDev-ADB-xudp-39003',
    });
    expect(appState.configs.map((config) => config.serverName).toSet(), {
      'Peer-ADB-xtcp',
      'Peer-ADB-xudp-39002',
      'Peer-ADB-xudp-39003',
    });
    expect(
      appState.configs.every((config) => config.secretKey == 'shared-secret'),
      isTrue,
    );
    expect(
      appState.configs.every((config) => config.bindAddr == '127.0.0.1'),
      isTrue,
    );
    expect(
      appState.configs.map((config) => config.groupId).toSet(),
      hasLength(1),
    );
    expect(appState.configs.first.groupId, greaterThan(0));
    expect(
      appState.configs.every((config) => config.groupName == 'MuMu ADB'),
      isTrue,
    );
    expect(
      appState.configs.where((config) => config.isGroupPrimary),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Fallback derives STCP and SUDP without extra fields', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();
    await _enter(tester, 'config_name', 'MuMuDev-ADB');
    await _enter(tester, 'server_proxy_name', 'Peer-ADB');
    await _enter(tester, 'secret_key', 'shared-secret');
    await _addProtocol(tester, 'xtcp');
    await _enter(tester, 'bind_ports_xtcp', '39001,39002');
    await _addProtocol(tester, 'xudp');
    await _enter(tester, 'bind_ports_xudp', '39100,39101');

    final fallback = find.text('Fallback');
    await tester.ensureVisible(fallback);
    await tester.tap(fallback);
    await tester.pumpAndSettle();
    expect(find.textContaining('Fallback Visitor'), findsNothing);

    await tester.ensureVisible(find.text('Configuration Preview'));
    await tester.tap(find.text('Configuration Preview'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('fallbackTo = "MuMuDev-ADB-stcp-39001"'),
      findsOneWidget,
    );
    expect(
      find.textContaining('fallbackTo = "MuMuDev-ADB-sudp-39100"'),
      findsOneWidget,
    );

    await _save(tester);
    expect(appState.configs, hasLength(8));
    expect(appState.configs.map((config) => config.protocol).toSet(), {
      'xtcp',
      'xudp',
      'stcp',
      'sudp',
    });
    final xtcp = appState.configs
        .where((config) => config.protocol == 'xtcp')
        .toList();
    final stcpNames = appState.configs
        .where((config) => config.protocol == 'stcp')
        .map((config) => config.name)
        .toSet();
    expect(xtcp.map((config) => config.fallbackTo).toSet(), stcpNames);
    final udpPorts = appState.configs
        .where(
          (config) => config.protocol == 'xudp' || config.protocol == 'sudp',
        )
        .map((config) => config.bindPort)
        .toList();
    expect(udpPorts.toSet(), hasLength(udpPorts.length));
    expect(appState.configs.every((config) => !config.useCustomStcp), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'editing a generated group restores shared fields and port lists',
    (tester) async {
      appState.configs = const [
        FrpConfig(
          id: 7,
          name: 'MuMuDev-ADB-xtcp-39001',
          protocol: 'xtcp',
          role: 'visitor',
          secretKey: 'shared-secret',
          serverName: 'Peer-ADB-xtcp-39001',
          bindPort: 39001,
          bindAddr: '127.0.0.1',
          serverId: 'SERVER01',
          groupId: 77,
          groupName: 'MuMu ADB',
          isGroupPrimary: true,
        ),
        FrpConfig(
          id: 8,
          name: 'MuMuDev-ADB-xtcp-39002',
          protocol: 'xtcp',
          role: 'visitor',
          secretKey: 'shared-secret',
          serverName: 'Peer-ADB-xtcp-39002',
          bindPort: 39002,
          bindAddr: '127.0.0.1',
          serverId: 'SERVER01',
          groupId: 77,
          groupName: 'MuMu ADB',
        ),
        FrpConfig(
          id: 9,
          name: 'MuMuDev-ADB-xudp',
          protocol: 'xudp',
          role: 'visitor',
          secretKey: 'shared-secret',
          serverName: 'Peer-ADB-xudp',
          bindPort: 39100,
          bindAddr: '127.0.0.1',
          serverId: 'SERVER01',
          groupId: 77,
          groupName: 'MuMu ADB',
        ),
      ];

      await tester.pumpWidget(
        const MaterialApp(home: ConfigEditScreen(configId: 7)),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('config_name')))
            .controller!
            .text,
        'MuMuDev-ADB',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('server_proxy_name')))
            .controller!
            .text,
        'Peer-ADB',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bind_ports_xtcp')))
            .controller!
            .text,
        '39001-39002',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('bind_ports_xudp')))
            .controller!
            .text,
        '39100',
      );

      final originalIds = appState.configs.map((config) => config.id).toSet();
      await _save(tester);
      expect(appState.configs.map((config) => config.id).toSet(), originalIds);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removing a protocol removes its expanded members on save', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();
    await _enter(tester, 'config_name', 'MuMuDev-ADB');
    await _enter(tester, 'server_proxy_name', 'Peer-ADB');
    await _enter(tester, 'secret_key', 'shared-secret');
    await _addProtocol(tester, 'xtcp');
    await _addProtocol(tester, 'xudp');

    final removeXudp = find.byKey(const ValueKey('remove_protocol_xudp'));
    await tester.ensureVisible(removeXudp);
    await tester.tap(removeXudp);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('protocol_card_xudp')), findsNothing);

    await _save(tester);
    expect(appState.configs, hasLength(1));
    expect(appState.configs.single.protocol, 'xtcp');
    expect(appState.configs.single.name, 'MuMuDev-ADB-xtcp');
  });

  testWidgets(
    'adding ports and protocols to a disabled SOCKS group preserves disabled state and settings',
    (tester) async {
      const socks = Socks5Config(
        targetIp: '192.0.2.10',
        username: 'alice',
        password: 'socks-secret',
        tcpPorts: [8080],
      );
      appState.configs = const [
        FrpConfig(
          id: 7,
          name: 'Forward-xtcp-39001',
          protocol: 'xtcp',
          secretKey: 'shared-secret',
          serverName: 'Peer-xtcp-39001',
          bindPort: 39001,
          serverId: 'SERVER01',
          groupId: 77,
          groupName: 'Forward',
          isGroupPrimary: true,
          enabled: false,
          socks5: socks,
        ),
        FrpConfig(
          id: 8,
          name: 'Forward-xtcp-39002',
          protocol: 'xtcp',
          secretKey: 'shared-secret',
          serverName: 'Peer-xtcp-39002',
          bindPort: 39002,
          serverId: 'SERVER01',
          groupId: 77,
          groupName: 'Forward',
          enabled: false,
          socks5: socks,
        ),
      ];
      await tester.pumpWidget(
        const MaterialApp(home: ConfigEditScreen(configId: 7)),
      );
      await tester.pumpAndSettle();
      await _enter(tester, 'bind_ports_xtcp', '39001,39002,39003');
      await _addProtocol(tester, 'xudp');
      await _enter(tester, 'bind_ports_xudp', '39100');
      await _save(tester);

      expect(appState.configs, hasLength(4));
      expect(appState.configs.every((config) => !config.enabled), isTrue);
      expect(
        appState.configs.every((config) => config.socks5 == socks),
        isTrue,
      );
      expect(appState.configs.map((config) => config.id), containsAll([7, 8]));
      expect(
        appState.configs
            .where((config) => config.protocol == 'xtcp')
            .map((config) => config.bindPort)
            .toSet(),
        {39001, 39002, 39003},
      );
      expect(
        appState.configs
            .singleWhere((config) => config.protocol == 'xudp')
            .bindPort,
        39100,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing mixed SOCKS visitors keeps UDP fallback in group scope',
    (tester) async {
      const socks = Socks5Config(
        targetIp: '127.0.0.1',
        tcpPorts: [5513, 5514],
        udpPorts: [5513, 5514],
      );
      appState.configs = const [
        FrpConfig(
          id: 7,
          name: 'Forward-xtcp',
          protocol: 'xtcp',
          secretKey: 'shared-secret',
          serverName: 'Peer-xtcp',
          bindPort: 5511,
          serverId: 'SERVER01',
          groupId: 77,
          groupName: 'SOCKS5 TCP + UDP',
          isGroupPrimary: true,
          useFallback: true,
          fallbackTo: 'Forward-stcp-fallback',
          socks5: socks,
        ),
        FrpConfig(
          id: 8,
          name: 'Forward-stcp-fallback',
          protocol: 'stcp',
          secretKey: 'shared-secret',
          serverName: 'Peer-stcp',
          bindPort: -1,
          serverId: 'SERVER01',
          groupId: 77,
          groupName: 'SOCKS5 TCP + UDP',
        ),
        FrpConfig(
          id: 9,
          name: 'Forward-xudp',
          protocol: 'xudp',
          secretKey: 'shared-secret',
          serverName: 'Peer-xudp',
          bindPort: 5512,
          serverId: 'SERVER01',
          groupId: 77,
          groupName: 'SOCKS5 TCP + UDP',
          socks5: socks,
        ),
      ];
      await tester.pumpWidget(
        const MaterialApp(home: ConfigEditScreen(configId: 7)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Configuration Preview'));
      await tester.tap(find.text('Configuration Preview'));
      await tester.pumpAndSettle();
      expect(find.textContaining('type = "socks5_udp"'), findsOneWidget);
      expect(find.textContaining('already used by a visitor'), findsNothing);
      expect(find.textContaining('type = "sudp"'), findsNothing);

      await _save(tester);
      expect(appState.configs, hasLength(4));
      expect(appState.configs.map((config) => config.groupId).toSet(), {77});
      expect(
        appState.configs.map((config) => config.id),
        containsAll([7, 8, 9]),
      );
      expect(
        appState.configs
            .where(
              (config) =>
                  config.protocol == 'xtcp' || config.protocol == 'xudp',
            )
            .every((config) => config.socks5 == socks),
        isTrue,
      );
      final runtime = appState.buildFullTomlFor(appState.servers.single);
      expect(runtime, contains('type = "socks5_udp"'));
      expect(runtime, isNot(contains('type = "sudp"')));
      expect(tester.takeException(), isNull);
    },
  );

  for (final groupId in [0, 77]) {
    testWidgets('adding enabled SOCKS ports previews shared group $groupId', (
      tester,
    ) async {
      const socks = Socks5Config(targetIp: '192.0.2.10', tcpPorts: [8080]);
      final ports = groupId == 0 ? [39001] : [39001, 39002];
      appState.configs = [
        for (var i = 0; i < ports.length; i++)
          FrpConfig(
            id: 7 + i,
            name: ports.length == 1
                ? 'Forward-xtcp'
                : 'Forward-xtcp-${ports[i]}',
            protocol: 'xtcp',
            secretKey: 'shared-secret',
            serverName: ports.length == 1
                ? 'Peer-xtcp'
                : 'Peer-xtcp-${ports[i]}',
            bindPort: ports[i],
            serverId: 'SERVER01',
            groupId: groupId,
            groupName: 'Forward',
            isGroupPrimary: groupId > 0 && i == 0,
            socks5: socks,
          ),
      ];
      await tester.pumpWidget(
        const MaterialApp(home: ConfigEditScreen(configId: 7)),
      );
      await tester.pumpAndSettle();
      await _enter(tester, 'bind_ports_xtcp', '39001,39002,39003');
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Configuration Preview'));
      await tester.tap(find.text('Configuration Preview'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Incomplete configuration'), findsNothing);
      expect(
        find.textContaining('name = "Forward-xtcp-39003"'),
        findsOneWidget,
      );

      await _save(tester);
      expect(appState.configs, hasLength(3));
      expect(appState.configs.every((config) => config.enabled), isTrue);
      expect(
        appState.configs.every((config) => config.socks5 == socks),
        isTrue,
      );
      expect(
        appState.configs.map((config) => config.groupId).toSet(),
        hasLength(1),
      );
      expect(appState.configs.first.groupId, greaterThan(0));
      expect(appState.configs.map((config) => config.id), contains(7));
      expect(tester.takeException(), isNull);
    });
  }
}
