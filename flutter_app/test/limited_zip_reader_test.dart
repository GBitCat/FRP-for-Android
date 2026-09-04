import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/services/limited_zip_reader.dart';
import 'package:frp_app/services/wipeable_zip_builder.dart';

void main() {
  test(
    'reads required files after bounded decompression and CRC validation',
    () {
      final zip = _zip({'manifest.json': utf8.encode('{"version":1}')});
      final files = LimitedZipReader.readRequiredFiles(
        zip,
        requiredFileNames: const {'manifest.json'},
        maxEntries: 4,
        maxEntryBytes: 1024,
        maxTotalBytes: 2048,
        allowAdditionalFiles: false,
      );

      expect(utf8.decode(files['manifest.json']!), '{"version":1}');
    },
  );

  test('copies STORE entries from non-zero stream positions', () {
    final zip = WipeableStoredZipBuilder.build([
      WipeableZipEntry('padding.bin', List<int>.filled(37, 0x5a)),
      WipeableZipEntry('manifest.json', utf8.encode('{"token":"secret"}')),
    ], maxOutputBytes: 4096);
    Map<String, Uint8List>? files;
    try {
      files = LimitedZipReader.readRequiredFiles(
        zip,
        requiredFileNames: const {'padding.bin', 'manifest.json'},
        maxEntries: 3,
        maxEntryBytes: 1024,
        maxTotalBytes: 1024,
        allowAdditionalFiles: false,
      );
      // STORE payloads are views into the complete ZIP input. In particular the
      // second entry starts at a non-zero InputMemoryStream.position; copying
      // from buffer offset zero would return a local header instead of JSON.
      expect(files['padding.bin'], everyElement(0x5a));
      expect(utf8.decode(files['manifest.json']!), '{"token":"secret"}');
    } finally {
      zip.fillRange(0, zip.length, 0);
      for (final contents in files?.values ?? const <Uint8List>[]) {
        contents.fillRange(0, contents.length, 0);
      }
    }
  });

  test('actual decompression cannot exceed a forged declared size', () {
    final zip = _zip({
      'manifest.json': Uint8List.fromList(List.filled(256 * 1024, 0x41)),
    });
    _writeCentralUint32(zip, 24, 1);

    expect(
      () => LimitedZipReader.readRequiredFiles(
        zip,
        requiredFileNames: const {'manifest.json'},
        maxEntries: 4,
        maxEntryBytes: 64 * 1024,
        maxTotalBytes: 64 * 1024,
      ),
      throwsFormatException,
    );
  });

  test(
    'rejects symbolic-link entry types before ZipDecoder can expand them',
    () {
      final zip = _zip({'manifest.json': utf8.encode('target')});
      _writeCentralUint32(zip, 38, 0xa000 << 16);

      expect(
        () => LimitedZipReader.readRequiredFiles(
          zip,
          requiredFileNames: const {'manifest.json'},
          maxEntries: 4,
          maxEntryBytes: 1024,
          maxTotalBytes: 2048,
        ),
        throwsFormatException,
      );
    },
  );

  test('rejects duplicate required filenames', () {
    final zip = _zip({
      'manifest.json': [1],
      'manifesz.json': [2],
    });
    _replaceAllAscii(zip, 'manifesz.json', 'manifest.json');

    expect(
      () => LimitedZipReader.readRequiredFiles(
        zip,
        requiredFileNames: const {'manifest.json'},
        maxEntries: 4,
        maxEntryBytes: 1024,
        maxTotalBytes: 2048,
      ),
      throwsFormatException,
    );
  });

  test('rejects an oversized EOCD entry count before directory decoding', () {
    // A central directory with 65,000 empty entries still fits below the
    // import byte limit, but allowing ZipDirectory to materialize every header
    // would create a disproportionate allocation. The EOCD count is enough to
    // reject it before any central-directory objects are built.
    final zip = Uint8List(22);
    final data = ByteData.sublistView(zip);
    data.setUint32(0, 0x06054b50, Endian.little);
    data.setUint16(8, 65000, Endian.little);
    data.setUint16(10, 65000, Endian.little);

    expect(
      () => LimitedZipReader.readRequiredFiles(
        zip,
        requiredFileNames: const {'manifest.json'},
        maxEntries: 64,
        maxEntryBytes: 1024,
        maxTotalBytes: 2048,
      ),
      throwsFormatException,
    );
  });

  test('counts central headers instead of trusting a forged EOCD count', () {
    final zip = _zip({
      'manifest.json': [1],
      'second.txt': [2],
      'third.txt': [3],
    });
    _writeEocdUint16(zip, 8, 1);
    _writeEocdUint16(zip, 10, 1);

    expect(
      () => LimitedZipReader.readRequiredFiles(
        zip,
        requiredFileNames: const {'manifest.json'},
        maxEntries: 2,
        maxEntryBytes: 1024,
        maxTotalBytes: 2048,
      ),
      throwsFormatException,
    );
  });

  test('rejects ZIP64 before directory decoding', () {
    final zip = Uint8List(22);
    final data = ByteData.sublistView(zip);
    data.setUint32(0, 0x06054b50, Endian.little);
    data.setUint16(8, 0xffff, Endian.little);
    data.setUint16(10, 0xffff, Endian.little);
    data.setUint32(12, 0xffffffff, Endian.little);
    data.setUint32(16, 0xffffffff, Endian.little);

    expect(
      () => LimitedZipReader.readRequiredFiles(
        zip,
        requiredFileNames: const {'manifest.json'},
        maxEntries: 64,
        maxEntryBytes: 1024,
        maxTotalBytes: 2048,
      ),
      throwsFormatException,
    );
  });
}

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void _writeCentralUint32(Uint8List zip, int fieldOffset, int value) {
  const signature = [0x50, 0x4b, 0x01, 0x02];
  var centralOffset = -1;
  for (var index = 0; index <= zip.length - signature.length; index++) {
    if (zip[index] == signature[0] &&
        zip[index + 1] == signature[1] &&
        zip[index + 2] == signature[2] &&
        zip[index + 3] == signature[3]) {
      centralOffset = index;
      break;
    }
  }
  if (centralOffset < 0) throw StateError('central directory not found');
  final data = ByteData.sublistView(zip);
  data.setUint32(centralOffset + fieldOffset, value, Endian.little);
}

void _writeEocdUint16(Uint8List zip, int fieldOffset, int value) {
  const signature = [0x50, 0x4b, 0x05, 0x06];
  for (var index = zip.length - 22; index >= 0; index--) {
    if (zip[index] == signature[0] &&
        zip[index + 1] == signature[1] &&
        zip[index + 2] == signature[2] &&
        zip[index + 3] == signature[3]) {
      ByteData.sublistView(zip)
          .setUint16(index + fieldOffset, value, Endian.little);
      return;
    }
  }
  throw StateError('end of central directory not found');
}

void _replaceAllAscii(Uint8List bytes, String from, String to) {
  final source = ascii.encode(from);
  final replacement = ascii.encode(to);
  if (source.length != replacement.length) {
    throw ArgumentError('replacement must preserve ZIP field length');
  }
  var replacements = 0;
  for (var index = 0; index <= bytes.length - source.length; index++) {
    var matches = true;
    for (var offset = 0; offset < source.length; offset++) {
      if (bytes[index + offset] != source[offset]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;
    bytes.setRange(index, index + replacement.length, replacement);
    replacements++;
    index += replacement.length - 1;
  }
  if (replacements < 2) throw StateError('ZIP names were not replaced');
}
