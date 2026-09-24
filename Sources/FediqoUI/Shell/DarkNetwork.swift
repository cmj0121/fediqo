import Foundation

/// **This device has no network right now** — and not a server that is slow, refused, or was
/// walked away from (#222).
///
/// Narrower than `ShellPictures.absence(from:)` on purpose. A picture written off wrongly costs
/// one refetch; an answer left unasked is asked again on **every** reload, and a reload waits for
/// what a server says it is before it reads any source. So a host that is up but hangs —
/// `.timedOut`, which is also what a reload's own deadline throws — must stay settled, or it
/// holds every source back by the whole deadline on every reload. Only the codes that say the
/// network itself is not there are here.
enum DarkNetwork {
    static func caused(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }
}
