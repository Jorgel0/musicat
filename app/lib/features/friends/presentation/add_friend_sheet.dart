import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/invite/invite_uri.dart';
import '../../../core/invite/qr_scanner_screen.dart';
import '../../../core/network/federation/account_client.dart';
import '../../../core/network/federation/federation_client.dart';
import 'account_controller.dart';
import 'friends_controller.dart';
import 'musicat_server_config_controller.dart';

/// Which field [_AddFriendSheetState] uses to fill in the friend's
/// address: the raw address text directly, or a username resolved
/// through this device's own relay (see
/// [_AddFriendSheetState._resolveUsernameAddress]).
enum _AddFriendMode { address, username }

/// The "Add a friend" bottom sheet: one username and one button when
/// signed in, and the older invite-code/QR way (ADR 0038/0045) folded away
/// underneath it — see [_inviteCodeWay].
///
/// Lifted out of `friends_screen.dart` unchanged, purely so that file
/// stops carrying five unrelated things at once; nothing about its
/// behaviour differs from when it lived there.
class AddFriendSheet extends ConsumerStatefulWidget {
  const AddFriendSheet({super.key, this.prefill});

  /// A friend invite already parsed from a deep link (see
  /// `pending_invite.dart`) — pre-fills the "Add a friend" fields below so
  /// the user still has to review and tap "Add friend" themselves; this
  /// never auto-submits.
  final FriendInvite? prefill;

