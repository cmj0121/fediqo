import CryptoKit
import Foundation
import Synchronization

/// One joined connection, made private to the two devices and bound to the code (#253) —
/// whatever the transport under it did.
///
/// **Why a second layer over TLS.** A six-digit code is a million guesses. A key made from the
/// code alone can be tried offline against a recording of the wire; so the two devices first
/// agree a fresh P-256 key each time they join, and the code is folded into that agreement:
/// `K = HKDF(ECDH shared secret, salt: session id, info: "fediqo-nearby-2" ‖ sender's key ‖
/// receiver's key ‖ the code's key)`. A recording and the code together give no `K` without
/// the private keys, which never leave their devices. Each side then proves it holds `K` — and
/// so the code — with an HMAC over both public keys before a word of the move is said; a proof
/// that does not match is a wrong code. Every frame after that rides sealed under `K` with a
/// counter nonce prefixed by its direction, so a frame moved, replayed or altered fails its tag.
///
/// The transport's own handshake stays: it keeps a stranger off the connection at all. This
/// keeps the person's secret out of reach of a recording.
public final class NearbyChannel: Sendable {
    /// Which side of the move this end is: the nonce's first byte, so the two directions never
    /// share a nonce under one key.
    public enum Role: UInt8, Sendable {
        case sender = 0
        case receiver = 1
    }

    private let connection: any NearbyPeerConnection
    private let key: SymmetricKey
    private let role: Role
    private let counters = Mutex<(sent: UInt64, received: UInt64)>((0, 0))
    private let inbox: any NearbyInbox

    /// Opens the channel over `connection`: sends this side's key, reads the peer's, agrees `K`
    /// bound to `psk`, and exchanges proofs. A proof that does not match — a wrong code — is
    /// `NearbyRefusal.wrongCode`; a link ending first is `NearbyDropped`.
    public static func open(
        over connection: any NearbyPeerConnection, inbox: any NearbyInbox, role: Role,
        psk: SymmetricKey, sessionID: String
    ) async throws -> NearbyChannel {
        let mine = P256.KeyAgreement.PrivateKey()
        let ours = mine.publicKey.x963Representation
        try await connection.send(.hello(ours))
        guard case .hello(let theirs) = try await inbox.next() else { throw NearbyRefusal.malformed }
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: theirs) else { throw NearbyRefusal.malformed }
        let (senderKey, receiverKey) = role == .sender ? (ours, theirs) : (theirs, ours)
        let key = try mine.sharedSecretFromKeyAgreement(with: peer).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(sessionID.utf8),
            sharedInfo: Data("fediqo-nearby-2".utf8) + senderKey + receiverKey + psk.withUnsafeBytes { Data($0) },
            outputByteCount: 32
        )
        let transcript = senderKey + receiverKey
        try await connection.send(.confirm(Self.proof(key, role: role, transcript: transcript)))
        guard case .confirm(let proof) = try await inbox.next() else { throw NearbyRefusal.malformed }
        let expected = Self.proof(key, role: role == .sender ? .receiver : .sender, transcript: transcript)
        guard proof == expected else { throw NearbyRefusal.wrongCode }
        return NearbyChannel(connection: connection, inbox: inbox, key: key, role: role)
    }

    private init(connection: any NearbyPeerConnection, inbox: any NearbyInbox, key: SymmetricKey, role: Role) {
        self.connection = connection
        self.inbox = inbox
        self.key = key
        self.role = role
    }

    /// HMAC-SHA256 under `key` over the side's letter and both public keys.
    static func proof(_ key: SymmetricKey, role: Role, transcript: Data) -> Data {
        let label = Data((role == .sender ? "S" : "R").utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: label + transcript, using: key))
    }

    /// The nonce of the `counter`th frame in `direction`: the direction, three zero bytes, and
    /// the counter.
    static func nonce(_ direction: Role, counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data([direction.rawValue, 0, 0, 0])
        bytes.appendLE(counter)
        return try AES.GCM.Nonce(data: bytes)
    }

    /// `frame`, sealed and sent.
    public func send(_ frame: NearbyFrame) async throws {
        let counter = counters.withLock { counters in
            defer { counters.sent += 1 }
            return counters.sent
        }
        let box = try AES.GCM.seal(
            try frame.encode(), using: key, nonce: try Self.nonce(role, counter: counter),
            authenticating: Data([role.rawValue])
        )
        guard let combined = box.combined else { throw NearbyRefusal.malformed }
        try await connection.send(.sealed(combined))
    }

    /// The next frame from the peer, unsealed, or `NearbyDropped` where the link ended. A frame
    /// that is not sealed, or does not open under the counter expected, is `.malformed`.
    public func next() async throws -> NearbyFrame {
        try unseal(try await inbox.next())
    }

    /// `frame` as the peer said it: a sealed frame opened under the counter expected. One that
    /// is not sealed, or does not open, is `.malformed`.
    public func unseal(_ frame: NearbyFrame) throws -> NearbyFrame {
        guard case .sealed(let combined) = frame else { throw NearbyRefusal.malformed }
        let counter = counters.withLock { counters in
            defer { counters.received += 1 }
            return counters.received
        }
        let from: Role = role == .sender ? .receiver : .sender
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              Data(box.nonce) == Data(try Self.nonce(from, counter: counter)),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Data([from.rawValue]))
        else { throw NearbyRefusal.malformed }
        return try NearbyFrame.decode(plain)
    }
}

/// Where a connection's frames are read from, one at a time: `NearbyMove` merges the frames
/// with the person's answer behind this, so either can be waited on.
public protocol NearbyInbox: Sendable {
    /// The next frame, or `NearbyDropped` where the link ended.
    func next() async throws -> NearbyFrame
}
