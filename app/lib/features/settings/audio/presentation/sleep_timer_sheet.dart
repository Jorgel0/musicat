import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sleep_timer_controller.dart';

Future<void> showSleepTimerSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    builder: (context) => const _SleepTimerSheet(),
  );
}

class _SleepTimerSheet extends ConsumerWidget {
  const _SleepTimerSheet();

  static const _presets = [
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(minutes: 60),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sleepTimerControllerProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Sleep timer',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          if (state.isActive)
            ListTile(
              leading: const Icon(Icons.timer_off_outlined),
              title: Text(
                'Cancel (${_formatRemaining(state.remaining!)} left)',
              ),
              onTap: () {
                ref.read(sleepTimerControllerProvider.notifier).cancel();
                Navigator.of(context).pop();
              },
            ),
          for (final duration in _presets)
            ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: Text('${duration.inMinutes} min'),
              onTap: () {
                ref.read(sleepTimerControllerProvider.notifier).start(duration);
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
    );
  }
}

String _formatRemaining(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
