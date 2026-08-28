import 'package:flutter_test/flutter_test.dart';
import 'package:musicat/core/invite/invite_uri.dart';

void main() {
  group('FriendInvite build/parse round-trip', () {
    test('round-trips with a display name', () {
      const invite = FriendInvite(
        address: 'friend.example:8080',
        code: 'abc123',
        displayName: 'Ada Lovelace',
      );

      final uri = InviteUri.build(invite);
      expect(uri.scheme, 'musicat');
      expect(uri.host, 'friend');

      final parsed = InviteUri.parseUri(uri);
      expect(parsed, invite);
    });

    test('round-trips without a display name — name is omitted entirely', () {
      const invite = FriendInvite(
        address: 'friend.example:8080',
        code: 'abc123',
      );

      final uri = InviteUri.build(invite);
      expect(uri.queryParameters.containsKey('name'), isFalse);

      final parsed = InviteUri.parseUri(uri);
      expect(parsed, invite);
    });

    test('round-trips via the raw string form (parse), not just parseUri', () {
      const invite = FriendInvite(
        address: 'friend.example:8080',
        code: 'abc123',
        displayName: 'Bea',
      );

      final raw = InviteUri.build(invite).toString();
      final parsed = InviteUri.parse(raw);
      expect(parsed, invite);
    });

    test('a display name with spaces and special characters survives the '
        'round trip URL-encoded', () {
      const invite = FriendInvite(
        address: 'friend.example:8080',
        code: 'abc123',
        displayName: 'Jörge & Co. / "Ñ" 100%',
      );

      final raw = InviteUri.build(invite).toString();
      // The raw link text should not contain the literal display name
      // unescaped — it must have gone through URL encoding.
      expect(raw.contains('Jörge & Co. / "Ñ" 100%'), isFalse);

      final parsed = InviteUri.parse(raw);
      expect(parsed, invite);
    });

    test('an address with spaces round-trips URL-encoded too', () {
      const invite = FriendInvite(address: 'a weird host:8080', code: 'xyz');

      final raw = InviteUri.build(invite).toString();
      expect(raw.contains(' '), isFalse);

      final parsed = InviteUri.parse(raw);
      expect(parsed, invite);
    });
  });

  group('PlaylistInvite build/parse round-trip', () {
    test('round-trips with a name', () {
      const invite = PlaylistInvite(id: 'playlist-42', name: 'Road trip');

      final uri = InviteUri.build(invite);
      expect(uri.scheme, 'musicat');
      expect(uri.host, 'playlist');

      final parsed = InviteUri.parseUri(uri);
      expect(parsed, invite);
    });

    test('round-trips without a name — name is omitted entirely', () {
      const invite = PlaylistInvite(id: 'playlist-42');

      final uri = InviteUri.build(invite);
      expect(uri.queryParameters.containsKey('name'), isFalse);

      final parsed = InviteUri.parseUri(uri);
      expect(parsed, invite);
    });

    test('a name with spaces and special characters survives the round '
        'trip URL-encoded', () {
      const invite = PlaylistInvite(
        id: 'playlist-42',
        name: 'Summer 2026: road trip & BBQ 🎵',
      );

      final raw = InviteUri.build(invite).toString();
      expect(raw.contains('Summer 2026: road trip & BBQ 🎵'), isFalse);

      final parsed = InviteUri.parse(raw);
      expect(parsed, invite);
    });
  });

  group('InviteUri.parse rejects malformed input', () {
    test('rejects a non-musicat scheme', () {
      expect(
        () => InviteUri.parse('https://friend?address=a:1&code=x'),
        throwsA(isA<InviteUriException>()),
      );
    });

    test('rejects a scheme-less/garbage string', () {
      expect(
        () => InviteUri.parse('not a link at all'),
        throwsA(isA<InviteUriException>()),
      );
    });

    test('rejects an unrecognized host', () {
      expect(
        () => InviteUri.parse('musicat://something-else?foo=bar'),
        throwsA(isA<InviteUriException>()),
      );
    });

    test('rejects a friend invite missing the address', () {
      expect(
        () => InviteUri.parse('musicat://friend?code=abc'),
        throwsA(isA<InviteUriException>()),
      );
    });

    test('rejects a friend invite missing the code', () {
      expect(
        () => InviteUri.parse('musicat://friend?address=a.example:8080'),
        throwsA(isA<InviteUriException>()),
      );
    });

    test('rejects a friend invite with an empty address', () {
      expect(
        () => InviteUri.parse('musicat://friend?address=&code=abc'),
        throwsA(isA<InviteUriException>()),
      );
    });

    test('rejects a playlist invite missing the id', () {
      expect(
        () => InviteUri.parse('musicat://playlist?name=Road%20trip'),
        throwsA(isA<InviteUriException>()),
      );
    });

    test('rejects a playlist invite with an empty id', () {
      expect(
        () => InviteUri.parse('musicat://playlist?id='),
        throwsA(isA<InviteUriException>()),
      );
    });

    test('rejects a malformed percent-encoded query value as an '
        'InviteUriException, not a raw FormatException (regression: '
        'Uri.queryParameters lazily UTF-8-decodes and throws its own '
        'FormatException for something like "%e0%e0", which Uri.parse '
        'itself accepts as syntactically valid percent-encoding)', () {
      expect(
        () => InviteUri.parse('musicat://friend?address=%e0%e0&code=abc'),
        throwsA(isA<InviteUriException>()),
      );
    });

    test(
      'rejects malformed percent-encoding via parseUri too, not just parse',
      () {
        final uri = Uri.parse('musicat://friend?address=%e0%e0&code=abc');
        expect(
          () => InviteUri.parseUri(uri),
          throwsA(isA<InviteUriException>()),
        );
      },
    );

    test('InviteUriException.message is plain, presentable text', () {
      try {
        InviteUri.parse('musicat://playlist?name=x');
        fail('expected InviteUriException');
      } on InviteUriException catch (e) {
        expect(e.message, isNot(contains('Exception')));
        expect(e.message, isNotEmpty);
      }
    });
  });

  group('InviteUri.tryParse', () {
    test('returns the payload for a valid link', () {
      expect(
        InviteUri.tryParse('musicat://playlist?id=abc'),
        const PlaylistInvite(id: 'abc'),
      );
    });

    test('returns null instead of throwing for an invalid link', () {
      expect(InviteUri.tryParse('not a link'), isNull);
    });
  });

  group('InvitePayload equality', () {
    test('FriendInvite instances with the same fields are equal', () {
      expect(
        const FriendInvite(address: 'a:1', code: 'x'),
        const FriendInvite(address: 'a:1', code: 'x'),
      );
    });

    test('FriendInvite instances with different fields are not equal', () {
      expect(
        const FriendInvite(address: 'a:1', code: 'x'),
        isNot(const FriendInvite(address: 'a:1', code: 'y')),
      );
    });

    test('a FriendInvite and PlaylistInvite are never equal', () {
      // ignore: unrelated_type_equality_checks
      expect(
        const FriendInvite(address: 'a:1', code: 'x') ==
            const PlaylistInvite(id: 'a:1'),
        isFalse,
      );
    });
  });
}
