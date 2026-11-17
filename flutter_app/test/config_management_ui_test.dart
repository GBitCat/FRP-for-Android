import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/screens/config_details_dialog.dart';
import 'package:frp_app/screens/config_edit_screen.dart';
import 'package:frp_app/screens/configs_screen.dart';
import 'package:frp_app/screens/socks5_config_dialog.dart';
import 'package:frp_app/services/config_store.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:frp_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fixtures = [
  FrpConfig(
    id: 1,
    name: 'single-xtcp',
    groupName: 'Single',
    protocol: 'xtcp',
    serverId: 'SERVER01',
    serverName: 'provider-xtcp',
    secretKey: 'test-key',
    bindPort: 1080,
  ),
  FrpConfig(
    id: 2,
    name: 'pair-xtcp',
    protocol: 'xtcp',
    serverId: 'SERVER01',
    serverName: 'pair-provider-xtcp',
    secretKey: 'test-key',
    bindPort: 1081,
    groupId: 7,
    groupName: 'Pair',
    isGroupPrimary: true,
  ),
  FrpConfig(
    id: 3,
    name: 'pair-xudp',
    protocol: 'xudp',
    serverId: 'SERVER01',
    serverName: 'pair-provider-xudp',
    secretKey: 'test-key',
    bindPort: 1082,
    groupId: 7,
    groupName: 'Pair',
  ),
];

