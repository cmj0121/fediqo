import CryptoKit
import Foundation

/// How paired devices find each other without telling anyone else who they are (D7). A sync
/// listener advertises under a random instance name, made fresh at every listen start, with
/// one TXT key: a tag that only the two holders of the pair secret can make or recognise, and
/// that rotates every 15 minutes, so a stranger can neither join nor follow a device around.
public enum SyncDiscovery {
    public static let label = SyncFrame.label
    /// TXT key of a sync listener: the rotating tag, and nothing else in the TXT.
    public static let tagKey = "t"
    /// TXT key marking a pairing hold ("1").
    public static let pairingKey = "p"
    /// A bucket is 15 minutes; b−1, b, b+1 accepted (±15 min of clock skew).
    public static let bucketSeconds: Int64 = 900

    /// floor(unix seconds / 900).
    public static func bucket(at date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / Double(bucketSeconds)).rounded(.down))
    }

    /// hex(HMAC-SHA256(key: HKDF(secret, info: "fediqo-sync-1 tag"), msg: bucket as 8 bytes BE)
    /// .prefix(16)): 32 lowercase hex characters.
    public static func tag(secret: SymmetricKey, bucket: Int64) -> String {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, info: Data("\(label) tag".utf8), outputByteCount: 32)
        let message = withUnsafeBytes(of: bucket.bigEndian) { Data($0) }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).prefix(16).hex
    }

    /// Whether `tag` is this pair's for a bucket within one of `date`'s.
    public static func accepts(_ tag: String, secret: SymmetricKey, at date: Date) -> Bool {
        let now = bucket(at: date)
        return (now - 1...now + 1).contains { self.tag(secret: secret, bucket: $0) == tag }
    }

    /// The TLS pre-shared key for one tag, also the `psk` handed to `NearbyChannel.open` with
    /// `sessionID: tag`.
    public static func psk(secret: SymmetricKey, tag: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret, salt: Data(tag.utf8), info: Data("\(label) psk".utf8), outputByteCount: 32
        )
    }

    /// The TLS PSK identity: public, rotating with the tag, unlinkable across buckets.
    public static func pskIdentity(tag: String) -> Data {
        Data("\(label) \(tag)".utf8)
    }

    /// "fq-" and 12 random hex characters. Never the device name.
    public static func instanceName() -> String {
        "fq-" + PackageKeys.random(6).hex
    }
}
