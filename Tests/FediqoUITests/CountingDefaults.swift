import Foundation

/// Defaults whose values live in this object only, and which keep each value set on them under
/// the key it was set for, in the order they were set, and count each one read: nothing reaches
/// `cfprefsd` or the disk.
final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    /// Every value set, oldest first.
    private(set) var sets: [(key: String, value: Any?)] = []
    var writes: Int { sets.count }
    /// How many times a value was asked for.
    private(set) var reads = 0

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? {
        reads += 1
        return values[key]
    }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func set(_ value: Any?, forKey key: String) {
        sets.append((key, value))
        values[key] = value
    }
    override func removeObject(forKey key: String) { values[key] = nil }
}
