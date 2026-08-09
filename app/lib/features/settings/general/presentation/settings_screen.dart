import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/design_system/theme.dart';
import '../../../library/presentation/library_providers.dart';
import '../../../library/presentation/pick_and_scan_folder.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final accentColor = ref.watch(accentColorProvider);
    final foldersAsync = ref.watch(watchedFoldersProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Appearance'),
          ListTile(
            title: const Text('Theme'),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode),
                  label: Text('Dark'),
                ),
              ],
              selected: {themeMode},
              onSelectionChanged: (selection) =>
                  ref.read(themeModeProvider.notifier).update(selection.first),
            ),
          ),
          ListTile(
            title: const Text('Accent color'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 12,
                children: MusicatTheme.accentOptions.map((color) {
                  final selected = color.toARGB32() == accentColor.toARGB32();
                  return InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () =>
                        ref.read(accentColorProvider.notifier).update(color),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: color,
                      child: selected
                          ? const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 18,
                            )
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const Divider(height: 32),
          const _SectionHeader('Audio'),
          ListTile(
            leading: const Icon(Icons.graphic_eq),
            title: const Text('Equalizer'),
            subtitle: const Text('Android only, for now'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/equalizer'),
          ),
          const Divider(height: 32),
          const _SectionHeader('Library folders'),
          foldersAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, stackTrace) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: $error'),
            ),
            data: (folders) {
              if (folders.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('No folders added yet.'),
                );
              }
              return Column(
                children: folders
                    .map((path) => _FolderTile(path: path))
                    .toList(),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add folder'),
              onPressed: () => pickAndScanFolder(context, ref),
            ),
          ),
          const Divider(height: 32),
          const _SectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About Musicat'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'Musicat',
              applicationLegalese: '© Musicat contributors — MIT License',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Open-source licenses'),
            onTap: () =>
                showLicensePage(context: context, applicationName: 'Musicat'),
          ),
        ],
      ),
    );
  }
}

class _FolderTile extends ConsumerWidget {
  const _FolderTile({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-scan',
            onPressed: () => _rescan(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Forget this folder',
            onPressed: () =>
                ref.read(libraryRepositoryProvider).removeFolder(path),
          ),
        ],
      ),
    );
  }

  Future<void> _rescan(BuildContext context, WidgetRef ref) async {
    final imported = await ref.read(libraryScannerProvider).scanFolder(path);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Imported $imported track(s).')));
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
