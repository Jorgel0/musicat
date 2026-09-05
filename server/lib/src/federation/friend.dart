/// One device belonging to a friend *account* — its [nodeId]/
/// [publicKeyBase64] are what an incoming signed request from that device
/// is verified against (see `request_signing.dart`), and its [address]/
/// [relayUrl] are how this node reaches *that* device when it initiates a
/// request (see `friend_reachability.dart`).
///
/// A friend account can have several of these live at once (phone +
/// desktop, ADR 0048), so trust is a property of the account and
/// reachability a property of each device.
///
/// [address]/[relayUrl] are nullable because the account service records
/// neither: a device learned from `GET /accounts/<accountId>/devices`
/// arrives with only its key material and [linkedAt]. Such a device can
/// still *verify* incoming requests (which is the whole point of learning
/// about it — the friend's new phone calling this node), it just isn't
/// outbound-reachable until it pairs an address of its own.
class FriendDevice {
  const FriendDevice({
    required this.nodeId,
    required this.publicKeyBase64,
    this.address,
    this.udpCandidate,
    this.relayUrl,
    this.linkedAt,
  });

  final String nodeId;
  final String publicKeyBase64;

  /// `host:port` this node reaches this device at, or `null` if unknown
  /// (see this class's own doc comment).
  final String? address;

  /// `host:port` this device's own external UDP mapping was last seen as
  /// (via STUN, ADR 0022), if known — the target for a NAT hole-punch
  /// attempt (ADR 0023). Not necessarily still valid: NAT mappings expire,
  /// and this is only ever as fresh as the last pairing/reconnect attempt.
  final String? udpCandidate;

  /// This device's own relay WebSocket endpoint (e.g.
  /// `ws://relay.example.com/connect`), if it reported one at pairing
  /// time — the fallback address for reaching it when [address] itself
  /// isn't (ADR 0032/0033): a request to it becomes
  /// `<relayUrl's http(s) origin>/<nodeId>/<path>` instead of
  /// `http://$address/<path>`. `null` if it didn't report a relay.
  final String? relayUrl;

  /// When the account service says this device was linked to its account —
  /// `null` for a device this node learned at pairing time rather than
  /// from the account service (including every legacy device-pinned
  /// friend). Used only to order reachability attempts, never for trust.
  final DateTime? linkedAt;

  FriendDevice copyWith({
    String? address,
    String? udpCandidate,
    String? relayUrl,
    DateTime? linkedAt,
  }) => FriendDevice(
    nodeId: nodeId,
    publicKeyBase64: publicKeyBase64,
    address: address ?? this.address,
    udpCandidate: udpCandidate ?? this.udpCandidate,
    relayUrl: relayUrl ?? this.relayUrl,
    linkedAt: linkedAt ?? this.linkedAt,
  );

  Map<String, Object?> toJson() => {
    'nodeId': nodeId,
    'publicKeyBase64': publicKeyBase64,
    'address': address,
    'udpCandidate': udpCandidate,
    'relayUrl': relayUrl,
    'linkedAt': linkedAt?.toIso8601String(),
  };

  factory FriendDevice.fromJson(Map<String, dynamic> json) => FriendDevice(
    nodeId: json['nodeId'] as String,
    publicKeyBase64: json['publicKeyBase64'] as String,
    address: json['address'] as String?,
    udpCandidate: json['udpCandidate'] as String?,
    relayUrl: json['relayUrl'] as String?,
    linkedAt: json['linkedAt'] == null
        ? null
        : DateTime.parse(json['linkedAt'] as String),
  );
}

