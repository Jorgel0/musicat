import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/federation/account_client.dart';
import 'account_devices_controller.dart';

/// Every device signed in to this account, and the way to revoke one —
/// the "lost or stolen phone" path the server shipped in ADR 0048 and
/// nothing in the app could reach until now.
///
/// Reached from the account screen (`/account/devices`). Deliberately its
/// own screen rather than a section on the account screen: it is a live
/// fetch every time it opens, and it is where the one destructive action in
/// this feature lives.
class AccountDevicesScreen extends ConsumerWidget {
  const AccountDevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesAsync = ref.watch(accountDevicesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your devices'),
        actions: [
          IconButton(
            tooltip: 'Check again',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.read(accountDevicesProvider.notifier).refresh(),
          ),
        ],
      ),
      body: SafeArea(
        child: devicesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          // Never a cached list behind this: see [AccountDevicesController].
          // The honest thing to show is that this device could not ask, not
          // an older answer that may already be wrong.
          error: (error, stackTrace) => _CouldNotList(error: error),
          data: (devices) => devices.isEmpty
              ? const _NoDevices()
              : _DevicesList(devices: devices),
        ),
      ),
    );
  }
}

class _DevicesList extends StatelessWidget {
  const _DevicesList({required this.devices});

  final List<AccountDevice> devices;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                devices.length == 1
                    ? 'One device is signed in to your account.'
                    : '${devices.length} devices are signed in to your '
                          'account.',
                style: textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Each of them can act as you: friends see them as you, and '
                'they can add friends in your name. Unlink one you have '
                'lost, sold, or simply stopped using.',
                style: textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              // Says out loud why the rows are named the way they are, so
              // "Android" does not read as a name somebody chose and
              // "Unknown device" does not read as a bug.
              Text(
                'Musicat only knows what kind of device each one is, never '
                'what you call it — when two look alike, go by when each '
                'was last used.',
                style: textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        for (final device in devices) _DeviceTile(device: device),
      ],
    );
  }
}

/// One device. Shows what a person can actually recognise it by — what kind
/// of device it is, when it was added, and whether it is the one in their
/// hand — and never the node id, which is neither.
class _DeviceTile extends ConsumerStatefulWidget {
  const _DeviceTile({required this.device});

  final AccountDevice device;

  @override
  ConsumerState<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends ConsumerState<_DeviceTile> {
  bool _unlinking = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    return ListTile(
      leading: Icon(_iconFor(device.deviceName)),
      title: Text(device.label),
      subtitle: Text(_describe(device)),
      trailing: _unlinking
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: _confirmUnlink,
              child: const Text('Unlink'),
            ),
    );
  }

  /// A hint at what kind of device this is, from the platform label it
  /// reported for itself. Falls back to a deliberately anonymous icon for
  /// anything unrecognised rather than guessing at a phone.
  static IconData _iconFor(String? deviceName) =>
      switch (deviceName?.toLowerCase()) {
        'android' || 'ios' => Icons.smartphone_outlined,
        'linux' || 'windows' || 'macos' => Icons.computer_outlined,
        _ => Icons.devices_other_outlined,
      };

  /// Asks before unlinking, naming the device and saying what unlinking
  /// actually does — including the two things that are easy to get wrong:
  /// the device is never told, and unlinking the one you are holding signs
  /// you out of it.
  ///
  /// Same dialog idiom as removing a friend on the Friends screen, which is
  /// the other irreversible-from-here action in this feature.
  Future<void> _confirmUnlink() async {
    final device = widget.device;
    final name = device.label;
    // Captured before every await: this tile is rebuilt (or gone) by the
    // time the calls below return, and on a self-unlink this whole screen
    // is popped.
    final controller = ref.read(accountDevicesProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          device.isThisDevice ? 'Unlink this device?' : 'Unlink $name?',
        ),
        content: Text(
          device.isThisDevice
              ? 'This is the device you are using, so unlinking it signs '
                    'you out here. Your friends stay on this device and '
                    'keep working exactly as they do now — you just stop '
                    'acting as your account on it, and can sign back in '
                    'whenever you like.'
              : 'That device stops being able to act as your account: it '
                    'can no longer add friends as you, and your friends '
                    'stop seeing it as one of yours.\n\n'
                    'It is not told, and it keeps any music already on it. '
                    'Whoever has it finds out the next time it tries to do '
                    'something as you. Signing in on it again links it '
                    'back.',
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
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _unlinking = true);
    try {
      final signedOut = await controller.unlink(device.nodeId);
      if (signedOut) {
        // The user unlinked themselves, on purpose. Staying on a device
        // list they are no longer allowed to read would be a broken shell;
        // the account screen behind this one already shows the signed-out
        // state, because the session was re-read as part of the unlink.
        if (router.canPop()) router.pop();
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'This device is no longer linked to your account, so it is '
              'signed out. Your friends are still here.',
            ),
          ),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('$name is no longer linked to your account.')),
      );
    } on AccountClientException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_unlinkFailure(e, name))));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not unlink $name right now. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _unlinking = false);
    }
  }

  /// The failures worth telling apart, all of which have to say the same
  /// reassuring thing first: **nothing was unlinked**. A device the user
  /// believes they revoked and did not is the worst outcome this screen
  /// has.
  static String _unlinkFailure(AccountClientException e, String name) =>
      switch (e.statusCode) {
        409 =>
          'You are not signed in on this device any more, so nothing was '
              'unlinked.',
        403 => 'Your account would not allow $name to be unlinked.',
        _ =>
          'Could not reach your account just now, so nothing was unlinked. '
              'Try again in a moment.',
      };
}

