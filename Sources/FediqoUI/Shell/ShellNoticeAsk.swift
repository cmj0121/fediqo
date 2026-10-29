import AuthenticationServices
import FediqoCore
import Foundation
import SwiftUI

/// Notices are asked of a sign-in only when the person presses for them on the notices page
/// (#323) — every sign-in alike, one made before notices existed and one made yesterday — and
/// **nobody is signed out to ask**.
///
/// They are asked as every part is (`ShellPartAsk`, #347): the press raises a question that
/// says what the source's own page is about to ask for, and only its yes opens that page, for
/// what the sign-in holds and notices. A page closed, a no on it, or any failure leaves the
/// sign-in the person had, doing everything it did; allowed, the wider sign-in takes its place
/// here and the one it had stays live at the source until the person signs out.
extension ShellSession {
    /// The press beside a source the notices page names as not asked, or as refused on its
    /// page: raises the question. Sends nothing. Returns whether a question was raised.
    ///
    /// **A sign-in that acts and was never asked for bookmarks is asked for them with the
    /// notices** (#285): the one part ticked beside the one pressed for, because the question
    /// names it, in the words it always had. One that was refused bookmarks, or whose source
    /// has none, is asked for notices alone — **and a source found to have none of them at
    /// that yes has said nothing of notices**, which are asked for again alone, at once.
    @discardableResult
    func askForNotices(host raw: String) -> Bool {
        let host = raw.lowercased()
        guard mastodon.notices(host: host) == .unasked else { return false }
        let bookmarks = mastodon.bookmarks(host: host) == .unasked && mastodon.standing(.bookmarks, host: host) == .unasked
        return askFor([.notices], with: bookmarks ? [.bookmarks] : [], host: host)
    }

    /// Whether the sign-in at `host` is being asked for something now: nothing more is asked,
    /// or read in its place, until that lands.
    func isAsking(host raw: String) -> Bool {
        mastodon.asking.contains(raw.lowercased())
    }
}

extension PartWords {
    /// The words notices were asked in before every part went one way (#323), and their
    /// place: what asking for them came to is said on the notices page, where the press is —
    /// never under the source's row, as a sign-in that failed would be.
    static let noticed: [MastodonPart: Earlier] = [
        .notices: Earlier(
            question: noticesQuestion,
            failed: "notices.ask.failed", none: "notices.source.refused", unasked: "notices.source.unasked",
            with: [.bookmarks],
            says: { session, host, key in
                // A no on the source's page, and a source with none, are each a line the page
                // draws about that source: nothing says them twice.
                let drawn = key == "part.ask.refused.said" || key == "notices.source.refused"
                let said = key.flatMap { drawn ? nil : ShellNoticeActs.Said(act: .ask, why: .unreachable, key: $0) }
                session.noticeList.acts.say(said, host: host)
            },
            allowed: { session, host in
                guard session.mastodon.notices(host: host) == .allowed else { return }
                await session.noticeList.acts.readPage(in: session)
            }
        ),
    ]

    /// The notices question in the words it had, **where they are true of the page**: they
    /// name what a sign-in that only reads has, or one that acts and bookmarks, and say
    /// whether dismissing is asked. Of any other page — a sign-in that acts without
    /// bookmarks, one whose words nobody has confirmed — nothing: the table's words are
    /// said, which name what that page asks and no more.
    static func noticesQuestion(_ ask: PartAsk, language: DummyLanguage?) -> ShellConfirmation? {
        let page = ask.said
        guard MastodonParts.reads(page), MastodonOAuth.notices(page) else { return nil }
        let acts = MastodonParts.holds(.acting, in: page)
        let dismisses = MastodonOAuth.dismisses(page)
        let bookmarks = MastodonOAuth.bookmarks(page)
        let asksBookmarks = ask.ticked.count > 1
        if acts, dismisses, bookmarks {
            return ShellQuestion.notices(host: ask.host, grant: .writing, bookmarks: asksBookmarks, language: language)
        }
        let onlyReads = page.split(separator: " ").allSatisfy { $0.hasPrefix("read:") }
        guard onlyReads, !asksBookmarks else { return nil }
        return ShellQuestion.notices(host: ask.host, grant: .reading, language: language)
    }
}

/// A sign-in question as it is put: the source, and **what it says of notices, read once**.
/// The card is drawn from this and its answer is handed it, so the sign-in that follows asks
/// for notices only where the question named them — whatever the sign-in held has come to
/// have while the card stood open.
struct SignInAsked: Equatable {
    let host: String
    /// Whether the question says the source's page asks for notices with the rest.
    let notices: Bool
}

extension ShellSession {
    /// The question open about `host`, with what it says of notices: read off the sign-in held
    /// the first time it is asked for, and the same until the question is put down
    /// (`noticesSaid`) — a card drawn again does not come to say something else.
    ///
    /// **Kept only while a question about `host` is open**: asked with none open, it is read
    /// and not kept, so nothing is left that no question's putting down would take away.
    func signInAsked(host raw: String) -> SignInAsked {
        let host = raw.lowercased()
        if let said = noticesSaid[host] { return SignInAsked(host: raw, notices: said) }
        let carries = mastodon.carriesNotices(host: host)
        if signInChoice?.lowercased() == host { noticesSaid[host] = carries }
        return SignInAsked(host: raw, notices: carries)
    }

    /// The read-or-act question about `host`, with what this session holds for it read here:
    /// whether the sign-in it leads to carries notices, which the question then names. The one
    /// function every place that raises it asks (`SignInChoiceQuestion`), so none can leave them out.
    ///
    /// **Where a sign-in is held, it says which answer ends it at the source** (#347) — and
    /// that any other device carrying it is then signed out too — before the page opens.
    ///
    /// **And what each answer's page asks beyond what that answer always asked, and what it
    /// gives up** (`ShellQuestion.signInSaid`): a sign-in asked for more where it stood is
    /// carried by reading and acting, and narrowed by reading alone; and a question raised
    /// from a part's lock names the part it ticks (`signInDrawn`).
    func signInQuestion(host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        signInQuestion(signInDrawn(host: host), host: host, language: language)
    }

    /// The read-or-act question about `host`, in the words of what it is drawn from.
    func signInQuestion(_ drawn: SignInDrawn, host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        var question = ShellQuestion.signIn(host: host, notices: drawn.notices, language: language)
        var sentences = ShellQuestion.signInSaid(drawn, language: language)
        // Put in the place of one whose yes opened no page, it says first why it is back.
        if partAsks.signInTicks(host: host.lowercased())?.again == true {
            sentences.insert(L10n.t("part.ask.again", language: language), at: 0)
        }
        for sentence in sentences {
            (question.line, question.help) = ShellQuestion.saying(
                sentence, line: question.line, help: question.help, language: language
            )
        }
        return question
    }

    /// The read-or-act question put down, answered or not: the next one reads afresh.
    func putDownSignInChoice() {
        if let signInChoice { noticesSaid[signInChoice.lowercased()] = nil }
        partAsks.putDownSignIn()
        signInChoice = nil
    }
}
