/// The commit this file was archived from, substituted **by `git archive`**
/// at deploy time because this file is marked `export-subst` in
/// `server/.gitattributes`. In a plain git checkout -- and in any copy of
/// this repository that was cloned rather than archived -- no substitution
/// has happened and this is still the literal placeholder, which is exactly
/// the state [BuildInfo.forThisProcess] detects and reports as "unknown"
/// rather than printing back at a caller as if it were a commit.
///
/// A raw string, so Dart doesn't read `$Format` as an interpolation; the
/// bytes on disk are what `git archive` looks for.
const String _archivedCommit = r'$Format:%H$';

/// That commit's own committer date (`%cI`, strict ISO 8601), substituted
/// the same way.
///
/// This is deliberately the commit's date and not a build timestamp: this
/// project's relay has **no build step at all** (`git archive` -> scp ->
/// `dart pub get` -> `systemctl restart`), so there is no moment of
/// compilation to stamp. The commit's date is the one truthful, verifiable
/// thing available -- and paired with [BuildInfo.startedAt] below it answers
/// the two questions an operator actually has: "how old is this code?" and
/// "did my restart take?".
const String _archivedCommitTime = r'$Format:%cI$';

/// A full 40-character git object name. Used to tell a substituted value
/// from an unsubstituted placeholder without writing a second copy of the
/// placeholder here -- which `git archive` would cheerfully substitute too,
/// leaving the comparison always false in exactly the deployment this whole
/// mechanism exists for.
final RegExp _fullCommitSha = RegExp(r'^[0-9a-f]{40}$');

/// The shortest commit prefix [RelayVersionCheck] will accept as an
/// expectation. Below this, a "match" is mostly coincidence.
const int _minimumCommitPrefixLength = 7;

/// What the running relay says about itself at `GET /version`.
///
/// **Why this exists at all.** The deployed relay has been silently stale
/// three separate times (ADR 0035, 0047, 0055). In the last one the running
/// binary predated the entire account service, which meant four ADRs' worth
/// of "verified end to end" had in fact only ever exercised relays the tests
/// spawned themselves. Deployment is `tar`+`scp`, so nothing tied the running
/// process to a commit and nothing reported the mismatch. This is the missing
/// half of that: a value a real-network test (or a human, or
/// `tool/check_relay_version.dart`) can assert *before* believing anything it
/// measured afterwards.
///
/// Unauthenticated on purpose, like `GET /directory/lookup`: it discloses a
/// public commit hash of a public repository and a process start time. That
/// is meaningfully less than the relay already tells any stranger by
/// answering at all, and a version endpoint nobody can read without a
/// credential is a version endpoint nobody checks.
class BuildInfo {
  const BuildInfo({
    required this.commit,
    required this.commitTime,
    required this.startedAt,
  });

  /// Reads the archive-substituted constants above, or reports them absent.
  ///
  /// [startedAt] defaults to now, and the intent is that this is constructed
  /// **once, when the process starts** (see [RelayHub]'s constructor) rather
  /// than per request -- a lazily-initialized top-level `final` would have
  /// quietly reported the time of the *first `/version` request* instead,
  /// which is the same number right up until it matters. It is a parameter
  /// only so tests can be deterministic.
  factory BuildInfo.forThisProcess({DateTime? startedAt}) {
    final commitTime = DateTime.tryParse(_archivedCommitTime);
    return BuildInfo(
      commit: _fullCommitSha.hasMatch(_archivedCommit) ? _archivedCommit : null,
      commitTime: commitTime?.toUtc(),
      startedAt: (startedAt ?? DateTime.now()).toUtc(),
    );
  }

  /// The commit this build was archived from, or `null` when it was not
  /// archived at all -- a developer running `dart run bin/relay.dart`
  /// straight from a checkout. `null` rather than the literal placeholder, or
  /// some invented "dev" string: the caller's question is "is this the commit
  /// I expect", and the honest answer here is "this cannot say", which is not
  /// the same as "no".
  final String? commit;

