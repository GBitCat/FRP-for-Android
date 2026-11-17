import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/socks5_config.dart';
import 'package:frp_app/screens/logs_screen.dart';
import 'package:frp_app/services/socks5_log_entry.dart';
import 'package:frp_app/theme.dart';

class _FakeLogsSource implements LogsSource {
  _FakeLogsSource({String? history}) {
    if (history != null) initialHistory.complete(history);
  }

  final initialHistory = Completer<String>();
  final _events = StreamController<String>.broadcast(sync: true);
  final _recent = <String>[];

  @override
  Stream<String> get logStream => _events.stream;

  @override
  List<String> get logs => List.unmodifiable(_recent);

  @override
  Future<String> readLogs() => initialHistory.future;

  void emit(String line) {
    _recent.add(line);
    _events.add(line);
  }

  Future<void> close() => _events.close();
}

Future<void> _open(
  WidgetTester tester,
  _FakeLogsSource source, {
  double width = 390,
  List<FrpConfig> configs = const [],
  ValueListenable<List<FrpConfig>>? configurations,
  Future<bool> Function(List<String> lines, {required bool filtered})? saveLogs,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(source.close);
  final configSource = configurations ?? ValueNotifier(configs);
  if (configurations == null) {
    addTearDown((configSource as ValueNotifier<List<FrpConfig>>).dispose);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(appAccents.first),
      home: LogsScreen(
        source: source,
        configurations: configSource,
        saveLogs: saveLogs,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollController _scrollController(WidgetTester tester) => tester
    .widget<ListView>(find.byKey(const ValueKey('logs_list')))
    .controller!;

void _expectBottom(WidgetTester tester) {
  final position = _scrollController(tester).position;
  expect(position.maxScrollExtent, greaterThan(0));
  expect(position.pixels, closeTo(position.maxScrollExtent, 0.1));
}

Future<void> _selectCategory(WidgetTester tester, String label) async {
  await _selectMenu(tester, 'logs_category', label);
}

Future<void> _selectMenu(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

List<String> _longHistory() => [
  for (var i = 0; i < 120; i++)
    '[frpc] line $i${i.isEven ? ' with a long message that wraps across several lines on a phone screen' : ''}',
];

FrpConfig _config({
  String server = 'server-a',
  int group = 42,
  String name = 'Gaming',
  List<Socks5Connection>? connections,
}) => FrpConfig(
  id: group,
  serverId: server,
  groupId: group,
  groupName: name,
  name: 'visitor-$group',
  protocol: 'xtcp',
  socks5: Socks5Config(
    targetIp: '192.0.2.10',
    connections: connections ?? [_games()],
  ),
);

Socks5Connection _games() => Socks5Connection(
  id: 'games',
  name: 'Games',
  tcpPorts: [5510, 5511],
  udpPorts: [5512],
);

String _event(
  FrpConfig config,
  Socks5Connection connection, {
  String protocol = 'tcp',
  int port = 5510,
  String message = 'channel ready',
}) =>
    '[SOCKS5] ${jsonEncode({'v': 1, ...Socks5LogContext.fromConfig(config, connection).toJson(), 'protocol': protocol, 'listenPort': port, 'event': 'ready', 'message': message})}';

String _display(String raw) => Socks5LogEntry.tryParse(raw)!.displayLine;

IconButton _saveButton(WidgetTester tester) =>
    tester.widget<IconButton>(find.byKey(const ValueKey('logs_save')));

void main() {
  testWidgets('category and case insensitive text filters work together', (
    tester,
  ) async {
    const frpc = '[I] [service.go:300] login to server success';
    const stun = '[STUN] probe reachable weight=1 elapsedMs=8';
    const timeout =
        '[W] [xtcp.go:123] nat hole prepare error: wait response from stun server timeout';
    const tcp = '[SOCKS5] TCP connected target=192.0.2.10:8080';
    const udp = '[SOCKS5] UDP failed stage=authenticate';
    final source = _FakeLogsSource(
      history: [frpc, stun, timeout, tcp, udp].join('\n'),
    );
    await _open(tester, source, width: 320);
    expect(tester.takeException(), isNull);
    final toggle = find.byKey(const ValueKey('logs_auto_scroll'));
    final category = find.byKey(const ValueKey('logs_category'));
    expect(
      tester.getTopLeft(category).dx,
      greaterThanOrEqualTo(tester.getTopRight(toggle).dx),
    );
    expect(
      tester.getCenter(category).dy,
      closeTo(tester.getCenter(toggle).dy, 1),
    );
    expect(find.text('5 lines'), findsOneWidget);

    await _selectCategory(tester, 'Socks5');
    expect(find.text(tcp), findsOneWidget);
    expect(find.text(udp), findsOneWidget);
    expect(find.text(frpc), findsNothing);
    expect(find.text('2 lines'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'CONNECTED');
    await tester.pumpAndSettle();
    expect(find.text(tcp), findsOneWidget);
    expect(find.text(udp), findsNothing);
    expect(find.text('1 lines'), findsOneWidget);

    await _selectCategory(tester, 'stun');
    expect(find.text('No matching logs'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'TIMEOUT');
    await tester.pumpAndSettle();
    expect(find.text(timeout), findsOneWidget);
    expect(find.text(stun), findsNothing);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(find.text(stun), findsOneWidget);
    expect(find.text('2 lines'), findsOneWidget);
    await _selectCategory(tester, 'frpc');
    expect(find.text(frpc), findsOneWidget);
    expect(find.text(stun), findsNothing);
    expect(find.text(tcp), findsNothing);
    await _selectCategory(tester, 'All');
    expect(find.text('5 lines'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('initial history follows the final wrapped row', (tester) async {
    final source = _FakeLogsSource(history: _longHistory().join('\n'));
    await _open(tester, source);
    _expectBottom(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first live batch scrolls after the list attaches', (
    tester,
  ) async {
    final source = _FakeLogsSource(history: '');
    await _open(tester, source);
    expect(find.text('No logs yet'), findsOneWidget);
    for (final line in _longHistory()) {
      source.emit(line);
    }
    await tester.pumpAndSettle();
    _expectBottom(tester);
    expect(find.text('120 lines'), findsOneWidget);
  });

  testWidgets('switch pauses new logs and resumes following immediately', (
    tester,
  ) async {
    final source = _FakeLogsSource(history: _longHistory().join('\n'));
    await _open(tester, source);
    await tester.tap(find.byKey(const ValueKey('logs_auto_scroll')));
    await tester.pumpAndSettle();
    _scrollController(tester).jumpTo(0);
    await tester.pumpAndSettle();
    source.emit('[frpc] a new log while paused');
    await tester.pumpAndSettle();
    expect(_scrollController(tester).offset, 0);

    await tester.tap(find.byKey(const ValueKey('logs_auto_scroll')));
    await tester.pumpAndSettle();
    _expectBottom(tester);
    source.emit('[frpc] another new log after resuming');
    await tester.pumpAndSettle();
    _expectBottom(tester);

    await tester.enterText(find.byType(TextField), 'line');
    await tester.pumpAndSettle();
    _expectBottom(tester);
  });

  testWidgets('turning off cancels a pending post frame scroll', (
    tester,
  ) async {
    final source = _FakeLogsSource(history: _longHistory().join('\n'));
    await _open(tester, source);
    _scrollController(tester).jumpTo(0);
    await tester.pumpAndSettle();
    source.emit('[frpc] queues a scroll for the next frame');
    tester
        .widget<Switch>(find.byKey(const ValueKey('logs_auto_scroll')))
        .onChanged!(false);
    await tester.pumpAndSettle();
    expect(_scrollController(tester).offset, 0);
  });

  testWidgets('new stream events preserve the native service history', (
    tester,
  ) async {
    final source = _FakeLogsSource(history: 'old first\nold second');
    await _open(tester, source);
    // The Dart engine was recreated, so its recent buffer lacks old history.
    source.emit('new third');
    await tester.pumpAndSettle();
    expect(find.text('old first'), findsOneWidget);
    expect(find.text('old second'), findsOneWidget);
    expect(find.text('new third'), findsOneWidget);
    expect(find.text('3 lines'), findsOneWidget);
  });

  testWidgets('snapshot and overlapping live events merge without lost lines', (
    tester,
  ) async {
    final source = _FakeLogsSource();
    await _open(tester, source);
    source.emit('new first');
    source.initialHistory.complete('old history\nnew first');
    source.emit('new second');
    await tester.pumpAndSettle();
    expect(find.text('old history'), findsOneWidget);
    expect(find.text('new first'), findsOneWidget);
    expect(find.text('new second'), findsOneWidget);
    expect(find.text('3 lines'), findsOneWidget);

    // Identical subsequent events are separate logs, not duplicates to remove.
    source.emit('repeat');
    source.emit('repeat');
    await tester.pumpAndSettle();
    expect(find.text('repeat'), findsNWidgets(2));
    expect(find.text('5 lines'), findsOneWidget);
  });

  testWidgets('SOCKS filters group named Ports across protocols and servers', (
    tester,
  ) async {
    final games = _games();
    final dns = Socks5Connection(id: 'dns', name: 'DNS', udpPorts: [5353]);
    final configA = _config(connections: [games, dns]);
    final configB = _config(server: 'server-b');
    final lines = [
      _event(configA, games, message: 'first TCP connection'),
      _event(configA, games, port: 5511, message: 'second TCP connection'),
      _event(configA, games, protocol: 'udp', port: 5512),
      _event(configA, dns, protocol: 'udp', port: 5353),
      _event(configB, games, message: 'other server connection'),
    ];
    const legacy = '[SOCKS5] TCP 5510: channel ready';
    await _open(
      tester,
      _FakeLogsSource(history: [...lines, legacy].join('\n')),
      configs: [
        configA,
        configA.copyWith(id: 99, protocol: 'xudp'),
        configB,
      ],
      width: 443,
    );
    expect(find.byKey(const ValueKey('logs_configuration')), findsNothing);
    expect(find.byKey(const ValueKey('logs_ports')), findsNothing);
    expect(find.text(_display(lines.first)), findsOneWidget);
    expect(find.text(lines.first), findsNothing);

    await _selectCategory(tester, 'Socks5');
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.byKey(const ValueKey('logs_ports')),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('logs_configuration')));
    await tester.pumpAndSettle();
    expect(find.text('Gaming · server-a'), findsOneWidget);
    expect(find.text('Gaming · server-b'), findsOneWidget);
    await tester.tap(find.text('Gaming · server-a'));
    await tester.pumpAndSettle();
    expect(find.text('4 lines'), findsOneWidget);
    expect(find.text(legacy), findsNothing);
    expect(find.text(_display(lines[4])), findsNothing);
    await _selectMenu(tester, 'logs_ports', 'Games');
    expect(find.text('3 lines'), findsOneWidget);
    for (final line in lines.take(3)) {
      expect(find.text(_display(line)), findsOneWidget);
    }
    expect(find.text(_display(lines[3])), findsNothing);

    await tester.enterText(find.byType(TextField), 'UDP');
    await tester.pumpAndSettle();
    expect(find.text('1 lines'), findsOneWidget);
    await _selectCategory(tester, 'frpc');
    expect(find.byKey(const ValueKey('logs_configuration')), findsNothing);
    expect(find.byKey(const ValueKey('logs_ports')), findsNothing);
    await _selectCategory(tester, 'Socks5');
    expect(find.text('Games'), findsOneWidget);
    expect(find.text('Gaming · server-a'), findsOneWidget);
    expect(find.text('1 lines'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    await _selectMenu(tester, 'logs_configuration', 'Gaming · server-b');
    expect(find.text('All ports'), findsOneWidget);
    expect(find.text('1 lines'), findsOneWidget);
    expect(find.text(_display(lines[4])), findsOneWidget);
    await _selectMenu(tester, 'logs_configuration', 'All configurations');
    expect(find.text('6 lines'), findsOneWidget);
    expect(find.text(legacy), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current names and disabled rows merge with historical options', (
    tester,
  ) async {
    final games = _games();
    final disabled = Socks5Connection(
      id: 'disabled',
      name: 'Disabled row',
      enabled: false,
      tcpPorts: [5514],
    );
    final current = _config(connections: [games, disabled]);
    final beforeRename = _event(
      current.copyWith(groupName: 'Old configuration'),
      games.copyWith(name: 'Old Ports'),
    );
    final archived = _config(server: 'old-server', group: 7, name: 'Archived');
    final archivedLog = _event(
      archived,
      games.copyWith(name: 'Archived Ports'),
    );
    await _open(
      tester,
      _FakeLogsSource(history: '$beforeRename\n$archivedLog'),
      configs: [current],
    );
    await _selectCategory(tester, 'Socks5');
    await tester.tap(find.byKey(const ValueKey('logs_configuration')));
    await tester.pumpAndSettle();
    expect(find.text('Gaming'), findsOneWidget);
    expect(find.text('Old configuration'), findsNothing);
    await tester.tap(find.text('Gaming'));
    await tester.pumpAndSettle();
    await _selectMenu(tester, 'logs_ports', 'Games');
    expect(find.text(_display(beforeRename)), findsOneWidget);
    expect(find.text('1 lines'), findsOneWidget);
    await _selectMenu(tester, 'logs_ports', 'Disabled row');
    expect(find.text('No matching logs'), findsOneWidget);
    await _selectMenu(tester, 'logs_configuration', 'Archived');
    await _selectMenu(tester, 'logs_ports', 'Archived Ports');
    expect(find.text(_display(archivedLog)), findsOneWidget);
    expect(find.text('1 lines'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('equal names and reused ports do not merge separate Ports IDs', (
    tester,
  ) async {
    final first = _games();
    final second = first.copyWith(id: 'second', enabled: false);
    final config = _config(connections: [first, second]);
    final firstLog = _event(config, first, message: 'first ownership');
    final secondLog = _event(config, second, message: 'second ownership');
    await _open(
      tester,
      _FakeLogsSource(history: '$firstLog\n$secondLog'),
      configs: [config],
    );
    await _selectCategory(tester, 'Socks5');
    await _selectMenu(tester, 'logs_configuration', 'Gaming');
    await _selectMenu(tester, 'logs_ports', 'Games · second');
    expect(find.text(_display(firstLog)), findsNothing);
    expect(find.text(_display(secondLog)), findsOneWidget);
    expect(find.text('1 lines'), findsOneWidget);
  });

  testWidgets(
    'removed options reset safely and new live history adds options',
    (tester) async {
      final games = _games();
      final spare = games.copyWith(id: 'spare', name: 'Spare', enabled: false);
      final config = _config(connections: [games, spare]);
      final configs = ValueNotifier<List<FrpConfig>>([config]);
      addTearDown(configs.dispose);
      final source = _FakeLogsSource(history: '');
      await _open(tester, source, configurations: configs);
      await _selectCategory(tester, 'Socks5');
      await _selectMenu(tester, 'logs_configuration', 'Gaming');
      await _selectMenu(tester, 'logs_ports', 'Games');
      configs.value = [
        _config(connections: [spare]),
      ];
      await tester.pumpAndSettle();
      expect(find.text('All ports'), findsOneWidget);
      expect(find.text('Gaming'), findsOneWidget);
      configs.value = [];
      await tester.pumpAndSettle();
      expect(find.text('All configurations'), findsOneWidget);
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('logs_ports')),
            )
            .enabled,
        isFalse,
      );
      source.emit(_event(config, games));
      await tester.pumpAndSettle();
      await _selectMenu(tester, 'logs_configuration', 'Gaming');
      await _selectMenu(tester, 'logs_ports', 'Games');
      expect(find.text('1 lines'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 360.0, 400.0, 443.0]) {
    testWidgets('SOCKS menus remain readable and ordered at $width dp', (
      tester,
    ) async {
      final config = _config();
      await _open(
        tester,
        _FakeLogsSource(history: _event(config, _games())),
        configs: [config],
        width: width,
      );
      await _selectCategory(tester, 'Socks5');
      final category = find.byKey(const ValueKey('logs_category'));
      final configuration = find.byKey(const ValueKey('logs_configuration'));
      final ports = find.byKey(const ValueKey('logs_ports'));
      for (final field in [category, configuration, ports]) {
        expect(tester.getSize(field).height, lessThanOrEqualTo(40));
        expect(tester.getTopLeft(field).dx, greaterThanOrEqualTo(0));
        expect(tester.getTopRight(field).dx, lessThanOrEqualTo(width));
      }
      expect(
        tester.getCenter(configuration).dy,
        closeTo(tester.getCenter(ports).dy, 1),
      );
      expect(
        tester.getTopLeft(ports).dx,
        greaterThan(tester.getTopRight(configuration).dx),
      );
      if (width >= 400) {
        expect(
          tester.getCenter(category).dy,
          closeTo(tester.getCenter(configuration).dy, 1),
        );
        expect(
          tester.getTopLeft(configuration).dx,
          greaterThan(tester.getTopRight(category).dx),
        );
      } else {
        expect(
          tester.getTopLeft(configuration).dy,
          greaterThan(tester.getBottomLeft(category).dy),
        );
      }
      await _selectMenu(tester, 'logs_configuration', 'Gaming');
      await _selectMenu(tester, 'logs_ports', 'Games');
      expect(find.text('1 lines'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a late snapshot after leaving the page is ignored', (
    tester,
  ) async {
    final source = _FakeLogsSource();
    await _open(tester, source);
    source.emit('new log');
    await tester.pumpWidget(const SizedBox.shrink());
    source.initialHistory.complete('old log\nnew log');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('save combines all filters and preserves raw SOCKS diagnostics', (
    tester,
  ) async {
    final games = _games();
    final dns = Socks5Connection(id: 'dns', name: 'DNS', udpPorts: [5353]);
    final configA = _config(connections: [games, dns]);
    final configB = _config(server: 'server-b');
    final tcp = _event(configA, games, message: 'Video upstream ready');
    final udp = _event(
      configA,
      games,
      protocol: 'udp',
      port: 5512,
      message: 'VIDEO returned to local app',
    );
    final lines = [
      '[I] video transport initialized',
      '[STUN] video probe reachable',
      '[SOCKS5] TCP 5510: video legacy log without owner',
      tcp,
      udp,
      _event(configA, games, message: 'unrelated keepalive'),
      _event(configA, dns, protocol: 'udp', port: 5353, message: 'video DNS'),
      _event(configB, games, message: 'video on another server'),
    ];
    List<String>? saved;
    bool? wasFiltered;
    await _open(
      tester,
      _FakeLogsSource(history: lines.join('\n')),
      width: 443,
      configs: [configA, configB],
      saveLogs: (snapshot, {required filtered}) async {
        saved = snapshot;
        wasFiltered = filtered;
        return true;
      },
    );
    await _selectCategory(tester, 'Socks5');
    await _selectMenu(tester, 'logs_configuration', 'Gaming · server-a');
    await _selectMenu(tester, 'logs_ports', 'Games');
    await tester.enterText(find.byType(TextField), 'ViDeO');
    await tester.pumpAndSettle();
    expect(find.text('2 lines'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('logs_save')));
    await tester.pumpAndSettle();
    expect(saved, [tcp, udp]);
    expect(wasFiltered, isTrue);
    // The file keeps the complete structured event, not only its UI summary.
    expect(
      jsonDecode(saved!.first.substring(9))['configKey'],
      Socks5LogContext.fromConfig(configA, games).configKey,
    );
    expect(find.text('Saved 2 log lines'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing category and search saves all retained raw logs', (
    tester,
  ) async {
    const lines = [
      '[I] login to server success',
      '[STUN] probe reachable',
      '[SOCKS5] TCP 5510: listening',
    ];
    final saved = <List<String>>[];
    final filteredFlags = <bool>[];
    await _open(
      tester,
      _FakeLogsSource(history: lines.join('\n')),
      saveLogs: (snapshot, {required filtered}) async {
        saved.add(snapshot);
        filteredFlags.add(filtered);
        return true;
      },
    );
    await _selectCategory(tester, 'stun');
    await tester.enterText(find.byType(TextField), 'PROBE');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('logs_save')));
    await tester.pumpAndSettle();
    expect(saved.last, [lines[1]]);
    expect(filteredFlags.last, isTrue);

    await _selectCategory(tester, 'All');
    await tester.tap(find.byKey(const ValueKey('logs_save')));
    await tester.pumpAndSettle();
    expect(saved.last, [lines[1]]);
    expect(filteredFlags.last, isTrue);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('logs_save')));
    await tester.pumpAndSettle();
    expect(saved.last, lines);
    expect(filteredFlags.last, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save waits for native history and disables an empty result', (
    tester,
  ) async {
    final source = _FakeLogsSource()..emit('[frpc] live line');
    await _open(
      tester,
      source,
      saveLogs: (_, {required filtered}) async => true,
    );
    expect(find.text('[frpc] live line'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
    source.initialHistory.complete('[frpc] old history\n[frpc] live line');
    await tester.pumpAndSettle();
    expect(_saveButton(tester).onPressed, isNotNull);
    await tester.enterText(find.byType(TextField), 'no matching entry');
    await tester.pumpAndSettle();
    expect(find.text('No matching logs'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('pending save freezes its snapshot and ignores repeated taps', (
    tester,
  ) async {
    final pending = Completer<bool>();
    final source = _FakeLogsSource(history: 'old first\nold second');
    List<String>? snapshot;
    bool? wasFiltered;
    var calls = 0;
    await _open(
      tester,
      source,
      saveLogs: (lines, {required filtered}) {
        snapshot = lines;
        wasFiltered = filtered;
        calls++;
        return pending.future;
      },
    );
    await tester.tap(find.byKey(const ValueKey('logs_save')));
    await tester.tap(find.byKey(const ValueKey('logs_save')));
    await tester.pump();
    expect(calls, 1);
    expect(_saveButton(tester).onPressed, isNull);

    source.emit('new matching line');
    await tester.enterText(find.byType(TextField), 'new matching');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1 lines'), findsOneWidget);
    expect(snapshot, ['old first', 'old second']);
    expect(wasFiltered, isFalse);
    expect(_saveButton(tester).onPressed, isNull);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Saved 2 log lines'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled and failed saves can be retried', (tester) async {
    var attempts = 0;
    await _open(
      tester,
      _FakeLogsSource(history: '[STUN] probe complete'),
      saveLogs: (_, {required filtered}) async {
        attempts++;
        if (attempts == 1) return false;
        if (attempts == 2) throw StateError('document provider unavailable');
        return true;
      },
    );
    for (final message in [
      'Log save cancelled',
      'Unable to save logs',
      'Saved 1 log lines',
    ]) {
      await tester.tap(find.byKey(const ValueKey('logs_save')));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNotNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
    expect(attempts, 3);
    expect(tester.takeException(), isNull);
  });

  for (final fails in [false, true]) {
    testWidgets('save finishing after leaving page is safe (fails: $fails)', (
      tester,
    ) async {
      final pending = Completer<bool>();
      await _open(
        tester,
        _FakeLogsSource(history: '[frpc] existing log'),
        saveLogs: (_, {required filtered}) => pending.future,
      );
      await tester.tap(find.byKey(const ValueKey('logs_save')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      if (fails) {
        pending.completeError(StateError('document provider closed'));
      } else {
        pending.complete(true);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
