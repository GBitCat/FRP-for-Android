import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/services/wipeable_zip_builder.dart';

void main() {
  test('fixed STORE ZIP round-trips every entry', () {
    final output = WipeableStoredZipBuilder.build([
      WipeableZipEntry('manifest.json', utf8.encode('{"token":"secret"}')),
      WipeableZipEntry(
        'servers/SERVER01.toml',
        List<int>.from(utf8.encode('auth.token = "secret"')),
      ),
    ], maxOutputBytes: 4096);
    try {
      final archive = ZipDecoder().decodeBytes(output);
      expect(archive.files.map((file) => file.name), [
        'manifest.json',
        'servers/SERVER01.toml',
      ]);
      expect(
        archive.files,
        everyElement(
          predicate<ArchiveFile>(
            (file) => file.compression == CompressionType.none,
            'is stored without compression',
          ),
        ),
      );
      expect(
        utf8.decode(archive.files[1].content as List<int>),
        'auth.token = "secret"',
      );
    } finally {
      output.fillRange(0, output.length, 0);
    }
  });

  test('rejects duplicate, unsafe, and oversized entries', () {
    expect(
      () => WipeableStoredZipBuilder.build(const [
        WipeableZipEntry('same', [1]),
        WipeableZipEntry('same', [2]),
      ], maxOutputBytes: 1024),
      throwsFormatException,
    );
    expect(
      () => WipeableStoredZipBuilder.build(const [
        WipeableZipEntry('../secret', [1]),
      ], maxOutputBytes: 1024),
      throwsFormatException,
    );
    expect(
      () => WipeableStoredZipBuilder.build([
        WipeableZipEntry('secret', List<int>.filled(1024, 1)),
      ], maxOutputBytes: 128),
      throwsFormatException,
    );
  });
}
