import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/services/log_file_export.dart';
import 'package:frp_app/services/sensitive_file_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const documents = MethodChannel('com.frp.app/document_io');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('log-export-test-');
    messenger.setMockMethodCallHandler(paths, (call) async {
      expect(call.method, 'getTemporaryDirectory');
      return cache.path;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(documents, null);
    messenger.setMockMethodCallHandler(paths, null);
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  test('saves complete UTF-8 raw records and removes private source', () async {
    final lines = [
      '[STUN] 探测结果：reachable',
      '[SOCKS5] {"v":1,"configKey":"s/group/1","connectionId":"ports-a",'
          '"message":"received 1040B","udpLocalRxPackets":12,"password":"***"}',
      '[frpc] final line',
    ];
    late File source;
    messenger.setMockMethodCallHandler(documents, (call) async {
      expect(call.method, 'saveFile');
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      expect(
        arguments.keys,
        unorderedEquals(['sourceFilePath', 'fileName', 'mimeTypes']),
      );
      expect(arguments['fileName'], matches(r'^frpc-logs-\d{8}-\d{6}\.txt$'));
      expect(arguments['mimeTypes'], ['text/plain']);
      source = File(arguments['sourceFilePath'] as String);
      expect(SensitiveFileCache.isManagedExportFile(source, cache), isTrue);
      expect(await source.readAsBytes(), utf8.encode('${lines.join('\n')}\n'));
      return 'content://test/saved.txt';
    });

    expect(await LogFileExport.save(lines), isTrue);
    expect(await source.exists(), isFalse);
    expect(await source.parent.exists(), isFalse);
  });

  test(
    'filtered export uses the supplied snapshot while picker is open',
    () async {
      final selected = ['[SOCKS5] selected port'];
      final pickerOpened = Completer<File>();
      final pickerResult = Completer<String?>();
      messenger.setMockMethodCallHandler(documents, (call) async {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        expect(
          arguments['fileName'],
          matches(r'^frpc-logs-\d{8}-\d{6}-filtered\.txt$'),
        );
        pickerOpened.complete(File(arguments['sourceFilePath'] as String));
        return pickerResult.future;
      });

      final saving = LogFileExport.save(selected, filtered: true);
      selected.add('[frpc] arrived after save was pressed');
      final source = await pickerOpened.future;
      expect(await source.readAsString(), '[SOCKS5] selected port\n');
      pickerResult.complete('content://test/filtered.txt');
      expect(await saving, isTrue);
      expect(await source.parent.exists(), isFalse);
    },
  );

  test('cancel and write failure both remove private export files', () async {
    for (final failure in [false, true]) {
      late File source;
      messenger.setMockMethodCallHandler(documents, (call) async {
        source = File((call.arguments as Map)['sourceFilePath'] as String);
        expect(await source.exists(), isTrue);
        if (failure) throw PlatformException(code: 'DOCUMENT_IO_ERROR');
        return null;
      });

      if (failure) {
        await expectLater(
          LogFileExport.save(['line']),
          throwsA(isA<PlatformException>()),
        );
      } else {
        expect(await LogFileExport.save(['line']), isFalse);
      }
      expect(await source.exists(), isFalse);
      expect(await source.parent.exists(), isFalse);
    }
  });

  test(
    'large history is not truncated or carried in the platform message',
    () async {
      final line = '界' * 4096;
      final lines = List<String>.filled(2000, line);
      final expectedBytes = (utf8.encode(line).length + 1) * lines.length;
      messenger.setMockMethodCallHandler(documents, (call) async {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        expect(arguments.length, 3);
        final source = File(arguments['sourceFilePath'] as String);
        expect(await source.length(), expectedBytes);
        final input = await source.open();
        try {
          await input.setPosition(expectedBytes - 4);
          expect(await input.read(4), [...utf8.encode('界'), 10]);
        } finally {
          await input.close();
        }
        return 'content://test/large.txt';
      });

      expect(await LogFileExport.save(lines), isTrue);
      expect(await cache.list().isEmpty, isTrue);
    },
  );

  test('empty history never starts a file picker', () async {
    messenger.setMockMethodCallHandler(documents, (_) async {
      fail('No document request is expected');
    });
    await expectLater(LogFileExport.save([]), throwsArgumentError);
    expect(await cache.list().isEmpty, isTrue);
  });
}
