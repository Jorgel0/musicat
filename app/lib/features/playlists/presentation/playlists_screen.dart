import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/invite/pending_invite.dart';
import 'create_or_join_joint_playlist_sheet.dart';
import 'joint_playlist_providers.dart';
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
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeHandlePendingInvite(ref.read(pendingInviteProvider)),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// Handles a pending playlist invite (deep link, see `pending_invite.dart`)
  /// once this screen is up: if [pending]'s id is already one of this
  /// device's joint playlists, go straight to it; otherwise open the
  /// create/join sheet pre-filled so the user can review and join. Leaves
  /// anything else (a friend invite, a parse error) for `FriendsScreen` /
  /// `AppShell` to handle.
  Future<void> _maybeHandlePendingInvite(PendingInvite? pending) async {
    if (pending is! PendingPlaylistInvite) return;
    ref.read(pendingInviteProvider.notifier).consume();
    final invite = pending.invite;

    var alreadyJoined = false;
    try {
      final playlists = await ref.read(jointPlaylistsProvider.future);
      alreadyJoined = playlists.any((p) => p.id == invite.id);
    } catch (_) {
      alreadyJoined = false;
    }
    if (!mounted) return;

    if (alreadyJoined) {
      context.push('/joint-playlists/${invite.id}');
    } else {
      showCreateOrJoinJointPlaylistSheet(
        context,
        prefillId: invite.id,
        prefillName: invite.name,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PendingInvite?>(
      pendingInviteProvider,
      (previous, next) => _maybeHandlePendingInvite(next),
    );

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
