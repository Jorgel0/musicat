import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/embedded_server/embedded_server.dart';
import 'friends_controller.dart';

/// Whether the Android-only "keep reachable in the background" concept
/// even applies on this platform — mirrors `qrScanningSupported`
/// (`core/invite/qr_scanner_screen.dart`)'s own plain-getter shape, for
/// the same reason: this is checked from UI code that only ever needs a
/// synchronous yes/no, and (like that getter) isn't something a widget
/// test on this repo's Linux dev/CI host can exercise either way — it's
/// verified for real on an actual Android device instead.
bool get androidBackgroundReachabilitySupported => Platform.isAndroid;

/// This device's manually-chosen override for whether its embedded server
/// (Android only — see `core/embedded_server/embedded_server.dart`)
/// should be kept reachable in the background via a real Android
/// foreground service, regardless of how many friends it currently has.
///
/// `null` (the default, and the persisted value until a user ever
/// explicitly flips the "Keep reachable in the background" toggle — see
/// `_ServerConfigSheet`) means "automatic": follow the live friend count
/// instead — see [desiredAndroidBackgroundReachableProvider]. `true`/
/// `false` mean the user has explicitly forced it on/off, which then wins
/// regardless of friend count from then on — a plain persisted value with
/// a sensible default, not something that keeps re-deriving itself once a
/// user has made an explicit choice, exactly mirroring how
/// [MusicatServerConfig.useEmbeddedServer] itself already works.
class AndroidBackgroundReachabilityOverrideController extends Notifier<bool?> {
  AndroidBackgroundReachabilityOverrideController([this._initial]);

  final bool? _initial;

  @override
  bool? build() => _initial;

  Future<void> save(bool? override) async {
    state = override;
    final prefs = await SharedPreferences.getInstance();
    if (override == null) {
      await prefs.remove(androidBackgroundReachabilityOverrideKey);
    } else {
      await prefs.setBool(androidBackgroundReachabilityOverrideKey, override);
    }
  }
}

final androidBackgroundReachabilityOverrideProvider =
    NotifierProvider<AndroidBackgroundReachabilityOverrideController, bool?>(
      AndroidBackgroundReachabilityOverrideController.new,
    );

/// Loads the persisted override, for overriding
/// [androidBackgroundReachabilityOverrideProvider] at bootstrap before the
/// first frame — same pattern as `loadMusicatServerConfigPreference`.
Future<bool?> loadAndroidBackgroundReachabilityOverride() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(androidBackgroundReachabilityOverrideKey);
}

/// Whether this device's embedded server *should* currently be reachable
/// in the background (a real Android foreground service, with its
/// unavoidable persistent notification) — purely computed, side-effect-
/// free, and safe to read on any platform; see
/// [androidBackgroundReachabilityEffectProvider] for what actually acts on
/// it. `true` whenever the manual override says so, or, absent an
/// override, whenever this device currently has at least one friend (a
/// user who's never touched the social feature shouldn't get a permanent
/// notification for a capability they don't use).
///
/// `autoDispose`, matching [friendsControllerProvider]'s own scoping: kept
/// alive only for as long as something (the Friends screen, or the
/// `_ServerConfigSheet` this toggle lives in) actually watches it, the
/// same as the live friend-status polling this ultimately depends on —
/// see [androidBackgroundReachabilityEffectProvider]'s own doc comment for
/// why that's fine even though it means the live 0→1 promotion only runs
/// while the Friends screen is open.
final desiredAndroidBackgroundReachableProvider = Provider.autoDispose<bool>((
  ref,
) {
  final override = ref.watch(androidBackgroundReachabilityOverrideProvider);
  if (override != null) return override;
  return ref.watch(
    friendsControllerProvider.select((s) => s.friends.isNotEmpty),
  );
});

/// Keeps this device's *real* Android background-service mode in sync
/// with [desiredAndroidBackgroundReachableProvider], for as long as
/// something watches this provider (see below for why that's `autoDispose`
/// rather than kicked off once for the whole app run the way
/// `embeddedServerProvider` is).
///
/// A plain [Provider], not a [Notifier]/state-holder: this provider's own
/// return value is meaningless (`void`) and nothing ever reads it back —
/// its only job is to own the two [Ref.listen] subscriptions below.
/// Deliberately built around `ref.listen` reacting to a state change, not
/// a bare side effect inlined directly in this `build()`: calling
/// [setAndroidBackgroundReachable] is not itself a Riverpod state write at
/// all (so it doesn't risk the ADR 0037/0039 "wrote to a not-yet-
/// initialized provider" bug class outright), but `ref.listen` is still
/// the standard, idiomatic way to run a side effect from inside a
/// provider without re-running it on every unrelated rebuild.
/// `fireImmediately: true` matters here: it's what applies a manual
/// override (or the last known friend-count truth) the moment this
/// provider first gets read, not only on some *later* change — otherwise
/// a user who force-enabled this in a previous session would never get
/// that choice re-applied to a freshly (re)started background service
/// just because nothing here *changed* this time.
///
/// `autoDispose`, deliberately *not* kept alive for the app's whole life:
/// [friendsControllerProvider] itself is `autoDispose`, tied to whether
/// the Friends screen is actually open, and polls this device's own
/// (locally-hosted, but not free — each friend's connection status is a
/// real check) federation server every 5 seconds while it is. Watching it
/// permanently from here would keep that running for the entire app
/// session regardless of whether the user ever looks at the Friends
/// screen again — real, avoidable battery/network cost for no benefit,
/// since a new friend can only ever be added while that screen is open in
/// the first place (`FriendsController.addFriend` redeems a code against
/// *this device's own* server and refreshes its own list synchronously as
/// part of that same call — there's no way for this device's friend count
/// to change from anything other than its own Friends screen being used).
/// [androidLastKnownHasFriendsKey] (`core/embedded_server/embedded_server.dart`)
/// is what makes the *correct* mode still survive to the next app cold
/// start even on a day the user never revisits that screen: this
/// provider's second listener below keeps that persisted flag fresh every
/// time it's actually known, which is every time this provider is alive
/// at all.
final androidBackgroundReachabilityEffectProvider = Provider.autoDispose<void>((
  ref,
) {
  ref.listen<bool>(
    friendsControllerProvider.select((s) => s.friends.isNotEmpty),
    (previous, hasFriends) => _persistLastKnownHasFriends(hasFriends),
    fireImmediately: true,
  );
  ref.listen<bool>(
    desiredAndroidBackgroundReachableProvider,
    (previous, next) => setAndroidBackgroundReachable(next),
    fireImmediately: true,
  );
});

Future<void> _persistLastKnownHasFriends(bool hasFriends) async {
  if (!Platform.isAndroid) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(androidLastKnownHasFriendsKey, hasFriends);
}
