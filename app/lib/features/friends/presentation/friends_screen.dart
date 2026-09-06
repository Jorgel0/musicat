import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/embedded_server/default_relay.dart';
import '../../../core/embedded_server/embedded_server.dart';
import '../../../core/invite/invite_uri.dart';
import '../../../core/invite/pending_invite.dart';
import '../../../core/network/federation/federation_client.dart';
import '../domain/musicat_server_config.dart';
import 'account_controller.dart';
import 'add_friend_sheet.dart';
import 'android_background_reachability_controller.dart';
import 'friend_requests_section.dart';
import 'friends_controller.dart';
import 'musicat_server_config_controller.dart';

/// Wraps [FriendsScreen]'s body; the actual screen also needs to notice a
/// pending friend invite (deep link, see `pending_invite.dart`) and open
/// the Add Friend sheet pre-filled, which needs a [State] to hook a
/// post-frame callback — hence [ConsumerStatefulWidget] rather than the
/// simpler [ConsumerWidget] most other top-level screens use.
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeOpenPendingInvite(ref.read(pendingInviteProvider));
      // Re-check for friend requests every time this screen is opened —
      // the moment someone is actually looking. Deliberately in a
      // post-frame callback, not in `build`/`initState` directly: writing
      // to a provider from either is the crash this project has already
      // shipped twice (ADR 0037/0039). A no-op when signed out.
      unawaited(ref.read(friendRequestsProvider.notifier).refresh());
    });
  }

  /// Opens the Add Friend sheet pre-filled if [pending] is a friend invite
  /// that hasn't been shown yet. Deliberately leaves anything else (a
  /// playlist invite, a parse error) untouched — those are some other
  /// screen's concern (`PlaylistsScreen`, `AppShell`).
  void _maybeOpenPendingInvite(PendingInvite? pending) {
    if (pending is! PendingFriendInvite) return;
    ref.read(pendingInviteProvider.notifier).consume();
    _showAddFriendSheet(context, ref, prefill: pending.invite);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PendingInvite?>(
      pendingInviteProvider,
      (previous, next) => _maybeOpenPendingInvite(next),
    );
    // Android only (a no-op everywhere else, see
    // `setAndroidBackgroundReachable`) — keeps this device's real
    // background-service mode in sync with its live friend count for as
    // long as this screen (the only place a friend can ever be added)
    // stays open. See `android_background_reachability_controller.dart`.
    ref.watch(androidBackgroundReachabilityEffectProvider);

    final config = ref.watch(effectiveMusicatServerConfigProvider);
    // Purely a UI nicety: while the embedded server is still starting up
    // (NAT traversal/STUN can take a few seconds), `config.isConfigured`
    // is `false` same as "genuinely unconfigured" — without this, the
    // "Set up Musicat Server" prompt (which has nothing to actually do on
    // the common desktop path any more) would flash briefly on every cold
    // start before flipping over to the friends list.
    final startingEmbeddedServer =
        ref.watch(
          musicatServerConfigControllerProvider.select(
            (c) => c.useEmbeddedServer,
          ),
        ) &&
        ref.watch(embeddedServerProvider).isLoading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Friends'),
        actions: [
          if (config.isConfigured)
            IconButton(
              tooltip: 'My profile',
              icon: const Icon(Icons.badge_outlined),
              onPressed: () => context.push('/my-profile'),
            ),
          IconButton(
            tooltip: 'Musicat Server settings',
            icon: const Icon(Icons.dns_outlined),
            onPressed: () => _showServerConfigSheet(context, ref),
          ),
        ],
      ),
      body: config.isConfigured
          // The account strip and any waiting friend requests sit above
          // the list itself, so neither is something to go looking for —
          // and both are absent entirely for a device that never signs
          // in, which keeps working exactly as it did before accounts.
          ? const Column(
              children: [
                AccountHeaderTile(),
                FriendRequestsSection(),
                Expanded(child: _FriendsList()),
              ],
            )
          : startingEmbeddedServer
          ? const _StartingEmbeddedServer()
          : _ServerSetupPrompt(
              onConfigure: () => _showServerConfigSheet(context, ref),
            ),
      floatingActionButton: config.isConfigured
          ? FloatingActionButton(
              onPressed: () => _showAddFriendSheet(context, ref),
              child: const Icon(Icons.person_add_alt),
            )
          : null,
    );
  }

  void _showServerConfigSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _ServerConfigSheet(),
    );
  }

  void _showAddFriendSheet(
    BuildContext context,
    WidgetRef ref, {
    FriendInvite? prefill,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => AddFriendSheet(prefill: prefill),
    );
  }
}

