import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/services/document_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.frp.app/document_io');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'pickFile'
              ? '/private/cache/selected.bin'
              : 'content://saved/document';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'pickFile forwards bounded MIME hints and returns private copy',
    () async {
      final result = await DocumentIo.pickFile(
        mimeTypes: const ['application/zip', 'application/json'],
      );

      expect(result, '/private/cache/selected.bin');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'pickFile');
      expect(calls.single.arguments, {
        'mimeTypes': ['application/zip', 'application/json'],
      });
    },
  );

  test(
    'saveFile forwards only the private source path and suggested name',
    () async {
      final result = await DocumentIo.saveFile(
        sourceFilePath: '/private/cache/export.zip',
        fileName: 'frp_backup.zip',
        mimeTypes: const ['application/zip'],
      );

      expect(result, 'content://saved/document');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'saveFile');
      expect(calls.single.arguments, {
        'sourceFilePath': '/private/cache/export.zip',
        'fileName': 'frp_backup.zip',
        'mimeTypes': ['application/zip'],
      });
    },
  );
}
