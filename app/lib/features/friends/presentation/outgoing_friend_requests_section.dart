import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/federation/account_client.dart';
import 'account_controller.dart';

/// The requests this account has sent and is still waiting on, shown on the
/// Friends screen just below the ones waiting for an answer.
///
/// Before this existed a sent request vanished from the app's model of the
/// world: there was no way to tell "they have not got round to it" from "I
/// typed the username wrong" from "it never went out", and no way to take
/// one back. The row is deliberately quieter than an incoming request —
/// there is nothing for the user to *decide* here, only something to know,
/// and one thing they may want to undo.
///
/// Shows nothing at all while loading, on a failure, or when there is
/// nothing pending. The failure case is not hidden: [FriendRequestsSection]
/// sits directly above this and says "could not check" for both lists,
/// which is honest because both come from the same single fetch (server ADR
/// 0056) — saying it twice would just be noise.
class OutgoingFriendRequestsSection extends ConsumerWidget {
  const OutgoingFriendRequestsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(signedInAccountProvider) == null) {
      return const SizedBox.shrink();
    }
    final pending =
        ref.watch(friendRequestsProvider).value?.pendingOutgoing ?? const [];
    if (pending.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            pending.length == 1
                ? 'Waiting for an answer'
                : 'Waiting for ${pending.length} answers',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final request in pending) _OutgoingRequestTile(request: request),
        const Divider(height: 1),
      ],
    );
  }
}

class _OutgoingRequestTile extends ConsumerStatefulWidget {
  const _OutgoingRequestTile({required this.request});

  final OutgoingFriendRequest request;

  @override
  ConsumerState<_OutgoingRequestTile> createState() =>
      _OutgoingRequestTileState();
}

class _OutgoingRequestTileState extends ConsumerState<_OutgoingRequestTile> {
  bool _cancelling = false;

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.hourglass_empty)),
      title: Text('${request.toLabel} has not answered yet'),
      subtitle: Text(_sentWhen(request.sentAt)),
      trailing: _cancelling
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: _confirmCancel,
              child: const Text('Cancel request'),
            ),
    );
  }

  /// Asks first, because the other person's copy of the request disappears
  /// too. The copy's one job is to not read like unfriending: nobody is a
  /// friend yet, nothing is removed, and sending another one later is
  /// allowed — all three said out loud, since "cancel" next to a person's
  /// name invites exactly the opposite reading.
  Future<void> _confirmCancel() async {
    final request = widget.request;
    final name = request.toLabel;
    // Captured before the awaits: this row disappears the moment the list
    // is re-read, taking its context with it.
    final controller = ref.read(friendRequestsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Take back your request to $name?'),
        content: Text(
          'They will no longer see it, and will not be able to accept it. '
          'This does not remove anyone — you are not friends yet — and you '
          'can send $name another request later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep waiting'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Take it back'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _cancelling = true);
    try {
      await controller.cancel(request.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Took back your request to $name.')),
      );
    } on AccountClientException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.statusCode == 409
                // The list was already stale when the button was tapped;
                // the controller has re-read it by now, so the row is gone
                // and this only has to explain why.
                ? '$name had already answered that request.'
                : 'Could not take that request back right now. Try again.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not take that request back right now. Try '
            'again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  /// How long they have had it, roughly — the thing that turns "no answer"
  /// into something a person can judge. Silent about the time entirely when
  /// the service did not say when it was sent, rather than implying "just
  /// now".
  static String _sentWhen(DateTime? sentAt) {
    if (sentAt == null) return 'Sent, and still waiting';
    final elapsed = DateTime.now().difference(sentAt);
    if (elapsed.inMinutes < 1) return 'Sent just now';
    if (elapsed.inHours < 1) return 'Sent ${elapsed.inMinutes} minutes ago';
    if (elapsed.inDays < 1) return 'Sent ${elapsed.inHours} hours ago';
    if (elapsed.inDays == 1) return 'Sent yesterday';
    if (elapsed.inDays < 30) return 'Sent ${elapsed.inDays} days ago';
    return 'Sent a while ago';
  }
}
