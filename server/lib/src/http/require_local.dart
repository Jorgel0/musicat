import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

Response _error(String message, {required int status}) => Response(
  status,
  body: jsonEncode({'error': message}),
  headers: {'content-type': 'application/json'},
);

/// Wraps [inner] so it only ever runs for a request that arrived on this
/// exact machine's own loopback interface (127.0.0.1 / ::1) -- i.e. this
/// device's own app talking to its own local server, never a friend's
/// server, another device on the LAN, or anyone reaching this node's public
/// IP or relay tunnel.
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
Handler requireLocal(Handler inner) {
  return (Request request) async {
    final connectionInfo = request.context['shelf.io.connection_info'];
    if (connectionInfo is! HttpConnectionInfo ||
        !connectionInfo.remoteAddress.isLoopback) {
      return _error(
        'This endpoint is only reachable from this device itself.',
        status: 403,
      );
    }
    return inner(request);
  };
}