/// A trusted remote friend — an *account* (ADR 0048) plus the set of that
/// account's devices this node currently knows about.
///
/// [accountId] is the unit of trust and of every authorization decision
/// (shared-track visibility, joint-playlist membership); [devices] is only
/// ever "which keys currently speak for this account, and where do I reach
/// them". Verification therefore accepts a signed request from *any* of
/// [devices] and reports [accountId] to whatever authorizes it — see
/// `request_signing.dart`.
///
/// **A legacy, device-pinned friend is the degenerate one-device case of
/// exactly this model**: its synthetic [accountId] is defined to be its own
/// `nodeId`, [devices] holds exactly that one device, and it is never
/// refreshed against the account service (see [isDevicePinned]). That's
/// what makes a `friends.json` written before accounts existed load and
/// behave identically with no migration: [Friend.fromJson] defaults a
/// missing `accountId` to the entry's own `nodeId` and a missing `devices`
/// to a single device built from the old top-level fields, the same
/// nullable-field-defaulting pattern `localNickname`/`relayUrl` already
/// use.
class Friend {
  const Friend({
    required this.accountId,
    required this.devices,
    this.displayName,
    this.localNickname,
    this.devicesRefreshedAt,
  });

  /// A legacy, device-pinned friend: one device, `accountId == nodeId`,
  /// never refreshed against anything. This is what `POST /friends`
  /// (pairing-code redemption, ADR 0020) creates when the caller doesn't
  /// claim an account, and what every `friends.json` entry written before
  /// Fase 5 loads as.
  factory Friend.devicePinned({
    required String nodeId,
    required String publicKeyBase64,
    required String address,
    String? displayName,
    String? udpCandidate,
    String? relayUrl,
    String? localNickname,
  }) => Friend(
    accountId: nodeId,
    devices: [
      FriendDevice(
        nodeId: nodeId,
        publicKeyBase64: publicKeyBase64,
        address: address,
        udpCandidate: udpCandidate,
        relayUrl: relayUrl,
      ),
    ],
    displayName: displayName,
    localNickname: localNickname,
  );

  final String accountId;

  /// Every device this node currently believes speaks for [accountId].
  /// May be empty (an account whose every device has been unlinked), in
  /// which case nothing this friend sends can verify — deliberately
  /// fail-closed rather than falling back to some older cached key.
  final List<FriendDevice> devices;

  final String? displayName;

  /// A purely local label this device's own user chose for this friend --
  /// distinct from [displayName], which is what the friend calls
  /// *themselves*. Set/read only through this node's own app-facing API
  /// (`PATCH /friends/<id>` in `federation_routes.dart`); never
  /// included in any outgoing federation request and never seen by, or
  /// sent to, the friend it labels.
  final String? localNickname;

  /// When [devices] was last refreshed from the account service — `null`
  /// if never (always the case for a device-pinned friend).
  final DateTime? devicesRefreshedAt;

  /// Whether this is a legacy, device-pinned friend (see the class doc
  /// comment): exactly one device, whose `nodeId` *is* this friend's
  /// [accountId]. Such a friend is never refreshed against the account
  /// service, so pairing keeps working with the account service absent or
  /// unreachable, exactly as before Fase 5.
  ///
  /// Safe to derive rather than persist as a flag: an account id is a
  /// 32-hex-character random id (`AccountStore`) while a nodeId is a
  /// 64-hex-character SHA-256 fingerprint (`NodeIdentity`), so an
  /// account-based friend can never accidentally look device-pinned.
  bool get isDevicePinned =>
      devices.length == 1 && devices.single.nodeId == accountId;

  /// This friend's device with the given [nodeId], or `null` if this node
  /// doesn't currently know that device as one of theirs.
  FriendDevice? deviceFor(String nodeId) {
    for (final device in devices) {
      if (device.nodeId == nodeId) return device;
    }
    return null;
  }

  /// [devices], most-recently-linked first (devices with no [linkedAt] —
  /// every pairing-time device, including legacy ones — last, in stored
  /// order). The order reachability attempts are made in: a freshly-linked
  /// device is the likeliest to be the friend's currently-active one.
  List<FriendDevice> get devicesByPreference {
    final sorted = [...devices];
    sorted.sort((a, b) {
      final aLinked = a.linkedAt;
      final bLinked = b.linkedAt;
      if (aLinked == null && bLinked == null) return 0;
      if (aLinked == null) return 1;
      if (bLinked == null) return -1;
      return bLinked.compareTo(aLinked);
    });
    return sorted;
  }

