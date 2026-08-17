import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'create_or_join_joint_playlist_sheet.dart';
import 'joint_playlists_tab.dart';
import 'local_playlists_tab.dart';
import 'playlist_providers.dart';
import 'prompt_playlist_name.dart';

class PlaylistsScreen extends ConsumerStatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  ConsumerState<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends ConsumerState<PlaylistsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Mine'),
            Tab(text: 'Joint'),
          ],
        ),
      ),
      floatingActionButton: _tabController.index == 0
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('New playlist'),
              onPressed: () => _createLocalPlaylist(context),
            )
          : FloatingActionButton.extended(
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('New joint playlist'),
              onPressed: () => showCreateOrJoinJointPlaylistSheet(context),
            ),
      body: TabBarView(
        controller: _tabController,
        children: const [LocalPlaylistsTab(), JointPlaylistsTab()],
      ),
    );
  }

  Future<void> _createLocalPlaylist(BuildContext context) async {
    final name = await promptPlaylistName(context);
    if (name == null || name.trim().isEmpty) return;
    await ref.read(playlistRepositoryProvider).createPlaylist(name.trim());
  }
}
