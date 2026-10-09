import FediqoCore
import Foundation

/// Why something asked of a source changed nothing: one vocabulary for every write — an act on
/// a post, a post or an answer, an act on a notice — and for the notices page's own reads.
///
/// **Only what is known.** Each case is something this device saw, and none of them guesses at
/// what the source was thinking.
enum WriteWhy: Equatable, Sendable {
    /// The source answered and said this sign-in may not.
    case refused
    /// Nothing answered: the source was not reached.
    case unreachable
    /// The source answered, and not with a yes or a refusal of the sign-in: it did not do
    /// it, and nothing is known of why.
    case declined
    /// It went out and no answer came in time: it may have been done all the same.
    case unconfirmed
    /// The sign-in could not be read off this device, so nothing was sent.
    case locked

    /// What a failure says happened: a 401 or a 403 is the source refusing this sign-in, and so
    /// is a 401 it stood by when asked who this is, which ended the sign-in (`signedOut`); any
    /// other answer is the source not doing it, for a reason nobody here was told; a write that
    /// ran out of time may have landed; and anything else never reached the source at all.
    ///
    /// `wrote` is false for a read, which has nothing to confirm.
    init(_ error: any Error, wrote: Bool = true) {
        if Self.refuses(error) || error as? MastodonAuthError == .signedOut {
            self = .refused
        } else if case .http? = error as? MastodonAuthError {
            self = .declined
        } else if error is MastodonNoticeError {
            self = .declined
        } else if wrote, (error as? URLError)?.code == .timedOut {
            self = .unconfirmed
        } else {
            self = .unreachable
        }
    }

    /// Whether a failure is the source saying this sign-in may not: a 401 it stood by, a 403.
    /// The one reading of it, for a write and for the notices list's own read.
    static func refuses(_ error: any Error) -> Bool {
        switch error as? MastodonAuthError {
        case .http(401)?, .http(403)?: true
        default: false
        }
    }
}
