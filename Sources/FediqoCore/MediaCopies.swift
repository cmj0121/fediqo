import Foundation

/// Copies of pictures already on this device, filed by the host they were read through.
///
/// A protocol in Core so the shell can be handed one without knowing where it lives on disk:
/// `FediqoPersistence.MediaCache` is the real one, and a test that does not care hands in none.
/// Hosts are folded by the conformer, not the caller.
public protocol MediaCopies: Sendable {
    /// Keeps `data` as the copy of `url`, read through `host`.
    func store(_ data: Data, host: String, url: URL) throws
    /// The copy of `url` kept under `host`, or nothing where there is none.
    func data(host: String, url: URL) -> Data?
    /// Drops the copy of `url` kept under `host`, where there is one.
    func remove(host: String, url: URL)
    /// Drops every copy kept under `host`, and nothing kept under any other.
    func forget(host: String)
    /// Drops the copies of every host not in `hosts`.
    func keepOnly(hosts: some Sequence<String>)
    /// Drops every copy, of every host: the drop by cache (#7).
    func removeAll()
    /// What the copies kept under `host` weigh on disk, in bytes.
    func bytes(host: String) -> Int
    /// How many copies are kept, every host together — what a limit says it let go of (#251).
    func count() -> Int
    /// Drops copies, oldest written first, until what is kept weighs no more than `cap` bytes,
    /// and returns what is kept then — the one full measure of the copies.
    @discardableResult
    func trim(toBytes cap: Int) -> Int
}
