import 'dart:io';

/// Owns temporary files created while importing or exporting backups.
///
/// Cleanup is deliberately restricted to exact app-owned filenames and
/// immediate `file_dialog-*` children of the app cache directory. A caller can
/// therefore never delete the original document selected by the user.
class SensitiveFileCache {
  static const _dialogDirectoryPrefix = 'file_dialog-';
  static const _temporaryBackupNames = {
    'frp_backup.frpbackup',
    'frp_backup_redacted.zip',
    'frp_backup.zip',
  };

  const SensitiveFileCache._();

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

  static Future<void> cleanupStaleFiles(Directory cacheDirectory) async {
    if (!await cacheDirectory.exists()) return;
    try {
      await for (final entity in cacheDirectory.list(followLinks: false)) {
        final name = _basename(entity.path);
        if (entity is Directory && name.startsWith(_dialogDirectoryPrefix)) {
          await entity.delete(recursive: true);
        } else if (entity is File && _temporaryBackupNames.contains(name)) {
          await entity.delete();
        }
      }
    } on FileSystemException {
      // A best-effort startup cleanup must not prevent app initialization.
    }
  }

  static String _normalized(String path) =>
      Uri.file(File(path).absolute.path).normalizePath().path;

  static String _basename(String path) {
    final segments = Uri.file(
      path,
    ).pathSegments.where((part) => part.isNotEmpty);
    return segments.isEmpty ? '' : segments.last;
  }
}
