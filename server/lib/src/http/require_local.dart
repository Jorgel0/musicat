import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:shelf/shelf.dart';

/// The header a non-loopback caller must present a matching value in for
/// [requireLocal] to let it through -- see its `appApiKey` parameter. Chosen
/// distinct from `X-API-Key` (`slskd_gateway.dart`'s header, presented
/// *outbound* to slskd) even though the two only differ in case -- headers
/// are case-insensitive on both ends anyway -- because they authenticate
/// entirely different things: that one lets this server talk to slskd, this
/// one lets a genuinely remote, explicitly self-hosted Musicat Server (see
/// `docs/self-hosting.md`) accept calls from an app that isn't running on
/// the same machine.
const appApiKeyHeader = 'X-Api-Key';

Response _error(String message, {required int status}) => Response(
  status,
  body: jsonEncode({'error': message}),
  headers: {'content-type': 'application/json'},
);

/// Compares [a] and [b] for equality without leaking how many leading
/// characters matched through response-timing -- the usual risk of a plain
/// `==` on a secret. Hashes both sides first (SHA-256, via the
/// `cryptography` package this project already depends on and already uses
/// this exact way elsewhere -- see `node_identity.dart`) so both digests are
/// always the same fixed length regardless of [a]/[b]'s own lengths, then
/// XOR-folds every byte of both digests unconditionally -- no early return
/// the moment a mismatch is found, which is what makes a naive comparison
/// loop timing-safe in the first place.
Future<bool> _constantTimeEquals(String a, String b) async {
  final hashA = await Sha256().hash(utf8.encode(a));
  final hashB = await Sha256().hash(utf8.encode(b));
  var difference = 0;
  for (var i = 0; i < hashA.bytes.length; i++) {
    difference |= hashA.bytes[i] ^ hashB.bytes[i];
  }
  return difference == 0;
}

/// Wraps [inner] so it only ever runs for a request that arrived on this
/// exact machine's own loopback interface (127.0.0.1 / ::1) -- i.e. this
/// device's own app talking to its own local server, never a friend's
/// server, another device on the LAN, or anyone reaching this node's public
/// IP or relay tunnel -- **unless** [appApiKey] is configured and the
/// request presents a matching one, the explicit opt-in escape hatch for
/// genuinely remote, intentionally self-hosted setups (see
/// `docs/self-hosting.md`): running Musicat Server on a separate machine
/// (NAS/VPS) and pointing the app at it over the real network, which the
/// loopback-only default would otherwise make impossible even for an
/// operator who wants exactly that. The embedded-server case (ADR
/// 0040-0043), which is now the default and never needs any of this, is
/// completely unaffected either way -- it's always loopback.
///
/// This is how every *app-facing* route (this node's own Soulseek backend,
/// its own shared-track/library bookkeeping, its own joint playlists, and a
/// handful of app-facing `/api/v1/federation/*` routes -- see the doc
/// comment on `buildFederationRouter` in federation_routes.dart) is
/// protected. Before this, none of them checked anything beyond "can this
/// caller reach the server at all" (a known, deliberate gap earlier ADRs
/// flagged), which meant anyone reachable on the LAN, at this node's direct
/// public IP, or through the relay (just by knowing its `nodeId`) could
/// mint themselves a fresh pairing code and immediately redeem it as their
/// own identity -- self-granting trust with zero involvement from this
/// device's real owner -- then list/remove its real friends, manage its
/// shared tracks and joint playlists, or control its Soulseek backend.
///
/// Genuinely federation-facing routes (what a *friend's* server calls --
/// pairing-code redemption, and everything under `/api/v1/sharing/`) must
/// never be wrapped in this: they need to keep working precisely when the
/// caller is *not* this device.
///
/// Reads `request.context['shelf.io.connection_info']`, the
/// [HttpConnectionInfo] `shelf_io`'s real `serve()` attaches to every
/// request that arrived through an actual `dart:io` socket. A request is
/// only let through to [inner] if that key is present *and* its
/// `.remoteAddress.isLoopback` is `true`; anything else -- a real
/// non-loopback address, or the key missing entirely -- gets a `403`.
///
/// The "missing entirely" case matters more than it looks: a request that
/// arrives through `RelayClient._handle()` (relay_client.dart) is a
/// synthetic [Request] built by hand from a relay-tunnel message, with no
/// real socket behind it at all, so it never carries this context key.
/// Treating "missing" the same as "not loopback" is deliberate, not an
/// oversight to fix later: the relay exists to carry friend-to-friend
/// network traffic, never "my own app talking to my own local server", so
/// an app-facing route must stay unreachable through it too. Treating
/// "missing" as "trusted" instead would reopen exactly the hole this closes
/// for anyone routing through the relay.
///
/// [appApiKey], when non-null and non-empty, is this operator's configured
/// shared secret (`MUSICAT_APP_API_KEY` -- mirrors the existing
/// `SLSKD_API_KEY` pattern, `server/README.md`/`docs/self-hosting.md`). A
/// non-loopback request is let through anyway if it carries a matching
/// value in the [appApiKeyHeader] header, compared with [_constantTimeEquals]
/// rather than a plain string `==` since this is a secret. A non-loopback
/// request with that header missing, empty, or wrong -- or [appApiKey] left
/// unconfigured entirely, the default -- gets the same `403` as before; a
/// loopback request never needs the key at all, [appApiKey] configured or
/// not.
Handler requireLocal(Handler inner, {String? appApiKey}) {
  return (Request request) async {
    final connectionInfo = request.context['shelf.io.connection_info'];
    final isLoopback =
        connectionInfo is HttpConnectionInfo &&
        connectionInfo.remoteAddress.isLoopback;
    if (isLoopback) {
      return inner(request);
    }

    if (appApiKey != null && appApiKey.isNotEmpty) {
      final provided = request.headers[appApiKeyHeader];
      if (provided != null && await _constantTimeEquals(provided, appApiKey)) {
        return inner(request);
      }
    }

    return _error(
      'This endpoint is only reachable from this device itself.',
      status: 403,
    );
  };
}
