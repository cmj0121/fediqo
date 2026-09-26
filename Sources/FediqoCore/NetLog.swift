import Foundation
import os

/// Where network and sign-in failures are written for Console, and the one way their lines are
/// built.
///
/// **A line holds a host, a fixed phrase and a failure's class, and nothing else**, so it can be
/// logged whole as public. Never the address past its host (a path names ids, a query can carry
/// a code or a token), never a body, and never an error's own description: a `URLError`'s carries
/// the full address it failed on.
public enum NetLog {
    public static let network = Logger(subsystem: "Fediqo", category: "network")
    public static let auth = Logger(subsystem: "Fediqo", category: "auth")
    /// A move nearby, step by step, on either side (#253), its lines built by `NearbyLog`.
    public static let nearby = Logger(subsystem: "Fediqo", category: "nearby")

    /// `request m.example: NSURLErrorDomain -1001`, `sign-in m.example: MastodonSignInError.denied`.
    public static func line(_ what: StaticString, host: String, error: any Error) -> String {
        "\(what) \(host): \(kind(of: error))"
    }

    /// An enum error's type and case, without its payload: a bridged code would be the
    /// compiler's case number, which reads as nothing. Anything else, its domain and code.
    static func kind(of error: any Error) -> String {
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum {
            // A case with a payload is named by its one child's label.
            if let label = mirror.children.first?.label { return "\(type(of: error)).\(label)" }
            // A case without one has no child, and prints as its name — unless its type prints
            // itself some other way, and then nothing it prints is trusted.
            if mirror.children.isEmpty, !printsItself(error) {
                return "\(type(of: error)).\(String(describing: error))"
            }
        }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// Whether the error's own type says how it prints. Asked of it as `Any`: asked of `any Error`,
    /// the bridge every error has to `NSError` makes the answer always yes, and an optimiser may
    /// fold it so, which would name no payload-free case in a release build.
    private static func printsItself(_ error: any Error) -> Bool {
        let value: Any = error
        return value is CustomStringConvertible || value is CustomDebugStringConvertible
            || value is TextOutputStreamable
    }

    /// `request m.example: HTTP 401`.
    public static func line(_ what: StaticString, host: String, status: Int) -> String {
        "\(what) \(host): HTTP \(status)"
    }
}
