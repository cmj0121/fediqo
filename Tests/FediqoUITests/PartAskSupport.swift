import Foundation
@testable import FediqoCore
@testable import FediqoUI

extension ShellSession {
    /// The bookmark mark's press and the yes to its question, in one: the question is raised
    /// as a row or Account raises it, and answered as its card answers it. Nothing, where no
    /// question is raised.
    func allowBookmarks(host: String, through browser: any OAuthBrowser) async {
        guard askBookmarks(host: host), let ask = partAsks.open else { return }
        partAsks.putDown()
        await allow(ask, through: browser)
    }

    /// The press beside a source on the notices page and the yes to its question, in one.
    /// Nothing, where no question is raised.
    func allowNotices(host: String, through browser: any OAuthBrowser) async {
        guard askForNotices(host: host), let ask = partAsks.open else { return }
        partAsks.putDown()
        await allow(ask, through: browser)
    }
}

extension ShellConfirmation {
    /// This question as an ask in place puts it: ended on what every one of them says — that
    /// the sign-in this device had stays live at `host`, and that a source already holding
    /// one for exactly this asks nothing more.
    func inPlace(at host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        var question = self
        let join = L10n.t("question.join", language: language)
        for key in ["part.ask.stays", "part.ask.same"] {
            let sentence = String(format: L10n.t(key, language: language), host)
            question.help = question.help.map { String(format: join, $0, sentence) } ?? sentence
        }
        return question
    }
}

enum PartAskFixture {
    /// A source's own account of a token holding `scopes`, as a Mastodon 4.6 words it
    /// (`MastodonSignInCaptures`): the words as a list, in the order made.
    static func info(_ scopes: String?) -> String {
        let words = (scopes ?? "").split(separator: " ").map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"resource_owner_id":1,"scope":[\#(words)],"expires_in":null,"application":{"uid":"cid"},"created_at":1791695432}"#
    }
}
