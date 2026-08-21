import 'package:flutter/services.dart';

/// Bridges portable password-encrypted backups to Android's audited crypto APIs.
class BackupCrypto {
  const BackupCrypto._();

  static const _channel = MethodChannel('com.frp.app/secure_store');
  static const _magic = [0x46, 0x52, 0x50, 0x42, 0x01]; // FRPB + v1
  static const maxEncryptedBytes = 5 * 1024 * 1024 + 128;

  static bool isEncrypted(Uint8List bytes) {
    if (bytes.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  static Future<Uint8List> encrypt(Uint8List data, String password) async {
    final encrypted = await _channel.invokeMethod<Uint8List>('encryptBackup', {
      'data': data,
      'password': password,
    });
    if (encrypted == null || !isEncrypted(encrypted)) {
      throw StateError('Android backup encryption returned invalid data');
    }
    return encrypted;
  }

  static Future<Uint8List> decrypt(Uint8List data, String password) async {
    final decrypted = await _channel.invokeMethod<Uint8List>('decryptBackup', {
      'data': data,
      'password': password,
    });
    if (decrypted == null || decrypted.isEmpty) {
      throw StateError('Encrypted backup is empty or invalid');
    }
    return decrypted;
  }
}
