/// The `musicat://` custom-scheme invite links used by both the in-app
/// QR/share flow and the Android deep-link handler, so the URI format is
/// built and parsed in exactly one place. See:
///  - `qr_scanner_screen.dart` — camera-based scanning, feeds a raw scanned
///    string into [InviteUri.parse].
///  - `../routing/app_router.dart` — the Android deep-link handler, feeds
///    the incoming [Uri] into [InviteUri.parseUri].
library;

/// A parsed `musicat://` invite link: either a friend pairing invite or a
/// joint-playlist invite.
sealed class InvitePayload {
  const InvitePayload();
}

/// `musicat://friend?address=host:port&code=pairing-code&name=optional-
/// display-name`.
final class FriendInvite extends InvitePayload {
  const FriendInvite({
    required this.address,
    required this.code,
    this.displayName,
  });

  /// The inviter's `host:port`, as entered under "Your address" in Musicat
  /// Server settings.
  final String address;

  /// A one-time pairing code (server ADR 0020).
  final String code;

  /// The inviter's display name, if they supplied one.
  final String? displayName;

  @override
  bool operator ==(Object other) =>
      other is FriendInvite &&
      other.address == address &&
      other.code == code &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(address, code, displayName);

  @override
  String toString() =>
      'FriendInvite(address: $address, code: $code, '
      'displayName: $displayName)';
}

/// `musicat://playlist?id=<playlist id>&name=<optional playlist name>`.
final class PlaylistInvite extends InvitePayload {
  const PlaylistInvite({required this.id, this.name});

  final String id;
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is PlaylistInvite && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'PlaylistInvite(id: $id, name: $name)';
}

/// Thrown by [InviteUri.parse]/[InviteUri.parseUri] for anything that isn't
/// a recognized, well-formed `musicat://friend` or `musicat://playlist`
/// link. [message] is plain, user-presentable text (no raw exception
/// internals) — safe to show directly in a SnackBar/error label.
class InviteUriException implements Exception {
  const InviteUriException(this.message);

  final String message;

  @override
  String toString() => 'InviteUriException: $message';
}

/// Builds and parses `musicat://` invite links.
abstract final class InviteUri {
  /// The custom scheme every invite link uses.
  static const scheme = 'musicat';

  /// Builds the `musicat://` [Uri] for [payload].
  static Uri build(InvitePayload payload) => switch (payload) {
    FriendInvite(:final address, :final code, :final displayName) => Uri(
      scheme: scheme,
      host: 'friend',
      queryParameters: {
        'address': address,
        'code': code,
        if (displayName != null && displayName.isNotEmpty) 'name': displayName,
      },
    ),
    PlaylistInvite(:final id, :final name) => Uri(
      scheme: scheme,
      host: 'playlist',
      queryParameters: {
        'id': id,
        if (name != null && name.isNotEmpty) 'name': name,
      },
    ),
  };

  /// Parses a raw string — typically scanned from a QR code, pasted by the
  /// user, or delivered as `Intent.getData().toString()` on Android — into
  /// an [InvitePayload].
  ///
  /// Throws [InviteUriException] if [raw] isn't a well-formed `musicat://`
  /// invite link: wrong/missing scheme, unrecognized host, or a required
  /// query parameter is missing or empty.
  static InvitePayload parse(String raw) {
    final Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } on FormatException {
      throw const InviteUriException('That does not look like a link.');
    }
    return parseUri(uri);
  }

  /// As [parse], but for an already-parsed [Uri] — used by the Android
  /// deep-link handler, which receives a [Uri] straight from go_router.
  static InvitePayload parseUri(Uri uri) {
    if (uri.scheme != scheme) {
      throw InviteUriException('Not a "$scheme://" link.');
    }
    // `Uri.queryParameters` lazily UTF-8-decodes each value the first time
    // it's accessed, and throws a raw `FormatException` (not
    // `InviteUriException`) for a malformed percent-encoded value (e.g.
    // `%e0%e0`, which `Uri.parse` itself accepts as syntactically valid
    // percent-encoding — the failure only surfaces here). Guarded once,
    // right at the point of access, so every caller of this method keeps
    // the documented "throws only InviteUriException" contract.
    final Map<String, String> queryParameters;
    try {
      queryParameters = uri.queryParameters;
    } on FormatException {
      throw const InviteUriException('This invite link is malformed.');
    }
    switch (uri.host) {
      case 'friend':
        final address = queryParameters['address'];
        final code = queryParameters['code'];
        if (address == null || address.isEmpty) {
          throw const InviteUriException(
            'This invite link is missing the address.',
          );
        }
        if (code == null || code.isEmpty) {
          throw const InviteUriException(
            'This invite link is missing the pairing code.',
          );
        }
        final name = queryParameters['name'];
        return FriendInvite(
          address: address,
          code: code,
          displayName: (name == null || name.isEmpty) ? null : name,
        );
      case 'playlist':
        final id = queryParameters['id'];
        if (id == null || id.isEmpty) {
          throw const InviteUriException(
            'This invite link is missing the playlist id.',
          );
        }
        final name = queryParameters['name'];
        return PlaylistInvite(
          id: id,
          name: (name == null || name.isEmpty) ? null : name,
        );
      default:
        throw InviteUriException('Unrecognized invite link: "${uri.host}".');
    }
  }

  /// Like [parse], but returns `null` instead of throwing — for callers
  /// that only want to know whether a scanned/pasted string is a valid
  /// invite of a *specific* subtype (check the runtime type of the result).
  static InvitePayload? tryParse(String raw) {
    try {
      return parse(raw);
    } on InviteUriException {
      return null;
    }
  }
}
