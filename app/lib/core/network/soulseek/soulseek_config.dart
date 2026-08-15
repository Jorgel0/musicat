/// Connection settings for a self-hosted slskd backend. See ADR 0004/0010.
class SoulseekConfig {
  const SoulseekConfig({
    required this.host,
    required this.port,
    required this.apiKey,
  });

  final String host;
  final int port;
  final String apiKey;

  bool get isConfigured => host.isNotEmpty && apiKey.isNotEmpty;

  String get baseUrl => 'http://$host:$port';

  static const empty = SoulseekConfig(host: '', port: 5030, apiKey: '');
}
