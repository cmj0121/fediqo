import FediqoCore
import SwiftUI

// The `…` items of #334, in the order X0 §4 fixes for both lanes: Translate, Boosted by,
// Favourited by after Open at its source; Pin to your page and Quiet this conversation after
// the own post's items, before Report. Each is drawn from `ItemActing.PostMore` alone, so the
// menu and a hold on the row read one value.

extension ShellMoreItem {
    /// An item whose act the sign-in lacks the part for: dim with the lock's glyph, saying the
    /// lock's line after its name, its press only asking — where asking is what changes it.
    static func locked(
        name: String, lock: ItemActing.Lock, language: DummyLanguage? = nil, press: @escaping () -> Void
    ) -> ShellMoreItem {
        let dim = ShellMark(SourceRow.permissionSymbol, name, look: .dim(.askAgain))
        return ShellMoreItem.plain(dim, ask: lock.place.asks ? press : nil, act: {}).because(lock.headLine(language: language))
    }
}

extension ItemActs {
    /// Which of the two places in the menu the items go to.
    enum PostGroup {
        /// After the way out to the post's own page: what anybody may read of it.
        case reading
        /// Among the own post's items: what changes how the post stands for the reader.
        case own
    }

    /// The glyph each item is drawn with.
    static let translateSymbol = "character.bubble"
    static let boostedBySymbol = "person.2.circle"
    static let favouritedBySymbol = "star.circle"
    static let pinSymbol = "pin"
    static let quietSymbol = "bell.slash"

    /// The items of `post` for `group`, in their fixed order — nothing where there is no `post`.
    static func postItems(_ post: ItemActing.PostMore?, group: PostGroup, language: DummyLanguage? = nil) -> [ShellMoreItem] {
        guard let post else { return [] }
        switch group {
        case .reading:
            var items: [ShellMoreItem] = []
            if let translate = post.translate {
                let asking = post.translation == .asking
                let name = L10n.t(post.translated ? "item.act.translate.original" : "item.act.translate", language: language)
                let mark = ShellMark(translateSymbol, name, look: asking ? .dim(.notNow) : .live, on: post.translated)
                items.append(.plain(mark, act: translate.press))
            } else if let host = post.translateSignedOut {
                // Dim: nobody is signed in there, said in its own words.
                let mark = ShellMark(translateSymbol, L10n.t("item.act.translate", language: language), look: .dim(.notNow))
                let why = String(format: L10n.t("item.act.translate.signIn", language: language), host)
                items.append(ShellMoreItem.plain(mark, act: {}).because(why))
            }
            if let boosted = post.boostedBy {
                items.append(.plain(boostedBySymbol, L10n.t("item.act.boostedBy", language: language), act: boosted.press))
            }
            if let favourited = post.favouritedBy {
                items.append(.plain(favouritedBySymbol, L10n.t("item.act.favouritedBy", language: language), act: favourited.press))
            }
            return items
        case .own:
            return [post.pin.map { turnItem($0, symbol: pinSymbol, names: ("item.act.pin", "item.act.unpin"), language: language) },
                    post.quiet.map { turnItem($0, symbol: quietSymbol, names: ("item.act.quiet", "item.act.unquiet"), language: language) }]
                .compactMap { $0 }
        }
    }

    /// A pin or a quiet as an item: named for what a press does, filled where it is on, dim while
    /// on its way — and, where the sign-in lacks the part, dim with the lock's glyph, its press
    /// only asking (as Report's is).
    private static func turnItem(
        _ turn: ItemActing.PostMore.Turn, symbol: String, names: (on: String, off: String), language: DummyLanguage?
    ) -> ShellMoreItem {
        let name = L10n.t(turn.on ? names.off : names.on, language: language)
        if let lock = turn.lock { return .locked(name: name, lock: lock, language: language, press: turn.press) }
        let mark = ShellMark(symbol, name, look: turn.out ? .dim(.notNow) : .live, on: turn.on)
        return .plain(mark, act: turn.press)
    }

}

/// The translation of a post, beside its words (#334): the words in the reader's language, the
/// cover line where there is one, and who made it from which language — never in place of the
/// original, which stands above it as the author wrote it. **In the pane only**, as a poll is:
/// a list row keeps its one height (#245), and Translate there opens the post.
struct TranslationBand: View {
    let translation: ShellPostActs.Translation
    let host: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            switch translation {
            case .asking:
                line(String(format: L10n.t("translation.asking"), host))
            case .failed(let why):
                line(why)
            case .shown(let said):
                line(Self.whoMadeIt(said, host: host))
                    .accessibilityAddTraits(.isHeader)
                if let spoiler = said.spoiler {
                    Text(spoiler)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(said.body)
                    .shellFont(.body)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func line(_ words: String) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Who made the translation, and from which language: the source's own words for both,
    /// each made fit for a line of ours.
    static func whoMadeIt(_ said: PostTranslation, host: String, language: DummyLanguage? = nil) -> String {
        let from = said.from.flatMap { L10n.locale(language).localizedString(forLanguageCode: $0) }
        let by = said.provider ?? host
        return from.map { String(format: L10n.t("translation.by.from", language: language), $0, by) }
            ?? String(format: L10n.t("translation.by", language: language), by)
    }
}
