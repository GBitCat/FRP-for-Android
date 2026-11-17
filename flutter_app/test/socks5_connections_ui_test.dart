import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/socks5_config.dart';
import 'package:frp_app/screens/socks5_config_dialog.dart';
import 'package:frp_app/theme.dart';
import 'package:frp_app/widgets/app_dropdown_field.dart';
import 'package:frp_app/widgets/frosted_dialog.dart';

Socks5Config _settings() => Socks5Config(
  targetIp: '192.0.2.10',
  username: 'alice',
  password: 'private-socks-password',
  connections: [
    Socks5Connection(id: 'web', name: 'Web', tcpPorts: [8080]),
    Socks5Connection(id: 'dns', name: 'DNS', udpPorts: [5353]),
  ],
);

Future<void> _open(
  WidgetTester tester, {
  Socks5Config? initial,
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

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

Future<void> _selectMode(WidgetTester tester, String label) async {
  await _tap(tester, 'socks_connection_mode');
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'details mask credentials and keep actions within sixty percent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settings = _settings().copyWith(
        connections: [
          for (var i = 0; i < 10; i++)
            Socks5Connection(
              id: 'row-$i',
              name: 'Connection $i',
              tcpPorts: [8000 + i],
            ),
        ],
      );
      await _open(tester, initial: settings);

      expect(find.byType(TextField), findsNothing);
      expect(find.text('192.0.2.10'), findsOneWidget);
      expect(find.text('***'), findsOneWidget);
      expect(find.textContaining('private-socks-password'), findsNothing);
      final card = find.byKey(const ValueKey('socks5_config_dialog'));
      expect(tester.getSize(card).height, lessThanOrEqualTo(420));
      final close = find.byKey(const ValueKey('socks_close'));
      final footerPosition = tester.getTopLeft(close);
      await tester.drag(
        find.byKey(const ValueKey('socks5_form_scroll')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(close), footerPosition);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adding a named connection saves from Back and preserves details',
    (tester) async {
      Socks5Config? saved;
      await _open(
        tester,
        initial: _settings(),
        onSave: (value) async => saved = value,
      );
      await _tap(tester, 'socks_connection_add');
      expect(
        find.byKey(const ValueKey('socks5_config_dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('socks5_connection_editor')),
        findsOneWidget,
      );
      await _enter(tester, 'socks_connection_name', 'Media');
      await _enter(tester, 'socks_tcp_ports', '8090, 8091');
      await _enter(tester, 'socks_udp_ports', '8090');

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('socks5_connection_editor')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await _tap(tester, 'socks_save_changes');

      expect(saved!.connections, hasLength(3));
      final added = saved!.connections.last;
      expect(added.name, 'Media');
      expect(added.targetIp, isEmpty);
      expect(added.enabled, isTrue);
      expect(added.mode, Socks5ConnectionMode.onDemand);
      expect(added.id, isNotEmpty);
      expect(added.tcpPorts, [8090, 8091]);
      expect(added.udpPorts, [8090]);
      expect(saved!.targetIp, '192.0.2.10');
      expect(saved!.username, 'alice');
      expect(saved!.password, 'private-socks-password');
      expect(
        find.byKey(const ValueKey('socks5_connection_editor')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('socks5_config_dialog')),
        findsOneWidget,
      );
      expect(find.text('Media'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mode-only edits can be discarded or saved from system Back', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final saved = <Socks5Config>[];
    await _open(
      tester,
      initial: _settings(),
      onSave: (value) async => saved.add(value!),
    );
    await _tap(tester, 'socks_connection_web');
    final modeField = find.byKey(const ValueKey('socks_connection_mode'));
    expect(tester.widget(modeField), isA<AppDropdownButtonFormField<String>>());
    expect(tester.state<FormFieldState<String>>(modeField).value, 'onDemand');
    await _selectMode(tester, 'Immediate');
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('socks5_connection_editor')),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await _tap(tester, 'socks_discard_changes');
    expect(saved, isEmpty);

    await _tap(tester, 'socks_connection_web');
    expect(tester.state<FormFieldState<String>>(modeField).value, 'onDemand');
    await _selectMode(tester, 'Immediate');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _tap(tester, 'socks_save_changes');
    expect(saved.single.connections.first.mode, Socks5ConnectionMode.immediate);
    expect(saved.single.connections.first.tcpPorts, [8080]);
    expect(saved.single.connections.last.mode, Socks5ConnectionMode.onDemand);
    expect(find.text('Immediate'), findsOneWidget);

    await _tap(tester, 'socks_connection_web');
    expect(tester.state<FormFieldState<String>>(modeField).value, 'immediate');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsNothing);
    expect(
      find.byKey(const ValueKey('socks5_connection_editor')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('new connection can override the shared target with IPv6', (
    tester,
  ) async {
    Socks5Config? saved;
    final initial = _settings();
    await _open(
      tester,
      initial: initial,
      onSave: (value) async => saved = value,
    );
    await _tap(tester, 'socks_connection_add');
    final target = find.byKey(const ValueKey('socks_connection_target_ip'));
    expect(tester.widget<TextField>(target).controller!.text, isEmpty);
    expect(tester.widget<TextField>(target).decoration!.hintText, '192.0.2.10');
    expect(find.text('Leave empty to use parent target IP.'), findsOneWidget);
    await _enter(tester, 'socks_connection_name', 'Media');
    await _enter(tester, 'socks_connection_target_ip', '  2001:db8::20  ');
    await _enter(tester, 'socks_tcp_ports', '47984,48010');
    await _enter(tester, 'socks_udp_ports', '47998');
    await _tap(tester, 'socks_connection_save');

    expect(saved!.targetIp, initial.targetIp);
    expect(saved!.connections.take(2), initial.connections);
    final added = saved!.connections.last;
    expect(added.targetIp, '2001:db8::20');
    expect(added.tcpPorts, [47984, 48010]);
    expect(added.udpPorts, [47998]);
    expect(
      tester
          .widget<Text>(
            find.byKey(ValueKey('socks_connection_target_${added.id}')),
          )
          .data,
      'Target IP: 2001:db8::20',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'target-only changes support discard, save, and clearing inheritance',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final saved = <Socks5Config>[];
      final initial = _settings();
      await _open(
        tester,
        initial: initial,
        onSave: (value) async => saved.add(value!),
      );
      await _tap(tester, 'socks_connection_web');
      await _enter(tester, 'socks_connection_target_ip', '192.0.2.20');
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('socks5_connection_editor')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await _tap(tester, 'socks_discard_changes');
      expect(saved, isEmpty);

      await _tap(tester, 'socks_connection_web');
      final target = find.byKey(const ValueKey('socks_connection_target_ip'));
      expect(tester.widget<TextField>(target).controller!.text, isEmpty);
      await _enter(tester, 'socks_connection_target_ip', '192.0.2.30');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _tap(tester, 'socks_save_changes');
      expect(saved.single.connections.first.targetIp, '192.0.2.30');
      expect(saved.single.connections.first.id, 'web');
      expect(saved.single.connections.first.tcpPorts, [8080]);
      expect(saved.single.connections.last, initial.connections.last);
      expect(saved.single.targetIp, initial.targetIp);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('socks_connection_target_web')),
            )
            .data,
        'Target IP: 192.0.2.30',
      );

      await _tap(tester, 'socks_connection_web');
      expect(tester.widget<TextField>(target).controller!.text, '192.0.2.30');
      await _enter(tester, 'socks_connection_target_ip', '   ');
      await _tap(tester, 'socks_connection_save');
      expect(saved.last.connections.first.targetIp, isEmpty);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('socks_connection_target_web')),
            )
            .data,
        'Target IP: 192.0.2.10 (inherited)',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'parent target edits update inherited rows but preserve overrides',
    (tester) async {
      final base = _settings();
      final initial = base.copyWith(
        connections: [
          base.connections.first,
          base.connections.last.copyWith(targetIp: '2001:db8::53'),
        ],
      );
      Socks5Config? saved;
      await _open(
        tester,
        initial: initial,
        onSave: (value) async => saved = value,
      );
      await _tap(tester, 'socks_edit');
      await _enter(tester, 'socks_target_ip', '192.0.2.40');
      await _tap(tester, 'socks_save');
      expect(saved!.connections, initial.connections);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('socks_connection_target_web')),
            )
            .data,
        'Target IP: 192.0.2.40 (inherited)',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('socks_connection_target_dns')),
            )
            .data,
        'Target IP: 2001:db8::53',
      );
      await _tap(tester, 'socks_connection_web');
      final target = find.byKey(const ValueKey('socks_connection_target_ip'));
      expect(tester.widget<TextField>(target).controller!.text, isEmpty);
      expect(
        tester.widget<TextField>(target).decoration!.hintText,
        '192.0.2.40',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid row target stays editable and is not saved', (
    tester,
  ) async {
    final saved = <Socks5Config>[];
    await _open(
      tester,
      initial: _settings(),
      onSave: (value) async => saved.add(value!),
    );
    await _tap(tester, 'socks_connection_web');
    for (final invalid in ['localhost', '256.0.0.1', 'fe80::1%wlan0']) {
      await _enter(tester, 'socks_connection_target_ip', invalid);
      await _tap(tester, 'socks_connection_save');
      expect(saved, isEmpty);
      expect(
        find.byKey(const ValueKey('socks_editor_save_error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('socks5_connection_editor')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('socks_connection_target_ip')),
            )
            .controller!
            .text,
        invalid,
      );
    }
    await _enter(tester, 'socks_connection_target_ip', '192.0.2.50');
    await _tap(tester, 'socks_connection_save');
    expect(saved.single.connections.first.targetIp, '192.0.2.50');
    expect(
      find.byKey(const ValueKey('socks5_connection_editor')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'editing preserves row identity and discarded changes stay local',
    (tester) async {
      final original = _settings();
      final saved = <Socks5Config>[];
      await _open(
        tester,
        initial: original,
        onSave: (value) async => saved.add(value!),
      );
      await _tap(tester, 'socks_connection_web');
      await _enter(tester, 'socks_connection_name', 'Unsaved label');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _tap(tester, 'socks_discard_changes');
      expect(saved, isEmpty);
      expect(find.text('Web'), findsOneWidget);
      expect(find.text('Unsaved label'), findsNothing);

      await _tap(tester, 'socks_connection_web');
      await _enter(tester, 'socks_connection_name', 'Website');
      await _enter(tester, 'socks_tcp_ports', '8081,8082');
      await _tap(tester, 'socks_connection_save');
      expect(saved.single.connections.first.id, 'web');
      expect(saved.single.connections.first.enabled, isTrue);
      expect(saved.single.connections.first.tcpPorts, [8081, 8082]);
      expect(saved.single.connections.last, original.connections.last);
      expect(find.text('Website'), findsOneWidget);
    },
  );

  testWidgets('failed Save from Back retains the draft for correction', (
    tester,
  ) async {
    var attempts = 0;
    Socks5Config? saved;
    await _open(
      tester,
      initial: _settings(),
      onSave: (value) async {
        attempts++;
        if (attempts == 1) throw const FormatException('Port is occupied');
        saved = value;
      },
    );
    await _tap(tester, 'socks_connection_web');
    await _enter(tester, 'socks_tcp_ports', '9000');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _tap(tester, 'socks_save_changes');
    expect(find.text('Port is occupied'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('socks5_connection_editor')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('socks_tcp_ports')))
          .controller!
          .text,
      '9000',
    );
    expect(saved, isNull);
    await _enter(tester, 'socks_tcp_ports', '9001');
    await _tap(tester, 'socks_connection_save');
    expect(saved!.connections.first.tcpPorts, [9001]);
    expect(
      find.byKey(const ValueKey('socks5_connection_editor')),
      findsNothing,
    );
  });

  testWidgets(
    'toggle and delete apply individually and retain data on failure',
    (tester) async {
      var fail = true;
      final saved = <Socks5Config>[];
      await _open(
        tester,
        initial: _settings(),
        onSave: (value) async {
          if (fail) throw const FormatException('Changes could not be applied');
          saved.add(value!);
        },
      );
      await _tap(tester, 'socks_connection_enabled_web');
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('socks_connection_enabled_web')),
            )
            .value,
        isTrue,
      );
      expect(find.text('Changes could not be applied'), findsOneWidget);
      fail = false;
      await _tap(tester, 'socks_connection_enabled_web');
      expect(saved.last.connections.first.enabled, isFalse);
      expect(saved.last.connections.last.enabled, isTrue);

      await _tap(tester, 'socks_connection_delete_dns');
      await _tap(tester, 'socks_connection_delete_cancel');
      expect(saved, hasLength(1));
      expect(find.text('DNS'), findsOneWidget);
      await _tap(tester, 'socks_connection_delete_dns');
      await _tap(tester, 'socks_connection_delete_confirm');
      expect(saved.last.connections.single.id, 'web');
      expect(saved.last.connections.single.enabled, isFalse);
      expect(find.text('DNS'), findsNothing);
      await _tap(tester, 'socks_connection_delete_web');
      await _tap(tester, 'socks_connection_delete_confirm');
      expect(saved.last.connections, isEmpty);
      expect(saved.last.targetIp, '192.0.2.10');
      expect(saved.last.username, 'alice');
      expect(saved.last.password, 'private-socks-password');
      expect(find.text('No SOCKS connections.'), findsOneWidget);
    },
  );

  testWidgets(
    'shared settings save independently before the first connection',
    (tester) async {
      final saved = <Socks5Config>[];
      await _open(
        tester,
        tcp: false,
        onSave: (value) async => saved.add(value!),
      );
      final add = find.byKey(const ValueKey('socks_connection_add'));
      expect(tester.widget<IconButton>(add).onPressed, isNull);
      await _tap(tester, 'socks_edit');
      await _enter(tester, 'socks_target_ip', '2001:db8::1');
      await _enter(tester, 'socks_username', 'shared-account');
      await _enter(tester, 'socks_password', 'new-private-password');
      await _tap(tester, 'socks_save');
      expect(saved.single.connections, isEmpty);
      expect(saved.single.targetIp, '2001:db8::1');
      expect(find.text('shared-account'), findsOneWidget);
      expect(find.textContaining('new-private-password'), findsNothing);
      expect(tester.widget<IconButton>(add).onPressed, isNotNull);
      await _tap(tester, 'socks_connection_add');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('socks_tcp_ports')))
            .enabled,
        isFalse,
      );
      await _enter(tester, 'socks_connection_name', 'Time');
      await _enter(tester, 'socks_udp_ports', '123');
      await _tap(tester, 'socks_connection_save');
      expect(saved.last.connections.single.udpPorts, [123]);
      expect(saved.last.connections.single.tcpPorts, isEmpty);
      expect(saved.last.username, 'shared-account');
      expect(saved.last.password, 'new-private-password');
    },
  );

  testWidgets('clean nested editor returns without a discard confirmation', (
    tester,
  ) async {
    await _open(tester, initial: _settings());
    await _tap(tester, 'socks_connection_add');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsNothing);
    expect(
      find.byKey(const ValueKey('socks5_connection_editor')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('socks5_config_dialog')), findsOneWidget);
    await _tap(tester, 'socks_edit');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('socks5_account_editor')), findsNothing);
    expect(find.byKey(const ValueKey('socks5_config_dialog')), findsOneWidget);
  });
}
