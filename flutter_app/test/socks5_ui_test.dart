import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/server_config.dart';
import 'package:frp_app/models/socks5_config.dart';
import 'package:frp_app/screens/config_details_dialog.dart';
import 'package:frp_app/screens/configs_screen.dart';
import 'package:frp_app/screens/socks5_config_dialog.dart';
import 'package:frp_app/state/app_state.dart';
import 'package:frp_app/theme.dart';
import 'package:frp_app/widgets/frosted_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _settings = Socks5Config(
  targetIp: '127.0.0.1',
  username: 'alice',
  password: 'hidden-socks-password',
  tcpPorts: [8080],
  udpPorts: [5353],
);

Future<void> _openSocks(
  WidgetTester tester, {
  Socks5Config? initial = _settings,
  bool tcp = true,
  bool udp = true,
  Future<void> Function(Socks5Config?)? onSave,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(appAccents.first),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showFrostedDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => Socks5ConfigDialog(
                initial: initial,
                supportsTcp: tcp,
                supportsUdp: udp,
                onSave: onSave ?? (_) async {},
              ),
            ),
            child: const Text('Open SOCKS'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open SOCKS'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStoreChannel = MethodChannel('com.frp.app/secure_store');
  const engineChannel = MethodChannel('com.frp.app/engine');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(const {});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      secureStoreChannel,
      (call) async => (call.arguments as Map<Object?, Object?>?)?['value'],
    );
    messenger.setMockMethodCallHandler(
      engineChannel,
      (call) async => switch (call.method) {
        'getTotalMemoryMb' => 8192.0,
        'getMemoryMb' => 0.0,
        'getIpv4' || 'getIpv6' => '',
        'isRunRequested' => false,
        'stop' => true,
        _ => null,
      },
    );
    appState.pausePolling();
    await appState.retryInitialization();
  });

  tearDown(() => appState.pausePolling());
  tearDownAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStoreChannel, null);
    messenger.setMockMethodCallHandler(engineChannel, null);
  });

  test(
    'details redact multiline and inline credentials without leaking comments',
    () {
      final result = redactConfigurationToml(
        '''
[[visitors]]
name = "visible-name"
secretKey = """
hidden-key-line-one
hidden-key-line-two
"""
password = '''
        "'''hidden-literal-password\nsecond-line'''"
        '''
headers = { Authorization = "hidden-inline-authorization", normal = "hidden-with-table" }
auth.token = "hidden-token" # hidden-comment
[proxies.requestHeaders.set]
Cookie = "hidden-session-cookie"
[privateKey]
value = "hidden-table-value"
[ordinary]
port = 1234
# password = "hidden-comment-only"
''',
      );
      expect(result, contains('visible-name'));
      expect(result, contains('port = 1234'));
      expect(result, contains('secretKey = "***"'));
      expect(result, contains('Cookie = "***"'));
      expect(result, isNot(contains('hidden-')));
      expect(result, isNot(contains('second-line')));
      expect(
        redactConfigurationToml(r'"pass\u0077ord" = "unicode-secret"'),
        isNot(contains('unicode-secret')),
      );
      expect(
        redactConfigurationToml('password = """unterminated-secret'),
        isNot(contains('unterminated-secret')),
      );
    },
  );

  testWidgets(
    'details stay within sixty percent with fixed actions and masked secrets',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(appAccents.first),
          home: Scaffold(
            body: Center(
              child: ConfigDetailsDialog(
                title: 'Example',
                configs: List.generate(
                  6,
                  (index) => FrpConfig(
                    id: index + 1,
                    name: 'visitor-$index',
                    protocol: index.isEven ? 'stcp' : 'sudp',
                    serverName: 'remote-$index',
                    secretKey: 'hidden-frp-key',
                    bindPort: 1080 + index,
                    socks5: _settings,
                  ),
                ),
                onEdit: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const ValueKey('config_details_dialog')))
            .height,
        lessThanOrEqualTo(420),
      );
      final footer = find.byKey(const ValueKey('config_details_actions'));
      final position = tester.getTopLeft(footer);
      await tester.drag(
        find.byKey(const ValueKey('config_details_scroll')),
        const Offset(0, -800),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(footer), position);
      expect(find.textContaining('hidden-frp-key'), findsNothing);
      expect(find.textContaining('hidden-socks-password'), findsNothing);
      expect(find.byKey(const ValueKey('config_details_socks')), findsNothing);
      expect(find.text('SOCKS5'), findsNothing);
      expect(find.text('Configuration 1'), findsNothing);
      expect(find.text('State'), findsNothing);
      expect(find.text('Bind address'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(
        find.byKey(const ValueKey('config_details_close')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('details remain mounted through editing and refresh on return', (
    tester,
  ) async {
    final configurations = ValueNotifier<List<FrpConfig>>([
      const FrpConfig(
        id: 1,
        name: 'visitor-original',
        protocol: 'stcp',
        serverName: 'remote',
        secretKey: 'hidden-frp-key',
        bindPort: 1080,
      ),
    ]);
    addTearDown(configurations.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(appAccents.first),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showFrostedDialog<void>(
                context: context,
                builder: (dialogContext) => ValueListenableBuilder(
                  valueListenable: configurations,
                  builder: (_, configs, _) => ConfigDetailsDialog(
                    title: 'Example',
                    configs: configs,
                    onEdit: () async {
                      await showFrostedDialog<void>(
                        context: dialogContext,
                        barrierDismissible: false,
                        builder: (editorContext) => FrostedCard(
                          key: const ValueKey('test_config_editor'),
                          child: TextButton(
                            onPressed: () {
                              configurations.value = [
                                configs.single.copyWith(
                                  name: 'visitor-renamed',
                                  bindPort: 2080,
                                ),
                              ];
                              Navigator.pop(editorContext);
                            },
                            child: const Text('Save edited configuration'),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              child: const Text('Open details'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open details'));
    await tester.pumpAndSettle();
    final detailsState = tester.state(find.byType(ConfigDetailsDialog));
    await tester.tap(find.byKey(const ValueKey('config_details_edit')));
    await tester.pumpAndSettle();
    expect(detailsState.mounted, isTrue);
    expect(find.byKey(const ValueKey('config_details_dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('test_config_editor')), findsOneWidget);
    expect(find.text('Save edited configuration'), findsOneWidget);

    await tester.tap(find.text('Save edited configuration'));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ConfigDetailsDialog)), same(detailsState));
    expect(find.textContaining('visitor-renamed'), findsOneWidget);
    expect(find.textContaining('bindPort = 2080'), findsOneWidget);
    expect(find.textContaining('visitor-original'), findsNothing);
    expect(find.textContaining('hidden-frp-key'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('config_details_close')));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigDetailsDialog), findsNothing);
    expect(find.text('Open details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'SOCKS shared settings guard dirty Back and return to readonly details',
    (tester) async {
      await _openSocks(tester);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('127.0.0.1'), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('socks5_config_dialog')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('socks_edit')));
      await tester.pumpAndSettle();
      final target = find.byKey(const ValueKey('socks_target_ip'));
      expect(
        find.byKey(const ValueKey('socks5_account_editor')),
        findsOneWidget,
      );
      await _enter(tester, 'socks_target_ip', '192.0.2.1');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('socks_keep_editing')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(target).controller!.text, '192.0.2.1');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('socks_discard_changes')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('socks5_account_editor')), findsNothing);
      expect(
        find.byKey(const ValueKey('socks5_config_dialog')),
        findsOneWidget,
      );
      expect(find.text('127.0.0.1'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('socks5_config_dialog')), findsNothing);
    },
  );

  testWidgets('save blocks closing until persistence completes', (
    tester,
  ) async {
    final pending = Completer<void>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await _openSocks(tester, onSave: (_) => pending.future);
    await tester.tap(find.byKey(const ValueKey('socks_edit')));
    await tester.pumpAndSettle();
    await _enter(tester, 'socks_target_ip', '192.0.2.2');
    await tester.tap(find.byKey(const ValueKey('socks_save')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('socks5_config_dialog')), findsOneWidget);
    expect(find.text('Unsaved changes'), findsNothing);
    expect(find.byKey(const ValueKey('socks5_account_editor')), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('socks_edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('socks5_account_editor')), findsNothing);
  });

  testWidgets(
    'small landscape form remains scrollable with the keyboard open',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.viewInsets = const FakeViewPadding(bottom: 170);
      addTearDown(tester.view.resetViewInsets);
      await _openSocks(tester);
      await tester.tap(find.byKey(const ValueKey('socks_edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('socks_save')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'single and grouped toggles wait for confirmation in both directions',
    (tester) async {
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues(const {});
        await appState.retryInitialization();
      });
      appState.servers = const [
        ServerConfig(
          serverId: 'SERVER01',
          name: 'Primary',
          serverAddr: 'localhost',
        ),
      ];
      appState.configs = const [
        FrpConfig(
          id: 1,
          name: 'Single',
          protocol: 'stcp',
          serverName: 'remote-one',
          secretKey: 'key',
          bindPort: 1080,
          serverId: 'SERVER01',
        ),
        FrpConfig(
          id: 2,
          name: 'Group TCP',
          protocol: 'stcp',
          serverName: 'remote-two',
          secretKey: 'key',
          bindPort: 1081,
          serverId: 'SERVER01',
          groupId: 7,
          groupName: 'Group',
          isGroupPrimary: true,
        ),
        FrpConfig(
          id: 3,
          name: 'Group UDP',
          protocol: 'sudp',
          serverName: 'remote-three',
          secretKey: 'key',
          bindPort: 1082,
          serverId: 'SERVER01',
          groupId: 7,
          groupName: 'Group',
        ),
      ];
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ConfigsScreen())),
      );
      await tester.pumpAndSettle();

      for (final switchKey in ['config_enable_1', 'config_group_enable_7']) {
        final toggle = find.byKey(ValueKey(switchKey));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(appState.configs.every((config) => config.enabled), isTrue);
        await tester.tap(find.byKey(const ValueKey('config_toggle_cancel')));
        await tester.pumpAndSettle();
        expect(appState.configs.every((config) => config.enabled), isTrue);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('config_toggle_confirm')),
              )
              .onPressed!();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
        final changed = switchKey == 'config_enable_1'
            ? appState.configs.where((config) => config.id == 1)
            : appState.configs.where((config) => config.groupId == 7);
        expect(changed.every((config) => !config.enabled), isTrue);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('Enable Configuration'), findsOneWidget);
        await tester.runAsync(() async {
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('config_toggle_confirm')),
              )
              .onPressed!();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
        expect(appState.configs.every((config) => config.enabled), isTrue);
      }
    },
  );
}
