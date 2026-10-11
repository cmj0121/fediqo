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
}

enum PartAskFixture {
    /// A source's own account of a token holding `scopes`, as a Mastodon 4.6 words it
    /// (`MastodonSignInCaptures`): the words as a list, in the order made.
    static func info(_ scopes: String?) -> String {
        let words = (scopes ?? "").split(separator: " ").map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"resource_owner_id":1,"scope":[\#(words)],"expires_in":null,"application":{"uid":"cid"},"created_at":1791695432}"#
    }
}
