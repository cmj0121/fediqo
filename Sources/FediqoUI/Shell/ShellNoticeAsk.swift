import AuthenticationServices
import FediqoCore
import Foundation
import SwiftUI

/// Notices are asked of a sign-in only when the person presses for them on the notices page
/// (#323) — every sign-in alike, one made before notices existed and one made yesterday — and
/// **nobody is signed out to ask**: #285's shape, as bookmarks are asked (`ShellBookmark`).
///
/// The press raises a question that says what the source's own page is about to ask for. Only
/// its yes opens that page, through the ordinary sign-in with notices added
/// (`MastodonSessions.signIn(host:through:writing:notices:noticesSaid:)`), which replaces the
/// token held only where a new one is issued: a page closed, a no on it, or any failure leaves
/// the sign-in the person had, doing everything it did.
extension ShellSession {
    /// The press beside a source the notices page names as not asked: raises the question.
    /// Sends nothing. Returns whether a question was raised.
    @discardableResult
    func askForNotices(host raw: String) -> Bool {
        let host = raw.lowercased()
        guard mastodon.notices(host: host) == .unasked else { return false }
        noticeAsk = host
        return true
    }

    /// The question answered no: everything stays as it was.
    func cancelNoticeAsk() {
        noticeAsk = nil
    }

    /// The question answered yes: the source's own page, asking for what the sign-in held
    /// already has and for notices — reading them, and dismissing them where it acts.
    ///
    /// `writing` is the answer of a sign-in made before any was asked what it may do
    /// (`MastodonGrant.unasked`), whose question is the read-or-act one with notices in both
    /// answers; every other sign-in keeps the part it has, and the argument is not read.
    ///
    /// **Only while that sign-in is still one to ask.** A question left open over a source
    /// that was signed out or already answered asks nothing.
    ///
    /// **What it says afterwards is what is true.** The sign-in held is still held, so a
    /// failure is "notices were not allowed", never "the sign-in failed"; a source with none
    /// to give is named by the page as having given none, and is not asked again; a page
    /// closed says nothing, as any sign-in's does. Where notices were allowed, the page reads.
    func allowNotices(host raw: String, through browser: any OAuthBrowser, writing chosen: Bool? = nil) async {
        noticeAsk = nil
        let host = raw.lowercased()
        guard mastodon.notices(host: host) == .unasked, let grant = mastodon.grants[host] else { return }
        let writing = grant == .unasked ? chosen ?? false : grant == .writing
        noticeList.acts.say(nil, host: host)
        let failure = await mastodon.signIn(host: host, through: browser, writing: writing, notices: true)
        await forgetReaderMarksDue()
        if let failure {
            NetLog.auth.notice("\(NetLog.line("notices", host: host, error: failure), privacy: .public)")
            // A source that has none is said to have none by its own line on the page.
            if mastodon.notices(host: host) != .unavailable {
                noticeList.acts.say(.init(act: .ask, why: .unreachable), host: host)
            }
            return
        }
        guard mastodon.notices(host: host) == .allowed else { return }
        await noticeList.acts.readPage(in: self)
        if mastodon.isSignedIn(host: host) { await readAsYou(host: host) }
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
        if signInChoice?.lowercased() == host || bookmarkAsk?.lowercased() == host { noticesSaid[host] = carries }
        return SignInAsked(host: raw, notices: carries)
    }

    /// The read-or-act question about `host`, with what this session holds for it read here:
    /// whether the sign-in it leads to carries notices, which the question then names. The one
    /// function every place that raises it asks (`SignInChoiceQuestion`), so none can leave them out.
    func signInQuestion(host: String) -> ShellConfirmation {
        ShellQuestion.signIn(host: host, notices: signInAsked(host: host).notices)
    }

    /// The bookmark question about `host`, naming notices where its sign-in carries them: what
    /// `BookmarkQuestion` puts.
    func bookmarkQuestion(host: String) -> ShellConfirmation {
        ShellQuestion.bookmarks(host: host, notices: signInAsked(host: host).notices)
    }

    /// The read-or-act question put down, answered or not: the next one reads afresh.
    func putDownSignInChoice() {
        if let signInChoice { noticesSaid[signInChoice.lowercased()] = nil }
        signInChoice = nil
    }
}

/// Notices, asked of a source already signed in to — a modifier, so the root's chain gains one
/// plain call and no presenter closure of its own, beside `BookmarkQuestion`.
struct NoticeQuestion: ViewModifier {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    let session: ShellSession

    func body(content: Content) -> some View {
        content.shellConfirm(asked, question: question, onChoice: answered)
    }

    private func question(_ host: String) -> ShellConfirmation {
        ShellQuestion.notices(
            host: host, grant: session.mastodon.grants[host], bookmarks: session.mastodon.bookmarks(host: host) == .unasked
        )
    }

    private func answered(_ host: String, _ id: String) {
        let browser = WebAuthBrowser(session: webAuthenticationSession)
        Task {
            await session.allowNotices(host: host, through: browser, writing: ShellQuestion.noticesChose(id))
        }
    }

    private var asked: Binding<String?> {
        Binding(get: { session.noticeAsk }, set: { if $0 == nil { session.cancelNoticeAsk() } })
    }
}
