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

  static final _algorithm = Ed25519();

  Future<String> publicKeyBase64() async {
    final publicKey = await keyPair.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  /// Signs [message] with this node's private key — the basis for proving
  /// a federation request really came from this node (Phase 4).
  Future<List<int>> sign(List<int> message) async {
    final signature = await _algorithm.sign(message, keyPair: keyPair);
    return signature.bytes;
  }
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

  Future<NodeIdentity> _identityOf(SimpleKeyPair keyPair) async => NodeIdentity(
    nodeId: await nodeIdForPublicKey((await keyPair.extractPublicKey()).bytes),
    keyPair: keyPair,
  );
}

/// The one and only definition of a nodeId: the lowercase hex-encoded
/// SHA-256 fingerprint of an Ed25519 public key's raw bytes.
///
/// This self-certifying property — anyone holding the key can recompute the
/// id, and nobody can produce a key for an id they don't own — is the trust
/// anchor of the whole federation model, so every place that accepts a
/// `nodeId`/`publicKeyBase64` pair from the wire has to check the pair
/// against *this* function rather than re-deriving the fingerprint itself:
/// `relay_hub.dart` (a node connecting to a relay), `account_routes.dart`
/// (a device logging in to an account) and `federation_routes.dart`'s
/// `POST /friends` (a peer redeeming a pairing code). Three independent
/// copies of the same three lines is exactly the kind of thing that drifts,
/// and a nodeId derived even slightly differently in one of them would
/// silently sever that anchor.
///
/// The encoding is load-bearing and must not change: nodeIds are persisted
/// in `friends.json`, in account device links, and in relay routing, and
/// they appear in URLs.
Future<String> nodeIdForPublicKey(List<int> publicKeyBytes) async {
  final fingerprint = await Sha256().hash(publicKeyBytes);
  return fingerprint.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}
