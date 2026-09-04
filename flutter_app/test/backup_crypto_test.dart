import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/services/backup_crypto.dart';

void main() {
  test(
    'backup passwords are rejected before platform key derivation',
    () async {
      final payload = Uint8List.fromList([1]);
      for (final password in [
        'short',
        List.filled(BackupCrypto.maxPasswordLength + 1, 'x').join(),
      ]) {
        await expectLater(
          BackupCrypto.encrypt(payload, password),
          throwsFormatException,
        );
        await expectLater(
          BackupCrypto.decrypt(payload, password),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'backup sizes are rejected before crossing the platform channel',
    () async {
      final oversized = Uint8List(BackupCrypto.maxEncryptedBytes + 1);
      await expectLater(
        BackupCrypto.encrypt(oversized, 'valid backup password'),
        throwsFormatException,
      );
      await expectLater(
        BackupCrypto.decrypt(oversized, 'valid backup password'),
        throwsFormatException,
      );
      await expectLater(
        BackupCrypto.decrypt(
          Uint8List.fromList(const [0x46, 0x52, 0x50]),
          'valid backup password',
        ),
        throwsFormatException,
      );
    },
  );
}
