/// Which backend [SoulseekConfig] points at. See ADR 0016/0017: `slskd` is
/// talked to directly (ADR 0010); `musicatServer` goes through a self-hosted
/// Musicat Server instance instead, which holds the slskd API key itself.
enum SoulseekBackendType { slskd, musicatServer }

/// Connection settings for the app's Soulseek backend. See ADR 0004/0010
/// (direct slskd) and ADR 0017 (via Musicat Server).
class SoulseekConfig {
  const SoulseekConfig({
    required this.backendType,
    required this.host,
    required this.port,
    required this.apiKey,
  });

  final SoulseekBackendType backendType;
  final String host;
  final int port;

  /// Only meaningful for [SoulseekBackendType.slskd] — a Musicat Server
  /// instance holds its own slskd API key server-side, so the app never
  /// needs one for that backend.
  final String apiKey;

  bool get isConfigured =>
      host.isNotEmpty &&
      (backendType == SoulseekBackendType.musicatServer || apiKey.isNotEmpty);

  String get baseUrl => 'http://$host:$port';

  static const empty = SoulseekConfig(
    backendType: SoulseekBackendType.slskd,
    host: '',
    port: 5030,
    apiKey: '',
  );
}
