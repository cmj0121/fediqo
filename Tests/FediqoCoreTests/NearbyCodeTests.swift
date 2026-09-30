import CryptoKit
import Foundation
import Network
import Testing
@testable import FediqoCore

/// #253's proof: the six digits, the key they become, and the parameters the real link joins
/// under. The radio itself is not here — a runner has none — only what it is handed.
@Suite("The pairing code and the key it becomes")
struct NearbyCodeTests {
    @Test("A code is six digits, drawn fresh each time, with leading zeros kept")
    func code() {
        var seen: Set<String> = []
        for _ in 0..<200 {
            let code = NearbyCode.make()
            #expect(NearbyCode.isWellFormed(code))
            seen.insert(code)
        }
        #expect(seen.count > 150, "two hundred draws are not a handful of values")
        #expect(NearbyCode.isWellFormed("000123"))
        #expect(!NearbyCode.isWellFormed("12345") && !NearbyCode.isWellFormed("1234567") && !NearbyCode.isWellFormed("12a456"))
        #expect(!NearbyCode.isWellFormed("１２３４５６"), "full-width digits are not what the other screen shows")
        #expect(NearbyCode.sessionID().count == 32 && NearbyCode.sessionID() != NearbyCode.sessionID())
    }

    @Test("The key is the same for the same code and session, and differs by either")
    func psk() {
        let a = NearbyCode.psk(code: "123456", sessionID: "s1")
        #expect(a == NearbyCode.psk(code: "123456", sessionID: "s1"))
        #expect(a == NearbyCode.psk(code: " 123456\n", sessionID: "s1"), "whitespace round the code is nothing")
        #expect(a != NearbyCode.psk(code: "123457", sessionID: "s1"))
        #expect(a != NearbyCode.psk(code: "123456", sessionID: "s2"))
        #expect(a.bitCount == 256)
        // Pinned: the two apps must derive the same bytes from the same digits.
        let bytes = NearbyCode.psk(code: "000000", sessionID: "0").withUnsafeBytes { Data($0) }
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data("000000".utf8)), salt: Data("0".utf8),
            info: Data("fediqo-nearby-1".utf8), outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        #expect(bytes == expected)
        #expect(NearbyCode.pskIdentity(sessionID: "abc") == Data("fediqo-nearby-1 abc".utf8))
        let mark = NearbyCode.mark(code: "123456", sessionID: "abc")
        #expect(mark.count == 4 && mark.allSatisfy(\.isHexDigit) && mark == NearbyCode.mark(code: " 123456 ", sessionID: "abc"))
        #expect(mark != NearbyCode.mark(code: "123456", sessionID: "abd"), "bound to the session")
        #expect(mark != NearbyCode.mark(code: "123457", sessionID: "abc"), "bound to the code, which a twin does not know")
    }

    @Test("The link's parameters are TLS over TCP with peer-to-peer on, and nothing is started")
    func parameters() {
        let parameters = NWNearbyLink.parameters(psk: NearbyCode.psk(code: "123456", sessionID: "s"), sessionID: "s")
        #expect(parameters.includePeerToPeer)
        let stack = parameters.defaultProtocolStack
        #expect(stack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
        #expect(stack.transportProtocol is NWProtocolTCP.Options)
        #expect(NearbyCode.service == "_fediqo._tcp")
        // The one suite: ECDHE-PSK with ChaCha20-Poly1305 (0xCCAC), and no other holds.
        #expect(NWNearbyLink.suite.rawValue == 0xCCAC)
        #expect(NWNearbyLink.suiteHolds(NWNearbyLink.suite))
        #expect(!NWNearbyLink.suiteHolds(nil))
        #expect(NWNearbyLink.fallbackSuite.rawValue == 0x00A8 && NWNearbyLink.suiteHolds(NWNearbyLink.fallbackSuite))
        #expect(!NWNearbyLink.suiteHolds(tls_ciphersuite_t(rawValue: 0x00AE)!), "another PSK suite is refused")
        #expect(!NWNearbyLink.suiteHolds(.AES_128_GCM_SHA256), "a certificate suite is refused")
    }

    @Test("A denied local network is said as not allowed; anything else as itself")
    func refusal() {
        #expect(NWNearbyLink.refusal(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))) as? NearbyRefusal == .notAllowed)
        #expect(NWNearbyLink.refusal(.posix(.EPERM)) as? NearbyRefusal == .notAllowed)
        if case .other = NWNearbyLink.refusal(.posix(.ECONNREFUSED)) as? NearbyRefusal {} else {
            Issue.record("a refused connection is not a refused permission")
        }
        #expect(NearbyRefusal(PackageRefusal.altered) == .package(.altered))
        #expect(NearbyRefusal(PackageFault.noRoom(needed: 3, free: 1)) == .noRoom(needed: 3, free: 1))
        #expect(NearbyRefusal(NearbyRefusal.wrongCode) == .wrongCode)
    }
}

