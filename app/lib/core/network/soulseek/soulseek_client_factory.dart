import 'musicat_server/musicat_server_soulseek_client.dart';
import 'slskd/slskd_soulseek_client.dart';
import 'soulseek_client.dart';
import 'soulseek_config.dart';

/// Builds the [SoulseekClient] implementation [config] points at — shared
/// by `soulseekClientProvider` and the Settings screen's "test connection"
/// action, so both always agree on which backend a config selects.
SoulseekClient buildSoulseekClient(SoulseekConfig config) =>
    switch (config.backendType) {
      SoulseekBackendType.slskd => SlskdSoulseekClient(
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
      ),
      SoulseekBackendType.musicatServer => MusicatServerSoulseekClient(
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
      ),
    };
