import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/screens/config_edit_screen.dart';
import 'package:frp_app/screens/main_shell.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _selectProtocol(
  WidgetTester tester, {
  required String from,
  required String to,
}) async {
  final dropdown = find.byKey(ValueKey('protocol_dropdown_$from'));
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(to.toUpperCase()).last);
  await tester.pumpAndSettle();
}

Future<void> _enterKeyedText(
  WidgetTester tester,
  String key,
  String value,
) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> _saveForm(WidgetTester tester) async {
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
    await appState.ready;
    appState.batteryHintPending = false;
  });

  tearDown(() {
    appState.pausePolling();
  });

  tearDownAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, null);
    messenger.setMockMethodCallHandler(engineChannel, null);
  });

  testWidgets('add menu opens the enabled form configuration editor', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(
        serverId: 'SERVER01',
        name: 'Primary',
        serverAddr: 'one.example.com',
      ),
    ];
    appState.configs = [];

    await tester.pumpWidget(const MaterialApp(home: MainShell()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add config'));
    await tester.pumpAndSettle();

    expect(find.text('Form Config'), findsOneWidget);
    expect(find.text('Manual Config'), findsOneWidget);
    expect(find.text('Server Config'), findsOneWidget);

    await tester.tap(find.text('Form Config'));
    await tester.pumpAndSettle();

    expect(find.text('Form Config'), findsOneWidget);
    expect(find.byKey(const ValueKey('form_config_card')), findsOneWidget);
    expect(find.text('Basic Information'), findsOneWidget);
    expect(find.text('TCP'), findsWidgets);
    final serverSelector = find.byKey(const ValueKey('server_selector'));
    final groupName = find.byKey(const ValueKey('group_name'));
    final protocolDropdown = find.byKey(
      const ValueKey('protocol_dropdown_tcp'),
    );
    expect(groupName, findsOneWidget);
    expect(
      tester.getTopLeft(groupName).dy,
      greaterThan(tester.getBottomLeft(serverSelector).dy),
    );
    expect(
      tester.getBottomLeft(groupName).dy,
      lessThan(tester.getTopLeft(protocolDropdown).dy),
    );

    await _selectProtocol(tester, from: 'tcp', to: 'http');
    expect(find.text('Custom Domains *'), findsOneWidget);
    expect(find.text('Remote Port *'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'form editor preserves custom XTCP names and previews its server',
    (tester) async {
      appState.servers = const [
        ServerConfig(
          serverId: 'SERVER01',
          name: 'Primary',
          serverAddr: 'one.example.com',
        ),
        ServerConfig(
          serverId: 'SERVER02',
          name: 'Secondary',
          serverAddr: 'two.example.com',
        ),
      ];
      appState.configs = const [
        FrpConfig(
          id: 7,
          name: 'custom-name',
          protocol: 'xtcp',
          role: 'visitor',
          secretKey: 'secret',
          serverName: 'remote-custom-name',
          bindPort: 39001,
          serverId: 'SERVER02',
        ),
      ];

      await tester.pumpWidget(
        const MaterialApp(home: ConfigEditScreen(configId: 7)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit Form Config'), findsOneWidget);
      expect(find.byKey(const ValueKey('form_config_card')), findsOneWidget);
      expect(find.text('Fixed Rule'), findsOneWidget);
      expect(find.text('Name is used as-is'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('configuration_preview')),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('Configuration Preview'));
      await tester.tap(find.text('Configuration Preview'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('serverAddr = "two.example.com"'),
        findsOneWidget,
      );
      expect(find.textContaining('name = "custom-name"'), findsOneWidget);
      expect(
        find.textContaining('serverName = "remote-custom-name"'),
        findsOneWidget,
      );
      expect(find.textContaining('custom-name-xtcp'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('form editor expands compact TCP port ranges in preview', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(
        serverId: 'SERVER01',
        name: 'Primary',
        serverAddr: 'one.example.com',
      ),
    ];
    appState.configs = [];

    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('local_ports')), findsOneWidget);
    expect(find.byKey(const ValueKey('remote_ports')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('config_name')),
      'services',
    );
    await tester.enterText(
      find.byKey(const ValueKey('local_ports')),
      '22,8000-8001',
    );
    await tester.enterText(find.byKey(const ValueKey('remote_ports')), '10022');
    await tester.pump();
    expect(
      find.text('Local and remote port counts must match (3 vs 1)'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('remote_ports')),
      '10022,9000-9001',
    );
    await tester.pump();
    expect(find.text('3 port mappings'), findsOneWidget);

    await tester.ensureVisible(find.text('Configuration Preview'));
    await tester.tap(find.text('Configuration Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('name = "services-22"'), findsOneWidget);
    expect(find.textContaining('name = "services-8000"'), findsOneWidget);
    expect(find.textContaining('name = "services-8001"'), findsOneWidget);
    expect(find.textContaining('remotePort = 9001'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('form editor restores existing multi-port mappings compactly', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(serverId: 'SERVER01', name: 'Primary'),
    ];
    appState.configs = const [
      FrpConfig(
        id: 8,
        name: 'services',
        protocol: 'tcp',
        localPort: 22,
        remotePort: 10022,
        portMappings: [
          PortMapping(localPort: 22, remotePort: 10022),
          PortMapping(localPort: 8000, remotePort: 9000),
          PortMapping(localPort: 8001, remotePort: 9001),
          PortMapping(localPort: 8002, remotePort: 9002),
        ],
        serverId: 'SERVER01',
      ),
    ];

    await tester.pumpWidget(
      const MaterialApp(home: ConfigEditScreen(configId: 8)),
    );
    await tester.pumpAndSettle();

    final local = tester.widget<TextField>(
      find.byKey(const ValueKey('local_ports')),
    );
    final remote = tester.widget<TextField>(
      find.byKey(const ValueKey('remote_ports')),
    );
    expect(local.controller!.text, '22,8000-8002');
    expect(remote.controller!.text, '10022,9000-9002');
    expect(find.text('4 port mappings'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('saving a multi-port form persists one logical config', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(serverId: 'SERVER01', name: 'Primary'),
    ];
    appState.configs = [];

    await tester.pumpWidget(const MaterialApp(home: MainShell()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add config'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Form Config'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('group_name')),
      'TCP Services',
    );
    await tester.enterText(
      find.byKey(const ValueKey('config_name')),
      'services',
    );
    await tester.enterText(
      find.byKey(const ValueKey('local_ports')),
      '22,8000-8001',
    );
    await tester.enterText(
      find.byKey(const ValueKey('remote_ports')),
      '10022,9000-9001',
    );
    tester.testTextInput.hide();
    await tester.pump();
    final saveButton = find.widgetWithText(TextButton, 'Save');
    expect(saveButton.hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<TextButton>(saveButton).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();

    final snackMessages = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    expect(
      appState.configs,
      hasLength(1),
      reason: 'Save feedback: $snackMessages',
    );
    final saved = appState.configs.single;
    expect(saved.name, 'services');
    expect(saved.groupName, 'TCP Services');
    expect(saved.localPort, 22);
    expect(saved.remotePort, 10022);
    expect(saved.portMappings, const [
      PortMapping(localPort: 22, remotePort: 10022),
      PortMapping(localPort: 8000, remotePort: 9000),
      PortMapping(localPort: 8001, remotePort: 9001),
    ]);
    expect(find.text('TCP Services'), findsOneWidget);
    expect(find.text('TCP · 3 ports · Visitor'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('switching protocols preserves independent form drafts', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(
        serverId: 'SERVER01',
        name: 'Primary',
        serverAddr: 'one.example.com',
      ),
    ];
    appState.configs = [];

    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();

    await _selectProtocol(tester, from: 'tcp', to: 'xtcp');
    expect(find.byKey(const ValueKey('protocol_chip_tcp')), findsNothing);
    expect(find.byKey(const ValueKey('protocol_chip_xtcp')), findsOneWidget);
    await _enterKeyedText(tester, 'config_name', 'ssh');
    await _enterKeyedText(tester, 'secret_key', 'xtcp-secret');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('server_proxy_name')))
          .controller!
          .text,
      'ssh-xtcp',
    );

    await _selectProtocol(tester, from: 'xtcp', to: 'xudp');
    expect(find.byKey(const ValueKey('protocol_chip_xtcp')), findsOneWidget);
    expect(find.byKey(const ValueKey('protocol_chip_xudp')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('protocol_count'))).data,
      '2',
    );
    await _enterKeyedText(tester, 'config_name', 'dns-xudp');
    await _enterKeyedText(tester, 'secret_key', 'xudp-secret');
    await _enterKeyedText(tester, 'server_proxy_name', 'remote-xudp');

    await tester.ensureVisible(
      find.byKey(const ValueKey('protocol_chip_xtcp')),
    );
    await tester.tap(find.byKey(const ValueKey('protocol_chip_xtcp')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('config_name')))
          .controller!
          .text,
      'ssh',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('secret_key')))
          .controller!
          .text,
      'xtcp-secret',
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('protocol_chip_xudp')),
    );
    await tester.tap(find.byKey(const ValueKey('protocol_chip_xudp')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('config_name')))
          .controller!
          .text,
      'dns-xudp',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('server_proxy_name')))
          .controller!
          .text,
      'remote-xudp',
    );

    await tester.ensureVisible(find.text('Configuration Preview'));
    await tester.tap(find.text('Configuration Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('name = "ssh-xtcp"'), findsOneWidget);
    expect(find.textContaining('name = "dns-xudp"'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('saving XTCP and XUDP creates one multi-protocol group', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(serverId: 'SERVER01', name: 'Primary'),
    ];
    appState.configs = [];

    await tester.pumpWidget(const MaterialApp(home: MainShell()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add config'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Form Config'));
    await tester.pumpAndSettle();

    await _selectProtocol(tester, from: 'tcp', to: 'xtcp');
    await _enterKeyedText(tester, 'config_name', 'combo');
    await _enterKeyedText(tester, 'secret_key', 'xtcp-secret');
    await _selectProtocol(tester, from: 'xtcp', to: 'xudp');
    await _enterKeyedText(tester, 'config_name', 'combo-xudp');
    await _enterKeyedText(tester, 'secret_key', 'xudp-secret');
    await _enterKeyedText(tester, 'server_proxy_name', 'remote-xudp');
    await _enterKeyedText(tester, 'group_name', 'Dual P2P');

    tester.testTextInput.hide();
    await tester.pump();
    final saveButton = find.widgetWithText(TextButton, 'Save');
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<TextButton>(saveButton).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();

    expect(appState.configs, hasLength(2));
    final xtcp = appState.configs.singleWhere(
      (config) => config.protocol == 'xtcp',
    );
    final xudp = appState.configs.singleWhere(
      (config) => config.protocol == 'xudp',
    );
    expect(xtcp.name, 'combo-xtcp');
    expect(xtcp.secretKey, 'xtcp-secret');
    expect(xudp.name, 'combo-xudp');
    expect(xudp.serverName, 'remote-xudp');
    expect(xtcp.groupId, greaterThan(0));
    expect(xudp.groupId, xtcp.groupId);
    expect(xtcp.groupName, 'Dual P2P');
    expect(xudp.groupName, 'Dual P2P');
    expect(xtcp.isGroupPrimary, isTrue);
    expect(xudp.isGroupPrimary, isFalse);
    expect(find.text('Dual P2P'), findsOneWidget);
    expect(find.text('XTCP + XUDP'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('XTCP fallback still creates a linked STCP group member', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(serverId: 'SERVER01', name: 'Primary'),
    ];
    appState.configs = [];

    await tester.pumpWidget(const MaterialApp(home: MainShell()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add config'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Form Config'));
    await tester.pumpAndSettle();

    await _selectProtocol(tester, from: 'tcp', to: 'xtcp');
    await _enterKeyedText(tester, 'config_name', 'fallback');
    await _enterKeyedText(tester, 'secret_key', 'shared-secret');
    final fallbackToggle = find.text('Fallback to STCP');
    await tester.ensureVisible(fallbackToggle);
    await tester.tap(fallbackToggle);
    await tester.pumpAndSettle();
    await _enterKeyedText(tester, 'group_name', 'Fallback Group');

    final saveButton = find.widgetWithText(TextButton, 'Save');
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<TextButton>(saveButton).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();

    expect(appState.configs, hasLength(2));
    final xtcp = appState.configs.singleWhere(
      (config) => config.protocol == 'xtcp',
    );
    final stcp = appState.configs.singleWhere(
      (config) => config.protocol == 'stcp',
    );
    expect(xtcp.fallbackTo, stcp.name);
    expect(stcp.secretKey, 'shared-secret');
    expect(stcp.groupId, xtcp.groupId);
    expect(stcp.groupName, 'Fallback Group');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('editing a group loads and updates every protocol draft', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(serverId: 'SERVER01', name: 'Primary'),
    ];
    appState.configs = const [
      FrpConfig(
        id: 7,
        name: 'combo-xtcp',
        protocol: 'xtcp',
        role: 'visitor',
        secretKey: 'xtcp-secret',
        serverName: 'combo-xtcp',
        bindPort: 9002,
        serverId: 'SERVER01',
        groupId: 77,
        groupName: 'Dual P2P',
        isGroupPrimary: true,
        createdAt: 10,
      ),
      FrpConfig(
        id: 8,
        name: 'combo-xudp',
        protocol: 'xudp',
        role: 'visitor',
        secretKey: 'xudp-secret',
        serverName: 'remote-xudp',
        bindPort: 9003,
        serverId: 'SERVER01',
        groupId: 77,
        groupName: 'Dual P2P',
        createdAt: 11,
      ),
    ];

    await tester.pumpWidget(
      const MaterialApp(home: ConfigEditScreen(configId: 7)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('protocol_chip_xtcp')), findsOneWidget);
    expect(find.byKey(const ValueKey('protocol_chip_xudp')), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('protocol_chip_xudp')),
    );
    await tester.tap(find.byKey(const ValueKey('protocol_chip_xudp')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('config_name')))
          .controller!
          .text,
      'combo-xudp',
    );
    await _enterKeyedText(tester, 'secret_key', 'updated-xudp-secret');

    final saveButton = find.widgetWithText(TextButton, 'Save');
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<TextButton>(saveButton).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();

    expect(appState.configs, hasLength(2));
    expect(appState.configs.map((config) => config.id).toSet(), {7, 8});
    expect(
      appState.configs
          .singleWhere((config) => config.protocol == 'xudp')
          .secretKey,
      'updated-xudp-secret',
    );
    expect(
      appState.configs
          .singleWhere((config) => config.protocol == 'xtcp')
          .secretKey,
      'xtcp-secret',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('removing a protocol chip removes that group member on save', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(serverId: 'SERVER01', name: 'Primary'),
    ];
    appState.configs = const [
      FrpConfig(
        id: 7,
        name: 'combo-xtcp',
        protocol: 'xtcp',
        role: 'visitor',
        secretKey: 'xtcp-secret',
        serverName: 'combo-xtcp',
        bindPort: 9002,
        serverId: 'SERVER01',
        groupId: 77,
        groupName: 'Dual P2P',
        isGroupPrimary: true,
      ),
      FrpConfig(
        id: 8,
        name: 'combo-xudp',
        protocol: 'xudp',
        role: 'visitor',
        secretKey: 'xudp-secret',
        serverName: 'combo-xudp',
        bindPort: 9003,
        serverId: 'SERVER01',
        groupId: 77,
        groupName: 'Dual P2P',
      ),
    ];

    await tester.pumpWidget(
      const MaterialApp(home: ConfigEditScreen(configId: 7)),
    );
    await tester.pumpAndSettle();
    final removeXudp = find.byKey(const ValueKey('remove_protocol_xudp'));
    await tester.ensureVisible(removeXudp);
    await tester.tap(removeXudp);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('protocol_chip_xudp')), findsNothing);

    final saveButton = find.widgetWithText(TextButton, 'Save');
    await tester.runAsync(() async {
      final result = Function.apply(
        tester.widget<TextButton>(saveButton).onPressed!,
        const [],
      );
      if (result is Future<void>) await result;
    });
    await tester.pumpAndSettle();

    expect(appState.configs, hasLength(1));
    expect(appState.configs.single.id, 7);
    expect(appState.configs.single.protocol, 'xtcp');
    expect(appState.configs.single.groupId, 0);
    expect(appState.configs.single.groupName, 'Dual P2P');
    expect(appState.configs.single.isGroupPrimary, isFalse);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('same protocol can be added twice and edited independently', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(serverId: 'SERVER01', name: 'Primary'),
    ];
    appState.configs = [];

    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();

    await _enterKeyedText(tester, 'group_name', 'Two TCP Services');
    await _enterKeyedText(tester, 'config_name', 'first');
    await _enterKeyedText(tester, 'local_ports', '22');
    await _enterKeyedText(tester, 'remote_ports', '10022');

    final addSame = find.byKey(const ValueKey('add_protocol_instance'));
    await tester.ensureVisible(addSame);
    await tester.tap(addSame);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('protocol_chip_tcp_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('protocol_chip_tcp_2')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('protocol_count'))).data,
      '2',
    );
    await _enterKeyedText(tester, 'config_name', 'second');
    await _enterKeyedText(tester, 'local_ports', '80');
    await _enterKeyedText(tester, 'remote_ports', '10080');

    final firstChip = find.byKey(const ValueKey('protocol_chip_tcp_1'));
    await tester.ensureVisible(firstChip);
    await tester.tap(firstChip);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('config_name')))
          .controller!
          .text,
      'first',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('local_ports')))
          .controller!
          .text,
      '22',
    );

    await _saveForm(tester);
    expect(appState.configs, hasLength(2));
    expect(appState.configs.map((config) => config.protocol).toList(), [
      'tcp',
      'tcp',
    ]);
    expect(appState.configs.map((config) => config.name).toSet(), {
      'first',
      'second',
    });
    expect(
      appState.configs.map((config) => config.groupId).toSet(),
      hasLength(1),
    );
    expect(appState.configs.first.groupId, greaterThan(0));
    expect(appState.configs.first.isGroupPrimary, isTrue);

    final originalIds = appState.configs.map((config) => config.id).toSet();
    final secondId = appState.configs
        .singleWhere((config) => config.name == 'second')
        .id;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MaterialApp(home: MainShell()));
    await tester.pumpAndSettle();
    expect(find.text('TCP ×2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(home: ConfigEditScreen(configId: secondId)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('protocol_chip_tcp_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('protocol_chip_tcp_2')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('config_name')))
          .controller!
          .text,
      'second',
    );
    await _saveForm(tester);
    expect(appState.configs.map((config) => config.id).toSet(), originalIds);
    expect(appState.configs.map((config) => config.name).toSet(), {
      'first',
      'second',
    });
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('duplicate XTCP members keep separate STCP fallbacks', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(serverId: 'SERVER01', name: 'Primary'),
    ];
    appState.configs = [];

    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();
    await _selectProtocol(tester, from: 'tcp', to: 'xtcp');
    await _enterKeyedText(tester, 'config_name', 'alpha');
    await _enterKeyedText(tester, 'secret_key', 'alpha-secret');
    var fallbackToggle = find.text('Fallback to STCP');
    await tester.ensureVisible(fallbackToggle);
    await tester.tap(fallbackToggle);
    await tester.pumpAndSettle();

    final addSame = find.byKey(const ValueKey('add_protocol_instance'));
    await tester.ensureVisible(addSame);
    await tester.tap(addSame);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('bind_port')))
          .controller!
          .text,
      '9003',
    );
    await _enterKeyedText(tester, 'config_name', 'beta');
    await _enterKeyedText(tester, 'secret_key', 'beta-secret');
    fallbackToggle = find.text('Fallback to STCP');
    await tester.ensureVisible(fallbackToggle);
    await tester.tap(fallbackToggle);
    await tester.pumpAndSettle();

    await _saveForm(tester);
    expect(appState.configs, hasLength(4));
    final xtcpConfigs = appState.configs
        .where((config) => config.protocol == 'xtcp')
        .toList();
    final stcpConfigs = appState.configs
        .where((config) => config.protocol == 'stcp')
        .toList();
    expect(xtcpConfigs, hasLength(2));
    expect(stcpConfigs, hasLength(2));
    expect(xtcpConfigs.map((config) => config.bindPort).toSet(), {9002, 9003});
    expect(xtcpConfigs.map((config) => config.fallbackTo).toSet(), {
      'alpha-stcp',
      'beta-stcp',
    });
    expect(stcpConfigs.map((config) => config.name).toSet(), {
      'alpha-stcp',
      'beta-stcp',
    });
    expect(
      stcpConfigs
          .singleWhere((config) => config.name == 'alpha-stcp')
          .secretKey,
      'alpha-secret',
    );
    expect(
      stcpConfigs.singleWhere((config) => config.name == 'beta-stcp').secretKey,
      'beta-secret',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('XUDP fallback creates and previews a linked SUDP visitor', (
    tester,
  ) async {
    appState.servers = const [
      ServerConfig(
        serverId: 'SERVER01',
        name: 'Primary',
        serverAddr: 'one.example.com',
      ),
    ];
    appState.configs = [];

    await tester.pumpWidget(const MaterialApp(home: ConfigEditScreen()));
    await tester.pumpAndSettle();
    await _selectProtocol(tester, from: 'tcp', to: 'xudp');
    await _enterKeyedText(tester, 'config_name', 'game-xudp');
    await _enterKeyedText(tester, 'secret_key', 'udp-secret');
    await _enterKeyedText(tester, 'server_proxy_name', 'remote-xudp');

    final fallbackToggle = find.text('Fallback to SUDP');
    await tester.ensureVisible(fallbackToggle);
    await tester.tap(fallbackToggle);
    await tester.pumpAndSettle();
    expect(find.text('SUDP Fallback Visitor'), findsOneWidget);

    await tester.ensureVisible(find.text('Configuration Preview'));
    await tester.tap(find.text('Configuration Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fallbackTo = "game-sudp"'), findsOneWidget);
    expect(find.textContaining('type = "sudp"'), findsOneWidget);

    final derivePeer = find.text('Derive Peer Config');
    await tester.ensureVisible(derivePeer);
    await tester.tap(derivePeer);
    await tester.pumpAndSettle();
    expect(find.textContaining('name = "remote-xudp"'), findsOneWidget);
    expect(find.textContaining('name = "remote-sudp"'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await _saveForm(tester);
    expect(appState.configs, hasLength(2));
    final xudp = appState.configs.singleWhere(
      (config) => config.protocol == 'xudp',
    );
    final sudp = appState.configs.singleWhere(
      (config) => config.protocol == 'sudp',
    );
    expect(xudp.fallbackTo, 'game-sudp');
    expect(sudp.name, xudp.fallbackTo);
    expect(sudp.serverName, 'remote-sudp');
    expect(sudp.secretKey, 'udp-secret');
    expect(sudp.bindPort, 9003);
    expect(sudp.groupId, xudp.groupId);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
