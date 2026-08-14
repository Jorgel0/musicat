import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/audio/replay_gain_reader.dart';

void main() {
  group('readTrackReplayGainDb', () {
    test('reads the track gain from a FLAC (Vorbis comment) file', () {
      final gain = readTrackReplayGainDb(
        'test/fixtures/replay_gain/with_gain.flac',
      );

      expect(gain, -3.5);
    });

    test('reads the track gain from an MP3 (ID3 TXXX) file', () {
      final gain = readTrackReplayGainDb(
        'test/fixtures/replay_gain/with_gain.mp3',
      );

      expect(gain, -3.5);
    });

    test('returns null when the file has no ReplayGain tags', () {
      final gain = readTrackReplayGainDb(
        'test/fixtures/replay_gain/no_gain.flac',
      );

      expect(gain, isNull);
    });

    test('returns null for a nonexistent file instead of throwing', () {
      final gain = readTrackReplayGainDb('test/fixtures/replay_gain/nope.flac');

      expect(gain, isNull);
    });
  });

  group('volumeFromReplayGainDb', () {
    test('returns full volume when there is no gain tag', () {
      expect(volumeFromReplayGainDb(null), 1.0);
    });

    test('returns full volume unchanged for a positive gain', () {
      // Positive ReplayGain values would mean *raising* the volume beyond
      // the source; we clamp to 1.0 rather than risk clipping.
      expect(volumeFromReplayGainDb(6.0), 1.0);
    });

    test('reduces volume for a negative gain', () {
      final volume = volumeFromReplayGainDb(-6.0);

      // 10^(-6/20) ≈ 0.501
      expect(volume, closeTo(0.501, 0.001));
    });

    test('never goes below zero for a very negative gain', () {
      expect(volumeFromReplayGainDb(-100.0), greaterThanOrEqualTo(0.0));
    });
  });
}
