import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';

import '../services/config_import_export.dart';
import '../services/frp_engine.dart';
import '../state/app_state.dart';
import '../widgets/app_card.dart';
import '../widgets/glass_sliver_appbar.dart';
import 'logs_screen.dart';

/// 缓存版本号，避免每次重建都走原生调用
final Future<String> _appVersion = FrpEngine.instance.getVersionName();

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
      final path = await FlutterFileDialog.pickFile(
        params: OpenFileDialogParams(
          mimeTypesFilter: ['application/json', 'application/zip'],
          copyFileToCacheDir: true,
        ),
      );
      if (path == null || path.isEmpty) return;
      final bytes = await File(path).readAsBytes();
      final data = ConfigImportExport.parseImportBytes(bytes);
      final count = await appState.applyImport(data);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            data == null
                ? 'Failed to parse config file'
                : 'Imported $count configurations',
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to import config')));
    }
  }

  Future<void> _exportConfig(BuildContext context) async {
    if (appState.configs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No configs to export')));
      return;
    }
    try {
      final zip = ConfigImportExport.buildExportZip(
        appState.configs,
        appState.servers,
        appState.selectedServerId,
        appState.buildAllServerTomls(),
      );
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/frp_backup.zip')..writeAsBytesSync(zip);
      final saved = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          sourceFilePath: file.path,
          fileName: 'frp_backup.zip',
          mimeTypesFilter: ['application/zip'],
        ),
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved != null
                ? 'Exported backup.zip (all servers + configs)'
                : 'Export cancelled',
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to export config')));
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
                          subtitle: DropdownButtonFormField<ThemeMode>(
                            initialValue: state.theme.mode,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                            ),
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
                            onChanged: (m) {
                              if (m == null) return;
                              appState.setTheme(state.theme.copyWith(mode: m));
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
                                    appState.setTheme(
                                      state.theme.copyWith(accentIndex: i),
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
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurface,
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
                            onChanged: (v) => state.setHideFromRecents(v),
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
                            'Import from JSON / zip backup file',
                          ),
                          onTap: () => _importConfig(context),
                        ),
                        ListTile(
                          leading: const Icon(Icons.file_download_outlined),
                          title: const Text('Export Config'),
                          subtitle: const Text(
                            'Export all servers and configs (contains plaintext secrets)',
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
