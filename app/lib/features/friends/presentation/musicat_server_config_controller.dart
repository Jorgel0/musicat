import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/federation/federation_client.dart';
import '../../../core/network/social/joint_playlist_client.dart';
import '../../../core/network/social/sharing_client.dart';
import '../domain/musicat_server_config.dart';

const _hostKey = 'musicatServerHost';
const _portKey = 'musicatServerPort';
const _myPublicAddressKey = 'musicatServerMyPublicAddress';

class MusicatServerConfigController extends Notifier<MusicatServerConfig> {
  MusicatServerConfigController([this._initial]);

  final MusicatServerConfig? _initial;

  @override
  MusicatServerConfig build() => _initial ?? MusicatServerConfig.empty;

  Future<void> save(MusicatServerConfig config) async {
    state = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hostKey, config.host);
    await prefs.setInt(_portKey, config.port);
    await prefs.setString(_myPublicAddressKey, config.myPublicAddress);
  }
}

final musicatServerConfigControllerProvider =
    NotifierProvider<MusicatServerConfigController, MusicatServerConfig>(
      MusicatServerConfigController.new,
    );

/// `null` when no Musicat Server is configured yet — the Friends screen
/// should treat this as "set up your server first", not an error.
final federationClientProvider = Provider<FederationClient?>((ref) {
  final config = ref.watch(musicatServerConfigControllerProvider);
  if (!config.isConfigured) return null;
  return FederationClient(baseUrl: config.baseUrl);
});

/// `null` when no Musicat Server is configured yet, same as
/// [federationClientProvider] — both talk to this device's own server.
final sharingClientProvider = Provider<SharingClient?>((ref) {
  final config = ref.watch(musicatServerConfigControllerProvider);
  if (!config.isConfigured) return null;
  return SharingClient(baseUrl: config.baseUrl);
});

/// `null` when no Musicat Server is configured yet, same as
/// [federationClientProvider].
final jointPlaylistClientProvider = Provider<JointPlaylistClient?>((ref) {
  final config = ref.watch(musicatServerConfigControllerProvider);
  if (!config.isConfigured) return null;
  return JointPlaylistClient(baseUrl: config.baseUrl);
});

/// This device's own full node info (id, public key, relay status), as
/// reported by its Musicat Server. `null` while unconfigured.
final myNodeInfoProvider = FutureProvider<MyNodeInfo?>((ref) async {
  final client = ref.watch(federationClientProvider);
  if (client == null) return null;
  return client.getMyNode();
});

/// This node's own id, e.g. to tell a joint-playlist item this device
/// added apart from ones a friend added. `null` while unconfigured.
final myNodeIdProvider = FutureProvider<String?>((ref) async {
  final info = await ref.watch(myNodeInfoProvider.future);
  return info?.nodeId;
});

/// Loads the persisted config, for overriding
/// [musicatServerConfigControllerProvider] at bootstrap before the first
/// frame — same pattern as the Soulseek backend preference.
Future<MusicatServerConfig> loadMusicatServerConfigPreference() async {
  final prefs = await SharedPreferences.getInstance();
  return MusicatServerConfig(
    host: prefs.getString(_hostKey) ?? '',
    port: prefs.getInt(_portKey) ?? 8080,
    myPublicAddress: prefs.getString(_myPublicAddressKey) ?? '',
  );
}
