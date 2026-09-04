import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/services/sensitive_file_cache.dart';

void main() {
  late Directory sandbox;
  late Directory cache;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('frp-cache-test-');
    cache = await Directory('${sandbox.path}/cache').create();
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('only immediate file dialog copies are treated as managed', () async {
    final managedDirectory = await Directory('${cache.path}/file_dialog-123')
        .create();
    final managed = File('${managedDirectory.path}/backup.zip');
    final original = File('${sandbox.path}/backup.zip');
    final nested = File('${managedDirectory.path}/nested/backup.zip');

    expect(SensitiveFileCache.isManagedImportCopy(managed, cache), isTrue);
    expect(SensitiveFileCache.isManagedImportCopy(original, cache), isFalse);
    expect(SensitiveFileCache.isManagedImportCopy(nested, cache), isFalse);
  });

  test(
    'import cleanup deletes the copy but never the selected original',
    () async {
      final managedDirectory = await Directory('${cache.path}/file_dialog-456')
          .create();
      final managed = await File('${managedDirectory.path}/backup.frpbackup')
          .writeAsString('encrypted');
      final original = await File('${sandbox.path}/original.frpbackup')
          .writeAsString('keep');

      await SensitiveFileCache.deleteManagedImportCopy(managed, cache);
      await SensitiveFileCache.deleteManagedImportCopy(original, cache);

      expect(await managed.exists(), isFalse);
      expect(await managedDirectory.exists(), isFalse);
      expect(await original.readAsString(), 'keep');
    },
  );

  test('concurrent exports receive isolated managed source paths', () async {
    final first = await SensitiveFileCache.createManagedExportFile(
      cache,
      'backup.frpbackup',
    );
    final second = await SensitiveFileCache.createManagedExportFile(
      cache,
      'backup.frpbackup',
    );
    await first.writeAsString('first-secret');
    await second.writeAsString('second-secret');

    expect(first.path, isNot(second.path));
    expect(first.parent.path, isNot(second.parent.path));
    expect(SensitiveFileCache.isManagedExportFile(first, cache), isTrue);
    expect(SensitiveFileCache.isManagedExportFile(second, cache), isTrue);

    await SensitiveFileCache.deleteManagedExportFile(first, cache);
    expect(await first.parent.exists(), isFalse);
    expect(await second.readAsString(), 'second-secret');

    await SensitiveFileCache.cleanupStaleFiles(cache);
    expect(await second.parent.exists(), isFalse);
  });

  test(
    'bounded reads reject oversized files before materializing them',
    () async {
      final source = await File('${sandbox.path}/oversized.bin')
          .writeAsBytes(List<int>.filled(17, 0x41));

      await expectLater(
        SensitiveFileCache.readBoundedFile(source, maxBytes: 16),
        throwsFormatException,
      );
    },
  );

  test('bounded reads return the complete file from one handle', () async {
    final source = await File('${sandbox.path}/source.bin')
        .writeAsBytes(const [1, 2, 3, 4]);

    final bytes = await SensitiveFileCache.readBoundedFile(source, maxBytes: 4);
    expect(bytes, Uint8List.fromList(const [1, 2, 3, 4]));
    bytes.fillRange(0, bytes.length, 0);
  });

  test(
    'bounded copies enforce the limit and clean partial destinations',
    () async {
      final source = await File('${sandbox.path}/source.bin')
          .writeAsBytes(List<int>.generate(65 * 1024, (index) => index & 0xff));
      final copied = File('${sandbox.path}/copied.bin');
      final rejected = File('${sandbox.path}/rejected.bin');

      await SensitiveFileCache.copyBoundedFile(
        source,
        copied,
        maxBytes: 65 * 1024,
      );
      expect(await copied.readAsBytes(), await source.readAsBytes());

      await expectLater(
        SensitiveFileCache.copyBoundedFile(
          source,
          rejected,
          maxBytes: 64 * 1024,
        ),
        throwsFormatException,
      );
      expect(await rejected.exists(), isFalse);
    },
  );

  test(
    'startup cleanup removes only known sensitive cache artifacts',
    () async {
      final staleDialog = await Directory('${cache.path}/file_dialog-stale')
          .create();
      await File('${staleDialog.path}/legacy.zip').writeAsString('secret');
      await File('${cache.path}/frp_backup.frpbackup').writeAsString('secret');
      await File('${cache.path}/frp_backup_redacted.zip').writeAsString('safe');
      await File('${cache.path}/frp_ca_export_home.frpca')
          .writeAsString('secret');
      await File('${cache.path}/frp_tls_export_frps.frptls')
          .writeAsString('secret');
      await File('${cache.path}/legacy-ca.frpca').writeAsString('secret');
      await File('${cache.path}/legacy-frps.frptls').writeAsString('secret');
      final unrelated = await File('${cache.path}/unrelated.txt')
          .writeAsString('keep');
      final similarExtension = await File('${cache.path}/keep.frptlsx')
          .writeAsString('keep');
      final nestedDirectory = await Directory('${cache.path}/nested').create();
      final nestedExport = await File('${nestedDirectory.path}/keep.frpca')
          .writeAsString('keep');
      final similarlyNamed = await Directory(
        '${cache.path}/not-file_dialog-stale',
      ).create();

      await SensitiveFileCache.cleanupStaleFiles(cache);

      expect(await staleDialog.exists(), isFalse);
      expect(
        await File('${cache.path}/frp_backup.frpbackup').exists(),
        isFalse,
      );
      expect(
        await File('${cache.path}/frp_backup_redacted.zip').exists(),
        isFalse,
      );
      expect(
        await File('${cache.path}/frp_ca_export_home.frpca').exists(),
        isFalse,
      );
      expect(
        await File('${cache.path}/frp_tls_export_frps.frptls').exists(),
        isFalse,
      );
      expect(await File('${cache.path}/legacy-ca.frpca').exists(), isFalse);
      expect(await File('${cache.path}/legacy-frps.frptls').exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep');
      expect(await similarExtension.readAsString(), 'keep');
      expect(await nestedExport.readAsString(), 'keep');
      expect(await similarlyNamed.exists(), isTrue);
    },
  );
}
