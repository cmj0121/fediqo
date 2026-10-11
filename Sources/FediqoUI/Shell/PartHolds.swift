import FediqoCore
import Foundation

/// What a sign-in holds, said part by part (#347) — on its source's row and on the source's
/// own page. **A part stands by itself**: a sign-in that only reads may hold a part that acts,
/// so "reads" or "reads and writes" cannot say what a sign-in is, and the parts are named.
///
/// **One reading, over the table** (`MastodonParts.holdings`): a part added there is named
/// here by its `part.<name>.name`, with no edit to this file.
///
/// **Only what is held.** What was refused, never asked, or is not there is said where its act
/// would be — the place's own line (`PartWords.place`) — and not a second time here.
extension PartWords {
    /// One sentence naming everything `scopes` holds — and a second for the held words this
    /// build asks for on no page, the source's own word for every read or every write among
    /// them, in the source's spelling as far as it can be seen (`shown`). Nothing where
    /// nothing is written down: such a sign-in's row already says it must be asked again.
    ///
    /// **`whole` is the source's own page, where every such word is said** — up to
    /// `wordsWhole`, each cut short. A row has room for the first few and says how many
    /// more there are.
    static func holds(_ scopes: String?, whole: Bool = false, language: DummyLanguage? = nil) -> String? {
        let holdings = MastodonParts.holdings(in: scopes)
        let names = holdings.entries.map { name($0, in: scopes, language: language) }
        var sentences: [String] = []
        if !names.isEmpty {
            let listed = names.joined(separator: L10n.t("mark.dim.names", language: language))
            sentences.append(String(format: L10n.t("part.held.line", language: language), listed))
        }
        if !holdings.other.isEmpty {
            let words = shown(holdings.other, most: whole ? wordsWhole : wordsShown, language: language)
            if !words.isEmpty {
                sentences.append(String(format: L10n.t("part.held.other", language: language), words))
            }
        }
        guard let first = sentences.first else { return nil }
        return sentences.dropFirst().reduce(first) {
            String(format: L10n.t("question.join", language: language), $0, $1)
        }
    }

    /// What one thing held among `scopes` is called: the part's name, the name of the act it
    /// gains beside acting, or — held in part — the half of it held, by that half's name
    /// (`halfKey`), and where the part has no such halves, that it is part of it, in the
    /// words of `partly`.
    private static func name(
        _ entry: MastodonHoldings.Entry, in scopes: String?, partly: String = "part.held.partly",
        language: DummyLanguage?
    ) -> String {
        switch entry {
        case .whole(let part): L10n.t(nameKey(part), language: language)
        case .beside(let part): L10n.t(nameKey(part) + ".beside", language: language)
        case .partly(let part):
            String(
                format: L10n.t(MastodonParts.half(of: part, in: scopes).map(halfKey) ?? partly, language: language),
                L10n.t(nameKey(part), language: language)
            )
        }
    }

    /// The key of what a half of a part is called, with the part's name for its argument:
    /// "seeing who you follow", "changing who you follow".
    static func halfKey(_ half: MastodonHalf) -> String {
        switch half {
        case .seeing: "account.signin.ask.seeing"
        case .changing: "account.signin.ask.givesUp.changing"
        }
    }

    /// The parts `words` are words of, by name and as one list — a part only some of whose
    /// words are among them by the half they are, or in the words of `partly` (`name`).
    /// Nothing where none is a word of a part: a word the table does not know is not named
    /// here.
    static func listed(_ words: [String], partly: String, language: DummyLanguage? = nil) -> String? {
        let scopes = words.joined(separator: " ")
        let entries = MastodonParts.holdings(in: scopes).entries
        guard !entries.isEmpty else { return nil }
        return entries.map { name($0, in: scopes, partly: partly, language: language) }
            .joined(separator: L10n.t("mark.dim.names", language: language))
    }

    /// The key of a part's name: the words its own question already asks for it in.
    static func nameKey(_ part: MastodonPart) -> String {
        "part.\(part.rawValue).name"
    }
}

extension MastodonSessions {
    /// What the sign-in at `host` holds, as its row and — `whole` — its page say it, or
    /// nothing where no sign-in is held there, or nothing is written down of the one that is.
    ///
    /// **Read off what rides beside the sign-in, never off a token**: this is drawn, and
    /// nothing is decided by it. It is the read every place draws a part's standing from
    /// (`heldParts`), taken again whenever who is signed in is, so a sign-in replaced, signed
    /// out of or removed is not said as the one before.
    func holds(host raw: String, whole: Bool = false, language: DummyLanguage? = nil) -> String? {
        heldParts[raw.lowercased()].flatMap { PartWords.holds($0.scopes, whole: whole, language: language) }
    }
}
