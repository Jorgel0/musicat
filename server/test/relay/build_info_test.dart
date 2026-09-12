import 'dart:convert';

import 'package:musicat_server/src/relay/build_info.dart';
import 'package:test/test.dart';

void main() {
  group('BuildInfo.forThisProcess', () {
    test('never reports the literal git-archive placeholder, whatever state '
        'this copy of the repository is in -- the whole point is that an '
        'unsubstituted value must not look like an answer', () {
      final info = BuildInfo.forThisProcess();

      expect(jsonEncode(info.toJson()), isNot(contains(r'Format')));
      expect(info.commit, anyOf(isNull, matches(RegExp(r'^[0-9a-f]{40}$'))));
    });

    test('degrades to a null commit when running from a git checkout, where '
        'no substitution has happened', () {
      // The test suite is always run from a checkout, never from an unpacked
      // `git archive` tarball -- so this is the deployed-versus-development
      // distinction, asserted from the development side.
      final info = BuildInfo.forThisProcess();

      expect(info.commit, isNull);
      expect(info.commitTime, isNull);
      expect(info.toJson()['commit'], isNull);
      expect(info.toJson()['commitTime'], isNull);
    });

    test('always reports a startedAt, in UTC, from the moment it was built '
        'rather than the moment it is read', () async {
      final before = DateTime.now().toUtc();
      final info = BuildInfo.forThisProcess();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(info.startedAt.isUtc, isTrue);
      expect(
        info.startedAt.isBefore(before.subtract(const Duration(hours: 1))),
        isFalse,
      );
      // Read a second time, well after construction: it is a stored value,
      // not a clock read on access.
      expect(info.startedAt, info.startedAt);
      expect(info.toJson()['startedAt'], info.startedAt.toIso8601String());
    });

    test('takes an explicit startedAt and normalizes it to UTC', () {
      final info = BuildInfo.forThisProcess(
        startedAt: DateTime.parse('2026-09-06T10:00:00+02:00'),
      );

      expect(info.startedAt.isUtc, isTrue);
      expect(info.startedAt, DateTime.utc(2026, 9, 6, 8));
    });
  });

  group('BuildInfo.fromJson', () {
    test('round-trips a real response', () {
      final original = BuildInfo(
        commit: 'a' * 40,
        commitTime: DateTime.utc(2026, 9, 6, 20, 40, 7),
        startedAt: DateTime.utc(2026, 9, 6, 21, 3, 11),
      );

      final parsed = BuildInfo.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(parsed.commit, original.commit);
      expect(parsed.commitTime, original.commitTime);
      expect(parsed.startedAt, original.startedAt);
    });

    test('reads a relay that reports no commit at all, rather than throwing '
        '-- that relay is exactly the one being diagnosed', () {
      final parsed = BuildInfo.fromJson({
        'commit': null,
        'commitTime': null,
        'startedAt': '2026-09-06T21:03:11.000Z',
      });

      expect(parsed.commit, isNull);
      expect(parsed.commitTime, isNull);
      expect(parsed.startedAt, DateTime.utc(2026, 9, 6, 21, 3, 11));
    });

    test('survives missing and malformed fields', () {
      final parsed = BuildInfo.fromJson({
        'commitTime': 'not a date',
        'startedAt': 42,
      });

      expect(parsed.commit, isNull);
      expect(parsed.commitTime, isNull);
      // Obviously wrong rather than plausibly recent: no real relay can
      // claim to have started at the epoch.
      expect(
        parsed.startedAt,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    });

    test('normalizes a non-UTC timestamp, so two relays in two timezones '
        'compare', () {
      final parsed = BuildInfo.fromJson({
        'commit': 'b' * 40,
        'commitTime': '2026-09-06T22:40:07+02:00',
        'startedAt': '2026-09-06T23:00:00+02:00',
      });

      expect(parsed.commitTime, DateTime.utc(2026, 9, 6, 20, 40, 7));
      expect(parsed.startedAt, DateTime.utc(2026, 9, 6, 21));
    });
  });

  group('RelayVersionCheck', () {
    BuildInfo running(String? commit) => BuildInfo(
      commit: commit,
      commitTime: DateTime.utc(2026, 9, 6),
      startedAt: DateTime.utc(2026, 9, 6, 1),
    );

    test('passes on an exact match', () {
      final check = RelayVersionCheck.against(running('a' * 40), 'a' * 40);

      expect(check.ok, isTrue);
      expect(check.message, contains('a' * 40));
    });

    test('passes on the short prefix a human copies out of git log', () {
      final check = RelayVersionCheck.against(
        running('95cf20b${'0' * 33}'),
        '95cf20b',
      );

      expect(check.ok, isTrue);
    });

    test('is case-insensitive, since a pasted hash may be either', () {
      final check = RelayVersionCheck.against(
        running('abcdef1${'0' * 33}'),
        'ABCDEF1',
      );

      expect(check.ok, isTrue);
    });

    test('fails a mismatch, and names the commit actually running -- the '
        'number the operator needs', () {
      final check = RelayVersionCheck.against(running('a' * 40), 'b' * 40);

      expect(check.ok, isFalse);
      expect(check.message, contains('a' * 40));
      expect(check.message, contains('b' * 40));
    });

    test('fails a relay that reports no commit: nothing about it can be '
        'established, which is not the same as "probably fine"', () {
      final check = RelayVersionCheck.against(running(null), 'a' * 40);

      expect(check.ok, isFalse);
      expect(check.message, contains('git archive'));
    });

    test('refuses an expectation too short to mean anything', () {
      final check = RelayVersionCheck.against(running('abc${'0' * 37}'), 'abc');

      expect(check.ok, isFalse);
      expect(check.message, contains('at least'));
    });
  });
}
