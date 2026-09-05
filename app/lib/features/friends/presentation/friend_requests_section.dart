import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/federation/account_client.dart';
import 'account_controller.dart';

/// The strip at the top of the Friends screen that answers "who am I here"
/// — a question this app could not answer at all until now — and offers the
/// way in for someone who has never signed in.
///
/// Renders nothing at all while the session is still loading, or if it
/// could not be read: both are "this device does not know yet", and
/// guessing either way (an invitation to sign in when you already are, or a
/// username when we are unsure) would be worse than saying nothing for a
/// frame. Signing in is never required — everything below it works exactly
/// the same for a device that never does.
class AccountHeaderTile extends ConsumerWidget {
  const AccountHeaderTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(accountSessionProvider);
    return session.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (account) => account == null
          ? const _SignedOutTile()
          : _SignedInTile(account: account),
    );
  }
}

class _SignedInTile extends StatelessWidget {
  const _SignedInTile({required this.account});

  final MyAccount account;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.account_circle_outlined),
      title: Text('Signed in as ${account.username}'),
      subtitle: const Text('Friends can add you with this username'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/account'),
    );
  }
}

class _SignedOutTile extends StatelessWidget {
  const _SignedOutTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.account_circle_outlined),
      title: const Text('Add friends by username'),
      subtitle: const Text('Sign in or create an account — no codes to swap'),
      trailing: FilledButton(
        onPressed: () => context.push('/account'),
        child: const Text('Sign in'),
      ),
      onTap: () => context.push('/account'),
    );
  }
}

/// Friend requests waiting for an answer, shown directly above the friends
/// list so answering one is never something to go looking for.
///
/// The whole point of this widget is the difference between the three
/// things an empty list can mean:
///
/// - a fresh answer that really is empty — show nothing at all;
/// - a stale one, because this device could not check just now — say so,
///   and say what it last saw;
/// - never having managed to check at all
///   ([FriendRequestsSnapshot.neverFetched]) — say that, because there
///   could be requests waiting and this device genuinely does not know.
///
/// Rendering the last two as "no friend requests" would be a lie the user
/// has no way to catch.
class FriendRequestsSection extends ConsumerWidget {
  const FriendRequestsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Signed out there is nothing to show and nothing to admit: friend
    // requests simply do not apply to this device.
    final signedIn = ref.watch(accountSessionProvider).value != null;
    if (!signedIn) return const SizedBox.shrink();

    return ref
        .watch(friendRequestsProvider)
        .when(
          loading: () => const SizedBox.shrink(),
          error: (error, stackTrace) => const _CouldNotCheck(
            message:
                'Could not check for friend requests just now — there may '
                'be some waiting.',
          ),
          data: (snapshot) {
            final pending = snapshot.pending;
            if (pending.isEmpty) {
              if (snapshot.live) return const SizedBox.shrink();
              return _CouldNotCheck(
                message: snapshot.neverFetched
                    ? 'Could not check for friend requests yet — there may '
                          'be some waiting.'
                    : 'Could not check for friend requests just now. Last '
                          'time this device checked, there were none.',
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    pending.length == 1
                        ? '1 friend request'
                        : '${pending.length} friend requests',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final request in pending)
                  _FriendRequestTile(request: request),
                if (!snapshot.live)
                  const _CouldNotCheck(
                    message:
                        'Could not check for new requests just now — this '
                        'is what this device last saw.',
                  ),
                const Divider(height: 1),
              ],
            );
          },
        );
  }
}

/// The honest empty/stale state — deliberately never phrased as "no friend
/// requests", which is a different claim than this widget is ever used to
/// make. Offers the retry, since "check again" is the only useful action.
class _CouldNotCheck extends ConsumerWidget {
  const _CouldNotCheck({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
          TextButton(
            onPressed: () =>
                ref.read(friendRequestsProvider.notifier).refresh(),
            child: const Text('Check again'),
          ),
        ],
      ),
    );
  }
}

class _FriendRequestTile extends ConsumerStatefulWidget {
  const _FriendRequestTile({required this.request});

  final IncomingFriendRequest request;

  @override
  ConsumerState<_FriendRequestTile> createState() => _FriendRequestTileState();
}

class _FriendRequestTileState extends ConsumerState<_FriendRequestTile> {
  bool _answering = false;

  /// Answers the request, then says what happened in the terms the user
  /// cares about ("you are now friends"), not in terms of the request
  /// record that just changed state.
  Future<void> _respond({required bool accept}) async {
    setState(() => _answering = true);
    final name = widget.request.fromLabel;
    try {
      await ref
          .read(friendRequestsProvider.notifier)
          .respond(widget.request.id, accept: accept);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            accept
                ? 'You and $name are now friends.'
                : 'Declined the request from $name.',
          ),
        ),
      );
    } on AccountClientException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.statusCode == 409
                ? 'That request had already been answered.'
                : 'Could not answer that request right now. Try again.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not answer that request right now. Try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _answering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.person_add_alt_1)),
      title: Text('${widget.request.fromLabel} wants to be your friend'),
      trailing: _answering
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => _respond(accept: false),
                  child: const Text('Decline'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () => _respond(accept: true),
                  child: const Text('Accept'),
                ),
              ],
            ),
    );
  }
}
