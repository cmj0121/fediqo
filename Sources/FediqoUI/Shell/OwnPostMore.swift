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
        guard let change = acting.change else { return ([], []) }
        let name = L10n.t("item.act.change", language: language)
        guard let lock = change.lock else {
            return ([.plain("pencil", name, act: change.press)], [])
        }
        let line = lock.line(language: language) ?? String(format: L10n.t(lock.place.key, language: language), lock.host)
        let dim = ShellMark(SourceRow.permissionSymbol, name, look: .dim(.askAgain))
        return ([ShellMoreItem.plain(dim, ask: lock.place.asks ? change.press : nil, act: {}).underHead], [line])
    }
}
