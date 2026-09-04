import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/backup_crypto.dart';
import '../services/config_import_export.dart';
import '../services/document_io.dart';
import '../services/frp_engine.dart';
import '../services/sensitive_file_cache.dart';
import '../state/app_state.dart';
import '../widgets/app_card.dart';
import '../widgets/glass_sliver_appbar.dart';
import 'logs_screen.dart';

/// 缓存版本号，避免每次重建都走原生调用
final Future<String> _appVersion = FrpEngine.instance.getVersionName();

enum _ExportMode { redacted, encrypted }

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const _accents = [
    Color(0xFF3B6CF6),
    Color(0xFFE91E63),
    Color(0xFF4CAF50),
    Color(0xFFFF9800),
    Color(0xFF9C27B0),
    Color(0xFF00BCD4),
    Color(0xFF795548),
  ];

  Future<void> _applySetting(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to save setting')));
    }
  }

  Future<void> _importConfig(BuildContext context) async {
    File? managedImportCopy;
    Directory? importCacheDirectory;
    final inMemoryFiles = <Uint8List>[];
    try {
      final path = await DocumentIo.pickFile(
        mimeTypes: const [
          'application/json',
          'application/zip',
          'application/octet-stream',
        ],
      );
      if (path == null || path.isEmpty) return;
      final file = File(path);
      final cacheDirectory = await getTemporaryDirectory();
      if (SensitiveFileCache.isManagedImportCopy(file, cacheDirectory)) {
        managedImportCopy = file;
        importCacheDirectory = cacheDirectory;
      }
      var bytes = await SensitiveFileCache.readBoundedFile(
        file,
        maxBytes: BackupCrypto.maxEncryptedBytes,
      );
      inMemoryFiles.add(bytes);
      if (BackupCrypto.isEncrypted(bytes)) {
        if (!context.mounted) return;
        final password = await _requestPassword(
          context,
          title: 'Decrypt backup',
        );
        if (password == null || !context.mounted) return;
        bytes = await BackupCrypto.decrypt(bytes, password);
        inMemoryFiles.add(bytes);
      }
      final data = ConfigImportExport.parseImportBytes(bytes);
      final count = await appState.applyImport(data);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            data == null
                ? 'Failed to parse config file'
                : data.redacted
                ? 'Imported $count redacted configurations; re-enter credentials'
                : 'Imported $count configurations',
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to import config')));
    } finally {
      for (final bytes in inMemoryFiles) {
        bytes.fillRange(0, bytes.length, 0);
      }
      if (managedImportCopy != null && importCacheDirectory != null) {
        await SensitiveFileCache.deleteManagedImportCopy(
          managedImportCopy,
          importCacheDirectory,
        );
      }
    }
  }

  Future<void> _exportConfig(BuildContext context) async {
    if (appState.configs.isEmpty && appState.servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No configuration to export')),
      );
      return;
    }
    final mode = await showDialog<_ExportMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export configuration'),
        content: const Text(
          'Redacted export clears recognized credential assignments while preserving '
          'manual TOML structure. Review custom fields before sharing. '
          'Use an encrypted backup when credentials must be portable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ExportMode.encrypted),
            child: const Text('Encrypted'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ExportMode.redacted),
            child: const Text('Export redacted'),
          ),
        ],
      ),
    );
    if (mode == null || !context.mounted) return;
    String? password;
    if (mode == _ExportMode.encrypted) {
      password = await _requestPassword(
        context,
        title: 'Protect backup',
        confirm: true,
      );
      if (password == null || !context.mounted) return;
    }
    File? temporaryFile;
    Directory? exportCacheDirectory;
    final inMemoryFiles = <Uint8List>[];
    try {
      final includeSecrets = mode == _ExportMode.encrypted;
      var bytes = ConfigImportExport.buildExportZip(
        appState.configs,
        appState.servers,
        appState.selectedServerId,
        includeSecrets ? appState.buildAllServerTomls() : const {},
        includeSecrets: includeSecrets,
      );
      inMemoryFiles.add(bytes);
      if (mode == _ExportMode.encrypted) {
        bytes = await BackupCrypto.encrypt(bytes, password!);
        inMemoryFiles.add(bytes);
      }
      exportCacheDirectory = await getTemporaryDirectory();
      final encrypted = mode == _ExportMode.encrypted;
      final fileName = encrypted
          ? 'frp_backup.frpbackup'
          : 'frp_backup_redacted.zip';
      temporaryFile = await SensitiveFileCache.createManagedExportFile(
        exportCacheDirectory,
        fileName,
      );
      await temporaryFile.writeAsBytes(bytes, flush: true);
      final saved = await DocumentIo.saveFile(
        sourceFilePath: temporaryFile.path,
        fileName: fileName,
        mimeTypes: [encrypted ? 'application/octet-stream' : 'application/zip'],
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved != null
                ? encrypted
                      ? 'Exported password-encrypted backup'
                      : 'Exported backup with recognized credentials cleared'
                : 'Export cancelled',
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to export config')));
    } finally {
      for (final bytes in inMemoryFiles) {
        bytes.fillRange(0, bytes.length, 0);
      }
      if (temporaryFile != null && exportCacheDirectory != null) {
        await SensitiveFileCache.deleteManagedExportFile(
          temporaryFile,
          exportCacheDirectory,
        );
      }
    }
  }

  Future<String?> _requestPassword(
    BuildContext context, {
    required String title,
    bool confirm = false,
  }) async {
    final password = TextEditingController();
    final confirmation = TextEditingController();
    String? error;
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: password,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Password (12+ characters)',
                    errorText: error,
                  ),
                ),
                if (confirm) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmation,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Confirm password',
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (password.text.length < BackupCrypto.minPasswordLength) {
                    setState(() => error = 'Use at least 12 characters');
                  } else if (password.text.length >
                      BackupCrypto.maxPasswordLength) {
                    setState(() => error = 'Use at most 1024 characters');
                  } else if (confirm && password.text != confirmation.text) {
                    setState(() => error = 'Passwords do not match');
                  } else {
                    Navigator.of(dialogContext).pop(password.text);
                  }
                },
                child: Text(confirm ? 'Encrypt' : 'Decrypt'),
              ),
            ],
          ),
        ),
      );
    } finally {
      password.clear();
      confirmation.clear();
      password.dispose();
      confirmation.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = appState;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return CustomScrollView(
          slivers: [
            const GlassSliverAppBar(title: 'Settings'),
            SliverPadding(
              // 底部留白：避免最后一张卡片（About/Version）被底部导航遮挡
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _SectionTitle('General'),
                  AppCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.brightness_6_outlined),
                          title: const Text('Theme mode'),
                          subtitle: InputDecorator(
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<ThemeMode>(
                                value: state.theme.mode,
                                isExpanded: true,
                                isDense: true,
                                items: const [
                                  DropdownMenuItem(
                                    value: ThemeMode.system,
                                    child: Text('System'),
                                  ),
                                  DropdownMenuItem(
                                    value: ThemeMode.light,
                                    child: Text('Light'),
                                  ),
                                  DropdownMenuItem(
                                    value: ThemeMode.dark,
                                    child: Text('Dark'),
                                  ),
                                ],
                                onChanged: (m) async {
                                  if (m == null) return;
                                  await _applySetting(
                                    context,
                                    () => appState.setThemeMode(m),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                        ListTile(
                          leading: const Icon(Icons.palette_outlined),
                          title: const Text('Theme color'),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: List.generate(_accents.length, (i) {
                                final selected = state.theme.accentIndex == i;
                                return GestureDetector(
                                  onTap: () async {
                                    await _applySetting(
                                      context,
                                      () => appState.setThemeAccent(i),
                                    );
                                  },
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      color: _accents[i],
                                      shape: BoxShape.circle,
                                      border: selected
                                          ? Border.all(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface,
                                              width: 2,
                                            )
                                          : null,
                                    ),
                                    child: Center(
                                      child: Text(
                                        'A',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(color: Colors.white),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                        ),
                        ListTile(
                          leading: const Icon(Icons.visibility_off),
                          title: const Text('Hide from recent apps'),
                          subtitle: const Text(
                            'App will not appear in the recent apps list',
                          ),
                          trailing: Switch(
                            value: state.hideFromRecents,
                            onChanged: (v) async {
                              await _applySetting(
                                context,
                                () => state.setHideFromRecents(v),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),
                  _SectionTitle('Logs'),
                  AppCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.list_alt_outlined),
                          title: const Text('View logs'),
                          subtitle: const Text(
                            'In-memory log viewer (up to 2000 lines)',
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const LogsScreen(),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),
                  _SectionTitle('Data'),
                  AppCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.file_upload_outlined),
                          title: const Text('Import Config'),
                          subtitle: const Text(
                            'Import JSON, zip or password-encrypted backup',
                          ),
                          onTap: () => _importConfig(context),
                        ),
                        ListTile(
                          leading: const Icon(Icons.file_download_outlined),
                          title: const Text('Export Config'),
                          subtitle: const Text(
                            'Redacted export preserves structure; encrypted export includes credentials',
                          ),
                          onTap: () => _exportConfig(context),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),
                  _SectionTitle('About'),
                  AppCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('Version'),
                      subtitle: FutureBuilder<String>(
                        future: _appVersion,
                        builder: (context, snap) => Text(snap.data ?? '...'),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}
