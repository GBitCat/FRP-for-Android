import 'dart:io';
import 'dart:typed_data';

/// Owns temporary files created while importing or exporting backups.
///
/// Cleanup is deliberately restricted to app-owned names in the immediate
/// cache directory and immediate `file_dialog-*` children. A caller can
/// therefore never delete the original document selected by the user.
class SensitiveFileCache {
  static const _dialogDirectoryPrefix = 'file_dialog-';
  static const _exportDirectoryPrefix = 'frp_export-';
  static const _caExportPrefix = 'frp_ca_export_';
  static const _tlsExportPrefix = 'frp_tls_export_';
  static const _temporaryBackupNames = {
    'frp_backup.frpbackup',
    'frp_backup_redacted.zip',
    'frp_backup.zip',
  };

  const SensitiveFileCache._();

  /// Reads one app-private file without ever allocating beyond [maxBytes].
  ///
  /// The size and bytes come from the same open handle. A concurrent truncate
  /// or append is rejected, and partially read sensitive bytes are erased.
  static Future<Uint8List> readBoundedFile(
    File file, {
    required int maxBytes,
  }) async {
    if (maxBytes <= 0) {
      throw const FormatException('File size limit is invalid');
    }
    RandomAccessFile? input = await file.open(mode: FileMode.read);
    Uint8List? bytes;
    var retained = false;
    try {
      final length = await input.length();
      if (length <= 0 || length > maxBytes) {
        throw const FormatException('File size is invalid');
      }
      bytes = Uint8List(length);
      var offset = 0;
      while (offset < length) {
        final read = await input.readInto(bytes, offset, length);
        if (read <= 0) {
          throw const FormatException('File changed while it was being read');
        }
        offset += read;
      }
      if (await input.readByte() != -1) {
        throw const FormatException('File changed while it was being read');
      }
      await input.close();
      input = null;
      retained = true;
      return bytes;
    } finally {
      if (!retained) bytes?.fillRange(0, bytes.length, 0);
      try {
        await input?.close();
      } on FileSystemException {
        // Preserve the original validation/read error.
      }
    }
  }

  /// Copies an app-owned export source through a fixed-size buffer.
  ///
  /// Like [readBoundedFile], this binds validation and reads to one handle and
  /// rejects a file which changes length during the operation.
  static Future<void> copyBoundedFile(
    File source,
    File destination, {
    required int maxBytes,
  }) async {
    if (maxBytes <= 0) {
      throw const FormatException('File size limit is invalid');
    }
    RandomAccessFile? input = await source.open(mode: FileMode.read);
    RandomAccessFile? output;
    final buffer = Uint8List(maxBytes < 64 * 1024 ? maxBytes : 64 * 1024);
    var completed = false;
    try {
      final length = await input.length();
      if (length <= 0 || length > maxBytes) {
        throw const FormatException('File size is invalid');
      }
      output = await destination.open(mode: FileMode.write);
      var remaining = length;
      while (remaining > 0) {
        final requested = remaining < buffer.length ? remaining : buffer.length;
        final read = await input.readInto(buffer, 0, requested);
        if (read <= 0) {
          throw const FormatException('File changed while it was being copied');
        }
        await output.writeFrom(buffer, 0, read);
        remaining -= read;
      }
      if (await input.readByte() != -1) {
        throw const FormatException('File changed while it was being copied');
      }
      await output.flush();
      await output.close();
      output = null;
      await input.close();
      input = null;
      completed = true;
    } finally {
      buffer.fillRange(0, buffer.length, 0);
      try {
        await output?.close();
      } on FileSystemException {
        // Preserve the original validation/copy error.
      }
      if (!completed) {
        try {
          await input?.close();
        } on FileSystemException {
          // Preserve the original validation/copy error.
        }
        try {
          if (await destination.exists()) await destination.delete();
        } on FileSystemException {
          // The caller also performs best-effort managed-cache cleanup.
        }
      }
    }
  }

