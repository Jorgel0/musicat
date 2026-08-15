import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/network/soulseek/slskd/slskd_soulseek_client.dart';
import '../../../../core/network/soulseek/soulseek_client.dart';
import '../../../../core/network/soulseek/soulseek_config.dart';

const _hostKey = 'soulseekHost';
const _portKey = 'soulseekPort';
const _apiKeyKey = 'soulseekApiKey';

class SoulseekConfigController extends Notifier<SoulseekConfig> {
  SoulseekConfigController([this._initial]);

  final SoulseekConfig? _initial;

  @override
  SoulseekConfig build() => _initial ?? SoulseekConfig.empty;

  Future<void> save(SoulseekConfig config) async {
    state = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hostKey, config.host);
    await prefs.setInt(_portKey, config.port);
    await prefs.setString(_apiKeyKey, config.apiKey);
  }
}

final soulseekConfigControllerProvider =
    NotifierProvider<SoulseekConfigController, SoulseekConfig>(
      SoulseekConfigController.new,
    );

/// `null` when no backend is configured yet — search/download features
/// should treat this as "Soulseek unavailable" and degrade gracefully
/// (local playback/library are never affected), not as an error.
final soulseekClientProvider = Provider<SoulseekClient?>((ref) {
  final config = ref.watch(soulseekConfigControllerProvider);
  if (!config.isConfigured) return null;
  return SlskdSoulseekClient(baseUrl: config.baseUrl, apiKey: config.apiKey);
});

/// Loads the persisted config, for overriding
/// [soulseekConfigControllerProvider] at bootstrap before the first frame —
/// same pattern as the theme/normalization preferences.
Future<SoulseekConfig> loadSoulseekConfigPreference() async {
  final prefs = await SharedPreferences.getInstance();
  return SoulseekConfig(
    host: prefs.getString(_hostKey) ?? '',
    port: prefs.getInt(_portKey) ?? 5030,
    apiKey: prefs.getString(_apiKeyKey) ?? '',
  );
}
