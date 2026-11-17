import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/screens/manual_config_edit_screen.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:frp_app/theme.dart';
import 'package:frp_app/widgets/frosted_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _openEditor(
  WidgetTester tester, {
  ManualConfigSaver? onSave,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(Colors.blue),
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              const Text('Configuration details'),
              TextButton(
                onPressed: () => showFrostedDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => ManualConfigEditScreen(
                    configId: 42,
                    asDialog: true,
                    onSave: onSave,
                  ),
                ),
                child: const Text('Edit'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Edit'));
  await tester.pumpAndSettle();
}

Future<void> _changeGroup(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).first, 'Updated group');
  await tester.pump();
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStore = MethodChannel('com.frp.app/secure_store');
  const engine = MethodChannel('com.frp.app/engine');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(const {});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      secureStore,
      (call) async => (call.arguments as Map<Object?, Object?>?)?['value'],
    );
    messenger.setMockMethodCallHandler(engine, (_) async => null);
    appState.pausePolling();
    await appState.retryInitialization();
  });

  setUp(() {
    appState.servers = const [
      ServerConfig(serverId: 'SERVER01', name: 'Primary'),
    ];
    appState.configs = const [
      FrpConfig(
        id: 42,
        serverId: 'SERVER01',
        groupName: 'Original group',
        manualToml: '[[visitors]]\nname = "manual-visitor"\ntype = "stcp"',
      ),
    ];
  });

  tearDown(appState.pausePolling);

  tearDownAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStore, null);
    messenger.setMockMethodCallHandler(engine, null);
  });

  testWidgets('clean manual dialog returns directly to details', (
    tester,
  ) async {
    await _openEditor(tester);
    await _back(tester);
    expect(find.byType(ManualConfigEditScreen), findsNothing);
    expect(find.text('Unsaved changes'), findsNothing);
    expect(find.text('Configuration details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dirty manual dialog blocks outside taps and guards Back', (
    tester,
  ) async {
    var saved = false;
    await _openEditor(tester, onSave: (_, _) async => saved = true);
    await _changeGroup(tester);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byType(ManualConfigEditScreen), findsOneWidget);

    await _back(tester);
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Updated group'), findsOneWidget);

    await _back(tester);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualConfigEditScreen), findsNothing);
    expect(find.text('Configuration details'), findsOneWidget);
    expect(saved, isFalse);
    expect(appState.configs.single.groupName, 'Original group');
  });

  testWidgets('Save from Back confirmation persists before closing', (
    tester,
  ) async {
    FrpConfig? saved;
    await _openEditor(tester, onSave: (config, _) async => saved = config);
    await _changeGroup(tester);
    await _back(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Save').last);
    await tester.pumpAndSettle();
    expect(saved?.groupName, 'Updated group');
    expect(find.byType(ManualConfigEditScreen), findsNothing);
    expect(find.text('Configuration details'), findsOneWidget);
  });

  testWidgets('failed save leaves the manual editor and draft open', (
    tester,
  ) async {
    await _openEditor(
      tester,
      onSave: (_, _) async => throw StateError('write failed'),
    );
    await _changeGroup(tester);
    await _back(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Save').last);
    await tester.pumpAndSettle();
    expect(find.byType(ManualConfigEditScreen), findsOneWidget);
    expect(find.text('Updated group'), findsOneWidget);
    expect(find.text('Unable to save configuration'), findsOneWidget);
    await _back(tester);
    expect(find.text('Unsaved changes'), findsOneWidget);
  });
}
