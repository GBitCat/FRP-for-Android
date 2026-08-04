import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';

import '../services/config_import_export.dart';
import '../state/app_state.dart';
import '../widgets/app_card.dart';
import 'logs_screen.dart';

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

  Future<void> _importConfig(BuildContext context) async {
    try {
      final path = await FlutterFileDialog.pickFile(params: OpenFileDialogParams(
        mimeTypesFilter: ['application/json', 'application/zip'],
        copyFileToCacheDir: true,
      ));
      if (path == null || path.isEmpty) return;
      final bytes = await File(path).readAsBytes();
      final data = ConfigImportExport.parseImportBytes(bytes);
      final count = await appState.applyImport(data);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(data == null
            ? 'Failed to parse config file'
            : 'Imported $count configurations'),
      ));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to import config')),
      );
    }
  }

  Future<void> _exportConfig(BuildContext context) async {
    if (appState.configs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No configs to export')),
      );
      return;
    }
    try {
      final zip = ConfigImportExport.buildExportZip(
        appState.configs,
        appState.server,
        appState.buildFullToml(),
      );
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/frp_backup.zip')..writeAsBytesSync(zip);
      final saved = await FlutterFileDialog.saveFile(params: SaveFileDialogParams(
        sourceFilePath: file.path,
        fileName: 'frp_backup.zip',
        mimeTypesFilter: ['application/zip'],
      ));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(saved != null
            ? 'Exported backup.zip (json + toml)'
            : 'Export cancelled'),
      ));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to export config')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = appState;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionTitle('General'),
            AppCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.brightness_6_outlined),
                    title: const Text('Theme mode'),
                    subtitle: DropdownButtonFormField<ThemeMode>(
                      initialValue: state.theme.mode,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: ThemeMode.system, child: Text('System')),
                        DropdownMenuItem(
                            value: ThemeMode.light, child: Text('Light')),
                        DropdownMenuItem(
                            value: ThemeMode.dark, child: Text('Dark')),
                      ],
                      onChanged: (m) {
                        if (m == null) return;
                        appState.theme = state.theme.copyWith(mode: m);
                        appState.notify();
                      },
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
                            onTap: () {
                              appState.theme =
                                  state.theme.copyWith(accentIndex: i);
                              appState.notify();
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
                                        color: Theme.of(context).colorScheme.onSurface,
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
                    leading: const Icon(Icons.data_usage),
                    title: const Text('Traffic statistics'),
                    subtitle: const Text(
                        'Monitor real-time traffic speed (may cost CPU)'),
                    trailing: Switch(
                      value: state.trafficEnabled,
                      onChanged: (v) {
                        appState.trafficEnabled = v;
                        appState.notify();
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
                    leading: const Icon(Icons.history),
                    title: const Text('Log retention'),
                    subtitle: const Text('Keep logs for 7 days'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.list_alt_outlined),
                    title: const Text('View logs'),
                    subtitle: const Text('Open frpc log viewer'),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const LogsScreen()),
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
                    subtitle: const Text('Import from JSON / zip backup file'),
                    onTap: () => _importConfig(context),
                  ),
                  ListTile(
                    leading: const Icon(Icons.file_download_outlined),
                    title: const Text('Export Config'),
                    subtitle: const Text('Export backup.zip (json + toml)'),
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
                subtitle: const Text('0.1.1'),
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
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }
}
