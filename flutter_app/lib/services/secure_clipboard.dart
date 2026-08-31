import 'package:flutter/services.dart';

/// Copies sensitive text using the Android clipboard sensitivity marker and a
/// native automatic-clear timeout.
class SecureClipboard {
  static const _channel = MethodChannel('com.frp.app/secure_store');

  const SecureClipboard._();

  static Future<void> copy(String text) async {
    await _channel.invokeMethod<void>('copySensitiveText', {'value': text});
  }
}
