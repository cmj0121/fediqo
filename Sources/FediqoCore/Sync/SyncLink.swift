import CryptoKit

/// The radios for syncing: a `NearbyLink` that can also hold for pairing. `NWNearbyLink` and
/// `PipeNearbyLink` conform.
public protocol SyncLink: NearbyLink {
    /// A pairing hold: `advertise(name:sessionID:psk:)` with `p=1` added to the TXT, so a
    /// browser lists it as `NearbyPeer.pairing`.
    func advertisePairing(name: String, sessionID: String, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error>
}