  @override
  ConsumerState<AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends ConsumerState<AddFriendSheet> {
  late final _friendAddressController = TextEditingController(
    text: widget.prefill?.address,
  );
  late final _codeController = TextEditingController(
    text: widget.prefill?.code,
  );
  final _pasteLinkController = TextEditingController();
  final _friendUsernameController = TextEditingController();

  /// The whole of the primary path's input: one username. Separate from
  /// [_friendUsernameController], which belongs to the invite-code way's
  /// own "look this name up in the relay directory" mode (ADR 0045) and
  /// still needs a pairing code alongside it.
  final _requestUsernameController = TextEditingController();

  _AddFriendMode _mode = _AddFriendMode.address;
  String? _myCode;
  bool _generatingCode = false;
  bool _addingFriend = false;
  bool _sendingRequest = false;
  String? _error;
  String? _requestError;

  @override
  void dispose() {
    _friendAddressController.dispose();
    _codeController.dispose();
    _pasteLinkController.dispose();
    _friendUsernameController.dispose();
    _requestUsernameController.dispose();
    super.dispose();
  }

  /// What went wrong sending a friend request, said in terms of the one
  /// thing the user typed. A `503` in particular must not read as "that
  /// username is wrong".
  static String _requestErrorMessage(
    AccountClientException e,
    String username,
  ) => switch (e.statusCode) {
    404 => 'No one is using the username "$username".',
    400 => 'Check that username — you cannot send a request to yourself.',
    409 => 'Sign in again to send friend requests.',
    502 || 503 =>
      'Friend requests are not available right now. Try again in a moment.',
    _ => 'Could not send that request right now. Try again.',
  };

  /// The primary path, end to end: one username, one request, sheet
  /// closed. No code to generate, nothing for the other person to paste
  /// back, and no second pairing in the other direction — they accept and
  /// both sides are friends (server ADR 0051).
  Future<void> _sendFriendRequest() async {
    final username = _requestUsernameController.text.trim();
    if (username.isEmpty) {
      setState(() => _requestError = 'Enter their username.');
      return;
    }
    setState(() {
      _sendingRequest = true;
      _requestError = null;
    });
    // Captured before the await: this sheet is popped on success, so
    // looking the messenger up afterwards would use a dead context.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref.read(friendRequestsProvider.notifier).send(username);
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Friend request sent to $username. You will be friends as soon '
            'as they accept.',
          ),
        ),
      );
    } on AccountClientException catch (e) {
      setState(() => _requestError = _requestErrorMessage(e, username));
    } catch (e) {
      setState(
        () =>
            _requestError = 'Could not send that request right now. Try again.',
      );
    } finally {
      if (mounted) setState(() => _sendingRequest = false);
    }
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

    final String friendAddress;
    if (_mode == _AddFriendMode.username &&
        (ref.read(myNodeInfoProvider).value?.relayUrl != null)) {
      try {
        friendAddress = await _resolveUsernameAddress();
      } catch (e) {
        setState(() {
          _error = e is FederationClientException
              ? e.message
              : 'Could not resolve that username: $e';
          _addingFriend = false;
        });
        return;
      }
    } else {
      friendAddress = _friendAddressController.text.trim();
    }

    try {
      await ref
          .read(friendsControllerProvider.notifier)
          .addFriend(
            friendAddress: friendAddress,
            code: _codeController.text.trim(),
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not add friend: $e');
    } finally {
      if (mounted) setState(() => _addingFriend = false);
    }
  }

  /// Resolves [_friendUsernameController]'s text to the friend's address,
  /// routed through this device's own currently-connected relay exactly
  /// the way ordinary friend-to-friend fallback traffic already is:
  /// `<relay-host>:<relay-port>/<nodeId>` (see `relay_hub.dart`'s own
  /// forwarding route shape on the server side) — no new addressing
  /// mechanism, [FederationClient.addFriend] already turns this into
  /// `http://<relay-host>:<relay-port>/<nodeId>/api/v1/federation/friends`
  /// the same way it does for a plain address today. Never calls
  /// `addFriend` itself; throws (without falling back to a bad address)
  /// if the username can't be resolved, or if this device has no relay to
  /// route through at all.
  Future<String> _resolveUsernameAddress() async {
    final client = ref.read(federationClientProvider);
    if (client == null) {
      throw StateError('Musicat Server not configured');
    }
    final myNode = await ref.read(myNodeInfoProvider.future);
    final relayHostAndPort = _relayHostAndPort(myNode?.relayUrl);
    if (relayHostAndPort == null) {
      throw const FederationClientException(
        503,
        'No relay is currently connected to this device.',
      );
    }
    final nodeId = await client.lookupUsername(
      _friendUsernameController.text.trim(),
    );
    return '$relayHostAndPort/$nodeId';
  }

  /// Strips the `ws://`/`wss://` scheme and any path from a relay's own
  /// `wss://<host>:<port>/session/<id>`-shaped [MyNodeInfo.relayUrl], down
  /// to just the `<host>:<port>` this sheet needs to build an "add friend
  /// by username" address — a small, local string operation, not a new
  /// server route. `null` for `null`/an unparsable [relayUrl].
  static String? _relayHostAndPort(String? relayUrl) {
    if (relayUrl == null) return null;
    final uri = Uri.tryParse(relayUrl);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.authority;
  }

  @override
  Widget build(BuildContext context) {
    final myPublicAddress = ref.watch(
      musicatServerConfigControllerProvider.select((c) => c.myPublicAddress),
    );
    // "By username" mode needs this device's own relay to route the
    // request through (see _resolveUsernameAddress) — hidden entirely
    // without one, same as _UsernameClaimSection hides the "Claim a
    // username" field in _ServerConfigSheet for the same reason.
    final hasRelay = ref.watch(myNodeInfoProvider).value?.relayUrl != null;
    final effectiveMode = hasRelay ? _mode : _AddFriendMode.address;
    // Signed in, the one-field path is the sheet; signed out, the sheet is
    // exactly what it has always been, with an offer to make it simpler.
    final signedIn = ref.watch(accountSessionProvider).value != null;

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
            Text('Add a friend', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (signedIn) ...[
              Text(
                'Type their username and send them a request. They accept '
                'it in Musicat, and you are both friends — nothing to copy, '
                'paste or scan.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _requestUsernameController,
                      autocorrect: false,
                      enableSuggestions: false,
                      onSubmitted: (_) =>
                          _sendingRequest ? null : _sendFriendRequest(),
                      decoration: const InputDecoration(
                        labelText: "Friend's username",
                        prefixIcon: Icon(Icons.alternate_email),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: FilledButton(
                      onPressed: _sendingRequest ? null : _sendFriendRequest,
                      child: _sendingRequest
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Send request'),
                    ),
                  ),
                ],
              ),
              if (_requestError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _requestError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 8),
              // The older way is kept, deliberately (ADR 0038/0045) — it is
              // the only way to add someone who has no account, and the
              // only one that works with no relay at all. Folded away so it
              // does not drown the one-field path above it.
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                // Open from the start when this sheet was opened *by* an
                // invite link (a deep link, see `pending_invite.dart`):
                // the fields it pre-filled are in here, and folding them
                // away would hide the very thing the user just tapped.
                initiallyExpanded: widget.prefill != null,
                title: const Text('Add with an invite code instead'),
                children: _inviteCodeWay(
                  context,
                  myPublicAddress: myPublicAddress,
                  hasRelay: hasRelay,
                  effectiveMode: effectiveMode,
                ),
              ),
            ] else ...[
              Text(
                'Sign in to add a friend by username alone — one field, no '
                'codes to swap. Or use an invite code below, exactly as '
                'before.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  context.push('/account');
                },
                icon: const Icon(Icons.account_circle_outlined),
                label: const Text('Sign in or create an account'),
              ),
              const Divider(height: 32),
              ..._inviteCodeWay(
                context,
                myPublicAddress: myPublicAddress,
                hasRelay: hasRelay,
                effectiveMode: effectiveMode,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The pre-accounts way of adding a friend, unchanged in behaviour:
  /// generate a single-use code (as a QR, a link, or plain text) for them,
  /// or redeem theirs against their address — see ADR 0038 for the invite
  /// links and ADR 0045 for looking their address up by the username they
  /// claimed on a relay. Still the only way to add someone who has not
  /// signed in to an account, so it is folded away rather than dropped.
  List<Widget> _inviteCodeWay(
    BuildContext context, {
    required String myPublicAddress,
    required bool hasRelay,
    required _AddFriendMode effectiveMode,
  }) {
    return [
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
        // removed from AddFriendSheet — see the class doc), and
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
              onPressed: () => Clipboard.setData(ClipboardData(text: _myCode!)),
            ),
            IconButton(
              tooltip: 'Share invite link',
              icon: const Icon(Icons.share),
              onPressed: () => SharePlus.instance.share(
                ShareParams(
                  text: InviteUri.build(
                    FriendInvite(address: myPublicAddress, code: _myCode!),
                  ).toString(),
                ),
              ),
            ),
          ],
        ),
      ],
      const Divider(height: 32),
      Text(
        'Add with their code',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      if (hasRelay) ...[
        SegmentedButton<_AddFriendMode>(
          segments: const [
            ButtonSegment(
              value: _AddFriendMode.address,
              label: Text('By address'),
            ),
            ButtonSegment(
              value: _AddFriendMode.username,
              label: Text('By username'),
            ),
          ],
          selected: {effectiveMode},
          onSelectionChanged: (selection) =>
              setState(() => _mode = selection.first),
        ),
        const SizedBox(height: 12),
      ],
      if (effectiveMode == _AddFriendMode.username)
        TextField(
          controller: _friendUsernameController,
          decoration: const InputDecoration(
            labelText: "Friend's username",
            hintText: 'the username they claimed on their own relay',
          ),
        )
      else
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
    ];
  }
}
