import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'document_io.dart';
import 'sensitive_file_cache.dart';

/// Saves a snapshot of already-sanitized logs through Android's document picker.
/// The platform channel carries only a private source path, never the log body.
class LogFileExport {
  const LogFileExport._();

  static Future<bool> save(List<String> lines, {bool filtered = false}) async {
    if (lines.isEmpty) {
      throw ArgumentError.value(lines, 'lines', 'No logs to save');
    }
    // Capture before the first await: live events and filter changes while the
    // document picker is open must not change the requested export.
    final snapshot = List<String>.of(lines, growable: false);
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year.toString().padLeft(4, '0')}'
        '${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final fileName = 'frpc-logs-$stamp${filtered ? '-filtered' : ''}.txt';
    final cache = await getTemporaryDirectory();
    File? source;
    try {
      source = await SensitiveFileCache.createManagedExportFile(
        cache,
        fileName,
      );
      final output = await source.open(mode: FileMode.write);
      try {
        // Bound temporary UTF-8 buffers without joining the entire history.
        // Preserve complete raw records, including SOCKS ownership/counters.
        for (var offset = 0; offset < snapshot.length; offset += 64) {
          final end = (offset + 64).clamp(0, snapshot.length);
          final batch = StringBuffer();
          for (var index = offset; index < end; index++) {
            batch.writeln(snapshot[index]);
          }
          await output.writeString(batch.toString(), encoding: utf8);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      return await DocumentIo.saveFile(
            sourceFilePath: source.path,
            fileName: fileName,
            mimeTypes: const ['text/plain'],
          ) !=
          null;
    } finally {
      if (source != null) {
        await SensitiveFileCache.deleteManagedExportFile(source, cache);
      }
    }
  }
}
