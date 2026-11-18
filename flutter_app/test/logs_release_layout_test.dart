import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/screens/logs_screen.dart';

class _Source implements LogsSource {
  _Source(List<String> history)
    : logs = [
        for (var i = 0; i < history.length; i++) (id: i + 1, line: history[i]),
      ],
      nextId = history.length + 1;

  @override
  final List<RuntimeLog> logs;
  final events = StreamController<RuntimeLog>.broadcast(sync: true);
  int nextId;

  @override
  Stream<RuntimeLog> get logStream => events.stream;

  @override
  Future<List<RuntimeLog>> readLogs() async => logs;

  void append(String line) => events.add((id: nextId++, line: line));
}

final _list = find.byKey(const ValueKey('logs_list'));
final _follow = find.byKey(const ValueKey('logs_auto_scroll'));

Future<_Source> _open(
  WidgetTester tester,
  List<String> rows, {
  LogsFileSaver? save,
}) async {
  final source = _Source(rows);
  final configs = ValueNotifier<List<FrpConfig>>([]);
  addTearDown(source.events.close);
  addTearDown(configs.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: LogsScreen(
        source: source,
        configurations: configs,
        saveLogs: save,
        anchorLatestLog: true,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return source;
}

void main() {
  testWidgets('short history starts at the top and grows down while paused', (
    tester,
  ) async {
    final source = await _open(tester, ['first', 'second']);
    final first = tester.getTopLeft(find.text('first')).dy;
    expect(first - tester.getTopLeft(_list).dy, closeTo(13, 1));
    expect(tester.getTopLeft(find.text('second')).dy, greaterThan(first));
    await tester.tap(_follow);
    await tester.pumpAndSettle();
    for (var i = 0; i < 100; i++) {
      source.append('new $i');
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('first')).dy, closeTo(first, 0.1));
    final controller = tester.widget<CustomScrollView>(_list).controller!;
    controller.jumpTo(250);
    await tester.pumpAndSettle();
    expect(controller.offset, 250);
    await tester.tap(_follow);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(find.text('new 99').hitTestable(), findsOneWidget);
  });

  testWidgets(
    'full history opens at the tail and paused rows keep their position',
    (tester) async {
      final rows = List.generate(
        2000,
        (i) => 'line $i ${'wrap ' * (i % 5 * 23)}',
      );
      final source = await _open(tester, rows);
      final controller = tester.widget<CustomScrollView>(_list).controller!;
      expect(controller.offset, 0);
      expect(find.text(rows.first), findsNothing);
      expect(find.text(rows.last).hitTestable(), findsOneWidget);
      expect(
        tester.getBottomLeft(_list).dy -
            tester.getBottomLeft(find.text(rows.last)).dy,
        closeTo(13, 1),
      );
      expect(
        tester.getTopLeft(find.text(rows[1998])).dy,
        lessThan(tester.getTopLeft(find.text(rows.last)).dy),
      );
      await tester.tap(_follow);
      await tester.pumpAndSettle();
      controller.jumpTo(-250);
      await tester.pumpAndSettle();
      final reading = rows.reversed.firstWhere(
        (s) => find.text(s).hitTestable().evaluate().isNotEmpty,
      );
      final before = tester.getTopLeft(find.text(reading)).dy;
      for (var i = 0; i < 35; i++) {
        source.append('later $i ${'new ' * (i % 4 * 40)}');
      }
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text(reading)).dy, closeTo(before, 0.1));
      expect(controller.offset, -250);
      await tester.tap(_follow);
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(find.textContaining('later 34 ').hitTestable(), findsOneWidget);
      expect(find.text('2000 lines'), findsOneWidget);
    },
  );

  testWidgets(
    'filter and save retain chronological order after changing follow',
    (tester) async {
      List<String>? saved;
      final source = await _open(
        tester,
        ['match A', 'other', 'match B'],
        save: (rows, {required filtered}) async {
          expect(filtered, isTrue);
          saved = List.of(rows);
          return true;
        },
      );
      await tester.enterText(find.byType(TextField), 'match');
      await tester.pumpAndSettle();
      await tester.tap(_follow);
      await tester.pumpAndSettle();
      source.append('match C');
      source.append('not included');
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('match C')).dy,
        greaterThan(tester.getTopLeft(find.text('match B')).dy),
      );
      await tester.tap(find.byKey(const ValueKey('logs_save')));
      await tester.pumpAndSettle();
      expect(saved, ['match A', 'match B', 'match C']);
    },
  );
}
