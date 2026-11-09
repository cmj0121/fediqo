import Foundation

extension Sequence<UInt8> {
    /// Each byte as two lowercase hex characters, in order: an id, a tag, a digest's name.
    public var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
