import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/embedded_server/embedded_server.dart';
import '../../../core/network/federation/federation_client.dart';
import '../../../core/network/social/joint_playlist_client.dart';
import '../../../core/network/social/sharing_client.dart';
import '../domain/musicat_server_config.dart';

const _hostKey = 'musicatServerHost';
const _portKey = 'musicatServerPort';
const _myPublicAddressKey = 'musicatServerMyPublicAddress';
const _myDisplayNameKey = 'musicatServerMyDisplayName';
const _useEmbeddedServerKey = 'musicatServerUseEmbeddedServer';
const _apiKeyKey = 'musicatServerApiKey';
const _relayUrlKey = 'musicatServerRelayUrl';

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
    await prefs.setString(_myDisplayNameKey, config.myDisplayName ?? '');
    await prefs.setBool(_useEmbeddedServerKey, config.useEmbeddedServer);
    await prefs.setString(_apiKeyKey, config.apiKey ?? '');
    await prefs.setString(_relayUrlKey, config.relayUrl ?? '');
  }
}

final musicatServerConfigControllerProvider =
    NotifierProvider<MusicatServerConfigController, MusicatServerConfig>(
      MusicatServerConfigController.new,
    );

/// The config this device's federation feature actually talks to right
/// now — [musicatServerConfigControllerProvider]'s persisted/manual value
/// unchanged when [MusicatServerConfig.useEmbeddedServer] is `false`, or,
/// when it's `true`, that same config with [MusicatServerConfig.host]/
/// [MusicatServerConfig.port] substituted for the embedded server's own
/// `localhost:<port>` — `isConfigured` stays `false` until
/// [embeddedServerProvider] actually resolves to a running server (still
/// starting up, unsupported on this platform, or failed to start all
/// count as "not configured yet", same as leaving the manual fields
/// blank).
///
/// A plain synchronous [Provider], not a [FutureProvider]: every consumer
/// of the *previous* `musicatServerConfigControllerProvider`-derived
/// providers below (`federationClientProvider` and friends) already only
/// needs a synchronous `MusicatServerConfig` to decide `isConfigured`/
/// `baseUrl` — turning this into an async value would ripple that
/// `AsyncValue` handling out to everything that reads them, for no benefit
/// they actually need. It only ever *reads* [embeddedServerProvider]'s
/// current [AsyncValue] via `ref.watch().when(...)` (never writes to any
/// provider's state), so there's no window where a not-yet-initialized
/// provider gets read or written from a widget-lifecycle callback — the
/// exact bug class ADR 0037/0039 already hit twice. See
/// `musicat_server_config_controller_test.dart` for `ProviderContainer`
/// tests proving a cold read of this (and of `friendsControllerProvider`,
/// which now transitively depends on it) never throws.
final effectiveMusicatServerConfigProvider = Provider<MusicatServerConfig>((
  ref,
) {
  final raw = ref.watch(musicatServerConfigControllerProvider);
  if (!raw.useEmbeddedServer) return raw;

  final embedded = ref.watch(embeddedServerProvider);
  return embedded.when(
    data: (info) => info == null
        ? raw.copyWith(host: '')
        : raw.copyWith(host: 'localhost', port: info.port),
    loading: () => raw.copyWith(host: ''),
    error: (error, stackTrace) => raw.copyWith(host: ''),
  );
});

/// `null` when no Musicat Server is configured yet — the Friends screen
/// should treat this as "set up your server first", not an error.
final federationClientProvider = Provider<FederationClient?>((ref) {
  final config = ref.watch(effectiveMusicatServerConfigProvider);
  if (!config.isConfigured) return null;
  return FederationClient(baseUrl: config.baseUrl, apiKey: config.apiKey);
});

/// `null` when no Musicat Server is configured yet, same as
/// [federationClientProvider] — both talk to this device's own server.
final sharingClientProvider = Provider<SharingClient?>((ref) {
  final config = ref.watch(effectiveMusicatServerConfigProvider);
  if (!config.isConfigured) return null;
  return SharingClient(baseUrl: config.baseUrl, apiKey: config.apiKey);
});

/// `null` when no Musicat Server is configured yet, same as
/// [federationClientProvider].
final jointPlaylistClientProvider = Provider<JointPlaylistClient?>((ref) {
  final config = ref.watch(effectiveMusicatServerConfigProvider);
  if (!config.isConfigured) return null;
  return JointPlaylistClient(baseUrl: config.baseUrl, apiKey: config.apiKey);
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
  final myDisplayName = prefs.getString(_myDisplayNameKey);
  // `null` (the key was never saved) means this is a fresh install/first
  // run on this device: default to the embedded server on platforms that
  // support it (Linux, Windows, Android — no setup needed for the common
  // case), `false` elsewhere (iOS isn't a target of this app at all yet,
  // see docs/adr/0001-flutter-multiplatform.md). Once the user has ever
  // explicitly saved a choice either way, that persisted value wins from
  // then on, regardless of platform.
  final persistedUseEmbeddedServer = prefs.getBool(_useEmbeddedServerKey);
  final apiKey = prefs.getString(_apiKeyKey);
  final relayUrl = prefs.getString(_relayUrlKey);
  return MusicatServerConfig(
    host: prefs.getString(_hostKey) ?? '',
    port: prefs.getInt(_portKey) ?? 8080,
    myPublicAddress: prefs.getString(_myPublicAddressKey) ?? '',
    myDisplayName: (myDisplayName == null || myDisplayName.isEmpty)
        ? null
        : myDisplayName,
    useEmbeddedServer: persistedUseEmbeddedServer ?? embeddedServerSupported,
    apiKey: (apiKey == null || apiKey.isEmpty) ? null : apiKey,
    relayUrl: (relayUrl == null || relayUrl.isEmpty) ? null : relayUrl,
  );
}
