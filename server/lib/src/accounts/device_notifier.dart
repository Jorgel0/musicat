/// What a [DeviceNotifier] push is *about*. **Deliberately an opaque kind
/// and nothing else** -- there is no payload here, and adding one would
/// break the security property this whole mechanism is built on.
///
/// See [DeviceNotifier] for why.
enum AccountEvent {
  /// "Your friend requests or your friend list changed -- go look." Covers a
  /// request arriving, being accepted, and being declined with one value on
  /// purpose: the node's reaction to all three is identical (re-fetch both
  /// lists from the account service, authenticated, as itself), so telling
  /// them apart would only invite a node to *act* on the relay's word about
  /// which happened.
  friendRequests,
}

/// A best-effort way to nudge one of an account's devices: "something you
/// care about changed on the account service, go and look".
///
/// The account service (`account_routes.dart`) holds one of these and
/// nothing more. It is deliberately a one-method interface rather than a
/// [RelayHub][] -- the same shape, and for the same reason, as
/// `federation/unknown_device_resolver.dart`: the account service has no
/// business being able to reach into a relay's tunnels, forward requests, or
/// read its username directory, and handing it the narrowest possible
/// capability is what makes that structural instead of a convention. It also
/// keeps the two modules separable (ADR 0048's stated reason for the account
/// service being its own module in the first place) and lets every existing
/// caller keep constructing an account router with no notifier at all.
///
/// [RelayHub]: ../relay/relay_hub.dart
///
/// ## The push carries no trusted payload, ever
///
/// [notifyDevice] can say *that* something changed and nothing about *what*.
/// A node that receives one re-fetches the real data itself, over its own
/// authenticated, signed request to the account service. That is the entire
/// point:
///
/// - a **compromised or malicious relay** -- which is what actually carries
///   these pushes, and which is a separate trust domain from the account
///   service even when the two run in one process today -- can at worst
///   cause a node to poll a little more often. It can never inject a friend,
///   a friend request, a device, or a key.
/// - a **forged push** (anyone who can write to a node's tunnel) is
///   identical in effect to a legitimate one, so there is nothing to
///   authenticate and nothing to get wrong. The security of the flow rests
///   entirely on the *re-fetch* being authenticated, which it already is.
///
/// Anything that ever wants to put real data in this channel wants a
/// different channel. Widening [AccountEvent] to carry a payload would
/// silently move a trust boundary.
abstract class DeviceNotifier {
  /// Nudges the device [nodeId], if it is currently reachable. Best-effort
  /// by definition: a device that is offline, or connected to some other
  /// relay, simply isn't told, and that is exactly what the polling fallback
  /// (`federation/account_update_poller.dart`) exists to cover.
  ///
  /// **Must never throw and must never block.** Callers invoke this from
  /// inside an HTTP handler that has already decided its response; a push
  /// that fails must not turn a successful accept into a `500`, and one that
  /// is slow must not make the user wait for it.
  void notifyDevice(String nodeId, AccountEvent event);
}
