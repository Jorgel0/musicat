import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/audio/equalizer_info.dart';
import '../../../player/presentation/player_providers.dart';
import 'equalizer_controller.dart';

class EqualizerScreen extends ConsumerWidget {
  const EqualizerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = ref.watch(currentTrackProvider) != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: !hasTrack
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Play a song first to set up the equalizer.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : const _EqualizerBody(),
    );
  }
}

class _EqualizerBody extends ConsumerWidget {
  const _EqualizerBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncInfo = ref.watch(equalizerControllerProvider);

    return asyncInfo.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(child: Text('Error: $error')),
      data: (info) {
        if (info == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'The equalizer is only available on Android for now.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return Column(
          children: [
            SwitchListTile(
              title: const Text('Enabled'),
              value: info.enabled,
              onChanged: (value) => ref
                  .read(equalizerControllerProvider.notifier)
                  .setEnabled(value),
            ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final band in info.bands)
                    _BandSlider(
                      band: band,
                      min: info.minDecibels,
                      max: info.maxDecibels,
                      enabled: info.enabled,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

class _BandSlider extends ConsumerWidget {
  const _BandSlider({
    required this.band,
    required this.min,
    required this.max,
    required this.enabled,
  });

  final EqualizerBandInfo band;
  final double min;
  final double max;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        Text('${band.gainDb.round()} dB'),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              min: min,
              max: max,
              value: band.gainDb.clamp(min, max),
              onChanged: enabled
                  ? (value) => ref
                        .read(equalizerControllerProvider.notifier)
                        .setBandGain(band.index, value)
                  : null,
            ),
          ),
        ),
        Text(_formatFrequency(band.centerFrequencyHz)),
      ],
    );
  }
}

String _formatFrequency(double hz) {
  if (hz >= 1000) {
    final khz = hz / 1000;
    return '${khz % 1 == 0 ? khz.toStringAsFixed(0) : khz.toStringAsFixed(1)}k';
  }
  return hz.round().toString();
}
