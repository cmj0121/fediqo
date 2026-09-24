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
    }

    @Test("The link's parameters are TLS over TCP with peer-to-peer on, and nothing is started")
    func parameters() {
        let parameters = NWNearbyLink.parameters(psk: NearbyCode.psk(code: "123456", sessionID: "s"), sessionID: "s")
        #expect(parameters.includePeerToPeer)
        let stack = parameters.defaultProtocolStack
        #expect(stack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
        #expect(stack.transportProtocol is NWProtocolTCP.Options)
        #expect(NearbyCode.service == "_fediqo._tcp")
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