Future<void> _openList(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(appAccents.first),
      home: const Scaffold(body: ConfigsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _swipe(
  WidgetTester tester,
  String itemKey, {
  bool left = true,
}) async {
  final row = find.byKey(ValueKey(itemKey));
  await tester.ensureVisible(row);
  await tester.drag(row, Offset(left ? -500 : 500, 0));
  await tester.pumpAndSettle();
}

Future<void> _pressTextButton(WidgetTester tester, String label) async {
  // A secondary confirmation can share its Save label with the editor below.
  final button = find.widgetWithText(TextButton, label).last;
  await tester.tap(button);
  await tester.pump();
  // The confirmation callback schedules removal after the route completes.
  // Queue a nonexistent-ID no-op in the real zone so the shared state's tail
  // does not remain bound to this test's FakeAsync zone after the test ends.
  var completed = false;
  Object? failure;
  await tester.runAsync(() async {
    appState
        .setConfigEnabled(-1, false)
        .then(
          (_) => completed = true,
          onError: (Object error) {
            failure = error;
            completed = true;
          },
        );
  });
  for (var attempt = 0; attempt < 100 && !completed; attempt++) {
    await tester.pump();
    await tester.runAsync(() async {});
  }
  expect(completed, isTrue, reason: 'the mutation queue must finish');
  expect(failure, isNull);
  await tester.pumpAndSettle();
}

Future<void> _openSingleDetails(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('config_swipe_1'));
  final options = find.descendant(of: row, matching: find.byTooltip('Options'));
  await tester.ensureVisible(options);
  await tester.tap(options);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Config'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('com.frp.app/secure_store');
  const engine = MethodChannel('com.frp.app/engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var failSave = false;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    messenger.setMockMethodCallHandler(secure, (call) async {
      if (failSave && call.method == 'encrypt') {
        throw PlatformException(code: 'SAVE_FAILED');
      }
      return (call.arguments as Map<Object?, Object?>?)?['value'];
    });
    messenger.setMockMethodCallHandler(engine, (call) async {
      return switch (call.method) {
        'getMemoryMb' || 'getTotalMemoryMb' => 0.0,
        'getIpv4' || 'getIpv6' => '',
        'isRunRequested' => false,
        'start' || 'stop' => true,
        _ => null,
      };
    });
    appState.pausePolling();
    await appState.retryInitialization();
  });

  setUp(() async {
    failSave = false;
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    await appState.retryInitialization();
    appState.pausePolling();
    appState.servers = const [
      ServerConfig(
        serverId: 'SERVER01',
        name: 'Primary',
        serverAddr: 'localhost',
      ),
    ];
    appState.configs = List.of(_fixtures);
  });

  tearDown(appState.pausePolling);
  tearDownAll(() {
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(engine, null);
  });

  testWidgets(
    'managed deletion requires a left swipe and explicit confirmation',
    (tester) async {
      await _openList(tester);
      await _swipe(tester, 'config_swipe_1');
      expect(find.text('Delete Configuration'), findsNothing);
      expect(appState.configs, hasLength(3));

      await tester.tap(find.byKey(const ValueKey('config_manage')));
      await tester.pumpAndSettle();
      await _swipe(tester, 'config_swipe_1', left: false);
      expect(find.text('Delete Configuration'), findsNothing);

      await _swipe(tester, 'config_swipe_1');
      expect(find.text('Delete Configuration'), findsOneWidget);
      expect(appState.configs, hasLength(3));
      await _pressTextButton(tester, 'Cancel');
      expect(appState.configs, hasLength(3));
      expect(find.byKey(const ValueKey('config_swipe_1')), findsOneWidget);

      await _swipe(tester, 'config_swipe_1');
      await _pressTextButton(tester, 'Delete');
      expect(appState.configs.map((config) => config.id), [2, 3]);
      expect(find.byKey(const ValueKey('config_swipe_1')), findsNothing);
      final saved = await tester.runAsync(
        () => ConfigStore().loadConfigurationSnapshot(),
      );
      expect(saved!.configs.map((config) => config.id), [2, 3]);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ConfigsScreen), findsOneWidget);
      expect(find.text('Manage'), findsOneWidget);
      expect(find.text('Swipe left to delete'), findsNothing);
      await _swipe(tester, 'config_swipe_group_7');
      expect(find.text('Delete Group'), findsNothing);
      expect(appState.configs, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('deleting a group removes every member and retains other items', (
    tester,
  ) async {
    await _openList(tester);
    await tester.tap(find.byKey(const ValueKey('config_manage')));
    await tester.pumpAndSettle();
    await _swipe(tester, 'config_swipe_group_7');
    expect(find.text('Delete Group'), findsOneWidget);
    await _pressTextButton(tester, 'Cancel');
    expect(appState.configs, hasLength(3));

    await _swipe(tester, 'config_swipe_group_7');
    await _pressTextButton(tester, 'Delete');
    expect(appState.configs.single.id, 1);
    expect(find.byKey(const ValueKey('config_swipe_group_7')), findsNothing);
    final saved = await tester.runAsync(
      () => ConfigStore().loadConfigurationSnapshot(),
    );
    expect(saved!.configs.single.id, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed deletion retains the item and allows retry', (
    tester,
  ) async {
    await _openList(tester);
    await tester.tap(find.byKey(const ValueKey('config_manage')));
    await tester.pumpAndSettle();
    failSave = true;
    await _swipe(tester, 'config_swipe_1');
    await _pressTextButton(tester, 'Delete');
    expect(appState.configs, hasLength(3));
    expect(find.byKey(const ValueKey('config_swipe_1')), findsOneWidget);
    expect(find.text('Unable to delete configuration'), findsOneWidget);

    failSave = false;
    await _swipe(tester, 'config_swipe_1');
    await _pressTextButton(tester, 'Delete');
    expect(appState.configs.map((config) => config.id), [2, 3]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'editing retains the details card and refreshes it after saving',
    (tester) async {
      await _openList(tester);
      await _openSingleDetails(tester);
      final detailsState = tester.state(find.byType(ConfigDetailsDialog));
      final details = find.byType(ConfigDetailsDialog, skipOffstage: false);
      final edit = find.byKey(const ValueKey('config_details_edit'));
      expect(find.byKey(const ValueKey('config_details_delete')), findsNothing);

      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.byType(ConfigEditScreen), findsOneWidget);
      expect(details, findsOneWidget);
      expect(tester.state(details), same(detailsState));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ConfigDetailsDialog), findsOneWidget);
      expect(tester.state(details), same(detailsState));

      await tester.tap(edit);
      await tester.pumpAndSettle();
      final ports = find.byKey(const ValueKey('bind_ports_xtcp'));
      await tester.ensureVisible(ports);
      await tester.enterText(ports, '1180');
      await tester.pump();
      await _pressTextButton(tester, 'Save');
      expect(find.byType(ConfigEditScreen), findsNothing);
      expect(tester.state(details), same(detailsState));
      expect(
        appState.configs.singleWhere((config) => config.id == 1).bindPort,
        1180,
      );
      final preview = find.descendant(
        of: find.byType(ConfigDetailsDialog),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data?.contains('bindPort = 1180') ?? false),
        ),
      );
      expect(preview, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('config_details_close')));
      await tester.pumpAndSettle();
      expect(find.byType(ConfigDetailsDialog), findsNothing);
      expect(find.byType(ConfigsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('replacing the protocol keeps details attached to the new ID', (
    tester,
  ) async {
    await _openList(tester);
    await _openSingleDetails(tester);
    final detailsState = tester.state(find.byType(ConfigDetailsDialog));
    await tester.tap(find.byKey(const ValueKey('config_details_edit')));
    await tester.pumpAndSettle();

    final removeTcp = find.byKey(const ValueKey('remove_protocol_xtcp'));
    await tester.ensureVisible(removeTcp);
    await tester.tap(removeTcp);
    await tester.pumpAndSettle();
    final protocol = find.byKey(const ValueKey('protocol_dropdown'));
    await tester.ensureVisible(protocol);
    await tester.tap(protocol);
    await tester.pumpAndSettle();
    await tester.tap(find.text('XUDP').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add_protocol')));
    await tester.pumpAndSettle();
    final udpPorts = find.byKey(const ValueKey('bind_ports_xudp'));
    await tester.ensureVisible(udpPorts);
    await tester.enterText(udpPorts, '1180');
    await tester.pump();
    await _pressTextButton(tester, 'Save');

    expect(find.byType(ConfigEditScreen), findsNothing);
    final replacement = appState.configs.singleWhere(
      (config) => config.groupName == 'Single',
    );
    expect(replacement.protocol, 'xudp');
    expect(replacement.id, isNot(1));
    expect(tester.state(find.byType(ConfigDetailsDialog)), same(detailsState));
    expect(
      tester
          .widget<ConfigDetailsDialog>(find.byType(ConfigDetailsDialog))
          .configs
          .single
          .id,
      replacement.id,
    );

    await tester.tap(find.byKey(const ValueKey('config_details_edit')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ConfigEditScreen>(find.byType(ConfigEditScreen)).configId,
      replacement.id,
    );
    expect(find.byKey(const ValueKey('bind_ports_xudp')), findsOneWidget);
    expect(find.byKey(const ValueKey('bind_ports_xtcp')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ConfigDetailsDialog)), same(detailsState));
    await tester.tap(find.byKey(const ValueKey('config_details_close')));
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('config_swipe_${replacement.id}'));
    final options = find.descendant(
      of: row,
      matching: find.byTooltip('Options'),
    );
    await tester.ensureVisible(options);
    await tester.tap(options);
    await tester.pumpAndSettle();
    await tester.tap(find.text('SOCKS'));
    await tester.pumpAndSettle();
    final socks = tester.widget<Socks5ConfigDialog>(
      find.byType(Socks5ConfigDialog),
    );
    expect(socks.supportsTcp, isFalse);
    expect(socks.supportsUdp, isTrue);
    await tester.tap(find.byKey(const ValueKey('socks_close')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dirty Config modal blocks outside taps and can discard on Back',
    (tester) async {
      await _openList(tester);
      await _openSingleDetails(tester);
      final details = find.byType(ConfigDetailsDialog);
      final originalDetailsState = tester.state(details);
      await tester.tap(find.byKey(const ValueKey('config_details_edit')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ConfigEditScreen>(find.byType(ConfigEditScreen)).asDialog,
        isTrue,
      );
      expect(
        tester
            .getSize(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('form_config_card')),
                    matching: find.byType(Card),
                  )
                  .first,
            )
            .height,
        lessThanOrEqualTo(760 * 0.85),
      );
      final ports = find.byKey(const ValueKey('bind_ports_xtcp'));
      await tester.ensureVisible(ports);
      await tester.enterText(ports, '1180');
      await tester.pump();
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.byType(ConfigEditScreen), findsOneWidget);
      expect(tester.state(details), same(originalDetailsState));
      expect(
        appState.configs.singleWhere((entry) => entry.id == 1).bindPort,
        1080,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await _pressTextButton(tester, 'Keep editing');
      expect(tester.widget<TextField>(ports).controller!.text, '1180');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _pressTextButton(tester, 'Discard');
      expect(find.byType(ConfigEditScreen), findsNothing);
      expect(tester.state(details), same(originalDetailsState));
      expect(
        appState.configs.singleWhere((entry) => entry.id == 1).bindPort,
        1080,
      );
      expect(find.textContaining('bindPort = 1080'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Save from dirty Back retains Config draft on failure and retries',
    (tester) async {
      await _openList(tester);
      await _openSingleDetails(tester);
      final details = find.byType(ConfigDetailsDialog);
      final originalDetailsState = tester.state(details);
      await tester.tap(find.byKey(const ValueKey('config_details_edit')));
      await tester.pumpAndSettle();
      final ports = find.byKey(const ValueKey('bind_ports_xtcp'));
      await tester.ensureVisible(ports);
      await tester.enterText(ports, '1180');
      await tester.pump();
      failSave = true;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _pressTextButton(tester, 'Save');
      expect(find.text('Unsaved changes'), findsNothing);
      expect(find.text('Unable to save configuration'), findsOneWidget);
      expect(find.byType(ConfigEditScreen), findsOneWidget);
      expect(tester.widget<TextField>(ports).controller!.text, '1180');
      expect(tester.state(details), same(originalDetailsState));
      expect(
        appState.configs.singleWhere((entry) => entry.id == 1).bindPort,
        1080,
      );

      failSave = false;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await _pressTextButton(tester, 'Save');
      expect(find.byType(ConfigEditScreen), findsNothing);
      expect(tester.state(details), same(originalDetailsState));
      expect(
        appState.configs.singleWhere((entry) => entry.id == 1).bindPort,
        1180,
      );
      expect(find.textContaining('bindPort = 1180'), findsOneWidget);
      final persisted = await tester.runAsync(
        () => ConfigStore().loadConfigurationSnapshot(),
      );
      expect(
        persisted!.configs.singleWhere((entry) => entry.id == 1).bindPort,
        1180,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