/// The channel over a joined pair: key agreement bound to the code, proofs both ways, and every
/// frame after sealed.
@Suite("The channel between two devices")
struct NearbyChannelTests {
    /// Two ends of a pipe, joined under `psk` on the holding side and `joining` on the other.
    private func ends(_ link: PipeNearbyLink, psk: SymmetricKey, joining: SymmetricKey) async throws
        -> (any NearbyPeerConnection, any NearbyPeerConnection)
    {
        let arrivals = link.advertise(name: "a", sessionID: "s", psk: psk)
        let sender = try await link.connect(to: NearbyPeer(id: "s", name: "a", sessionID: "s"), psk: joining)
        for try await arrival in arrivals {
            if case .joined(let receiver) = arrival { return (sender, receiver) }
        }
        throw NearbyDropped()
    }

    @Test("Both sides agree a key, prove it, and every frame after crosses sealed and in order")
    func agrees() async throws {
        let link = PipeNearbyLink()
        let psk = NearbyCode.psk(code: "123456", sessionID: "s")
        let (a, b) = try await ends(link, psk: psk, joining: psk)
        async let sender = NearbyChannel.open(over: a, inbox: PlainInbox(a), role: .sender, psk: psk, sessionID: "s")
        async let receiver = NearbyChannel.open(over: b, inbox: PlainInbox(b), role: .receiver, psk: psk, sessionID: "s")
        let (s, r) = try await (sender, receiver)
        try await s.send(.have(7))
        try await s.send(.bytes(Data("x".utf8)))
        try await r.send(.done)
        #expect(try await r.next() == .have(7))
        #expect(try await r.next() == .bytes(Data("x".utf8)))
        #expect(try await s.next() == .done)
        let tags = Set(link.transcript.compactMap(\.first))
        #expect(tags == [NearbyFrame.Tag.hello.rawValue, NearbyFrame.Tag.confirm.rawValue, NearbyFrame.Tag.sealed.rawValue])
        // A sealed frame replayed is out of order for the counter, and refused.
        let replay = link.transcript.last { $0.first == NearbyFrame.Tag.sealed.rawValue }!
        #expect(throws: NearbyRefusal.malformed) { try s.unseal(try NearbyFrame.decode(replay)) }
        #expect(throws: NearbyRefusal.malformed) { try r.unseal(.accept) }
    }

    @Test("A code that differs fails the proof as a wrong code, and no key is agreed")
    func wrongCode() async throws {
        let link = PipeNearbyLink()
        let psk = NearbyCode.psk(code: "123456", sessionID: "s")
        let other = NearbyCode.psk(code: "123457", sessionID: "s")
        // Both got past the transport (as a sniffer who recorded it has): only the proof tells.
        let (a, b) = try await ends(link, psk: psk, joining: psk)
        let sender = Task { try await NearbyChannel.open(over: a, inbox: PlainInbox(a), role: .sender, psk: other, sessionID: "s") }
        let receiver = Task { try await NearbyChannel.open(over: b, inbox: PlainInbox(b), role: .receiver, psk: psk, sessionID: "s") }
        let senderOutcome = await sender.result
        let receiverOutcome = await receiver.result
        #expect(senderOutcome.refusal == .wrongCode && receiverOutcome.refusal == .wrongCode)
    }
}

