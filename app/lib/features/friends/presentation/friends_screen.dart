import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/embedded_server/embedded_server.dart';
import '../../../core/invite/invite_uri.dart';
import '../../../core/invite/pending_invite.dart';
import '../../../core/invite/qr_scanner_screen.dart';
import '../../../core/network/federation/federation_client.dart';
import '../domain/musicat_server_config.dart';
import 'android_background_reachability_controller.dart';
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
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeOpenPendingInvite(ref.read(pendingInviteProvider)),
    );
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
          ? const _FriendsList()
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
      builder: (context) => _AddFriendSheet(prefill: prefill),
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
      onRefresh: () => ref.read(friendsControllerProvider.notifier).refresh(),
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
                  onPressed: () => ref
                      .read(friendsControllerProvider.notifier)
                      .removeFriend(entry.friend.nodeId),
                ),
              ],
            ),
            onTap: () => context.push('/friends/${entry.friend.nodeId}'),
          );
        },
      ),
    );
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
  late bool _useEmbeddedServer;

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
    _useEmbeddedServer = config.useEmbeddedServer;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _myAddressController.dispose();
    _myDisplayNameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final myDisplayName = _myDisplayNameController.text.trim();
    final config = MusicatServerConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 8080,
      myPublicAddress: _myAddressController.text.trim(),
      myDisplayName: myDisplayName.isEmpty ? null : myDisplayName,
      useEmbeddedServer: _useEmbeddedServer,
    );
    await ref.read(musicatServerConfigControllerProvider.notifier).save(config);
    if (mounted) Navigator.of(context).pop();
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

class _AddFriendSheet extends ConsumerStatefulWidget {
  const _AddFriendSheet({this.prefill});

  /// A friend invite already parsed from a deep link (see
  /// `pending_invite.dart`) — pre-fills the "Add a friend" fields below so
  /// the user still has to review and tap "Add friend" themselves; this
  /// never auto-submits.
  final FriendInvite? prefill;

  @override
  ConsumerState<_AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends ConsumerState<_AddFriendSheet> {
  late final _friendAddressController = TextEditingController(
    text: widget.prefill?.address,
  );
  late final _codeController = TextEditingController(
    text: widget.prefill?.code,
  );
  final _pasteLinkController = TextEditingController();
  String? _myCode;
  bool _generatingCode = false;
  bool _addingFriend = false;
  String? _error;

  @override
  void dispose() {
    _friendAddressController.dispose();
    _codeController.dispose();
    _pasteLinkController.dispose();
    super.dispose();
  }

  /// Runs [raw] — from a QR scan or the "paste an invite link" field —
  /// through the shared [InviteUri] parser and pre-fills the address/code
  /// fields above on a valid friend invite. Never auto-submits; the user
  /// still has to review and tap "Add friend". Any `name` the invite
  /// itself carries is the inviter's own display name — not something
  /// this sheet asks the user to redo; it arrives automatically once the
  /// invite is redeemed (see `FriendsController.addFriend`).
  void _applyInvite(String raw) {
    setState(() => _error = null);
    final InvitePayload payload;
    try {
      payload = InviteUri.parse(raw);
    } on InviteUriException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    if (payload is! FriendInvite) {
      setState(() => _error = 'That link is not a friend invite.');
      return;
    }
    final invite = payload;
    setState(() {
      _friendAddressController.text = invite.address;
      _codeController.text = invite.code;
      _pasteLinkController.clear();
    });
  }

  Future<void> _scanInvite() async {
    final raw = await scanQrCode(context, title: "Scan a friend's invite");
    if (raw == null) return;
    _applyInvite(raw);
  }

  Future<void> _generateMyCode() async {
    setState(() => _generatingCode = true);
    try {
      final code = await ref
          .read(friendsControllerProvider.notifier)
          .generateMyPairingCode();
      setState(() => _myCode = code);
    } catch (e) {
      setState(() => _error = 'Could not generate a code: $e');
    } finally {
      setState(() => _generatingCode = false);
    }
  }

  Future<void> _addFriend() async {
    setState(() {
      _addingFriend = true;
      _error = null;
    });
    try {
      await ref
          .read(friendsControllerProvider.notifier)
          .addFriend(
            friendAddress: _friendAddressController.text.trim(),
            code: _codeController.text.trim(),
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not add friend: $e');
    } finally {
      if (mounted) setState(() => _addingFriend = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myPublicAddress = ref.watch(
      musicatServerConfigControllerProvider.select((c) => c.myPublicAddress),
    );

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Your invite', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Share this code and your address ($myPublicAddress) with a '
              'friend — they enter both on their own device.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_myCode == null)
              OutlinedButton(
                onPressed: _generatingCode ? null : _generateMyCode,
                child: _generatingCode
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Generate a code'),
              )
            else ...[
              // This self-invite link deliberately omits `name`: the
              // friend redeeming it never reads it (that field was
              // removed from _AddFriendSheet — see the class doc), and
              // this node's own configured myDisplayName already reaches
              // them automatically, as the `displayName` on the addFriend
              // request they send when redeeming this code (see
              // FriendsController.addFriend).
              Builder(
                builder: (context) {
                  final inviteUri = InviteUri.build(
                    FriendInvite(address: myPublicAddress, code: _myCode!),
                  );
                  return Center(
                    // Fixed-size SizedBox, not just for layout: qr_flutter
                    // always wraps QrImageView in a LayoutBuilder
                    // internally, which is incompatible with any ancestor
                    // that sizes itself via IntrinsicWidth (e.g. an
                    // AlertDialog, like the joint-playlist share dialog
                    // uses) unless something above it already imposes
                    // tight constraints — kept consistent here too.
                    child: SizedBox(
                      width: 180,
                      height: 180,
                      child: QrImageView(
                        // Keyed on its own data so a widget test can
                        // confirm exactly what got encoded (qr_flutter
                        // doesn't expose `data` as a public getter to
                        // assert on directly).
                        key: ValueKey('friend-invite-qr:$inviteUri'),
                        data: inviteUri.toString(),
                        version: QrVersions.auto,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      _myCode!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: _myCode!)),
                  ),
                  IconButton(
                    tooltip: 'Share invite link',
                    icon: const Icon(Icons.share),
                    onPressed: () => SharePlus.instance.share(
                      ShareParams(
                        text: InviteUri.build(
                          FriendInvite(
                            address: myPublicAddress,
                            code: _myCode!,
                          ),
                        ).toString(),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const Divider(height: 32),
            Text(
              'Add a friend',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _friendAddressController,
              decoration: const InputDecoration(
                labelText: "Friend's address",
                hintText: 'their-address.example:8080',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(labelText: "Friend's code"),
            ),
            const SizedBox(height: 12),
            if (qrScanningSupported) ...[
              OutlinedButton.icon(
                onPressed: _scanInvite,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan a friend\'s QR code'),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _pasteLinkController,
                    decoration: const InputDecoration(
                      labelText: 'Or paste an invite link',
                      hintText: 'musicat://friend?...',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: OutlinedButton(
                    onPressed: () => _applyInvite(_pasteLinkController.text),
                    child: const Text('Use'),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _addingFriend ? null : _addFriend,
              child: _addingFriend
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Add friend'),
            ),
          ],
        ),
      ),
    );
  }
}
