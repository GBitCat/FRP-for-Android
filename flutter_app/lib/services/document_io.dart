import 'package:flutter/services.dart';

/// App-owned Storage Access Framework bridge.
///
/// Imports are copied into a bounded app-private cache directory; exports may
/// read only direct files in app-managed cache directories. The Android side
/// enforces both rules.
class DocumentIo {
  const DocumentIo._();

  static const _channel = MethodChannel('com.frp.app/document_io');

  static Future<String?> pickFile({required List<String> mimeTypes}) =>
      _channel.invokeMethod<String>('pickFile', {'mimeTypes': mimeTypes});

  static Future<String?> saveFile({
    required String sourceFilePath,
    required String fileName,
    required List<String> mimeTypes,
  }) => _channel.invokeMethod<String>('saveFile', {
    'sourceFilePath': sourceFilePath,
    'fileName': fileName,
    'mimeTypes': mimeTypes,
  });
}