  /// [commit]'s committer date in UTC, or `null` on the same
  /// not-from-an-archive path. See [_archivedCommitTime] for why this is a
  /// commit date rather than a build date.
  final DateTime? commitTime;

  /// When this relay process started, in UTC -- the field that catches the
  /// specific failure the others cannot: a deploy that copied the new files
  /// and never restarted the service.
  final DateTime startedAt;

  Map<String, dynamic> toJson() => {
    'commit': commit,
    'commitTime': commitTime?.toIso8601String(),
    'startedAt': startedAt.toIso8601String(),
  };

  /// Parses a `GET /version` response. Tolerant on purpose: a relay old
  /// enough to be missing a field is precisely the relay this is used to
  /// diagnose, so a missing or malformed value reads as `null` instead of
  /// throwing and telling the operator nothing.
  ///
  /// [startedAt] is the one field with no sensible null: a response without a
  /// usable one falls back to the epoch, which no real relay can claim and
  /// which therefore reads as obviously wrong rather than plausible.
  factory BuildInfo.fromJson(Map<String, dynamic> json) => BuildInfo(
    commit: json['commit'] as String?,
    commitTime: json['commitTime'] is String
        ? DateTime.tryParse(json['commitTime'] as String)?.toUtc()
        : null,
    startedAt:
        (json['startedAt'] is String
                ? DateTime.tryParse(json['startedAt'] as String)
                : null)
            ?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

/// The verdict of "is the relay I am about to test against running the
/// commit I think it is" -- the whole point of [BuildInfo] existing, kept
/// here as a pure function of two values so it can be tested without a
/// network, and so `tool/check_relay_version.dart` is a thin shell around
/// something covered rather than the only place the rule lives.
class RelayVersionCheck {
  const RelayVersionCheck._({required this.ok, required this.message});

  /// Compares [running] (what the relay reported) against [expectedCommit]
  /// (what the caller believes it deployed).
  ///
  /// [expectedCommit] may be a short prefix, since that is what a human
  /// copies out of `git log --oneline` -- but not shorter than
  /// [_minimumCommitPrefixLength], because a three-character "match" is
  /// mostly luck and this exists to stop false confidence, not to create a
  /// cheaper source of it.
  ///
  /// A relay that reports **no** commit is a failure, not an unknown: it
  /// means the deployment was not made with `git archive`, so nothing about
  /// what is running there can be established at all -- which is the exact
  /// situation ADR 0055 spent a session untangling.
  factory RelayVersionCheck.against(BuildInfo running, String expectedCommit) {
    final expected = expectedCommit.trim().toLowerCase();
    if (expected.length < _minimumCommitPrefixLength) {
      return RelayVersionCheck._(
        ok: false,
        message:
            'Refusing to check against "$expected": give at least '
            '$_minimumCommitPrefixLength characters of a commit hash.',
      );
    }

    final commit = running.commit;
    if (commit == null) {
      return const RelayVersionCheck._(
        ok: false,
        message:
            'The relay reports no commit. It was not deployed with '
            '`git archive`, so what it is running cannot be established -- '
            'redeploy it the documented way before trusting any result '
            'measured against it.',
      );
    }

    if (!commit.toLowerCase().startsWith(expected)) {
      return RelayVersionCheck._(
        ok: false,
        message:
            'The relay is running commit $commit, not $expected. Anything '
            'you test against it is testing that older code.',
      );
    }

    return RelayVersionCheck._(
      ok: true,
      message:
          'The relay is running commit $commit '
          '(committed ${running.commitTime?.toIso8601String() ?? "unknown"}, '
          'process started ${running.startedAt.toIso8601String()}).',
    );
  }

  /// Whether the relay is running the expected commit. `false` is always
  /// worth stopping for: every other outcome here means a test result would
  /// be about code nobody chose.
  final bool ok;

  /// A line to print. Says what is running and why that is or isn't fine --
  /// never just "mismatch", since the number that was actually found is the
  /// part an operator needs.
  final String message;
}
