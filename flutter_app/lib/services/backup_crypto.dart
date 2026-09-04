import 'package:flutter/services.dart';

/// Bridges portable password-encrypted backups to Android's audited crypto APIs.
class BackupCrypto {
  const BackupCrypto._();

  static const _channel = MethodChannel('com.frp.app/secure_store');
  static const _magic = [0x46, 0x52, 0x50, 0x42, 0x01]; // FRPB + v1
  static const maxPlaintextBytes = 5 * 1024 * 1024;
  static const maxEncryptedBytes = maxPlaintextBytes + 128;
  static const minPasswordLength = 12;
  static const maxPasswordLength = 1024;

  static void _validatePassword(String password) {
    if (password.length < minPasswordLength ||
        password.length > maxPasswordLength) {
      throw const FormatException(
        'Backup password must contain 12–1024 characters',
      );
    }
  }

  static bool isEncrypted(Uint8List bytes) {
    if (bytes.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  static Future<Uint8List> encrypt(Uint8List data, String password) async {
    _validatePassword(password);
    if (data.isEmpty || data.length > maxPlaintextBytes) {
      throw const FormatException('Backup payload size is invalid');
    }
    final encrypted = await _channel.invokeMethod<Uint8List>('encryptBackup', {
      'data': data,
      'password': password,
    });
    if (encrypted == null) {
      throw StateError('Android backup encryption returned invalid data');
    }
    if (encrypted.length > maxEncryptedBytes || !isEncrypted(encrypted)) {
      encrypted.fillRange(0, encrypted.length, 0);
      throw StateError('Android backup encryption returned invalid data');
    }
    return encrypted;
  }

  static Future<Uint8List> decrypt(Uint8List data, String password) async {
    _validatePassword(password);
    if (data.length > maxEncryptedBytes || !isEncrypted(data)) {
      throw const FormatException('Encrypted backup size or format is invalid');
    }
    final decrypted = await _channel.invokeMethod<Uint8List>('decryptBackup', {
      'data': data,
      'password': password,
    });
    if (decrypted == null) {
      throw StateError('Encrypted backup is empty or invalid');
    }
    if (decrypted.isEmpty || decrypted.length > maxPlaintextBytes) {
      decrypted.fillRange(0, decrypted.length, 0);
      throw StateError('Encrypted backup is empty or invalid');
    }
    return decrypted;
  }
}
