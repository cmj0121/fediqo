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
    case .notThatKind(let socialProtocol, let host): t("error.notThatKind", host, t("onboarding.protocol.\(socialProtocol.rawValue)"))
    case .unsupported(let socialProtocol): t("error.unsupported", t("onboarding.protocol.\(socialProtocol.rawValue)"))
    case .badHost(let host): t("error.badHost", host)
    case .http(let code): t("error.http", String(code))
    case .signInFailed(let reason): t("error.signInFailed", reason)
    case .transport(let reason), .store(let reason): reason
    }
}
