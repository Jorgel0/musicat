import 'dart:io';

import 'package:musicat_server/src/identity/node_identity.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'musicat_server_identity_test_',
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('creates a node identity with a hex-encoded SHA-256 nodeId', () async {
    final identity = await NodeIdentityStore(tempDir).loadOrCreate();

    expect(identity.nodeId, hasLength(64));
    expect(identity.nodeId, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('persists the identity across loads from the same directory', () async {
    final first = await NodeIdentityStore(tempDir).loadOrCreate();
    final second = await NodeIdentityStore(tempDir).loadOrCreate();

    expect(second.nodeId, first.nodeId);
  });

  test('different data directories get different node identities', () async {
    final otherDir = Directory.systemTemp.createTempSync(
      'musicat_server_identity_test_other_',
    );
    addTearDown(() => otherDir.deleteSync(recursive: true));

    final a = await NodeIdentityStore(tempDir).loadOrCreate();
    final b = await NodeIdentityStore(otherDir).loadOrCreate();

    expect(a.nodeId, isNot(equals(b.nodeId)));
  });

  test('creates the data directory if it does not exist yet', () async {
    final nestedDir = Directory('${tempDir.path}/nested/data');

    final identity = await NodeIdentityStore(nestedDir).loadOrCreate();

    expect(nestedDir.existsSync(), isTrue);
    expect(File('${nestedDir.path}/node_identity.json').existsSync(), isTrue);
    expect(identity.nodeId, hasLength(64));
  });
}
