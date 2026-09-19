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

    /// `request m.example: NSURLErrorDomain -1001`, `sign-in m.example: MastodonSignInError.denied`.
    public static func line(_ what: StaticString, host: String, error: any Error) -> String {
        "\(what) \(host): \(kind(of: error))"
    }

    /// An enum error's type and case, without its payload: a bridged code would be the
    /// compiler's case number, which reads as nothing. Anything else, its domain and code.
    static func kind(of error: any Error) -> String {
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum {
            // A case without a payload has no child, and prints as its name unless the type
            // prints itself some other way.
            let printsItself = error is CustomStringConvertible || error is CustomDebugStringConvertible
                || error is TextOutputStreamable
            let name = mirror.children.first?.label ?? (printsItself ? nil : String(describing: error))
            if let name { return "\(type(of: error)).\(name)" }
        }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// `request m.example: HTTP 401`.
    public static func line(_ what: StaticString, host: String, status: Int) -> String {
        "\(what) \(host): HTTP \(status)"
    }
}
