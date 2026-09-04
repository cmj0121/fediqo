import Foundation
import FediqoCore

/// Why a source gave nothing, said in the reader's language.
///
/// `SourceFailure` carries the reason as a case rather than a sentence precisely so this can
/// exist: a failure the user is shown has to follow the language they chose, and Core has no
/// business knowing what that is.
@MainActor
func message(for failure: SourceFailure) -> String {
    switch failure {
    case .needsSignIn(let host): t("error.needsSignIn", host)
    case .tokenRejected(let host): t("error.tokenRejected", host)
    case .notThatKind(let socialProtocol, let host): t("error.notThatKind", host, t("onboarding.protocol.\(socialProtocol.rawValue)"))
    case .unsupported(let socialProtocol): t("error.unsupported", t("onboarding.protocol.\(socialProtocol.rawValue)"))
    case .badHost(let host): t("error.badHost", host)
    case .notItsPost(let uri): t("error.notItsPost", uri)
    // The cut in the reader's own words, not `here`/`elsewhere` — the case is a name for a
    // question and this is the sentence a person would have asked it in.
    case .wouldNotCut(let host, let writers): t("error.wouldNotCut", host, t("writers.\(writers.rawValue)"))
    case .http(let code, _): t("error.http", String(code))
    case .signInFailed(let reason): t("error.signInFailed", reason)
    case .emptyDraft: t("error.emptyDraft")
    case .tooLong(let host, let limit): t("error.tooLong", host, String(limit))
    case .tooManyPictures(let host, let most): t("error.tooManyPictures", host, String(most))
    // The size in what a reader reads sizes in, not in bytes: nobody knows what 8388608 is, and
    // a limit somebody cannot picture is a limit they cannot act on.
    case .pictureTooLarge(let host, let name, let limit):
        t("error.pictureTooLarge", name,
          "\(host) (\(ByteCountFormatStyle().format(Int64(limit))))")
    case .pictureNotTaken(let host, let name, _): t("error.pictureNotTaken", host) + " (\(name))"
    case .transport(let reason), .store(let reason): reason
    }
}
