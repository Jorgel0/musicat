import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

/// A Musicat Server node's cryptographic identity.
///
/// [nodeId] is the SHA-256 fingerprint of the node's Ed25519 public key,
/// hex-encoded. It is the stable identifier other nodes will use to
/// recognize this server once Phase 4 pins friend trust to it, so it must
/// stay the same across restarts as long as [NodeIdentityStore] can find the
/// persisted key.
class NodeIdentity {
  const NodeIdentity({required this.nodeId, required this.keyPair});

  final String nodeId;
  final SimpleKeyPair keyPair;
}

/// Loads a node's [NodeIdentity] from [dataDirectory], generating and
/// persisting a new Ed25519 keypair the first time it is asked for one.
class NodeIdentityStore {
  NodeIdentityStore(this.dataDirectory);

  final Directory dataDirectory;

  static final _algorithm = Ed25519();

  File get _identityFile =>
      File(p.join(dataDirectory.path, 'node_identity.json'));

  Future<NodeIdentity> loadOrCreate() async {
    final file = _identityFile;
    if (file.existsSync()) {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final seed = base64Decode(json['privateKeySeed'] as String);
      final keyPair = await _algorithm.newKeyPairFromSeed(seed);
      return _identityOf(keyPair);
    }

    final keyPair = await _algorithm.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    await dataDirectory.create(recursive: true);
    await file.writeAsString(
      jsonEncode({'privateKeySeed': base64Encode(seed)}),
    );
    return _identityOf(keyPair);
  }

  Future<NodeIdentity> _identityOf(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    final fingerprint = await Sha256().hash(publicKey.bytes);
    return NodeIdentity(nodeId: _hex(fingerprint.bytes), keyPair: keyPair);
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