  /// The single device that stands in for this friend wherever a
  /// device-pinned view of them is still needed — the legacy projection in
  /// [toJson] (which this device's own app still reads as a flat
  /// `nodeId`/`publicKeyBase64`/`address` triple). Prefers a device with a
  /// known [FriendDevice.address], since an address-less device is useless
  /// to a caller that wants to reach one. `null` only when [devices] is
  /// empty.
  ///
  /// Deliberately *not* exposed as `Friend.nodeId`: everything that
  /// authorizes anything must use [accountId], and a `nodeId` getter here
  /// would be exactly the wrong thing to reach for by accident.
  FriendDevice? get primaryDevice {
    final ordered = devicesByPreference;
    for (final device in ordered) {
      if (device.address != null && device.address!.isNotEmpty) return device;
    }
    return ordered.isEmpty ? null : ordered.first;
  }

  Friend copyWith({
    List<FriendDevice>? devices,
    String? displayName,
    DateTime? devicesRefreshedAt,
  }) => Friend(
    accountId: accountId,
    devices: devices ?? this.devices,
    displayName: displayName ?? this.displayName,
    localNickname: localNickname,
    devicesRefreshedAt: devicesRefreshedAt ?? this.devicesRefreshedAt,
  );

  /// Both the persisted form and what this node's own app-facing
  /// `GET /friends` returns.
  ///
  /// The flat `nodeId`/`publicKeyBase64`/`address`/`udpCandidate`/
  /// `relayUrl` keys are the [primaryDevice] projection, kept verbatim on
  /// purpose: they are what the app's own parser reads today, and keeping
  /// them means a file written by this version is still readable by the
  /// pre-Fase-5 one. `accountId`/`devices` are what a reader that
  /// understands accounts should use.
  Map<String, Object?> toJson() {
    final primary = primaryDevice;
    return {
      'nodeId': primary?.nodeId ?? accountId,
      'publicKeyBase64': primary?.publicKeyBase64 ?? '',
      'address': primary?.address ?? '',
      'displayName': displayName,
      'udpCandidate': primary?.udpCandidate,
      'relayUrl': primary?.relayUrl,
      'localNickname': localNickname,
      'accountId': accountId,
      'devices': [for (final device in devices) device.toJson()],
      'devicesRefreshedAt': devicesRefreshedAt?.toIso8601String(),
    };
  }

  /// Reads either format: an entry with `devices`/`accountId` (written by
  /// this version) or a legacy one with only the flat device fields
  /// (written before Fase 5), which becomes a device-pinned friend with
  /// `accountId == nodeId` — see the class doc comment.
  factory Friend.fromJson(Map<String, dynamic> json) {
    final devicesJson = json['devices'] as List<dynamic>?;
    final devices = devicesJson == null
        ? [
            FriendDevice(
              nodeId: json['nodeId'] as String,
              publicKeyBase64: json['publicKeyBase64'] as String,
              address: json['address'] as String?,
              udpCandidate: json['udpCandidate'] as String?,
              relayUrl: json['relayUrl'] as String?,
            ),
          ]
        : [
            for (final device in devicesJson)
              FriendDevice.fromJson(device as Map<String, dynamic>),
          ];
    return Friend(
      accountId:
          json['accountId'] as String? ??
          (devices.isEmpty ? json['nodeId'] as String : devices.first.nodeId),
      devices: devices,
      displayName: json['displayName'] as String?,
      localNickname: json['localNickname'] as String?,
      devicesRefreshedAt: json['devicesRefreshedAt'] == null
          ? null
          : DateTime.parse(json['devicesRefreshedAt'] as String),
    );
  }
}
