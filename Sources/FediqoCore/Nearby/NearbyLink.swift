import CryptoKit
import Foundation

/// The radios, behind a protocol (#253): what finds a device nearby, what lets one find this
/// device, and what joins the two — nothing more. `NWNearbyLink` is the real one, over
/// Network.framework; `PipeNearbyLink` joins two ends in one process, for tests and previews.
///
/// **The pairing code is the key.** Every connection here is made under a pre-shared key the
/// two people derived from the same six digits (`NearbyCode.psk`), so a device that does not
/// know the code never gets past the handshake — "nothing moves until both agree the same
/// proof" is the link's own rule, not a screen's. Nothing here passes through anywhere but the
/// two devices: the link speaks to the peer it was pointed at, and to nobody else.
public protocol NearbyLink: Sendable {
    /// Lets devices nearby find this one as `name`, under a session `sessionID` the code is bound
    /// to, and hands over each that joins under `psk`. A device that tried and failed the
    /// handshake — a wrong code — is reported so the code can be rolled. Ends when the task
    /// reading it is cancelled; a device not allowed to look nearby throws
    /// `NearbyRefusal.notAllowed`.
    func advertise(name: String, sessionID: String, psk: SymmetricKey) -> AsyncThrowingStream<NearbyArrival, any Error>
    /// Every device nearby that is holding, as the list changes. Throws `NearbyRefusal.notAllowed`
    /// where this device may not look.
    func browse() -> AsyncThrowingStream<[NearbyPeer], any Error>
    /// Joins `peer` under `psk`. A wrong code fails here, as `NearbyRefusal.wrongCode`.
    func connect(to peer: NearbyPeer, psk: SymmetricKey) async throws -> any NearbyPeerConnection
}

/// A device nearby that is holding: how it names itself, and the session it advertises.
public struct NearbyPeer: Sendable, Hashable, Identifiable {
    /// What the link knows it by — an endpoint's spelling, not shown.
    public let id: String
    /// The name the device gave itself, as the person nearby sees it on that device.
    public let name: String
    /// The session it is holding under, which the code is bound to.
    public let sessionID: String

    public init(id: String, name: String, sessionID: String) {
        self.id = id
        self.name = name
        self.sessionID = sessionID
    }
}

/// What reaches a device that is holding: a peer that joined under the key, or one that tried
/// and could not — which is a wrong code, and the receiver's cue to roll it.
public enum NearbyArrival: Sendable {
    case joined(any NearbyPeerConnection)
    case failedHandshake
}

/// One joined pair of devices. Frames go in order, whole, and the stream ends — or throws —
/// when the link drops.
public protocol NearbyPeerConnection: Sendable {
    /// The peer, as its device names itself, where the link knows it: the advertised name on
    /// the side that joined, and nothing on the side that was joined until the offer says.
    var peerName: String? { get }
    func send(_ frame: NearbyFrame) async throws
    /// Every frame the peer sends, in order. Read by one task.
    var frames: AsyncThrowingStream<NearbyFrame, any Error> { get }
    func close()
}

/// Why a move nearby could not go on. Each is its own sentence on screen.
public enum NearbyRefusal: Error, Sendable, Equatable {
    /// This device was not allowed to look nearby — the local-network permission was refused.
    /// Said as that, never as "nobody nearby".
    case notAllowed
    /// The code typed is not the one the other device shows: the handshake failed.
    case wrongCode
    /// The other device said no.
    case refusedThere
    /// The link dropped and did not come back.
    case lost
    /// The link dropped after everything was sent and did not come back to say whether the
    /// other device read it back: the outcome is on that device's screen, not this one's.
    case unsure
    /// Too many wrong codes in one hold: someone nearby is guessing, and the hold is closed.
    case guessing
    /// Nobody joined while the hold was up.
    case timedOut
    /// The other device sent something no build of ours would: the move is closed.
    case malformed
    /// What arrived is not as it was sent (#252's checks), or cannot be read back here.
    case package(PackageRefusal)
    /// Not enough room here for the package and its staging, with the numbers.
    case noRoom(needed: Int, free: Int)
    /// Something else refused, said as itself.
    case other(String)

    public init(_ error: any Error) {
        switch error {
        case let refusal as NearbyRefusal: self = refusal
        case let refusal as PackageRefusal: self = .package(refusal)
        case PackageFault.noRoom(let needed, let free): self = .noRoom(needed: needed, free: free)
        case is CancellationError: self = .lost
        default: self = .other(error.localizedDescription)
        }
    }
}

/// The link ended without a word — the peer went out of reach, the app was put away — which
/// is not a refusal: the sender joins again and the receiver waits. A link throws this, and
/// nothing else, for a drop.
public struct NearbyDropped: Error, Sendable, Equatable {
    public init() {}
}
