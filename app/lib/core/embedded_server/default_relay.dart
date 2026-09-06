import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The relay this build of Musicat falls back to when the user has not
/// configured one of their own — **the one place to fill in to give every
/// fresh install a working relay.**
///
/// Empty today, deliberately: the only relay this project has ever actually
/// deployed is a bare IP on a home connection (ADR 0035), and whether to
/// bake that into a public, open-source repo is the project owner's call,
/// not something to guess at. Everything that consumes this — the fallback
/// itself ([resolveRelayUrl]), the "your own relay always wins" rule, the
/// copy in the server settings sheet, and the honest "this copy of Musicat
/// has nowhere to sign in" state on the account screen — is built and
/// tested against both states, so shipping a default is a one-line change
/// here and nothing else.
///
/// While it is empty, this app behaves exactly as it did before: an
/// embedded server with no relay configured, no account service derived
/// from it (see `accountServiceUrlForRelay`), and a UI that says so up
/// front instead of letting the user find out through a failed sign-in.
///
/// Must be a `ws://`/`wss://` (or `http(s)://`) URL of a deployed Musicat
/// relay, including its path, e.g. `ws://relay.example:8090/connect` — the
/// account service is derived from it rather than configured separately
/// (`accountServiceUrlForRelay`), so a value that isn't a relay this
/// project deployed will also break accounts.
const defaultRelayUrl = '';

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
