import CryptoKit
import Foundation

/// The six digits both people see (#253), and the key they become.
///
/// **One guess per code.** The code is drawn from the system's random source, never from a
/// clock or a counter; the session id is drawn the same way and changes with the code, so the
/// key derived from a code that failed opens nothing that is still listening. Six digits are a
/// million; a person is watching each try.
public enum NearbyCode {
    /// How many digits a code has.
    public static let digits = 6
    /// The Bonjour service the receiver advertises under.
    public static let service = "_fediqo._tcp"

    /// Six digits, from the system's random source, with leading zeros kept.
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = Int.random(in: 0..<1_000_000, using: &generator)
        return String(format: "%0\(digits)d", value)
    }

    /// A fresh session id, 16 random bytes as hex.
    public static func sessionID() -> String {
        PackageKeys.random(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `code` is six digits, as typed.
    public static func isWellFormed(_ code: String) -> Bool {
        code.count == digits && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The pre-shared key both sides derive: HKDF-SHA256 over the code's digits, salted by the
    /// session id, under this protocol's own label. Whitespace round the code is nothing.
    public static func psk(code: String, sessionID: String) -> SymmetricKey {
        let digits = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(digits.utf8)),
            salt: Data(sessionID.utf8), info: Data("fediqo-nearby-1".utf8), outputByteCount: 32
        )
    }

    /// Four hex characters of the session id's digest, shown beside the code on the device
    /// holding and beside its name on the device choosing, so a second device advertising the
    /// same name is told apart by the person before a code is typed.
    public static func mark(sessionID: String) -> String {
        let digest = SHA256.hash(data: Data(sessionID.utf8))
        return digest.prefix(2).map { String(format: "%02X", $0) }.joined()
    }

    /// The identity both sides name the key by in the handshake: the session id, which is
    /// public.
    public static func pskIdentity(sessionID: String) -> Data {
        Data("fediqo-nearby-1 \(sessionID)".utf8)
    }
}
