import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/connection_status.dart';
import 'package:frp_app/services/frp_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('test/frpc-log-delivery');

  Future<void> deliver(String method, Object? value) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, value)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });

  test(
    'release keeps history in Android and streams only while subscribed',
    () async {
      final history = ['before opening'];
      final requests = <bool>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'setLogSubscription':
            requests.add(call.arguments as bool);
            return null;
          case 'readLogSnapshot':
            return {'firstId': 10, 'lines': List.of(history)};
          default:
            throw UnsupportedError(call.method);
        }
      });
      final engine = FrpEngine.withChannel(channel, nativeLogHistory: true);
      final records = <RuntimeLog>[];
      final statuses = <ConnectionStatus>[];
      final statusSub = engine.statusStream.listen(statuses.add);
      await deliver('onStatus', {'scope': 'server', 'type': 'p2p'});
      expect(statuses.single.type, ConnectionType.p2p);
      expect(requests, isEmpty);

      final first = engine.logStream.listen(records.add);
      final second = engine.logStream.listen((_) {});
      expect((await engine.readLogSnapshot()).single, (
        id: 10,
        line: 'before opening',
      ));
      expect(requests, [true]);
      history.addAll(['repeat', 'repeat']);
      await deliver('onLogBatch', {
        'firstId': 11,
        'lines': ['repeat', 'repeat'],
      });
      expect(records, [(id: 11, line: 'repeat'), (id: 12, line: 'repeat')]);
      expect(engine.logs, isEmpty);
      await first.cancel();
      expect(requests, [true]);
      await second.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(requests, [true, false]);

      history.add('during navigation');
      // An in-flight batch from the previous route can arrive after it closes.
      await deliver('onLogBatch', {
        'firstId': 13,
        'lines': ['during navigation'],
      });
      expect(engine.logs, isEmpty);
      final reopened = engine.logStream.listen(records.add);
      final snapshot = await engine.readLogSnapshot();
      expect(snapshot.map((row) => row.line), history);
      expect(snapshot.last.id, 13);
      expect(requests, [true, false, true]);
      await reopened.cancel();
      await statusSub.cancel();
    },
  );

  test('debug and profile keep their existing unsolicited history', () async {
    final requests = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      requests.add(call.method);
      return null;
    });
    final engine = FrpEngine.withChannel(channel, nativeLogHistory: false);
    await deliver('onLog', [7, 'while off screen']);
    final seen = <RuntimeLog>[];
    final sub = engine.logStream.listen(seen.add);
    await deliver('onLog', [8, 'while visible']);
    await sub.cancel();
    expect(seen, [(id: 8, line: 'while visible')]);
    expect(engine.logs, [
      (id: 7, line: 'while off screen'),
      (id: 8, line: 'while visible'),
    ]);
    expect(requests, isEmpty);
  });
}