  static bool isManagedImportCopy(File file, Directory cacheDirectory) {
    final parent = file.parent;
    return _normalized(parent.parent.path) ==
            _normalized(cacheDirectory.path) &&
        _basename(parent.path).startsWith(_dialogDirectoryPrefix);
  }

  static Future<void> deleteManagedImportCopy(
    File file,
    Directory cacheDirectory,
  ) async {
    if (!isManagedImportCopy(file, cacheDirectory)) return;
    try {
      if (await file.exists()) await file.delete();
      final parent = file.parent;
      if (await parent.exists() &&
          await parent.list(followLinks: false).isEmpty) {
        await parent.delete();
      }
    } on FileSystemException {
      // Cache cleanup must not turn a completed import into an error.
    }
  }

  /// Reserves a unique app-private source path for one export operation.
  /// Keeping each source in its own directory prevents overlapping Storage
  /// Access Framework requests from overwriting or deleting each other's data.
  static Future<File> createManagedExportFile(
    Directory cacheDirectory,
    String fileName,
  ) async {
    if (!_isSafeLeafName(fileName)) {
      throw const FormatException('Export filename is invalid');
    }
    final directory = await cacheDirectory.createTemp(_exportDirectoryPrefix);
    return File('${directory.path}/$fileName');
  }

  static bool isManagedExportFile(File file, Directory cacheDirectory) {
    final parent = file.parent;
    return _normalized(parent.parent.path) ==
            _normalized(cacheDirectory.path) &&
        _basename(parent.path).startsWith(_exportDirectoryPrefix) &&
        _isSafeLeafName(_basename(file.path));
  }

  static Future<void> deleteManagedExportFile(
    File file,
    Directory cacheDirectory,
  ) async {
    if (!isManagedExportFile(file, cacheDirectory)) return;
    try {
      if (await file.exists()) await file.delete();
      final parent = file.parent;
      if (await parent.exists() &&
          await parent.list(followLinks: false).isEmpty) {
        await parent.delete();
      }
    } on FileSystemException {
      // Cache cleanup must not turn a completed export into an error.
    }
  }

  static Future<void> cleanupStaleFiles(Directory cacheDirectory) async {
    if (!await cacheDirectory.exists()) return;
    try {
      await for (final entity in cacheDirectory.list(followLinks: false)) {
        final name = _basename(entity.path);
        try {
          if (entity is Directory &&
              (name.startsWith(_dialogDirectoryPrefix) ||
                  name.startsWith(_exportDirectoryPrefix))) {
            await entity.delete(recursive: true);
          } else if (entity is File && _isManagedTopLevelFile(name)) {
            await entity.delete();
          }
        } on FileSystemException {
          // Continue cleaning other independently managed cache artifacts.
        }
      }
    } on FileSystemException {
      // A best-effort startup cleanup must not prevent app initialization.
    }
  }

  static bool _isManagedTopLevelFile(String name) {
    if (_temporaryBackupNames.contains(name)) return true;
    final lower = name.toLowerCase();
    final currentExport =
        (name.startsWith(_caExportPrefix) && lower.endsWith('.frpca')) ||
        (name.startsWith(_tlsExportPrefix) && lower.endsWith('.frptls'));
    if (currentExport) return true;

    // Compatibility cleanup for export filenames used before controlled
    // prefixes were introduced. These are still constrained to safe filename
    // characters and the app-private top-level cache directory.
    return RegExp(
      r'^[A-Za-z0-9._-]+\.(?:frpca|frptls)$',
      caseSensitive: false,
    ).hasMatch(name);
  }

  static String _normalized(String path) =>
      Uri.file(File(path).absolute.path).normalizePath().path;

  static bool _isSafeLeafName(String value) =>
      value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains(r'\') &&
      !value.contains('\x00');

  static String _basename(String path) {
    final segments = Uri.file(path).pathSegments
        .where((part) => part.isNotEmpty);
    return segments.isEmpty ? '' : segments.last;
  }
}
