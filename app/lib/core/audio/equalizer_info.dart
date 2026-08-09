class EqualizerBandInfo {
  const EqualizerBandInfo({
    required this.index,
    required this.centerFrequencyHz,
    required this.gainDb,
  });

  final int index;
  final double centerFrequencyHz;
  final double gainDb;
}

class EqualizerInfo {
  const EqualizerInfo({
    required this.enabled,
    required this.minDecibels,
    required this.maxDecibels,
    required this.bands,
  });

  final bool enabled;
  final double minDecibels;
  final double maxDecibels;
  final List<EqualizerBandInfo> bands;
}
