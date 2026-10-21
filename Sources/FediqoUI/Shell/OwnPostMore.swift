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
    /// The own post's items of `…`, and what the menu's head says of them: a lock's words where
    /// the sign-in lacks what one needs — the report item's shape.
    static func ownItems(
        on item: DummyItem, acting: ItemActing, language: DummyLanguage? = nil
    ) -> (items: [ShellMoreItem], head: [String]) {
        var items: [ShellMoreItem] = []
        var head: [String] = []
        if let change = acting.change {
            let name = L10n.t("item.act.change", language: language)
            if let lock = change.lock {
                head.append(lock.line(language: language) ?? String(format: L10n.t(lock.place.key, language: language), lock.host))
                let dim = ShellMark(SourceRow.permissionSymbol, name, look: .dim(.askAgain))
                items.append(ShellMoreItem.plain(dim, ask: lock.place.asks ? change.press : nil, act: {}).underHead)
            } else {
                items.append(.plain("pencil", name, act: change.press))
            }
        }
        if let quotes = acting.ownQuotes {
            let own = quoteItems(quotes, language: language)
            items += own.items
            head += own.head
        }
        return (items, head)
    }

    /// Who may quote the post — three ticked lines, the one it is set to ticked, shown at once
    /// and sent after (X0 §3) — and its quotes, where any are. A post only followers or those it
    /// names may read is fixed at nobody (asked of 4.6.6), its other two dim with why.
    static func quoteItems(
        _ quotes: ItemActing.OwnQuotes, language: DummyLanguage? = nil
    ) -> (items: [ShellMoreItem], head: [String]) {
        var head = [L10n.t("item.act.quotePolicy.line", language: language)]
        if quotes.fixed { head.append(L10n.t("compose.quotePolicy.private", language: language)) }
        if let lock = quotes.lock {
            head.append(lock.line(language: language) ?? String(format: L10n.t(lock.place.key, language: language), lock.host))
        }
        var items: [ShellMoreItem] = QuotePolicy.allCases.map { policy in
            let name = String(
                format: L10n.t("item.act.quotePolicy", language: language), QuoteWords.policy(policy, language: language)
            )
            let chosen = quotes.policy == policy
            let look: MarkLook = quotes.lock != nil ? .dim(.askAgain) : (quotes.fixed && policy != .nobody ? .dim(.never) : .live)
            let mark = ShellMark(chosen ? "checkmark.circle" : "circle", name, look: look, on: chosen)
            let ask: (() -> Void)? = quotes.lock?.place.asks == true ? { quotes.choose(policy) } : nil
            return ShellMoreItem.plain(mark, ask: ask) { if !chosen { quotes.choose(policy) } }
        }
        if let count = quotes.count, let open = quotes.openQuotes {
            items.append(.plain("quote.bubble", String(format: L10n.t("item.act.quotes", language: language), count), act: open))
        }
        return (items, head)
    }
}
