import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/services/stun_server_selector.dart';

const reachable = StunProbeResult(StunProbeStatus.reachable, exitCode: 0);
const timeout = StunProbeResult(StunProbeStatus.timeout, exitCode: 1);
const failure = StunProbeResult(StunProbeStatus.error, exitCode: 1);

List<InternetAddress> addresses(List<String> values) =>
    values.map(InternetAddress.new).toList();

void main() {
  test(
    'filters IPv6, deduplicates IPv4 and rotates only successful probes',
    () async {
      final probes = <String>[];
      final selector = StunServerSelector(
        lookup: (_) async => addresses([
          '2001:db8::1',
          '192.0.2.1',
          '192.0.2.2',
          '192.0.2.1',
          '192.0.2.3',
          '192.0.2.4',
        ]),
        probe: (endpoint) async {
          probes.add(endpoint);
          return switch (endpoint) {
            '192.0.2.1:3478' => timeout,
            '192.0.2.3:3478' => failure,
            _ => reachable,
          };
        },
      );
      addTearDown(selector.dispose);

      expect(await selector.nextEndpoint(), '192.0.2.2:3478');
      expect(await selector.nextEndpoint(), '192.0.2.4:3478');
      expect(await selector.nextEndpoint(), '192.0.2.2:3478');
      expect(probes, [
        '192.0.2.1:3478',
        '192.0.2.2:3478',
        '192.0.2.3:3478',
        '192.0.2.4:3478',
      ]);
      expect(selector.candidates.map((candidate) => candidate.weight), [
        0,
        1,
        0,
        1,
      ]);
      expect(() => selector.candidates.clear(), throwsUnsupportedError);
    },
  );

  test(
    'overlapping selections share one scan and probes run sequentially',
    () async {
      final enteredFirst = Completer<void>();
      final releaseFirst = Completer<StunProbeResult>();
      var lookups = 0;
      var active = 0;
      var maxActive = 0;
      final probes = <String>[];
      final selector = StunServerSelector(
        lookup: (_) async {
          lookups++;
          return addresses(['192.0.2.1', '192.0.2.2']);
        },
        probe: (endpoint) async {
          active++;
          if (active > maxActive) maxActive = active;
          probes.add(endpoint);
          if (probes.length == 1) {
            enteredFirst.complete();
            await releaseFirst.future;
          }
          active--;
          return reachable;
        },
      );
      addTearDown(selector.dispose);
      final first = selector.nextEndpoint();
      await enteredFirst.future;
      final second = selector.nextEndpoint();
      await Future<void>.delayed(Duration.zero);
      expect(probes, ['192.0.2.1:3478']);
      releaseFirst.complete(reachable);

      expect(await first, '192.0.2.1:3478');
      expect(await second, '192.0.2.2:3478');
      expect(lookups, 1);
      expect(maxActive, 1);
    },
  );

  test('expired candidates are resolved and probed again before use', () async {
    var now = DateTime.utc(2026, 11, 14);
    var lookups = 0;
    final probes = <String>[];
    final selector = StunServerSelector(
      clock: () => now,
      cacheDuration: const Duration(minutes: 5),
      lookup: (_) async {
        lookups++;
        return addresses(['192.0.2.$lookups']);
      },
      probe: (endpoint) async {
        probes.add(endpoint);
        return reachable;
      },
    );
    addTearDown(selector.dispose);

    expect(await selector.nextEndpoint(), '192.0.2.1:3478');
    now = now.add(const Duration(minutes: 4));
    expect(await selector.nextEndpoint(), '192.0.2.1:3478');
    expect(lookups, 1);
    now = now.add(const Duration(minutes: 2));
    expect(await selector.nextEndpoint(), '192.0.2.2:3478');
    expect(probes, ['192.0.2.1:3478', '192.0.2.2:3478']);
  });

  test('DNS timeout fails selection without invoking frpc', () async {
    var probes = 0;
    final lookup = Completer<List<InternetAddress>>();
    final selector = StunServerSelector(
      lookup: (_) => lookup.future,
      lookupTimeout: Duration.zero,
      probe: (_) async {
        probes++;
        return reachable;
      },
    );
    addTearDown(selector.dispose);

    await expectLater(
      selector.nextEndpoint(),
      throwsA(
        isA<StunSelectionException>().having(
          (error) => error.message,
          'message',
          contains('DNS lookup timed out'),
        ),
      ),
    );
    expect(probes, 0);
    expect(selector.candidates, isEmpty);
  });

  test('an IPv6-only response never becomes a candidate for udp4', () async {
    var probes = 0;
    final selector = StunServerSelector(
      lookup: (_) async => addresses(['2001:db8::1']),
      probe: (_) async {
        probes++;
        return reachable;
      },
    );
    addTearDown(selector.dispose);
    await expectLater(
      selector.nextEndpoint(),
      throwsA(
        isA<StunSelectionException>().having(
          (error) => error.message,
          'message',
          contains('No IPv4 addresses'),
        ),
      ),
    );
    expect(probes, 0);
  });

  test('all failed probes cannot return an unverified address and a later start retries', () async {
    var recovered = false;
    var lookups = 0;
    final selector = StunServerSelector(
      lookup: (_) async {
        lookups++;
        return addresses(['192.0.2.1', '192.0.2.2']);
      },
      probe: (endpoint) async =>
          recovered && endpoint == '192.0.2.2:3478' ? reachable : timeout,
    );
    addTearDown(selector.dispose);

    await expectLater(
      selector.nextEndpoint(),
      throwsA(isA<StunSelectionException>()),
    );
    expect(selector.candidates.map((candidate) => candidate.weight), [0, 0]);
    recovered = true;
    expect(await selector.nextEndpoint(), '192.0.2.2:3478');
    expect(lookups, 2);
  });

  test('a failed native invocation has weight zero and does not abort later probes', () async {
    final selector = StunServerSelector(
      lookup: (_) async => addresses(['192.0.2.1', '192.0.2.2']),
      probe: (endpoint) async {
        if (endpoint == '192.0.2.1:3478') {
          throw StateError('native worker unavailable');
        }
        return reachable;
      },
    );
    addTearDown(selector.dispose);
    expect(await selector.nextEndpoint(), '192.0.2.2:3478');
    expect(selector.candidates.first.result.status, StunProbeStatus.error);
    expect(selector.candidates.map((candidate) => candidate.weight), [0, 1]);
  });

  test('dispose prevents remaining probes and cannot publish a late successful result', () async {
    final entered = Completer<void>();
    final release = Completer<StunProbeResult>();
    final probes = <String>[];
    final selector = StunServerSelector(
      lookup: (_) async => addresses(['192.0.2.1', '192.0.2.2']),
      probe: (endpoint) {
        probes.add(endpoint);
        entered.complete();
        return release.future;
      },
    );
    final preparing = selector.prepare();
    await entered.future;
    selector.dispose();
    release.complete(reachable);
    await preparing;

    expect(probes, ['192.0.2.1:3478']);
    expect(selector.candidates, isEmpty);
    await expectLater(
      selector.nextEndpoint(),
      throwsA(isA<StunSelectionException>()),
    );
  });

  test(
    'native success requires both the success status and zero exit code',
    () {
      expect(
        StunProbeResult.fromMap({'status': 'reachable', 'exitCode': 0}).status,
        StunProbeStatus.reachable,
      );
      expect(
        StunProbeResult.fromMap({'status': 'reachable', 'exitCode': 1}).status,
        StunProbeStatus.error,
      );
      expect(
        StunProbeResult.fromMap({'status': 'reachable'}).status,
        StunProbeStatus.error,
      );
      expect(
        StunProbeResult.fromMap({'status': 'timeout', 'exitCode': 1}).status,
        StunProbeStatus.timeout,
      );
    },
  );
}
