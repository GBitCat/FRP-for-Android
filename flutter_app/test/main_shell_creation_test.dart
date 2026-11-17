import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/screens/config_edit_screen.dart';
import 'package:frp_app/screens/configs_screen.dart';
import 'package:frp_app/screens/main_shell.dart';
import 'package:frp_app/screens/manual_config_edit_screen.dart';
import 'package:frp_app/services/config_store.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:frp_app/theme.dart';
import 'package:frp_app/widgets/editor_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _openFromAddMenu(
  WidgetTester tester, {
  bool manual = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(appAccents.first),
      home: const MainShell(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Add config'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(manual ? 'Manual Config' : 'visitor.FormConfig'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  final button = tester.widget<TextButton>(
    find.widgetWithText(TextButton, 'Save').last,
  );
  // Execute async persistence outside FakeAsync so the shared mutation queue
  // is drained before another widget test starts.
  await tester.runAsync(() async {
    final result = Function.apply(button.onPressed!, const []);
    if (result is Future<void>) await result;
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('com.frp.app/secure_store');
  const engine = MethodChannel('com.frp.app/engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    messenger.setMockMethodCallHandler(
      secure,
      (call) async => (call.arguments as Map<Object?, Object?>?)?['value'],
    );
    messenger.setMockMethodCallHandler(engine, (call) async {
      return switch (call.method) {
        'getInitialTab' => 1,
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
    SharedPreferences.setMockInitialValues(const {'battery_hint_shown': true});
    await appState.retryInitialization();
    appState.pausePolling();
    appState.batteryHintPending = false;
    appState.servers = const [
      ServerConfig(
        serverId: 'SERVER01',
        name: 'Primary',
        serverAddr: 'localhost',
      ),
    ];
    appState.configs = [];
  });

  tearDown(appState.pausePolling);
  tearDownAll(() {
    messenger.setMockMethodCallHandler(secure, null);
    messenger.setMockMethodCallHandler(engine, null);
  });

  for (final manual in [false, true]) {
    final kind = manual ? 'manual' : 'form';
    testWidgets('$kind creation opens a floating card and returns cleanly', (
      tester,
    ) async {
      await _openFromAddMenu(tester, manual: manual);
      expect(find.byType(EditorCard), findsOneWidget);
      expect(find.byType(ConfigsScreen), findsOneWidget);
      expect(find.text('Add Configuration'), findsNothing);
      if (manual) {
        expect(
          tester
              .widget<ManualConfigEditScreen>(
                find.byType(ManualConfigEditScreen),
              )
              .asDialog,
          isTrue,
        );
      } else {
        expect(
          tester
              .widget<ConfigEditScreen>(find.byType(ConfigEditScreen))
              .asDialog,
          isTrue,
        );
      }
      expect(tester.getSize(find.byType(EditorCard)).height, lessThan(760));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(EditorCard), findsNothing);
      expect(find.text('Unsaved changes'), findsNothing);
      expect(find.byType(ConfigsScreen), findsOneWidget);
      expect(find.byTooltip('Add config'), findsOneWidget);
      expect(appState.configs, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$kind creation keeps dirty drafts until Back is confirmed', (
      tester,
    ) async {
      await _openFromAddMenu(tester, manual: manual);
      if (manual) {
        await tester.enterText(
          find
              .descendant(
                of: find.byType(ManualConfigEditScreen),
                matching: find.byType(TextField),
              )
              .first,
          'Unsaved manual visitor',
        );
        await tester.pumpAndSettle();
      } else {
        await _enter(tester, 'group_name', 'Unsaved visitor');
      }
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.byType(EditorCard), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorCard), findsNothing);
      expect(find.byType(ConfigsScreen), findsOneWidget);
      expect(appState.configs, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('new form visitor saves from its card back to Configurations', (
    tester,
  ) async {
    await _openFromAddMenu(tester);
    await _enter(tester, 'group_name', 'Created from shell');
    await _enter(tester, 'config_name', 'shell-visitor');
    await _enter(tester, 'server_proxy_name', 'provider');
    final addProtocol = find.byKey(const ValueKey('add_protocol'));
    await tester.ensureVisible(addProtocol);
    await tester.tap(addProtocol);
    await tester.pumpAndSettle();
    await _enter(tester, 'bind_ports_xtcp', '32001');
    await _enter(tester, 'secret_key', 'test-secret');
    await _save(tester);
    expect(find.byType(EditorCard), findsNothing);
    expect(find.byType(ConfigsScreen), findsOneWidget);
    expect(appState.configs, hasLength(1));
    final config = appState.configs.single;
    expect(config.role, 'visitor');
    expect(config.protocol, 'xtcp');
    expect(config.bindPort, 32001);
    expect(config.serverId, 'SERVER01');
    expect(config.groupName, 'Created from shell');
    final saved = await tester.runAsync(
      () => ConfigStore().loadConfigurationSnapshot(),
    );
    expect(saved!.configs.single.id, config.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new manual visitor saves from its card back to Configurations', (
    tester,
  ) async {
    await _openFromAddMenu(tester, manual: true);
    final content = find
        .descendant(
          of: find.byType(ManualConfigEditScreen),
          matching: find.byType(TextField),
        )
        .last;
    await tester.ensureVisible(content);
    await tester.enterText(content, '''[[visitors]]
name = "shell-manual"
type = "stcp"
serverName = "provider"
secretKey = "test-secret"
bindAddr = "127.0.0.1"
bindPort = 32002
''');
    await tester.pumpAndSettle();
    await _save(tester);
    expect(find.byType(EditorCard), findsNothing);
    expect(find.byType(ConfigsScreen), findsOneWidget);
    expect(appState.configs, hasLength(1));
    expect(appState.configs.single.role, 'visitor');
    expect(appState.configs.single.manualToml, contains('shell-manual'));
    final saved = await tester.runAsync(
      () => ConfigStore().loadConfigurationSnapshot(),
    );
    expect(saved!.configs.single.manualToml, contains('shell-manual'));
    expect(tester.takeException(), isNull);
  });
}
