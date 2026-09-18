import Foundation

/// Copies of multimedia already on this device, filed by the host they were read through.
///
/// A protocol in Core so the shell can be handed one without knowing where it lives on disk:
/// `FediqoPersistence.MediaCache` is the real one, and a test that does not care hands in none.
public protocol MediaCopies: Sendable {
    /// Keeps `data` as the copy of `url`, read through `host`.
    func store(_ data: Data, host: String, url: URL) throws
    /// The copy of `url` kept under `host`, or nothing where there is none.
    func data(host: String, url: URL) -> Data?
    /// Drops every copy kept under `host`, and nothing kept under any other.
    func forget(host: String) throws
}
