import 'dart:io';
import 'dart:math' as math;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

/// Reads a track's ReplayGain track-gain tag (in dB), if present — an
/// ID3v2 TXXX frame for MP3, or a Vorbis comment for FLAC/OGG/Opus.
/// Returns `null` if the tag is absent (common — Soulseek downloads in
/// particular rarely carry ReplayGain data) or the file can't be parsed.
double? readTrackReplayGainDb(String filePath) {
  try {
    final metadata = readAllMetadata(File(filePath), getImage: false);
    final raw = switch (metadata) {
      Mp3Metadata m => _lookupCaseInsensitive(
        m.customMetadata,
        'REPLAYGAIN_TRACK_GAIN',
      ),
      VorbisMetadata v => v.replayGainTrackGain.firstOrNull,
      _ => null,
    };
    if (raw == null) return null;
    return _parseGainDb(raw);
  } catch (_) {
    // Unreadable/unsupported file — normalization just won't apply to it.
    return null;
  }
}

/// Converts a ReplayGain dB value into a linear volume multiplier,
/// clamped to avoid clipping (no headroom/peak handling — see ADR 0008).
double volumeFromReplayGainDb(double? gainDb) {
  if (gainDb == null) return 1.0;
  final linear = math.pow(10, gainDb / 20).toDouble();
  return linear.clamp(0.0, 1.0);
}

String? _lookupCaseInsensitive(Map<String, String> map, String key) {
  for (final entry in map.entries) {
    if (entry.key.toUpperCase() == key) return entry.value;
  }
  return null;
}

double? _parseGainDb(String raw) {
  final match = RegExp(r'-?\d+(\.\d+)?').firstMatch(raw);
  if (match == null) return null;
  return double.tryParse(match.group(0)!);
}
