import FediqoCore
import SwiftUI

/// Every question the app asks before something that cannot be undone, and the two notices that
/// share its sheet (#238) — **what each says, in one place and in words a test can read.**
///
/// Each is a `ShellConfirmation`: a title naming the act, one line saying what will happen, and
/// what the question used to say at length behind its (?). The long text is the key it always
/// was; the line is new. The screens that ask only hand these the facts they already hold.
///
/// `language` is threaded for the tests, as `ItemActs.withdrawQuestion` threads it; nothing
/// means the shell's own.
@MainActor
enum ShellQuestion {
    /// The id every one-yes question answers with.
    static let yes = "yes"

    /// How wide a question's line may be: one line of the sheet, at the widths it is drawn at,
    /// counted in the columns a Latin letter takes.
    static let lineLength = 70

    /// How wide `text` is drawn, in columns: a Han character, a kana, a Hangul syllable or a
    /// full-width mark takes about two of a Latin letter's. A line of seventy characters is one
    /// line in English and nearly two in Chinese, so a rule that counts characters passes a line
    /// that does not fit.
    static func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { sum, scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
                 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
                sum + 2
            default:
                sum + 1
            }
        }
    }

    /// A question's line and detail with one more whole sentence said (#294) — how many kept
    /// posts stay, how many of the posts brought are kept. **On the line where the line can take
    /// it**, since the line is what is read before the yes; behind the (?) where it cannot, and
    /// then the detail is where it is. Nothing changes where there is no sentence to say.
    ///
    /// Joined as two sentences by a key of its own, so a language that puts nothing between two
    /// sentences is not handed a space.
    static func saying(
        _ sentence: String?, line: String, help: String?, language: DummyLanguage? = nil
    ) -> (line: String, help: String?) {
        guard let sentence else { return (line, help) }
        let join = L10n.t("question.join", language: language)
        let longer = String(format: join, line, sentence)
        if width(longer) <= lineLength { return (longer, help) }
        return (line, help.map { String(format: join, $0, sentence) } ?? sentence)
    }

    /// "3 posts you keep stay." — or nothing where none is kept: what a question that lets posts
    /// go says of the ones it leaves (#294).
    static func keptStay(_ kept: Int, language: DummyLanguage? = nil) -> String? {
        kept > 0 ? L10n.count("question.kept.stay", kept, language: language) : nil
    }

    /// "3 of them are kept." — what a question that brings posts in says of them (#294): none,
    /// where the package says so; and that it does not say, where it does not.
    static func keptBrought(_ kept: Int?, language: DummyLanguage? = nil) -> String {
        guard let kept else { return L10n.t("question.kept.brought.unsaid", language: language) }
        return kept == 0
            ? L10n.t("question.kept.brought.none", language: language)
            : L10n.count("question.kept.brought", kept, language: language)
    }

    /// Stopping keeping every kept post, or every one from one source (#294). The title names the
    /// count; the line says whose and that nothing goes now; the (?) says what the yes costs.
    /// **A loss, and drawn as one**: nothing goes at the press, but the marks do not come back by
    /// themselves, and what they held back may go at the next limit.
    ///
    /// **The count is of posts that will be ordinary afterwards.** Where some of that source's
    /// kept posts are kept through another source too, they stay kept, and the question says how
    /// many rather than counting them in.
    static func stopKeeping(_ ask: KeptAsk, language: DummyLanguage? = nil) -> ShellConfirmation {
        let (line, help) = saying(
            ask.elsewhere > 0 ? L10n.count("usage.kept.elsewhere", ask.elsewhere, language: language) : nil,
            line: String(
                format: L10n.t("usage.kept.ask.line", language: language),
                SpanSection.whereLabel(ask.host, language: language)
            ),
            help: L10n.t("usage.kept.ask.detail", language: language), language: language
        )
        return ShellConfirmation(
            symbol: "bookmark.slash", title: L10n.count("usage.kept.ask", ask.posts, language: language),
            line: line,
            help: help,
            choices: [.init(yes, L10n.t("usage.kept.stop", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Taking back what the reader wrote (#109). `copy` is the copy that goes (#136): its words
    /// and its host are what is named.
    static func withdraw(_ copy: DummyItem, language: DummyLanguage? = nil) -> ShellConfirmation {
        let words = ItemActs.withdrawQuestion(copy, language: language)
        return ShellConfirmation(
            symbol: "arrow.uturn.backward", title: words.title,
            line: String(format: L10n.t("withdraw.line", language: language), copy.source.host),
            help: words.detail,
            choices: [.init(yes, L10n.t("withdraw.confirm", language: language), role: .destructive)],
            cancel: L10n.t("compose.cancel", language: language)
        )
    }

    /// Discarding a text that waits to be sent (`ShellOutbox`). **A loss, and drawn as one**:
    /// the words are deleted from this device and do not come back.
    ///
    /// **One that may have been posted is not said to be unsent.** Its question is about this
    /// device's copy alone: forgetting it here takes nothing back from its source, where — if
    /// it was posted — it stays, to be taken back from its own row.
    static func discard(_ sending: ShellOutbox.Sending, language: DummyLanguage? = nil) -> ShellConfirmation {
        let kind = sending.unsent.answers == nil ? "post" : "answer"
        let maybe = sending.standing == .unconfirmed
        let opening = OutboxWords.opening(sending.unsent.text)
        return ShellConfirmation(
            symbol: "trash",
            title: L10n.t("outbox.discard.title\(maybe ? ".unconfirmed" : "").\(kind)", language: language),
            line: maybe
                ? String(format: L10n.t("outbox.discard.line.unconfirmed", language: language), sending.unsent.host)
                : String(format: L10n.t("outbox.discard.line", language: language), opening),
            help: maybe ? String(format: L10n.t("outbox.discard.detail.unconfirmed", language: language), opening) : nil,
            choices: [.init(
                yes, L10n.t(maybe ? "outbox.discard.confirm.unconfirmed" : "outbox.discard", language: language),
                role: .destructive
            )],
            cancel: L10n.t("compose.cancel", language: language)
        )
    }

    /// Before a text that may have been posted is sent all the same: said plainly that it may
    /// then be posted twice, and where to look first. `changed` is the person having typed
    /// over it: what goes is then a new post, and the first — if it was posted — stays.
    static func resend(
        _ sending: ShellOutbox.Sending, changed: Bool, language: DummyLanguage? = nil
    ) -> ShellConfirmation {
        let kind = sending.unsent.answers == nil ? "post" : "answer"
        let host = sending.unsent.host
        return ShellConfirmation(
            symbol: "questionmark.circle",
            title: L10n.t("outbox.resend.title.\(kind)", language: language),
            line: String(format: L10n.t(changed ? "outbox.resend.line.changed" : "outbox.resend.line", language: language), host),
            help: String(format: L10n.t("outbox.resend.detail", language: language), host),
            choices: [.init(yes, L10n.t("outbox.resend.confirm", language: language), role: .destructive)],
            cancel: L10n.t("compose.cancel", language: language)
        )
    }

    /// Removing a source. The line says what will happen to its posts — they go, or they stay
    /// as the reader chose on Preferences (#250, `postsStay`) — and the boards it takes do not
    /// come back, so where there are any the line names them too; the (?) says the rest.
    ///
    /// `kept` is how many of its posts the person keeps (#294): where its posts go, the line
    /// itself says how many stay for that — a line of its own, so the count is read before the
    /// yes — and the (?) says the rest as before. Where they all stay it says nothing of them:
    /// none goes.
    ///
    /// `unsent` is how many texts wait to be sent to it (`ShellOutbox`): they are deleted with
    /// it, and the question says how many — on the line where the line can take it.
    static func remove(
        host: String, boards: Int, postsStay: Bool = false, kept: Int = 0, unsent: Int = 0,
        language: DummyLanguage? = nil
    ) -> ShellConfirmation {
        let stay = postsStay ? ".stay" : ""
        // Only the boards keys carry a count to format; the rest are said as written.
        func said(_ key: String) -> String {
            boards > 0
                ? String(format: L10n.t("\(key)\(stay).boards", language: language), boards)
                : L10n.t("\(key)\(stay)", language: language)
        }
        var line = postsStay || boards > 0 ? said("account.remove.line") : L10n.t("account.remove.detail", language: language)
        var help = postsStay || boards > 0 ? said("account.remove.detail") : nil
        if kept > 0, !postsStay {
            line = boards > 0
                ? counted("account.remove.line.kept.boards", kept, String(boards), language: language)
                : L10n.count("account.remove.line.kept", kept, language: language)
            // The line has said how many stay; the (?) says the rest without saying it again.
            help = boards > 0
                ? String(format: L10n.t("account.remove.detail.boards.counted", language: language), boards)
                : L10n.t("account.remove.detail.counted", language: language)
        }
        (line, help) = saying(
            unsent > 0 ? L10n.count("question.unsent.go", unsent, language: language) : nil,
            line: line, help: help, language: language
        )
        return ShellConfirmation(
            symbol: "trash", title: String(format: L10n.t("account.remove.title", language: language), host),
            line: line, help: help,
            choices: [.init(yes, L10n.t("account.remove.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Clearing what a source left here. `detailKey` is `SourceRow.clearDetailKey`'s answer for
    /// this host; the line follows it, so a saved password's going is said on the line itself.
    ///
    /// **Keyed and not destructive**, for decision 29's reason: the weight of the yes matches the
    /// weight of the act, and most of what Clear drops comes back — so ⌘Return answers it, and it
    /// is drawn as a plain press. **Except where a saved password goes**: that does not come back,
    /// so that Clear is a loss, drawn and chorded (⌘D) as one.
    static func clear(host: String, detailKey: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "eraser", title: String(format: L10n.t("account.clear.title", language: language), host),
            line: L10n.t(clearLineKey(detailKey), language: language),
            help: L10n.t(detailKey, language: language),
            choices: [.init(
                yes, L10n.t("account.clear.confirm", language: language),
                role: detailKey == SourceRow.clearDetailKey(hasPassword: true, reachedSignIn: false)
                    ? .destructive : .keyed
            )],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Forgetting the password saved for a forum, and nothing else of it. **A loss**: the
    /// password does not come back, and is typed again the next time the forum asks. The sign-in
    /// it made stays until that ends, which the (?) says.
    static func forgetPassword(host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "key.slash",
            title: String(format: L10n.t("prefs.password.forget.title", language: language), host),
            line: L10n.t("prefs.password.forget.line", language: language),
            help: L10n.t("prefs.password.forget.detail", language: language),
            choices: [.init(yes, L10n.t("prefs.password.forget.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// The line beside each of Clear's three long texts.
    static func clearLineKey(_ detailKey: String) -> String {
        detailKey.replacingOccurrences(of: "account.clear.detail", with: "account.clear.line")
    }

    /// Reading, or reading and writing, on a source being signed in to. Neither is a loss, and
    /// neither is lit: the narrower comes first and is the one a key answers (⌘Return), so the
    /// answer given without looking is the one that grants the least.
    ///
    /// `notices` where this sign-in carries the notices the one held has
    /// (`MastodonSessions.carriesNotices`): the source's page then asks to read them, and to
    /// dismiss them where acting is chosen, and **everything the page will ask is said before
    /// it opens** (#283) — in the words the notices question's own choice has.
    static func signIn(host: String, notices: Bool = false, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "key", title: String(format: L10n.t("account.signin.ask.title", language: language), host),
            line: L10n.t(notices ? "notices.ask.choose.line" : "account.signin.ask.line", language: language),
            help: notices
                ? String(format: L10n.t("notices.ask.signin.detail", language: language), host)
                : L10n.t("account.signin.ask.detail", language: language),
            choices: [
                .init(signInRead, L10n.t("account.signin.ask.read", language: language), role: .keyed),
                .init(signInWrite, L10n.t("account.signin.ask.write", language: language), role: .plain),
            ],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Signing out of a source, asked when its key is pressed while signed in. The title names
    /// the host; the line and the (?) say what goes, which is not the same for the two kinds a
    /// sign-in exists for.
    ///
    /// A Mastodon (`mastodon`): the token leaves this device and the server is asked to end it,
    /// so reading as the person and everything the sign-in allowed stop. A forum: its session on
    /// this device goes — and with it the saved password, where one is held (`hasPassword`).
    ///
    /// **Keyed and not destructive, as Clear is and for its reason**: signing in again brings
    /// the sign-in back. **Except where a saved password goes**: that does not come back, so
    /// that sign-out is a loss, drawn and chorded as one.
    static func signOut(
        host: String, mastodon: Bool, hasPassword: Bool = false, language: DummyLanguage? = nil
    ) -> ShellConfirmation {
        let key = mastodon ? "account.signout.ask.mastodon"
            : hasPassword ? "account.signout.ask.forum.password" : "account.signout.ask.forum"
        return ShellConfirmation(
            symbol: "key", title: String(format: L10n.t("account.signout.ask.title", language: language), host),
            line: L10n.t(key + ".line", language: language),
            help: L10n.t(key + ".detail", language: language),
            choices: [.init(
                yes, L10n.t("account.signout.ask.confirm", language: language),
                role: !mastodon && hasPassword ? .destructive : .keyed
            )],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Bookmarks, asked of a sign-in that already reads and acts (#285). Not a loss: what the
    /// sign-in does today it goes on doing, and the source's own page asks again before anything
    /// is granted. The line says what the page will ask for, bookmarks among it.
    ///
    /// `notices` where that sign-in carries notices: the page asks to read and to dismiss them
    /// with the rest, and the question says so in the words the notices question has for a
    /// sign-in that acts and lacks bookmarks — the same page, asked for from the other side.
    static func bookmarks(host: String, notices: Bool = false, language: DummyLanguage? = nil) -> ShellConfirmation {
        let key = notices ? "notices.ask.actsBookmarks" : "item.bookmark.ask"
        return ShellConfirmation(
            symbol: "bookmark",
            title: String(format: L10n.t("item.bookmark.ask.title", language: language), host),
            line: L10n.t(key + ".line", language: language),
            help: String(format: L10n.t(key + ".detail", language: language), host),
            choices: [.init(yes, L10n.t("item.bookmark.ask.confirm", language: language), role: .keyed)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Notices, asked of a sign-in already held (#323), **naming what the source's own page is
    /// about to ask for before it opens**: reading notices, and dismissing them too where that
    /// sign-in acts. Not a loss: the sign-in goes on as it is whatever happens on the page.
    ///
    /// A sign-in made before any was asked what it may do (`unasked`) has never chosen between
    /// reading and acting, and asking it for notices alone would write that choice down for
    /// it: its question is the read-or-act one (`signIn`), with notices in both answers.
    ///
    /// **Everything the page will ask is said** (#283). A sign-in that acts is asked for
    /// bookmarks with the rest; where it was made before bookmarks were asked for (`bookmarks`,
    /// #285) that is one thing more than it holds, and the question names it as #285's own does.
    static func notices(
        host: String, grant: MastodonGrant?, bookmarks: Bool = false, language: DummyLanguage? = nil
    ) -> ShellConfirmation {
        let title = String(format: L10n.t("notices.ask.title", language: language), host)
        let cancel = L10n.t("board.choose.cancel", language: language)
        guard grant == .unasked else {
            let key = grant != .writing ? "notices.ask.reads" : bookmarks ? "notices.ask.actsBookmarks" : "notices.ask.acts"
            return ShellConfirmation(
                symbol: "bell", title: title, line: L10n.t(key + ".line", language: language),
                help: String(format: L10n.t(key + ".detail", language: language), host),
                choices: [.init(yes, L10n.t("item.bookmark.ask.confirm", language: language), role: .keyed)],
                cancel: cancel
            )
        }
        return ShellConfirmation(
            symbol: "bell", title: title, line: L10n.t("notices.ask.choose.line", language: language),
            help: String(format: L10n.t("notices.ask.choose.detail", language: language), host),
            choices: [
                .init(signInRead, L10n.t("notices.ask.choose.read", language: language), role: .keyed),
                .init(signInWrite, L10n.t("notices.ask.choose.write", language: language), role: .plain),
            ],
            cancel: cancel
        )
    }

    /// What an answer to the notices question says of acting: read or act, where the question
    /// was that choice, and nothing where it was the one yes of a sign-in that keeps its part.
    static func noticesChose(_ id: String) -> Bool? {
        switch id {
        case signInRead: false
        case signInWrite: true
        default: nil
        }
    }

    /// Dismissing one line of the notices page at its source (#323). **A loss**: it goes
    /// there, and so in every other app the person reads that source with, and does not come
    /// back. A line the source gathered says how many notices go with it.
    static func dismiss(_ notice: Notice, language: DummyLanguage? = nil) -> ShellConfirmation {
        let host = notice.source.host
        let many = notice.count > 1
        return ShellConfirmation(
            symbol: NoticeActs.dismissSymbol,
            title: many
                ? counted("notices.dismiss.title.gathered", notice.count, host, language: language)
                : String(format: L10n.t("notices.dismiss.title", language: language), host),
            line: L10n.t(many ? "notices.dismiss.line.gathered" : "notices.dismiss.line", language: language),
            help: nil,
            choices: [.init(yes, L10n.t("notices.dismiss", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Dismissing every notice one source has (#323). **A loss, and a wider one than the page
    /// shows**: the source takes away the ones not read on to and the kinds left out as well,
    /// which the line says before the yes. Other sources are left alone, and the (?) says so.
    static func dismissAll(host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: NoticeActs.dismissSymbol,
            title: String(format: L10n.t("notices.dismissAll.title", language: language), host),
            line: L10n.t("notices.dismissAll.line", language: language),
            help: String(format: L10n.t("notices.dismissAll.detail", language: language), host),
            choices: [.init(yes, L10n.t("notices.dismissAll.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Letting one person's held-back notices through (#323). **Asked first, and not drawn as
    /// a loss**: nothing is taken away, but the source also stops holding back what that person
    /// sends from then on, and nothing Fediqo can ask of it takes that back — so it is not done
    /// on one press. Keyed, as Clear's yes is.
    ///
    /// **Who is named by their handle** (`NoticeWords.named`), here and in letting go: the
    /// question is whose notices, and a name is whatever its owner typed.
    static func letThrough(_ request: NoticeRequest, language: DummyLanguage? = nil) -> ShellConfirmation {
        let name = NoticeWords.named(request.person, language: language), host = request.source.host
        return ShellConfirmation(
            symbol: NoticeActs.throughSymbol,
            title: String(format: L10n.t("notices.held.through.title", language: language), name, host),
            line: L10n.t("notices.held.through.line", language: language),
            help: String(format: L10n.t("notices.held.through.detail", language: language), name, host),
            choices: [.init(yes, L10n.t("notices.held.through", language: language), role: .keyed)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Letting go of one person's notices a source is holding back (#323). **A loss**: they
    /// are dismissed there without having been shown.
    static func letGo(_ request: NoticeRequest, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: NoticeActs.dismissSymbol,
            title: String(
                format: L10n.t("notices.held.go.title", language: language),
                NoticeWords.named(request.person, language: language), request.source.host
            ),
            line: L10n.t("notices.held.go.line", language: language), help: nil,
            choices: [.init(yes, L10n.t("notices.held.go", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    static let signInRead = "read"
    static let signInWrite = "write"

    /// Dropping every picture copy on this device.
    static func dropCopies(language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "trash", title: L10n.t("prefs.drop.copies.title", language: language),
            line: L10n.t("prefs.drop.copies.line", language: language),
            help: L10n.t("prefs.drop.copies.detail", language: language),
            choices: [.init(yes, L10n.t("prefs.drop.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Keeping fewer months than now.
    static func shorten(months: Int, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "hourglass", title: L10n.count("prefs.keep.shorten.title", months, language: language),
            line: L10n.t("prefs.keep.shorten.line", language: language),
            help: L10n.t("prefs.keep.shorten.detail", language: language),
            choices: [.init(yes, L10n.t("prefs.drop.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Giving the store less room than now (#249): the copies, and then the oldest posts, may go
    /// at once.
    static func tighten(room: Int, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "internaldrive",
            title: String(format: L10n.t("prefs.room.tighten.title", language: language), UsagePane.size(room, language: language)),
            line: L10n.t("prefs.room.tighten.line", language: language),
            help: L10n.t("prefs.room.tighten.detail", language: language),
            choices: [.init(yes, L10n.t("prefs.drop.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Clearing the limits' account (#251). **Not a loss, and not drawn as one**: only the lines
    /// go, and they were about posts already gone; nothing held goes with them. Keyed, as
    /// Clear's yes is, so the question has the one yes a `…` item acts on (⌘Return).
    static func clearAccount(language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "eraser", title: L10n.t("prefs.limits.clear.title", language: language),
            line: L10n.t("prefs.limits.clear.line", language: language),
            help: L10n.t("prefs.limits.clear.detail", language: language),
            choices: [.init(yes, L10n.t("prefs.limits.clear.confirm", language: language), role: .keyed)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Letting go of the posts of a span of days, from one source or every one (#248): the title
    /// counts them, the line names the days and where they come from and that they do not come
    /// back, and the (?) says what stays.
    static func letGo(_ ask: SpanAsk, language: DummyLanguage? = nil) -> ShellConfirmation {
        let (line, help) = saying(
            keptStay(ask.kept, language: language),
            line: String(
                format: L10n.t("prefs.span.ask.line", language: language),
                SpanSection.spanLabel(from: ask.from, to: ask.to, language: language),
                SpanSection.whereLabel(ask.host, language: language)
            ),
            help: L10n.t(ask.kept > 0 ? "prefs.span.ask.detail.counted" : "prefs.span.ask.detail", language: language),
            language: language
        )
        return ShellConfirmation(
            symbol: "trash", title: L10n.count("prefs.span.ask", ask.posts, language: language),
            line: line,
            help: help,
            choices: [.init(yes, L10n.t("prefs.gone.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Removing a host the person added for one of their sources. **A loss**: what it let
    /// through for that source is refused from the yes on. Nothing held goes with it.
    static func removeOwnHost(_ host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "trash", title: String(format: L10n.t("allow.own.remove.title", language: language), host),
            line: L10n.t("allow.own.remove.line", language: language),
            help: L10n.t("allow.own.remove.detail", language: language),
            choices: [.init(yes, L10n.t("allow.own.removeIt", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Removing a timeline. Its line already says it all, so there is no (?).
    static func removeTimeline(named name: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "trash", title: String(format: L10n.t("timeline.remove.title", language: language), name),
            line: L10n.t("timeline.remove.detail", language: language), help: nil,
            choices: [.init(yes, L10n.t("timeline.remove.confirm", language: language), role: .destructive)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// A store written by a newer build: nothing to choose, one press to say it was read.
    static func storeNewer(language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "exclamationmark.triangle", title: L10n.t("store.newer.title", language: language),
            line: L10n.t("store.newer.line", language: language),
            help: L10n.t("store.newer.detail", language: language),
            choices: [], cancel: L10n.t("store.newer.ok", language: language)
        )
    }

    // MARK: - A store that did not open (#295)

    /// The ids the store notices answer with.
    static let keepInPlace = "keepInPlace"
    static let putBack = "putBack"
    static let told = "told"

    /// What went wrong with this device's store at launch, said at the first thing the person
    /// sees: that it could not be opened; that it was damaged, something took its place and the
    /// damaged one will be deleted for good; or that a read back was interrupted and there are
    /// two stores to choose between.
    ///
    /// **A damaged store's notice has a press of its own**, and only that press is the person
    /// having been told: what waits on it is a deletion, and a sheet goes away for many reasons
    /// that are not somebody reading it. Put down any other way, it is shown again.
    ///
    /// **Of two stores, the one in place can always be kept** — keeping it moves nothing, and
    /// one that then proves damaged brings the other back. The one set aside is offered only
    /// where it could be glanced at. Either choice is a loss, and is drawn as one.
    static func storeTrouble(_ trouble: StoreTrouble, language: DummyLanguage? = nil) -> ShellConfirmation {
        func said(_ key: String) -> String { L10n.t(key, language: language) }
        switch trouble {
        case .unreachable(let why):
            let key = switch why {
            case .inUse: "store.unreachable.inUse"
            case .noRoom: "store.unreachable.noRoom"
            case .outOfReach: "store.unreachable.outOfReach"
            case .readBackInterrupted: "store.unreachable.readBack"
            case .putAsideOnly: "store.unreachable.putAside"
            case .otherComesBack: "store.unreachable.otherBack"
            }
            return ShellConfirmation(
                symbol: "exclamationmark.triangle", title: said("store.unreachable.title"),
                line: said(key + ".line"), help: said(key + ".detail"),
                choices: [], cancel: said("store.newer.ok")
            )
        case .damaged(let replacedBy):
            let key = replacedBy == .empty ? "store.damaged" : "store.damaged.other"
            return ShellConfirmation(
                symbol: "exclamationmark.triangle", title: said("store.damaged.title"),
                line: said(key + ".line"), help: said(key + ".detail"),
                choices: [.init(told, said("store.damaged.told"), role: .destructive)],
                cancel: said("store.damaged.later")
            )
        case .twoStores(let inPlace, let setAside):
            var choices = [ShellConfirmation.Choice(keepInPlace, said("store.two.keep"), role: .destructive)]
            if setAside.posts != nil { choices.append(.init(putBack, said("store.two.back"), role: .destructive)) }
            let neither = inPlace.posts == nil && setAside.posts == nil
            return ShellConfirmation(
                symbol: "exclamationmark.triangle", title: said("store.two.title"),
                line: said(neither ? "store.two.line.neither" : "store.two.line"),
                help: String(
                    format: said(neither ? "store.two.detail.neither" : "store.two.detail"),
                    glance(inPlace, language: language), glance(setAside, language: language)
                ),
                choices: choices, cancel: said("store.two.later")
            )
        }
    }

    /// "12 posts, last written 5 Oct 2026 at 14:02" — what can be said of a store without
    /// opening it to write, and that it cannot be read where it would not say.
    static func glance(_ glance: StoreGlance, language: DummyLanguage? = nil) -> String {
        let posts = glance.posts.map { $0 == 0
            ? L10n.t("prefs.held.posts.none", language: language)
            : L10n.count("prefs.held.posts", $0, language: language)
        } ?? L10n.t("store.glance.unread", language: language)
        guard let written = glance.written else { return posts }
        let when = written.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale(language))
        )
        return String(format: L10n.t("store.glance", language: language), posts, when)
    }

    /// What a press on a store notice answers. Putting one down answers nothing.
    static func storeTroubleChose(_ id: String) -> StoreTroubleAnswer? {
        switch id {
        case told: .told
        case keepInPlace: .keepInPlace
        case putBack: .putBack
        default: nil
        }
    }

    // MARK: - Taking away and reading back (#247, #252)

    static let withPictures = "with"
    static let withoutPictures = "without"

    /// Whether the picture copies ride, with what each would come to on the line. Neither is a
    /// loss; without is the one a key answers, being the smaller.
    static func takeAway(_ weight: PackageWeight, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "square.and.arrow.up", title: L10n.t("carry.take.ask.title", language: language),
            line: String(
                format: L10n.t("carry.take.ask.line", language: language),
                UsagePane.size(weight.withPictures, language: language),
                UsagePane.size(weight.withoutPictures, language: language)
            ),
            help: L10n.t("carry.take.ask.help", language: language),
            choices: [
                .init(withoutPictures, L10n.t("carry.take.without", language: language), role: .keyed),
                .init(withPictures, L10n.t("carry.take.with", language: language), role: .plain),
            ],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// #252's question: how many posts, from which sources, taken away when — and, where this
    /// device holds a store, that a yes replaces it, which is a loss and is drawn as one.
    ///
    /// **And how many of the posts it brings are kept** (#294), before the yes: a kept post is
    /// one no limit here will let go, and a store read back arrives with every one of its marks.
    /// What the header says — which the read back holds the package to (`StorePackager`) — or,
    /// of a package whose header says nothing, that it does not say.
    static func readBack(_ summary: PackageSummary, held: Bool, language: DummyLanguage? = nil) -> ShellConfirmation {
        let sources = summary.sources.map(\.host).joined(separator: ", ")
        let day = summary.takenAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale(language))
        )
        var help = String(
            format: L10n.t("carry.read.ask.help", language: language), sources, day, summary.device, summary.appVersion
        )
        if held { help = String(format: L10n.t("carry.read.ask.help.held", language: language), help) }
        let (line, said) = saying(
            summary.contents == .whole ? keptBrought(summary.kept, language: language) : nil,
            line: String(format: L10n.t("carry.read.ask.line", language: language), sources, day),
            help: help, language: language
        )
        return ShellConfirmation(
            symbol: "square.and.arrow.down",
            title: L10n.count("carry.read.ask.title", summary.posts, language: language),
            line: line,
            help: said,
            choices: [held
                ? .init(yes, L10n.t("carry.read.replace", language: language), role: .destructive)
                : .init(yes, L10n.t("carry.read.go", language: language), role: .primary)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
    }

    /// Why a take-away or a read back stopped, each its own sentence, and nothing to choose.
    static func carryRefused(_ trouble: ShellCarry.Trouble, language: DummyLanguage? = nil) -> ShellConfirmation {
        let (key, line): (String, String)
        switch trouble {
        case .package(let refusal):
            key = "carry.refused.\(refusal)"
            line = L10n.t(key + ".line", language: language)
        case .noRoom(let needed, let free):
            key = "carry.refused.noRoom"
            line = String(
                format: L10n.t(key + ".line", language: language),
                UsagePane.size(needed, language: language), UsagePane.size(free, language: language)
            )
        case .emptyPassword:
            key = "carry.refused.empty"
            line = L10n.t(key + ".line", language: language)
        case .shortPassword:
            key = "carry.refused.short"
            line = String(format: L10n.t(key + ".line", language: language), PackageFormat.minPasswordCount)
        case .indexIsNewer:
            key = "carry.refused.indexNewer"
            line = L10n.t(key + ".line", language: language)
        case .storeNotOpened:
            key = "carry.refused.storeNotOpened"
            line = L10n.t(key + ".line", language: language)
        case .nothingToTake:
            key = "carry.refused.nothingToTake"
            line = L10n.t(key + ".line", language: language)
        case .unwound(let steps):
            key = "carry.refused.unwound"
            let named = steps.map { L10n.t("carry.step.\($0)", language: language) }.joined(separator: ", ")
            line = String(format: L10n.t(key + ".line", language: language), named)
        case .other(let said):
            key = "carry.refused.other"
            line = String(format: L10n.t(key + ".line", language: language), said)
        }
        return ShellConfirmation(
            symbol: "exclamationmark.triangle", title: L10n.t(key + ".title", language: language),
            line: line, help: nil, choices: [], cancel: L10n.t("store.newer.ok", language: language)
        )
    }

    /// It is done: taken away, or read back with the count.
    static func carryDone(_ done: ShellCarry.Done, language: DummyLanguage? = nil) -> ShellConfirmation {
        switch done {
        case .taken:
            ShellConfirmation(
                symbol: "checkmark.circle", title: L10n.t("carry.done.taken.title", language: language),
                line: L10n.t("carry.done.taken.line", language: language), help: nil, choices: [],
                cancel: L10n.t("store.newer.ok", language: language)
            )
        case .readBack(let summary):
            ShellConfirmation(
                symbol: "checkmark.circle", title: L10n.t("carry.done.read.title", language: language),
                line: L10n.count("carry.done.read.line", summary.posts, language: language), help: nil, choices: [],
                cancel: L10n.t("store.newer.ok", language: language)
            )
        }
    }

    // MARK: - Moving to and from a device nearby (#253, #6)

    /// #252's question, asked on both devices: what would move, to or from which device, and —
    /// on the one that will hold it — that a store here is replaced, which is a loss and is
    /// drawn as one. Sign-ins alone (#6) are asked as that.
    static func nearbyAsk(_ ask: ShellNearby.Ask, language: DummyLanguage? = nil) -> ShellConfirmation {
        let summary = ask.offer.summary
        let sources = summary.sources.map(\.host).joined(separator: ", ")
        let signInsOnly = summary.contents == .signInsOnly
        let way = ask.receiving ? "hold" : "move"
        let title = signInsOnly
            ? String(format: L10n.t("nearby.ask.\(way).signIns.title", language: language), ask.peer)
            : counted("nearby.ask.\(way).title", summary.posts, ask.peer, language: language)
        let size = UsagePane.size(Int(ask.offer.fileBytes), language: language)
        let plainLine = String(format: L10n.t("nearby.ask.line", language: language), sources, size)
        var plainHelp = String(
            format: L10n.t(ask.receiving ? "nearby.ask.hold.help" : "nearby.ask.move.help", language: language),
            ask.peer, summary.device, summary.appVersion
        )
        if ask.receiving, ask.held, !signInsOnly {
            plainHelp = String(format: L10n.t("carry.read.ask.help.held", language: language), plainHelp)
        }
        let replaces = ask.receiving && ask.held && !signInsOnly
        // How many of the posts are kept (#294), said on both devices: the one that will hold
        // them is the one it matters to, and the one sending them reads the same question.
        let (line, help) = saying(
            signInsOnly ? nil : keptBrought(summary.kept, language: language), line: plainLine, help: plainHelp,
            language: language
        )
        return ShellConfirmation(
            symbol: ask.receiving ? "antenna.radiowaves.left.and.right" : "paperplane",
            title: title, line: line, help: help,
            choices: [replaces
                ? .init(yes, L10n.t("carry.read.replace", language: language), role: .destructive)
                : .init(yes, L10n.t(ask.receiving ? "nearby.ask.hold.go" : "nearby.ask.move.go", language: language), role: .primary)],
            cancel: L10n.t("nearby.ask.refuse", language: language)
        )
    }

    /// A count and a name in one sentence, singular where the count is one and the language has
    /// it (`L10n.count`'s rule): the count is `%1$d` and the name `%2$@`.
    nonisolated static func counted(_ key: String, _ count: Int, _ name: String, language: DummyLanguage? = nil) -> String {
        let one = key + ".one"
        let singular = count == 1 ? L10n.t(one, language: language) : one
        return String(format: singular == one ? L10n.t(key, language: language) : singular, count, name)
    }

    /// Before the sender joins: the mark its digits and the chosen device's session make, and
    /// whether the other screen shows the same one. Not the same is the way out, back to the
    /// list; nothing has joined either way.
    static func nearbyMark(_ mark: String, peer: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "checkmark.seal",
            title: String(format: L10n.t("nearby.mark.ask.title", language: language), mark),
            line: String(format: L10n.t("nearby.mark.ask.line", language: language), peer),
            help: L10n.t("nearby.mark.ask.help", language: language),
            choices: [.init(yes, L10n.t("nearby.mark.ask.same", language: language), role: .primary)],
            cancel: L10n.t("nearby.mark.ask.different", language: language)
        )
    }

    /// Why a move nearby stopped, each its own sentence. A refused look nearby is said as that —
    /// this device was not allowed to look — never as nobody being there.
    static func nearbyRefused(_ refusal: NearbyRefusal, language: DummyLanguage? = nil) -> ShellConfirmation {
        let (key, line): (String, String)
        switch refusal {
        case .package(let inner):
            return carryRefused(.package(inner), language: language)
        case .noRoom(let needed, let free):
            return carryRefused(.noRoom(needed: needed, free: free), language: language)
        case .storeNotOpened:
            return carryRefused(.storeNotOpened, language: language)
        case .nothingToTake:
            return carryRefused(.nothingToTake, language: language)
        case .notAllowed, .wrongCode, .refusedThere, .lost, .malformed, .unsure, .guessing, .timedOut:
            key = "nearby.refused.\(refusal)"
            line = L10n.t(key + ".line", language: language)
        case .other(let said):
            key = "nearby.refused.other"
            line = String(format: L10n.t(key + ".line", language: language), said)
        }
        return ShellConfirmation(
            symbol: "exclamationmark.triangle", title: L10n.t(key + ".title", language: language),
            line: line, help: nil, choices: [], cancel: L10n.t("store.newer.ok", language: language)
        )
    }

    /// It is done, and where it went or came from.
    static func nearbyDone(_ summary: PackageSummary, peer: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        let line = summary.contents == .signInsOnly
            ? L10n.t("nearby.done.signIns.line", language: language)
            : L10n.count("carry.done.read.line", summary.posts, language: language)
        return ShellConfirmation(
            symbol: "checkmark.circle", title: String(format: L10n.t("nearby.done.title", language: language), peer),
            line: line, help: nil, choices: [], cancel: L10n.t("store.newer.ok", language: language)
        )
    }

    /// Sources that ended a sign-in on their own side.
    static func signedOut(hosts: [String], language: DummyLanguage? = nil) -> ShellConfirmation {
        let named = hosts.joined(separator: ", ")
        return ShellConfirmation(
            symbol: "person.crop.circle.badge.xmark",
            title: L10n.t("account.mastodon.ended.title", language: language),
            line: String(format: L10n.t("account.mastodon.ended.line", language: language), named),
            help: String(format: L10n.t("account.mastodon.ended.detail", language: language), named),
            choices: [], cancel: L10n.t("store.newer.ok", language: language)
        )
    }
}