/// Shown instead of [_ServerSetupPrompt] while this device's own embedded
/// Musicat Server is still starting up — see
/// `_FriendsScreenState.build`'s `startingEmbeddedServer`.
class _StartingEmbeddedServer extends StatelessWidget {
  const _StartingEmbeddedServer();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Starting your Musicat Server…', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ServerSetupPrompt extends StatelessWidget {
  const _ServerSetupPrompt({required this.onConfigure});

  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Connect this device to your own Musicat Server to add '
              'friends and share music.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onConfigure,
              child: const Text('Set up Musicat Server'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendsList extends ConsumerWidget {
  const _FriendsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(friendsControllerProvider);

    if (state.error != null) {
      return Center(child: Text('Could not reach your Musicat Server.'));
    }
    if (state.friends.isEmpty) {
      return const Center(child: Text('No friends yet — tap + to add one.'));
    }

    return RefreshIndicator(
      // Refreshes both halves of this screen: pulling down on a friends
      // list is also how someone asks "any new requests?".
      onRefresh: () async {
        await ref.read(friendRequestsProvider.notifier).refresh();
        await ref.read(friendsControllerProvider.notifier).refresh();
      },
      child: ListView.builder(
        itemCount: state.friends.length,
        itemBuilder: (context, index) {
          final entry = state.friends[index];
          final connected = entry.status?.connected ?? false;
          final hasRelay = entry.friend.relayUrl != null;
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: connected ? Colors.green : Colors.grey,
              child: const Icon(Icons.person, color: Colors.white),
            ),
            title: Text(entry.friend.displayLabel),
            subtitle: Text(connected ? 'Connected' : 'Not connected'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasRelay)
                  const Tooltip(
                    message: 'Has a relay fallback registered',
                    child: Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.cloud_queue, size: 20),
                    ),
                  ),
                IconButton(
                  tooltip: 'Remove friend',
                  icon: const Icon(Icons.person_remove_outlined),
                  onPressed: () =>
                      _confirmRemoveFriend(context, ref, entry.friend),
                ),
              ],
            ),
            onTap: () => context.push('/friends/${entry.friend.nodeId}'),
          );
        },
      ),
    );
  }

  /// Asks before removing [friend], by name.
  ///
  /// This is the one action on this screen that cannot be taken back from
  /// here: the removal is immediate and permanent locally (this device
  /// keeps a record that stops any later sync from bringing them back),
  /// and it throws away the address and the name this device had learned
  /// for them. It sits a few pixels from the row's own tap target, so
  /// hitting it by accident was always going to happen eventually.
  ///
  /// Same dialog idiom as the sign-out confirmation in
  /// `account_screen.dart` — which guards the *harmless* action, and until
  /// now was the only confirmation anywhere in this feature.
  Future<void> _confirmRemoveFriend(
    BuildContext context,
    WidgetRef ref,
    FederationFriend friend,
  ) async {
    final name = friend.displayLabel;
    // Both captured before the dialog's own await, so nothing reaches for
    // a context/provider through a widget that may be gone by then.
    final controller = ref.read(friendsControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $name?'),
        content: Text(
          '$name will no longer be able to see anything you share, and '
          'this device forgets the name and address it had for them. You '
          'can add each other again later, but it starts from scratch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.removeFriend(friend.nodeId);
      messenger.showSnackBar(SnackBar(content: Text('Removed $name.')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not remove $name right now. Try again.')),
      );
    }
  }
}

class _ServerConfigSheet extends ConsumerStatefulWidget {
  const _ServerConfigSheet();

  @override
  ConsumerState<_ServerConfigSheet> createState() => _ServerConfigSheetState();
}

class _ServerConfigSheetState extends ConsumerState<_ServerConfigSheet> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _myAddressController;
  late final TextEditingController _myDisplayNameController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _relayUrlController;
  final _usernameController = TextEditingController();
  late bool _useEmbeddedServer;
  bool _claimingUsername = false;
  String? _usernameError;

  @override
  void initState() {
    super.initState();
    final config = ref.read(musicatServerConfigControllerProvider);
    _hostController = TextEditingController(text: config.host);
    _portController = TextEditingController(text: config.port.toString());
    _myAddressController = TextEditingController(text: config.myPublicAddress);
    _myDisplayNameController = TextEditingController(
      text: config.myDisplayName,
    );
    _apiKeyController = TextEditingController(text: config.apiKey);
    _relayUrlController = TextEditingController(text: config.relayUrl);
    _useEmbeddedServer = config.useEmbeddedServer;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _myAddressController.dispose();
    _myDisplayNameController.dispose();
    _apiKeyController.dispose();
    _relayUrlController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  /// Claims [_usernameController]'s text on this device's own
  /// currently-connected relay (see [FederationClient.setUsername]) —
  /// only ever invoked while that relay connection is up, since the
  /// "Claim" button is only shown then in the first place. A 409 ("already
  /// taken") is worth spelling out plainly rather than surfacing the raw
  /// exception text.
  Future<void> _claimUsername() async {
    final client = ref.read(federationClientProvider);
    if (client == null) return;
    final username = _usernameController.text.trim();
    setState(() {
      _claimingUsername = true;
      _usernameError = null;
    });
    try {
      await client.setUsername(username);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Username "$username" claimed.')),
        );
      }
    } on FederationClientException catch (e) {
      setState(() {
        _usernameError = e.statusCode == 409
            ? 'That username is already taken — try another one.'
            : e.message;
      });
    } catch (e) {
      setState(() => _usernameError = 'Could not claim a username: $e');
    } finally {
      if (mounted) setState(() => _claimingUsername = false);
    }
  }

  Future<void> _save() async {
    final myDisplayName = _myDisplayNameController.text.trim();
    final apiKey = _apiKeyController.text.trim();
    final relayUrl = _relayUrlController.text.trim();
    final previousRelayUrl =
        ref.read(musicatServerConfigControllerProvider).relayUrl ?? '';
    final config = MusicatServerConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 8080,
      myPublicAddress: _myAddressController.text.trim(),
      myDisplayName: myDisplayName.isEmpty ? null : myDisplayName,
      useEmbeddedServer: _useEmbeddedServer,
      apiKey: apiKey.isEmpty ? null : apiKey,
      // Empty means "use the one Musicat comes with" (see
      // `resolveRelayUrl`), which is resolved when the server starts, not
      // stored here — so this only ever holds a relay the user typed
      // themselves, and a default can never overwrite it.
      relayUrl: relayUrl.isEmpty ? null : relayUrl,
    );
    // Captured before the await: this sheet is popped right after.
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(musicatServerConfigControllerProvider.notifier).save(config);
    if (!mounted) return;
    Navigator.of(context).pop();
    // The hint under the field already says a relay change needs a
    // restart, but a hint you read a minute ago is not a reminder at the
    // moment it becomes true.
    if (relayUrl != previousRelayUrl) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Saved. Restart Musicat to start using it.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final myNodeInfoAsync = ref.watch(myNodeInfoProvider);

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      // Scrollable, same as the sibling _AddFriendSheet below: the new
      // "Use the built-in server" toggle (plus its explanatory subtitle)
      // made this sheet's content taller than a small window/short screen
      // can always show at once without this.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Musicat Server',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Where this device reaches your own Musicat Server, and the '
              'address to give friends so their server can reach yours.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _RelayStatusRow(myNodeInfoAsync: myNodeInfoAsync),
            const SizedBox(height: 12),
            _UsernameClaimSection(
              myNodeInfoAsync: myNodeInfoAsync,
              usernameController: _usernameController,
              claiming: _claimingUsername,
              error: _usernameError,
              onClaim: _claimUsername,
            ),
            const SizedBox(height: 12),
            // Only shown where an embedded server is even possible (Linux,
            // Windows, and — as of this round — Android too). On any other
            // platform the sheet looks exactly as it did before this
            // feature.
            if (embeddedServerSupported) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use the built-in server'),
                subtitle: const Text(
                  'Runs automatically on this device — no setup needed. Turn '
                  'off to point at a separately self-hosted server instead '
                  '(NAS, VPS, Docker Compose).',
                ),
                value: _useEmbeddedServer,
                onChanged: (value) =>
                    setState(() => _useEmbeddedServer = value),
              ),
              const SizedBox(height: 12),
            ],
            if (_useEmbeddedServer && embeddedServerSupported) ...[
              _EmbeddedServerStatusRow(
                embeddedAsync: ref.watch(embeddedServerProvider),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _relayUrlController,
                decoration: InputDecoration(
                  labelText: 'Relay URL (optional)',
                  // Only ever pre-filled with a relay the *user* set (see
                  // `_save`), so an empty field genuinely means "whatever
                  // this build comes with" — which is what the hint has to
                  // say, since the two cases lead to opposite conclusions
                  // about whether anything works.
                  hintText: ref.watch(defaultRelayUrlProvider).isEmpty
                      ? 'Lets friends on a different network reach this '
                            'device. This copy of Musicat does not come '
                            'with one — ask whoever gave it to you, or use '
                            'your own. Takes effect the next time you '
                            'restart the app.'
                      : 'Lets friends on a different network reach this '
                            'device. Leave it empty to use the one Musicat '
                            'comes with. Takes effect the next time you '
                            'restart the app.',
                ),
              ),
              const SizedBox(height: 12),
              // Android only: on Linux/Windows this app runs full-time
              // anyway, so there's no separate "background reachability"
              // concept distinct from "use the built-in server" itself.
              if (androidBackgroundReachabilitySupported) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep reachable in the background'),
                  subtitle: const Text(
                    'Shows a persistent notification so a friend can still '
                    'reach your shared music while Musicat is closed. Turns '
                    'on automatically once you add your first friend — use '
                    'this to force it on or off yourself instead.',
                  ),
                  value: ref.watch(desiredAndroidBackgroundReachableProvider),
                  onChanged: (value) => ref
                      .read(
                        androidBackgroundReachabilityOverrideProvider.notifier,
                      )
                      .save(value),
                ),
                const SizedBox(height: 12),
              ],
            ] else ...[
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  hintText: 'localhost',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _portController,
                decoration: const InputDecoration(labelText: 'Port'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                decoration: const InputDecoration(
                  labelText: 'API key (only needed for a remote server)',
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _myAddressController,
              decoration: const InputDecoration(
                labelText: 'Your address (given to friends)',
                hintText: 'mydomain.example:8080',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _myDisplayNameController,
              decoration: const InputDecoration(
                labelText: 'Your display name',
                hintText: 'Sent automatically when you add a friend',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}

/// Read-only status row telling the user whether *this device's own*
/// Musicat Server currently has a relay fallback connected (ADR
/// 0033/0034) — no raw relay URL shown, just a plain connected/not state.
class _RelayStatusRow extends StatelessWidget {
  const _RelayStatusRow({required this.myNodeInfoAsync});

  final AsyncValue<MyNodeInfo?> myNodeInfoAsync;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    return myNodeInfoAsync.when(
      loading: () => Row(
        children: [
          const SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('Checking relay status…', style: textStyle),
        ],
      ),
      error: (error, stackTrace) => Row(
        children: [
          Icon(
            Icons.help_outline,
            size: 16,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          Text('Relay status unavailable', style: textStyle),
        ],
      ),
      data: (info) {
        final connected = info?.relayUrl != null;
        return Row(
          children: [
            Icon(
              connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              connected ? 'Relay: connected' : 'Relay: not connected',
              style: textStyle,
            ),
          ],
        );
      },
    );
  }
}

/// Lets this device claim a friendly username on its own
/// currently-connected relay — so a friend can add it via
/// `_AddFriendSheet`'s "By username" mode instead of needing a raw
/// address. Only shown once [myNodeInfoAsync] resolves to a node with a
/// relay actually connected (`relayUrl` non-null): a relay is what stores
/// and serves the username directory, so there's nothing to claim
/// without one — a plain note is shown in its place otherwise.
class _UsernameClaimSection extends StatelessWidget {
  const _UsernameClaimSection({
    required this.myNodeInfoAsync,
    required this.usernameController,
    required this.claiming,
    required this.error,
    required this.onClaim,
  });

  final AsyncValue<MyNodeInfo?> myNodeInfoAsync;
  final TextEditingController usernameController;
  final bool claiming;
  final String? error;
  final Future<void> Function() onClaim;

  @override
  Widget build(BuildContext context) {
    final hasRelay = myNodeInfoAsync.value?.relayUrl != null;
    if (!hasRelay) {
      return Text(
        'Connect to a relay to claim a username.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: usernameController,
                decoration: const InputDecoration(
                  labelText: 'Your username (optional)',
                  hintText: 'lets a friend add you without your address',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                onPressed: claiming ? null : onClaim,
                child: claiming
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Claim'),
              ),
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}

/// Read-only status row shown in place of the host/port fields while
/// [MusicatServerConfig.useEmbeddedServer] is on — this device's own
/// server isn't something the user types in, just something to see the
/// state of (starting up, running on which port, or unavailable).
class _EmbeddedServerStatusRow extends StatelessWidget {
  const _EmbeddedServerStatusRow({required this.embeddedAsync});

  final AsyncValue<EmbeddedServerInfo?> embeddedAsync;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    return embeddedAsync.when(
      loading: () => Row(
        children: [
          const SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('Starting your built-in server…', style: textStyle),
        ],
      ),
      error: (error, stackTrace) => Row(
        children: [
          Icon(
            Icons.error_outline,
            size: 16,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          Text('Could not start the built-in server', style: textStyle),
        ],
      ),
      data: (info) => Row(
        children: [
          Icon(
            info == null ? Icons.info_outline : Icons.check_circle_outline,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            info == null
                ? 'Not available on this device'
                : 'Running locally on port ${info.port}',
            style: textStyle,
          ),
        ],
      ),
    );
  }
}
