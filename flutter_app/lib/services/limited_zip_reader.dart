import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Reads selected ZIP entries only after validating the complete central
/// directory. Actual decompression is written into a hard-bounded output
/// stream, so forged size metadata cannot turn a small archive into an
/// unbounded allocation.
abstract final class LimitedZipReader {
  static Map<String, Uint8List> readRequiredFiles(
    List<int> bytes, {
    required Set<String> requiredFileNames,
    required int maxEntries,
    required int maxEntryBytes,
    required int maxTotalBytes,
    bool allowAdditionalFiles = true,
    bool allowDirectories = true,
  }) {
    if (bytes.isEmpty ||
        requiredFileNames.isEmpty ||
        maxEntries <= 0 ||
        maxEntryBytes <= 0 ||
        maxTotalBytes <= 0) {
      throw const FormatException('ZIP limits are invalid');
    }

    // ZipDirectory allocates one header object per entry while parsing the
    // central directory. Inspect the fixed-size EOCD first so an attacker
    // cannot make that allocation for tens of thousands of empty entries
    // before [maxEntries] is enforced.
    _preflightEndOfCentralDirectory(bytes, maxEntries: maxEntries);
    final directory = ZipDirectory();
    directory.read(InputMemoryStream(bytes));
    final headers = directory.fileHeaders;
    if (headers.isEmpty ||
        headers.length > maxEntries ||
        directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0 ||
        directory.totalCentralDirectoryEntriesOnThisDisk != headers.length ||
        directory.totalCentralDirectoryEntries != headers.length ||
        directory.centralDirectoryOffset < 0 ||
        directory.centralDirectorySize < 0 ||
        directory.centralDirectoryOffset + directory.centralDirectorySize >
            bytes.length) {
      throw const FormatException('ZIP directory is invalid');
    }

    final seen = <String>{};
    var declaredTotal = 0;
    for (final header in headers) {
      final name = header.filename;
      final isDirectory = name.endsWith('/') || name.endsWith(r'\');
      if (!_isSafeName(name, isDirectory: isDirectory) || !seen.add(name)) {
        throw const FormatException('ZIP contains an unsafe or duplicate name');
      }
      if (isDirectory && !allowDirectories) {
        throw const FormatException('ZIP contains an unexpected directory');
      }
      if (!isDirectory &&
          !allowAdditionalFiles &&
          !requiredFileNames.contains(name)) {
        throw const FormatException('ZIP contains an unexpected file');
      }
      if ((header.generalPurposeBitFlag & 0x1) != 0 ||
          (header.compressionMethod != 0 && header.compressionMethod != 8)) {
        throw const FormatException(
          'ZIP encryption or compression method is unsupported',
        );
      }
      final fileType = (header.externalFileAttributes >> 16) & 0xf000;
      if (fileType == 0xa000 ||
          (fileType != 0 &&
              fileType != 0x8000 &&
              !(isDirectory && fileType == 0x4000))) {
        throw const FormatException('ZIP contains an unsafe entry type');
      }
      if (header.file == null ||
          header.file!.filename != name ||
          header.localHeaderOffset < 0 ||
          header.localHeaderOffset >= bytes.length ||
          header.compressedSize < 0 ||
          header.compressedSize > bytes.length ||
          header.uncompressedSize < 0 ||
          header.uncompressedSize > maxEntryBytes ||
          (isDirectory && header.uncompressedSize != 0)) {
        throw const FormatException('ZIP entry metadata is invalid');
      }
      declaredTotal += header.uncompressedSize;
      if (declaredTotal > maxTotalBytes) {
        throw const FormatException('ZIP expanded size exceeds the limit');
      }
    }

    if (!seen.containsAll(requiredFileNames)) {
      throw const FormatException('ZIP is missing a required file');
    }

    final result = <String, Uint8List>{};
    var actualTotal = 0;
    try {
      for (final header in headers) {
        if (!requiredFileNames.contains(header.filename)) continue;
        final output = _BoundedOutputStream(maxEntryBytes);
        Uint8List? content;
        var retained = false;
        try {
          header.file!.decompress(output);
          content = output.getBytes();
          if (content.length != header.uncompressedSize ||
              getCrc32(content) != header.crc32) {
            throw const FormatException(
              'ZIP entry size or checksum is invalid',
            );
          }
          actualTotal += content.length;
          if (actualTotal > maxTotalBytes) {
            throw const FormatException('ZIP expanded size exceeds the limit');
          }
          result[header.filename] = content;
          retained = true;
        } finally {
          output.erase();
          if (!retained) content?.fillRange(0, content.length, 0);
        }
      }
      return result;
    } catch (_) {
      for (final contents in result.values) {
        contents.fillRange(0, contents.length, 0);
      }
      rethrow;
    }
  }

  static bool _isSafeName(String name, {required bool isDirectory}) {
    if (name.isEmpty ||
        name.contains('\x00') ||
        name.contains(r'\') ||
        name.startsWith('/') ||
        name.length > 512) {
      return false;
    }
    final value = isDirectory ? name.substring(0, name.length - 1) : name;
    final segments = value.split('/');
    return segments.isNotEmpty &&
        segments.every(
          (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
        );
  }

  static void _preflightEndOfCentralDirectory(
    List<int> bytes, {
    required int maxEntries,
  }) {
    const eocdLength = 22;
    const maxCommentLength = 0xffff;
    const eocdSignature = 0x06054b50;
    const zip64LocatorSignature = 0x07064b50;
    if (bytes.length < eocdLength) {
      throw const FormatException('ZIP end record is missing');
    }

    final earliest = bytes.length > eocdLength + maxCommentLength
        ? bytes.length - eocdLength - maxCommentLength
        : 0;
    int? eocdOffset;
    for (var offset = bytes.length - eocdLength; offset >= earliest; offset--) {
      if (_readUint32(bytes, offset) != eocdSignature) continue;
      final commentLength = _readUint16(bytes, offset + 20);
      if (offset + eocdLength + commentLength == bytes.length) {
        eocdOffset = offset;
        break;
      }
    }
    if (eocdOffset == null) {
      throw const FormatException('ZIP end record is invalid');
    }

    final disk = _readUint16(bytes, eocdOffset + 4);
    final centralDirectoryDisk = _readUint16(bytes, eocdOffset + 6);
    final entriesOnDisk = _readUint16(bytes, eocdOffset + 8);
    final totalEntries = _readUint16(bytes, eocdOffset + 10);
    final centralDirectorySize = _readUint32(bytes, eocdOffset + 12);
    final centralDirectoryOffset = _readUint32(bytes, eocdOffset + 16);
    final hasZip64Locator =
        eocdOffset >= 20 &&
        _readUint32(bytes, eocdOffset - 20) == zip64LocatorSignature;
    if (hasZip64Locator ||
        entriesOnDisk == 0xffff ||
        totalEntries == 0xffff ||
        centralDirectorySize == 0xffffffff ||
        centralDirectoryOffset == 0xffffffff) {
      throw const FormatException('ZIP64 archives are unsupported');
    }
    if (disk != 0 ||
        centralDirectoryDisk != 0 ||
        entriesOnDisk != totalEntries ||
        totalEntries == 0 ||
        totalEntries > maxEntries ||
        centralDirectoryOffset + centralDirectorySize != eocdOffset) {
      throw const FormatException('ZIP end record exceeds allowed limits');
    }

    // Do not trust the EOCD count by itself. ZipDirectory walks the byte range
    // described by centralDirectorySize, so a forged count of one can still
    // make it allocate thousands of header objects. Count those fixed-format
    // records with integer offsets before constructing any archive objects.
    const centralHeaderLength = 46;
    const centralHeaderSignature = 0x02014b50;
    var cursor = centralDirectoryOffset;
    var actualEntries = 0;
    while (cursor < eocdOffset) {
      if (eocdOffset - cursor < centralHeaderLength ||
          _readUint32(bytes, cursor) != centralHeaderSignature) {
        throw const FormatException('ZIP central directory is invalid');
      }
      final nameLength = _readUint16(bytes, cursor + 28);
      final extraLength = _readUint16(bytes, cursor + 30);
      final commentLength = _readUint16(bytes, cursor + 32);
      final next =
          cursor +
          centralHeaderLength +
          nameLength +
          extraLength +
          commentLength;
      if (next <= cursor || next > eocdOffset) {
        throw const FormatException('ZIP central directory is truncated');
      }
      actualEntries++;
      if (actualEntries > maxEntries) {
        throw const FormatException('ZIP contains too many entries');
      }
      cursor = next;
    }
    if (cursor != eocdOffset || actualEntries != totalEntries) {
      throw const FormatException('ZIP central directory count is invalid');
    }
  }

  static int _readUint16(List<int> bytes, int offset) =>
      (bytes[offset] & 0xff) | ((bytes[offset + 1] & 0xff) << 8);

  static int _readUint32(List<int> bytes, int offset) =>
      _readUint16(bytes, offset) | (_readUint16(bytes, offset + 2) << 16);
}

class _BoundedOutputStream extends OutputStream {
  _BoundedOutputStream(this.maxLength)
    : _buffer = Uint8List(maxLength),
      super(byteOrder: ByteOrder.littleEndian);

  final int maxLength;
  final Uint8List _buffer;
  int _length = 0;

  @override
  int get length => _length;

  void _requireCapacity(int count) {
    if (count < 0 || _length + count > maxLength) {
      throw const FormatException('ZIP entry expands beyond the size limit');
    }
  }

  @override
  void clear() => _length = 0;

  @override
  void flush() {}

  @override
  void writeByte(int value) {
    _requireCapacity(1);
    _buffer[_length++] = value;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count > bytes.length) {
      throw const FormatException('ZIP decoder produced invalid output');
    }
    _requireCapacity(count);
    _buffer.setRange(_length, _length + count, bytes);
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    final count = stream.length;
    _requireCapacity(count);
    // Preserve InputMemoryStream's zero-copy buffer semantics and copy from
    // its current position. Other InputStream implementations are consumed
    // incrementally so an implementation-specific materialization cannot
    // create an unowned sensitive temporary buffer.
    if (stream is InputMemoryStream && stream.buffer != null) {
      _buffer.setRange(
        _length,
        _length + count,
        stream.buffer!,
        stream.position,
      );
      _length += count;
      return;
    }
    final end = _length + count;
    while (_length < end) {
      _buffer[_length++] = stream.readByte();
    }
  }

  @override
  void writeBackReference(int distance, int count) {
    if (distance <= 0 || distance > _length || count < 0) {
      throw const FormatException('ZIP back-reference is invalid');
    }
    _requireCapacity(count);
    var source = _length - distance;
    final end = _length + count;
    while (_length < end) {
      _buffer[_length++] = _buffer[source++];
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final normalizedStart = start < 0 ? _length + start : start;
    final rawEnd = end ?? _length;
    final normalizedEnd = rawEnd < 0 ? _length + rawEnd : rawEnd;
    if (normalizedStart < 0 ||
        normalizedEnd < normalizedStart ||
        normalizedEnd > _length) {
      throw const FormatException('ZIP output range is invalid');
    }
    return Uint8List.sublistView(_buffer, normalizedStart, normalizedEnd);
  }

  @override
  Uint8List getBytes() =>
      Uint8List.fromList(Uint8List.sublistView(_buffer, 0, _length));

  void erase() {
    _buffer.fillRange(0, _buffer.length, 0);
    _length = 0;
  }
}
