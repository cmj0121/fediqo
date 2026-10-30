import FediqoCore
import Foundation

/// What quoting says (#330, X0 §3 and §6), as functions of what is known, so a test reads what is
/// drawn.
@MainActor
enum QuoteWords {
    /// A policy as the composer's menu and the post's `…` name it.
    nonisolated static func policy(_ policy: QuotePolicy, language: DummyLanguage? = nil) -> String {
        switch policy {
        case .anyone: L10n.t("compose.quotePolicy.public", language: language)
        case .followers: L10n.t("compose.quotePolicy.followers", language: language)
        case .nobody: L10n.t("compose.quotePolicy.nobody", language: language)
        }
    }

    /// What the menu says where nothing was chosen: the account's own setting, and nothing sent.
    /// `set` is that setting where the source said it, for a new post (#437).
    static func unsaid(host: String, set: QuotePolicy? = nil, language: DummyLanguage? = nil) -> String {
        guard let set else { return String(format: L10n.t("compose.quotePolicy.unsaid", language: language), host) }
        return String(format: L10n.t("compose.quotePolicy.unsaid.set", language: language), host, policy(set, language: language))
    }

    /// The question before a quote drops what the draft carries (D3).
    static func dropQuestion(_ ask: ShellQuoting.Ask, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "quote.opening",
            title: L10n.t("compose.quote.drop.title", language: language),
            line: L10n.t("compose.quote.drop.line", language: language),
            help: nil,
            choices: [
                .init("drop", L10n.t("compose.quote.drop.confirm", language: language), role: .primary),
            ],
            cancel: L10n.t("compose.quote.drop.keep", language: language)
        )
    }

    /// The question before a quote of one's own post is taken back.
    static func revokeQuestion(_ quoting: Note, language: DummyLanguage? = nil) -> ShellConfirmation {
        let whom = LineText.oneLine(quoting.handle)
        return ShellConfirmation(
            symbol: "hand.raised.slash",
            title: String(format: L10n.t("quotes.revoke.title", language: language), whom),
            line: String(format: L10n.t("quotes.revoke.line", language: language), quoting.source.host),
            help: nil,
            choices: [.init("revoke", L10n.t("quotes.revoke", language: language), role: .destructive)],
            cancel: L10n.t("compose.cancel", language: language)
        )
    }

    /// Whether a quote of one's own post was taken back.
    static func revoked(_ quoting: Note) -> Bool {
        quoting.quote?.state == .revoked
    }

    /// One quote of one's own post as VoiceOver reads it (X0 §5).
    static func spoken(_ quoting: Note, language: DummyLanguage? = nil) -> String {
        [
            quoting.author, quoting.handle, DummyItemRow.exact(quoting.postedAt), OutboxWords.opening(quoting.body),
            revoked(quoting) ? L10n.t("quotes.revoked", language: language) : nil,
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