extension Result where Failure == any Error {
    var refusal: NearbyRefusal? {
        if case .failure(let error) = self { error as? NearbyRefusal } else { nil }
    }
}

/// A connection's frames read one at a time.
final class PlainInbox: NearbyInbox, @unchecked Sendable {
    private var iterator: AsyncThrowingStream<NearbyFrame, any Error>.Iterator

    init(_ connection: any NearbyPeerConnection) {
        iterator = connection.frames.makeAsyncIterator()
    }

    func next() async throws -> NearbyFrame {
        guard let frame = try await iterator.next() else { throw NearbyDropped() }
        return frame
    }
}

/// What the two devices say to each other, as bytes.
@Suite("The frames between two devices")
struct NearbyFrameTests {
    private static let summary = PackageSummary(
        contents: .signInsOnly, sources: [.init(host: "one.example", kind: .mastodon)], posts: 0, timelines: 0,
        takenAt: Date(timeIntervalSince1970: 1_800_000_000), withPictures: false, bytes: 40, hasSecrets: true,
        device: "a phone", appVersion: "0.7.0", entryCount: 1
    )

    @Test("Every frame comes back as it went")
    func roundTrip() throws {
        let frames: [NearbyFrame] = [
            .offer(NearbyOffer(id: "o1", summary: Self.summary, fileBytes: 12_345)),
            .accept, .refuse, .key(Data(repeating: 7, count: 32)), .have(0), .have(1 << 40),
            .bytes(Data("hello".utf8)), .bytes(Data(repeating: 1, count: NearbyFrame.mostBytes)), .done,
            .hello(Data(repeating: 2, count: 65)), .confirm(Data(repeating: 3, count: 32)), .sealed(Data(repeating: 4, count: 40)),
        ]
        for frame in frames {
            #expect(try NearbyFrame.decode(try frame.encode()) == frame)
        }
        #expect(try NearbyFrame.mostBytes == 256 * 1024)
    }

    @Test("What no build of ours would send is refused as malformed")
    func malformed() {
        let bad: [Data] = [
            Data(), Data([0]), Data([9]), Data([2, 1]), Data([4]) + Data(repeating: 1, count: 31),
            Data([5, 1, 2, 3]), Data([5]) + Data(repeating: 0xFF, count: 8), Data([6]),
            Data([6]) + Data(repeating: 1, count: NearbyFrame.mostBytes + 1), Data([1]) + Data("{}".utf8),
            Data([1]) + Data(#"{"id":"","summary":{},"fileBytes":-1}"#.utf8),
            Data([8]) + Data(repeating: 2, count: 32), Data([9]) + Data(repeating: 3, count: 31), Data([10]) + Data(repeating: 4, count: 27),
            Data([1]) + Data(#"{"id":"x","summary":{"header":{"contents":"whole","sources":[],"posts":0,"timelines":0,"hasSecrets":false,"device":"","appVersion":"","entryCount":0},"takenAt":0,"withPictures":false,"bytes":0},"fileBytes":1099511627777}"#.utf8),
        ]
        for data in bad {
            #expect(throws: NearbyRefusal.malformed) { try NearbyFrame.decode(data) }
        }
        #expect(throws: PackageRefusal.newer) {
            _ = try NearbyFrame.decode(Data([1]) + Data(#"{"id":"x","summary":{"header":{"contents":"future","sources":[],"posts":0,"timelines":0,"hasSecrets":false,"device":"","appVersion":"","entryCount":0},"takenAt":0,"withPictures":false,"bytes":0},"fileBytes":1}"#.utf8))
        }
    }

    @Test("A summary crosses whole, its unknown contents refused as a newer build's")
    func summary() throws {
        let data = try JSONEncoder().encode(Self.summary)
        #expect(try JSONDecoder().decode(PackageSummary.self, from: data) == Self.summary)
        let newer = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"signInsOnly\"", with: "\"future\"")
        #expect(throws: PackageRefusal.newer) { try JSONDecoder().decode(PackageSummary.self, from: Data(newer.utf8)) }
    }
}
