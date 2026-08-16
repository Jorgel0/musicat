/// Connection settings for the slskd instance this server wraps.
class SlskdConfig {
  const SlskdConfig({
    required this.host,
    required this.port,
    required this.apiKey,
  });

  final String host;
  final int port;
  final String apiKey;

  String get baseUrl => 'http://$host:$port';

  factory SlskdConfig.fromEnvironment(Map<String, String> env) => SlskdConfig(
    host: env['SLSKD_HOST'] ?? 'localhost',
    port: int.tryParse(env['SLSKD_PORT'] ?? '') ?? 5030,
    apiKey: env['SLSKD_API_KEY'] ?? '',
  );
}
