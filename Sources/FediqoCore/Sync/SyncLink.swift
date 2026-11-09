import CryptoKit

/// The radios for syncing: a `NearbyLink` that can also hold for pairing, and advertise and
/// find sync listeners. `NWNearbyLink` and `PipeNearbyLink` conform.
public protocol SyncLink: NearbyLink {
    /// A pairing hold: `advertise(name:sessionID:psk:)` with `p=1` added to the TXT, so a
    /// browser lists it as `NearbyPeer.pairing`.
    func advertisePairing(name: String, sessionID: String, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error>
    /// Lets the paired device find this one as `name`, with TXT `t=<tag>` only, and hands over
    /// each join made under `psk` (TLS identity `SyncDiscovery.pskIdentity(tag:)`). Ends when
    /// cancelled; throws `NearbyRefusal.notAllowed` where refused.
    func advertise(name: String, tag: String, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error>
    /// Every sync listener nearby (TXT `t`), as the list changes. `.notAllowed` where refused.
    func browseTags() -> AsyncThrowingStream<[SyncPeer], any Error>
    /// Joins a sync listener under `psk`. A wrong psk is `NearbyRefusal.wrongCode`.
    func connect(to peer: SyncPeer, psk: SymmetricKey) async throws -> any NearbyPeerConnection
}

/// A sync listener nearby: its random instance name and the tag it advertises.
public struct SyncPeer: Sendable, Hashable, Identifiable {
    /// The endpoint's spelling, not shown.
    public let id: String
    /// The Bonjour instance name (`SyncDiscovery.instanceName()`), so a device tells its own
    /// listeners from the other's: both ends of a pair advertise the same tag.
    public let name: String
    public let tag: String

    public init(id: String, name: String, tag: String) {
        self.id = id
        self.name = name
        self.tag = tag
    }
}
