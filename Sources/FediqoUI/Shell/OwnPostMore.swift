import FediqoCore
import SwiftUI

// The own post's group of the row's `…` (X0 §4): what the reader may do to a post they wrote,
// in the order fixed for both lanes — Change it… (#332), then who may quote it and its quotes
// (#330), then pinning and quieting (#334). Each lane's items live in its own file; `more()`
// calls this once.

extension ItemActing {
    /// Changing the post (#332): the sheet's press, or — where the sign-in lacks the writing
    /// part — dim with that lock, its press asking for it. Nothing where the post is not the
    /// reader's own at a source whose posts change, or is gone or leaving.
    struct Change {
        var lock: Lock?
        let press: () -> Void
    }
}

extension ItemActs {
    /// The own post's items of `…`: a dim one says its lock's words after its name where the
    /// sign-in lacks what it needs — the report item's shape.
    static func ownItems(
        on item: DummyItem, acting: ItemActing, language: DummyLanguage? = nil
    ) -> [ShellMoreItem] {
        var items: [ShellMoreItem] = []
        if let change = acting.change {
            let name = L10n.t("item.act.change", language: language)
            if let lock = change.lock {
                items.append(.locked(name: name, lock: lock, language: language, press: change.press))
            } else {
                items.append(.plain("pencil", name, act: change.press))
            }
        }
        if let quotes = acting.ownQuotes {
            items += quoteItems(quotes, language: language)
        }
        return items
    }

    /// Who may quote the post — three ticked lines, the one it is set to ticked, shown at once
    /// and sent after (X0 §3) — and its quotes, where any are. A post only followers or those it
    /// names may read is fixed at nobody (asked of 4.6.6), its other two dim with why.
    static func quoteItems(
        _ quotes: ItemActing.OwnQuotes, language: DummyLanguage? = nil
    ) -> [ShellMoreItem] {
        var items: [ShellMoreItem] = QuotePolicy.allCases.map { policy in
            let name = String(
                format: L10n.t("item.act.quotePolicy", language: language), QuoteWords.policy(policy, language: language)
            )
            let chosen = quotes.policy == policy
            let look: MarkLook = quotes.lock != nil ? .dim(.askAgain) : (quotes.fixed && policy != .nobody ? .dim(.never) : .live)
            let mark = ShellMark(chosen ? "checkmark.circle" : "circle", name, look: look, on: chosen)
            let ask: (() -> Void)? = quotes.lock?.place.asks == true ? { quotes.choose(policy) } : nil
            let why = quotes.lock.map { $0.headLine(language: language) }
                ?? (quotes.fixed ? L10n.t("compose.quotePolicy.private", language: language) : nil)
            return ShellMoreItem.plain(mark, ask: ask) { if !chosen { quotes.choose(policy) } }
                .because(why)
                .hinted(L10n.t("item.act.quotePolicy.line", language: language))
        }
        if let count = quotes.count, let open = quotes.openQuotes {
            items.append(.plain("quote.opening", String(format: L10n.t("item.act.quotes", language: language), count), act: open))
        }
        return items
    }
}
