import CommonCrypto
import CryptoKit
import Foundation

/// The two keys a package is sealed under, made from what locks it.
///
/// **Apple's own primitives and nothing else.** A password goes through PBKDF2-HMAC-SHA256
/// (CommonCrypto, `PackageFormat.rounds` rounds, the prelude's 16-byte salt) into 32 bytes; a
/// direct key is its 32 bytes as they are. Either is then HKDF-SHA256 (CryptoKit), salted with the
/// same salt, into a header key and an entries key, so a tag failing on the header is a tag
/// failing on the only box that key seals. Argon2 would be a dependency for a marginal gain
/// against a file the person keeps in their own hands, and is left out; the round count is in
/// the prelude so it can rise.
struct PackageKeys {
    let header: SymmetricKey
    let entries: SymmetricKey

    /// How much a package with `keying` may be locked with: a password only opens a package
    /// locked by one, a key only one locked by a key.
    init(_ key: PackageKey, prelude: PackageFormat.Prelude) throws {
        guard key.keying == prelude.keying else { throw PackageRefusal.wrongPassword }
        let ikm: SymmetricKey
        switch key {
        case .password(let password):
            guard !password.isEmpty else { throw PackageFault.emptyPassword }
            guard prelude.rounds <= PackageFormat.maxRounds else { throw PackageRefusal.altered }
            ikm = try Self.stretch(password, salt: prelude.salt, rounds: prelude.rounds)
        case .direct(let direct):
            ikm = direct
        }
        header = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: prelude.salt, info: Data("fediqo-package-1 header".utf8),
            outputByteCount: 32
        )
        entries = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: prelude.salt, info: Data("fediqo-package-1 entries".utf8),
            outputByteCount: 32
        )
    }

    /// PBKDF2-HMAC-SHA256 over the password's UTF-8. The password's bytes and the derived key
    /// are wiped once the key object holds its own copy, so neither lingers in a freed buffer.
    static func stretch(_ password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        var passwordBytes = password.utf8.map { CChar(bitPattern: $0) }
        defer {
            _ = memset_s(&derived, derived.count, 0, derived.count)
            _ = memset_s(&passwordBytes, passwordBytes.count, 0, passwordBytes.count)
        }
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, passwordBytes.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count
            )
        }
        guard status == kCCSuccess else { throw PackageFault.keyDerivation }
        return SymmetricKey(data: derived)
    }

    /// `count` bytes from the system's random source.
    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var generator = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes)
    }
}

/// What can go wrong around a package that is not a refusal of the file itself.
public enum PackageFault: Error, Sendable, Equatable {
    /// A package locked by nothing is nothing: an empty password is refused before a byte is
    /// written.
    case emptyPassword
    /// A password shorter than `PackageFormat.minPasswordCount`, refused before a byte is written.
    case shortPassword
    /// The system's key derivation refused, which no input of ours reaches.
    case keyDerivation
    /// The writer was told one number of entries and given another, or finished twice.
    case miscounted
    /// Not enough room on this device for what the package holds, with the numbers.
    case noRoom(needed: Int, free: Int)
    /// This device already holds a store, and the person has not yet said what becomes of it.
    case alreadyHeld
    /// The package's store could not be read back as a store, though every tag held.
    case unreadableStore
}
