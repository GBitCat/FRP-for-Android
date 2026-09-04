import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One file for [WipeableStoredZipBuilder].
final class WipeableZipEntry {
  const WipeableZipEntry(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}

/// Builds a STORE-only ZIP in one fixed, caller-wipeable allocation.
///
/// The archive package's normal deflate path creates private intermediate
/// buffers. Its growable output stream can also abandon old buffers during
/// expansion. This builder avoids both paths. The returned [Uint8List] aliases
/// the sole output allocation and must be overwritten by the caller when it
/// may contain secrets.
abstract final class WipeableStoredZipBuilder {
  static Uint8List build(
    Iterable<WipeableZipEntry> sourceEntries, {
    required int maxOutputBytes,
  }) {
    if (maxOutputBytes <= 0 || maxOutputBytes > 0xffffffff) {
      throw const FormatException('ZIP output limit is invalid');
    }

    final entries = sourceEntries.toList(growable: false);
    if (entries.isEmpty || entries.length > 0xffff) {
      throw const FormatException('ZIP entry count is invalid');
    }

    final ownedCopies = <Uint8List>[];
    _FixedOutputStream? output;
    var retained = false;
    try {
      final prepared = <_PreparedEntry>[];
      final names = <String>{};
      var capacity = 22; // End of central directory, with no comment.
      for (final entry in entries) {
        final encodedName = utf8.encode(entry.name);
        if (!_isSafeFileName(entry.name) ||
            encodedName.isEmpty ||
            encodedName.length > 0xffff ||
            !names.add(entry.name) ||
            entry.bytes.length > 0xffffffff) {
          throw const FormatException('ZIP entry is invalid');
        }
        final Uint8List bytes;
        final sourceBytes = entry.bytes;
        if (sourceBytes is Uint8List) {
          bytes = sourceBytes;
        } else {
          bytes = Uint8List.fromList(sourceBytes);
          ownedCopies.add(bytes);
        }
        prepared.add(_PreparedEntry(entry.name, bytes));

        // A stored file without comments/extras uses a 30-byte local header
        // and a 46-byte central-directory header; the filename occurs twice.
        capacity += bytes.length + 76 + (2 * encodedName.length);
        if (capacity > maxOutputBytes || capacity > 0xffffffff) {
          throw const FormatException('ZIP output exceeds the size limit');
        }
      }

      output = _FixedOutputStream(capacity);
      final archive = Archive();
      for (final entry in prepared) {
        archive.addFile(
          ArchiveFile.noCompress(entry.name, entry.bytes.length, entry.bytes),
        );
      }
      ZipEncoder().encodeStream(archive, output, autoClose: true);
      if (output.length != capacity) {
        throw const FormatException('ZIP encoder output format changed');
      }
      retained = true;
      return output.getBytes();
    } finally {
      for (final copy in ownedCopies) {
        copy.fillRange(0, copy.length, 0);
      }
      if (!retained) output?.erase();
    }
  }

  static bool _isSafeFileName(String name) {
    if (name.isEmpty ||
        name.length > 512 ||
        name.contains('\x00') ||
        name.contains(r'\') ||
        name.startsWith('/') ||
        name.endsWith('/')) {
      return false;
    }
    return name
        .split('/')
        .every(
          (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
        );
  }
}

final class _PreparedEntry {
  const _PreparedEntry(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// Fixed capacity is a security property: an encoder change fails before a
/// second plaintext buffer can be allocated during growth.
final class _FixedOutputStream extends OutputStream {
  _FixedOutputStream(int capacity)
    : _buffer = Uint8List(capacity),
      super(byteOrder: ByteOrder.littleEndian);

  final Uint8List _buffer;
  int _length = 0;

  @override
  int get length => _length;

  void _requireCapacity(int count) {
    if (count < 0 || _length + count > _buffer.length) {
      throw const FormatException('ZIP encoder exceeded its fixed output');
    }
  }

  @override
  void clear() {
    _buffer.fillRange(0, _length, 0);
    _length = 0;
  }

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
      throw const FormatException('ZIP encoder produced invalid output');
    }
    _requireCapacity(count);
    _buffer.setRange(_length, _length + count, bytes);
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    final count = stream.length;
    _requireCapacity(count);
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
  Uint8List getBytes() => Uint8List.sublistView(_buffer, 0, _length);

  void erase() {
    _buffer.fillRange(0, _buffer.length, 0);
    _length = 0;
  }
}
