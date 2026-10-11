import SwiftUI

extension ShellQuestion {
    /// Sources that ended a sign-in on their own side — and, for those in `left`, that the
    /// earlier sign-ins this device had left there were ended with it (#347): other devices
    /// carrying one are signed out too, and are not left to find out.
    static func signedOut(hosts: [String], left: Set<String>, language: DummyLanguage? = nil) -> ShellConfirmation {
        var notice = signedOut(hosts: hosts, language: language)
        let others = hosts.filter { left.contains($0.lowercased()) }
        guard !others.isEmpty else { return notice }
        let added = String(
            format: L10n.t("account.mastodon.ended.left", language: language), others.joined(separator: ", ")
        )
        (notice.line, notice.help) = saying(added, line: notice.line, help: notice.help, language: language)
        return notice
    }

    /// "Any other device carrying this sign-in is signed out too." — what a question whose
    /// yes ends a Mastodon sign-in says first (#347): signing out here ends every sign-in
    /// this device holds or left there, and each is one another device may be carrying.
    static func othersSignedOut(language: DummyLanguage? = nil) -> String {
        L10n.t("account.signout.ask.others", language: language)
    }

    /// What the read-or-act question adds where a sign-in is held (#347): which answer ends
    /// it at the source, and that every other device carrying it is signed out with it.
    static func signInEnds(
        _ ends: MastodonSessions.SignInEnds, host: String, language: DummyLanguage? = nil
    ) -> String {
        let key = switch ends {
        case .reading: "account.signin.ask.ends.read"
        case .either: "account.signin.ask.ends.either"
        case .another: "account.signin.ask.ends.another"
        }
        return String(format: L10n.t(key, language: language), host)
    }

    /// One thing to tell of a source that was asked to end a sign-in (#347). A notice, as a
    /// sign-in a source ended is: after a Remove there is no row to say it under, and after
    /// a sign-out the row says signed out.
    static func left(_ told: MastodonSessions.LeftTold, language: DummyLanguage? = nil) -> ShellConfirmation {
        let (symbol, key) = switch told.kind {
        case .unconfirmed: ("exclamationmark.triangle", "account.signout.unconfirmed")
        case .refused: ("exclamationmark.triangle", "account.left.refused")
        case .others: ("person.crop.circle.badge.xmark", "account.left.others")
        }
        return ShellConfirmation(
            symbol: symbol, title: L10n.t(key + ".title", language: language),
            line: String(format: L10n.t(key + ".line", language: language), told.host),
            help: nil, choices: [], cancel: L10n.t("store.newer.ok", language: language)
        )
    }
}

extension ShellSession {
    /// `question`, saying first that other devices carrying the sign-in are signed out too
    /// (#347) — where its yes ends a Mastodon sign-in this device holds at `host`, could
    /// not keep, or left there: a sign-out, a Clear, a Remove. Any other question is handed
    /// back as it is.
    func sayingOthersSignedOut(
        _ question: ShellConfirmation, host: String, language: DummyLanguage? = nil
    ) -> ShellConfirmation {
        guard mastodon.endsSignIns(host: host) else { return question }
        var said = question
        (said.line, said.help) = ShellQuestion.saying(
            ShellQuestion.othersSignedOut(language: language), line: question.line, help: question.help,
            language: language
        )
        return said
    }
}

/// What is yet to be told of sources asked to end a sign-in, one at a time — out of the chain
/// for `EndedSignInNotice`'s reason.
struct LeftSignInsNotice: ViewModifier {
    let mastodon: MastodonSessions

    func body(content: Content) -> some View {
        content.shellConfirm(told, question: { ShellQuestion.left($0) }) { _, _ in }
    }

    private var told: Binding<MastodonSessions.LeftTold?> {
        Binding(
            get: { mastodon.leftTold.first },
            set: { if $0 == nil { mastodon.leftToldSeen() } }
        )
    }
}
