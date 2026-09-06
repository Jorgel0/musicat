import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The relay this build of Musicat falls back to when the user has not
/// configured one of their own — **the one place to fill in to give every
/// fresh install a working relay.**
///
/// A **name, not an IP, and `wss://` rather than `ws://`** — both on
/// purpose. ADR 0035's deployment was a bare home IP over plain
/// WebSocket, which had two problems a default cannot live with: every
/// installed copy would break at once and unfixably the day the ISP
/// changed that address, and every request — including the password sent
/// at sign-in — would cross the network in the clear. A DNS name kept
/// current by the relay host, plus a Let's Encrypt certificate, fixes
/// both. See ADR 0055.
///
/// Emptying this string is a supported state, not a broken one: the app
/// then behaves exactly as it did before a default existed (no relay, no
/// account service derived from it, and a UI that says so up front rather
/// than letting the user discover it through a failed sign-in). Anyone
/// forking Musicat should replace it with their own relay, or clear it.
///
/// Must be a `ws://`/`wss://` (or `http(s)://`) URL of a deployed Musicat
/// relay, including its path — the account service is derived from it
/// rather than configured separately (`accountServiceUrlForRelay`), so a
/// value that isn't a relay this project deployed will also break
/// accounts.
const defaultRelayUrl = 'wss://musicat-relay.duckdns.org/connect';

/// Which relay this device should actually use: [configured] (whatever the
/// user typed in the server settings sheet) when they set one, and
/// [defaultUrl] — this build's own [defaultRelayUrl] — otherwise. `null`
/// when there is neither.
///
/// Two rules this encodes, both deliberate:
///
/// - **A stored value always wins.** The default is resolved here, at the
///   moment the relay is used, and is never written into the user's own
///   saved config — so someone self-hosting their own relay can never have
///   it silently replaced by a default that appears in a later build.
/// - **Empty means "use the default", not "no relay".** Clearing the field
///   is how you go back to the built-in one; the field's own copy says so.
///   Deliberately leaving *no* way to say "no relay at all" while a default
///   exists: that state has no use (a relay this device never reaches costs
///   nothing) and would be one more thing to get stuck in.
///
/// [defaultUrl] is a parameter rather than a direct read of the constant so
/// tests can exercise both a build that ships a relay and one that does
/// not, whichever way [defaultRelayUrl] happens to be set right now.
String? resolveRelayUrl(
  String? configured, {
  String defaultUrl = defaultRelayUrl,
}) {
  if (configured != null && configured.isNotEmpty) return configured;
  return defaultUrl.isEmpty ? null : defaultUrl;
}

/// [defaultRelayUrl], as a provider — the single place both halves of the
/// app read it from: the UI (to know whether accounts have anywhere to go,
/// and what the relay field's own copy should say) and
/// `embeddedServerProvider` (which hands it to the server it starts).
/// Exists as a provider rather than only a constant so a test can exercise
/// both a build that ships a relay and one that does not, whichever way
/// the constant happens to be set. Nothing in the app itself ever
/// overrides it.
final defaultRelayUrlProvider = Provider<String>((ref) => defaultRelayUrl);
