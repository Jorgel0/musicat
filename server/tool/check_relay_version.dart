import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:musicat_server/src/relay/build_info.dart';

/// Asserts that a **deployed** relay is running the commit you think it is,
/// before you believe anything you measure against it.
///
/// This is the operational half of `GET /version` (see [BuildInfo]). A
/// version endpoint nobody checks solves nothing, and the failure it exists
/// for is not hypothetical: the deployed relay has been silently stale three
/// times (ADR 0035, 0047, 0055), and the last time it invalidated four ADRs'
/// worth of end-to-end claims at once.
///
/// ```
/// # Against whatever is checked out here (the usual case):
/// dart run tool/check_relay_version.dart https://musicat-relay.duckdns.org
///
/// # Against a specific commit, e.g. the one you meant to deploy:
/// dart run tool/check_relay_version.dart https://musicat-relay.duckdns.org 9fa3337
/// ```
///
/// Exit codes are the contract, so this can be the first line of a script
/// that then runs a real-network test: `0` the relay is running that commit,
/// `1` it is running something else (or will not say), `2` it could not be
/// asked at all.
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2 || args.first.startsWith('-')) {
    stderr.writeln(
      'Usage: dart run tool/check_relay_version.dart <relay-base-url> '
      '[expected-commit]\n'
      '\n'
      '  <relay-base-url>    e.g. https://musicat-relay.duckdns.org\n'
      '  [expected-commit]   defaults to this checkout\'s HEAD',
    );
    exit(2);
  }

  final baseUrl = args.first.endsWith('/')
      ? args.first.substring(0, args.first.length - 1)
      : args.first;
  final expected = args.length == 2 ? args[1] : await _headCommit();
  if (expected == null) {
    stderr.writeln(
      'Could not read HEAD from git here, and no commit was given. Pass one '
      'explicitly.',
    );
    exit(2);
  }

  final uri = Uri.parse('$baseUrl/version');
  final http.Response response;
  try {
    response = await http.get(uri).timeout(const Duration(seconds: 10));
  } catch (error) {
    // Deliberately exit 2, not 1: "the relay did not answer" is a different
    // thing from "the relay answered and it is the wrong code", and a script
    // wrapping this one may well want to treat them differently.
    stderr.writeln('Could not reach $uri: $error');
    exit(2);
  }

  if (response.statusCode == 404) {
    stderr.writeln(
      'The relay at $baseUrl has no /version endpoint at all, which means it '
      'predates this check -- so it is certainly not running $expected.',
    );
    exit(1);
  }
  if (response.statusCode != 200) {
    stderr.writeln('$uri answered ${response.statusCode}: ${response.body}');
    exit(2);
  }

  final BuildInfo running;
  try {
    running = BuildInfo.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  } catch (error) {
    stderr.writeln('$uri answered something unreadable: ${response.body}');
    exit(2);
  }

  final check = RelayVersionCheck.against(running, expected);
  (check.ok ? stdout : stderr).writeln(check.message);
  exit(check.ok ? 0 : 1);
}

/// This checkout's `HEAD`, or `null` if git can't answer (not a repository,
/// git not installed) -- in which case the caller has to name the commit
/// itself rather than have one guessed for it.
Future<String?> _headCommit() async {
  try {
    final result = await Process.run('git', ['rev-parse', 'HEAD']);
    if (result.exitCode != 0) return null;
    final commit = (result.stdout as String).trim();
    return commit.isEmpty ? null : commit;
  } catch (_) {
    return null;
  }
}