/// The one line under a device's name.
///
/// Leads with **when it was last used**, because that is what actually
/// decides this screen's only question — which of these is the phone I
/// lost? Two desktops linked the same afternoon both read "Linux · Added
/// today", and the date they were added separates them not at all; "used a
/// minute ago" versus "not used since June" does.
///
/// Falls back to the added-date for a server too old to report recency, so
/// the row is never worse than it was before this existed.
String _describe(AccountDevice device) {
  final parts = [
    if (device.isThisDevice) 'This device',
    if (device.lastLoginAt != null)
      _lastUsed(device.lastLoginAt!)
    else
      _addedWhen(device.linkedAt),
  ];
  return parts.join(' · ');
}

/// When a device was last signed in — the same vague-but-useful idiom as
/// [_addedWhen], phrased as use rather than as an event.
String _lastUsed(DateTime at) {
  final since = DateTime.now().difference(at);
  if (since.inMinutes < 2) return 'Used just now';
  if (since.inMinutes < 60) return 'Used ${since.inMinutes} minutes ago';
  if (since.inHours < 24) {
    final hours = since.inHours;
    return hours == 1 ? 'Used an hour ago' : 'Used $hours hours ago';
  }
  final days = since.inDays;
  if (days == 1) return 'Used yesterday';
  if (days < 30) return 'Used $days days ago';
  if (days < 365) {
    final months = days ~/ 30;
    return months == 1 ? 'Not used for a month' : 'Not used for $months months';
  }
  return 'Not used for over a year';
}

/// When a device was linked, in the vaguest terms that are still useful —
/// same idiom (and same reasoning) as the friend device summary on
/// `friend_detail_screen.dart`.
String _addedWhen(DateTime linkedAt) {
  final days = DateTime.now().difference(linkedAt).inDays;
  if (days <= 0) return 'Added today';
  if (days == 1) return 'Added yesterday';
  if (days < 30) return 'Added $days days ago';
  if (days < 365) {
    final months = days ~/ 30;
    return months == 1 ? 'Added a month ago' : 'Added $months months ago';
  }
  return 'Added over a year ago';
}

/// The honest failure state. Deliberately offers no list at all: there is
/// no older copy to fall back on, and inventing one for a screen whose
/// whole purpose is deciding what to revoke would be worse than saying
/// nothing.
class _CouldNotList extends ConsumerWidget {
  const _CouldNotList({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 16),
            Text(_message(error), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () =>
                  ref.read(accountDevicesProvider.notifier).refresh(),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  static String _message(Object error) {
    if (error is! AccountClientException) {
      return 'Could not check which devices are signed in to your account. '
          'Try again in a moment.';
    }
    return switch (error.statusCode) {
      409 => 'You are not signed in on this device.',
      _ =>
        'Could not check which devices are signed in to your account just '
            'now. Musicat never shows an older list here, because it is '
            'not something to guess at — try again in a moment.',
    };
  }
}

/// Only reachable if the account genuinely has no devices, which cannot
/// normally happen — this one is asking. Says so plainly instead of showing
/// an empty screen.
class _NoDevices extends StatelessWidget {
  const _NoDevices();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No devices are signed in to your account.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
