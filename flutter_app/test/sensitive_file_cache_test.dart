import 'dart:io';

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
    final managedDirectory = await Directory(
      '${cache.path}/file_dialog-123',
    ).create();
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
      final managedDirectory = await Directory(
        '${cache.path}/file_dialog-456',
      ).create();
      final managed = await File(
        '${managedDirectory.path}/backup.frpbackup',
      ).writeAsString('encrypted');
      final original = await File(
        '${sandbox.path}/original.frpbackup',
      ).writeAsString('keep');

      await SensitiveFileCache.deleteManagedImportCopy(managed, cache);
      await SensitiveFileCache.deleteManagedImportCopy(original, cache);

      expect(await managed.exists(), isFalse);
      expect(await managedDirectory.exists(), isFalse);
      expect(await original.readAsString(), 'keep');
    },
  );

  test(
    'startup cleanup removes only known sensitive cache artifacts',
    () async {
      final staleDialog = await Directory(
        '${cache.path}/file_dialog-stale',
      ).create();
      await File('${staleDialog.path}/legacy.zip').writeAsString('secret');
      await File('${cache.path}/frp_backup.frpbackup').writeAsString('secret');
      await File('${cache.path}/frp_backup_redacted.zip').writeAsString('safe');
      final unrelated = await File(
        '${cache.path}/unrelated.txt',
      ).writeAsString('keep');
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
      expect(await unrelated.readAsString(), 'keep');
      expect(await similarlyNamed.exists(), isTrue);
    },
  );
}
