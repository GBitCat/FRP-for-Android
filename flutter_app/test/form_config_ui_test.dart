import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/screens/config_edit_screen.dart';
import 'package:frp_app/screens/configs_screen.dart';
import 'package:frp_app/screens/main_shell.dart';
import 'package:frp_app/state/app_state.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStoreChannel = MethodChannel('com.frp.app/secure_store');
  const engineChannel = MethodChannel('com.frp.app/engine');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(const {});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      return (call.arguments as Map<Object?, Object?>)['value'] as String?;
    });
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
    appState.servers = const [
      ServerConfig(
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
          .widget<SelectableText>(
            find.byKey(const ValueKey('peer_config_text')),
          )
          .data!;
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
}
