import FediqoCore
import SwiftUI

// How one of #54's acts is drawn and said on a row: the glyph, the name a pointer reads, the
// sentence VoiceOver hears, and — where the act is not offered — the reason its mark is dim.
//
// **Here rather than inside `DummyItemRow`'s body**, which is this package's standing arrangement
// and the reason it is one: three controls in this milestone shipped wired to the wrong thing and
// stayed green, because what decided them sat in a `View` body no test could reach. What a mark
// draws, what it is called and what a listener is told are all functions of two facts — where the
// act has got to, and what the source last said — so they are written as functions of those two
// facts and asserted directly.

/// One row's share of #54's acts: what the post offers, where each offered act has got to, and
/// the presses themselves.
///
/// **A value the panes pass down rather than a property per act on the row.** #54 names four acts
/// and three panes draw rows; a property each would be twelve parameters to keep in step across
/// three call sites, and the first one forgotten is a mark that never appears with nothing to say
/// it should have.
///
/// The default is a row that does not act: a fixture, a preview, anything drawn with no session
/// behind it. It offers nothing, which is `PostActs.none`, and every mark on it is drawn dim.
struct ItemActing {
    var acts: PostActs = .none
    /// Where each offered act has got to, **on the copy it goes through** — `through`'s.
    var standings: [PostAct: ShellActStanding] = [:]
    /// The copy each offered act goes through, where the row stands for more than one (#136).
    /// Missing is the row itself, which is every row of one.
    ///
    /// **Carried so the mark reads the same copy the press goes to.** A merged row is drawn as
    /// its first copy, and a boost that goes through the second would otherwise show the first
    /// source's "not boosted" over a press that the second source has already said yes to.
    var through: [PostAct: DummyItem] = [:]
    /// The press on one act's mark, **one closure for the four** rather than one each: boosting
    /// the post to its source or taking the boost back (#106), the same for a favourite (#107),
    /// answering it (#108) — from a timeline by opening the conversation it belongs to, since
    /// that is where an answer is written, and from inside the conversation by opening the answer
    /// — and bookmarking it (#285). Taking back is asked first, and is `withdraw`'s.
    ///
    /// Nothing where the list cannot act — a fixture, a preview — and then every act's mark is
    /// drawn dim, as not right now.
    var perform: ((PostAct) -> Void)?
    /// The press on the keep mark (#284): keeps the row, or un-keeps it. **Beside `perform` and
    /// not one of its acts**, because it is none of #54's: nothing is sent to a source, so it is
    /// offered on a row whatever its source offers, signed in or not, and it has no standing to
    /// be on its way or to fail. Nothing where the list cannot act, and then its mark is dim.
    var keep: (() -> Void)?
    /// The press on a mark whose act the sign-in must be asked again for (#285) — bookmarking,
    /// on a sign-in made before it was asked for. It raises the question and sends nothing.
    /// Nothing where the list cannot act, and then the dim mark's press goes nowhere.
    var ask: ((PostAct) -> Void)?
    /// Taking the post back (#109), which is never a mark: the question it asks and what its yes
    /// does, for the one destructive item of the row's `…`. Nothing where the list cannot act,
    /// or the post does not offer it.
    var withdraw: Withdraw?

    /// The question taking a post back asks, and what a yes to it does. **The question is built
    /// when the item is chosen** — it names the copy that goes as things stand at the press.
    struct Withdraw {
        let asks: () -> ShellConfirmation
        let yes: () -> Void
    }
}

/// What one act's mark draws on one row — `ItemActs.mark`'s answer.
struct ItemMark: Equatable {
    /// The glyph, unfilled — what a `ShellMark` is made from, which fills it where the act is done.
    let glyph: String
    /// What the source the act goes through last said.
    let done: Bool
    let count: Int?
    /// The mark's name to a pointer and to VoiceOver.
    let spoken: String
}

/// The vocabulary of the acts a reader performs on a post.
enum ItemActs {
    /// The glyph of an act's mark, unfilled: the act's own, or where the act has got to.
    ///
    /// **The act's own glyph is replaced while the act is not settled, and that is the whole of
    /// "the mark shows the act is on its way".** A mark that kept its shape and changed only its
    /// colour would say nothing to a reader who cannot tell the two colours apart. On its way is
    /// `hourglass` and never `ellipsis`, which on this row is the menu and nothing else.
    ///
    /// **Whether the act is offered is not asked**: a mark the source does not offer is the same
    /// glyph in the dim ink (`look`), so there is no second glyph for "must be asked first".
    static func glyph(_ act: PostAct, standing: ShellActStanding?) -> String {
        switch standing {
        case .onItsWay: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case nil: break
        }
        switch act {
        case .boost: return "arrow.2.squarepath"
        case .favourite: return "star"
        // An answer is never "done" on the post: the reader may answer as often as they like, and
        // the words they wrote are rows of their own in the thread.
        case .answer: return "arrowshape.turn.up.left"
        // Never "done": a post taken back is not on the row to be drawn.
        case .withdraw: return "trash"
        case .bookmark: return "bookmark"
        }
    }

    /// What the mark is called — to a pointer, and as the first half of what VoiceOver is told.
    ///
    /// The name says what a press will do rather than what has happened, because that is what a
    /// control is for: a post already boosted offers to take it back.
    static func name(_ act: PostAct, done: Bool, language: DummyLanguage? = nil) -> String {
        switch act {
        case .boost: return L10n.t(done ? "item.act.unboost" : "item.act.boost", language: language)
        case .favourite:
            return L10n.t(done ? "item.act.unfavourite" : "item.act.favourite", language: language)
        case .answer: return L10n.t("item.act.answer", language: language)
        case .withdraw: return L10n.t("item.act.withdraw", language: language)
        case .bookmark:
            return L10n.t(done ? "item.act.unbookmark" : "item.act.bookmark", language: language)
        }
    }

    /// The whole of what a reader using VoiceOver is owed about one mark: what a press does, and
    /// where the last press got to.
    ///
    /// **One reader for the glyph and the listener**, which is #97's arrangement and for its
    /// reason: a mark and a sentence built from two derivations of one fact are two things that
    /// can be told different stories about one post.
    ///
    /// `host` is the source the act goes through, named where the row stands for more than one
    /// (#136) — so a reader who hears the row name two sources also hears which one a press
    /// reaches. Nothing on a row of one, whose source the row already names once.
    static func spoken(
        _ act: PostAct, done: Bool, standing: ShellActStanding?, through host: String? = nil,
        language: DummyLanguage? = nil
    ) -> String {
        var name = name(act, done: done, language: language)
        if let host {
            name = String(format: L10n.t("item.act.through", language: language), name, host)
        }
        switch standing {
        case .onItsWay: return name + " " + L10n.t("item.act.onItsWay", language: language)
        case .failed: return name + " " + L10n.t("item.act.failed", language: language)
        case nil: return name
        }
    }

    /// Everything one act's mark draws on one row: its glyph, whether it is done, the count
    /// beside it and the sentence a pointer and VoiceOver are given.
    ///
    /// `done` is what the source last said, never what was pressed: a boost the reader made in
    /// another app reads as done here the moment this device has fetched the post.
    ///
    /// **All of it is read off the copy the act goes through** (#136) — `acting.through`, or the
    /// row where there is none — so the row never shows one source's state and presses another's.
    /// One reader for the four, `spoken`'s reason: the glyph and the sentence told apart would be
    /// two stories about one mark.
    static func mark(
        _ act: PostAct, on item: DummyItem, acting: ItemActing, language: DummyLanguage? = nil
    ) -> ItemMark {
        let copy = acting.through[act] ?? item
        let standing = acting.standings[act]
        let (done, count): (Bool, Int?) = switch act {
        case .boost: (copy.boosted == true, copy.counts.reblogs)
        case .favourite: (copy.favourited == true, copy.counts.favourites)
        case .answer: (false, copy.counts.replies)
        // Never a mark (`line`); here because the switch names every act.
        case .withdraw: (false, nil)
        // What the source the act goes through last said (#285); a source counts no bookmarks.
        case .bookmark: (copy.bookmarked == true, nil)
        }
        let host = item.otherCopies.isEmpty ? nil : copy.source.host
        var said = spoken(act, done: done, standing: standing, through: host, language: language)
        // **On a reblog's row the mark says whose post it goes to** (#290): the row is headed by
        // who reblogged, and a press here reaches the post and never the reblog.
        if item.isReblog {
            said = String(format: L10n.t("item.act.onPost", language: language), said, copy.author)
        }
        return ItemMark(
            glyph: glyph(act, standing: standing),
            done: done,
            count: count,
            spoken: said
        )
    }

    /// The question taking a post back asks (#109): **what goes, by name, before anything goes.**
    ///
    /// The post's own opening words and the source it goes from, what goes with it on most
    /// sources — the answers other people wrote under it — and that it does not come back.
    static func withdrawQuestion(
        _ item: DummyItem, language: DummyLanguage? = nil
    ) -> (title: String, detail: String) {
        let words = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = words.count > 80 ? String(words.prefix(80)) + "…" : words
        return (
            L10n.t("withdraw.title", language: language),
            String(format: L10n.t("withdraw.detail", language: language), opening, item.source.host)
        )
    }

    /// Why a post offers none of #54's acts, as a sentence: what the head of the row's `…` says,
    /// and what each dim mark tells a pointer and VoiceOver after its reason.
    ///
    /// **Four reasons, four sentences, and nothing folded.** The reader is being told what to do
    /// about it, and "sign in again" and "this forum cannot be written to from here" are different
    /// instructions. **No `default:`**, so a fifth refusal has to be given words.
    static func refusalLine(_ refusal: PostActRefusal, language: DummyLanguage? = nil) -> String {
        switch refusal {
        case .protocolCannot: return L10n.t("item.act.no.protocol", language: language)
        case .notSignedIn: return L10n.t("item.act.no.signIn", language: language)
        case .turnedAway: return L10n.t("item.act.no.turnedAway", language: language)
        case .unnameable: return L10n.t("item.act.no.unnameable", language: language)
        }
    }

    /// Why the marks of a post that offers no act are dim. **No `default:`.**
    ///
    /// A forum's post and one this device cannot name have no such act at all. **Not signed in,
    /// and a source that turned a write away, are "not right now" and never "asked again"**:
    /// `askAgain` is the one reason whose press puts a question, and a post's row has no question
    /// that leads to signing in — that is asked on the source's own row. No mark says it must be
    /// asked again and then does nothing; these say what is true, with the sentence that says
    /// which after it, take the press and do nothing.
    static func reason(_ refusal: PostActRefusal) -> DimReason {
        switch refusal {
        case .protocolCannot: .never
        case .unnameable: .never
        case .turnedAway: .notNow
        case .notSignedIn: .notNow
        }
    }

    /// Why quoting is dim on every row, as a sentence of its own: this app writes no quote yet.
    /// It is what the quote says in place of "not right now", so it is said once.
    static func quoteLine(language: DummyLanguage? = nil) -> String {
        L10n.t("item.act.quote.no", language: language)
    }
}

/// One mark under a post (#306): which it is, the shared mark it is drawn as — glyph, name,
/// look, state and count — and the sentence a pointer and VoiceOver are given.
struct RowMark: Identifiable, Equatable {
    enum Kind: Hashable {
        /// One of #54's acts, done on the post — or dim, where the post does not offer it.
        case act(PostAct)
        /// Keeping the row on this device (#284).
        case keep
        /// Quoting, which this app does not write yet: always dim.
        case quote
        /// `…`: the row's menu. Never an act and never dim.
        case more
    }

    let kind: Kind
    let mark: ShellMark
    /// The mark's name, and for a dim one its reason and the sentence that says which — what a
    /// pointer and VoiceOver are given, and for quoting its line at the head of the menu.
    let label: String

    var id: Kind { kind }

    var isBookmark: Bool { kind == .act(.bookmark) }
}

extension ItemActs {
    /// The marks every post draws, in the order they are drawn. **Every post from every source
    /// draws these seven**: taking back is not among them — it is an item of `…` alone.
    static let line: [RowMark.Kind] = [
        .act(.answer), .act(.boost), .quote, .act(.favourite), .act(.bookmark), .keep, .more,
    ]

    /// How one act's mark is drawn on a post, and the sentence that says why where it is dim.
    ///
    /// Live where the post offers the act and the list has somewhere for the press to go.
    /// Otherwise dim, for the first of these that is true: the sign-in must be asked again for
    /// this act (#285); the post offers no act and says why (`reason`); the source offers its
    /// other acts and not this one; and — a post gone at its source, a source that has left, a
    /// list that cannot act — not right now.
    static func look(
        _ act: PostAct, acting: ItemActing, language: DummyLanguage? = nil
    ) -> (look: MarkLook, why: String?) {
        look(act, acting: acting, refused: refused(acting, language: language))
    }

    /// Why the post offers no act, where it offers none: the reason its marks are dim for, and
    /// the sentence that says which. Read once for the whole line of marks.
    private static func refused(
        _ acting: ItemActing, language: DummyLanguage?
    ) -> (reason: DimReason, line: String)? {
        acting.acts.refused.map { (reason($0), refusalLine($0, language: language)) }
    }

    private static func look(
        _ act: PostAct, acting: ItemActing, refused: (reason: DimReason, line: String)?
    ) -> (look: MarkLook, why: String?) {
        if acting.acts.asks(act) { return (.dim(.askAgain), nil) }
        if let refused { return (.dim(refused.reason), refused.line) }
        guard acting.acts.offers(act) else {
            return (.dim(acting.acts.offered.isEmpty ? .notNow : .never), nil)
        }
        return (acting.perform == nil ? .dim(.notNow) : .live, nil)
    }

    /// The marks under a post, in the order they are drawn — **the one list the row's line of
    /// marks and its menu are both made from** (#306), so neither can offer what the other
    /// does not.
    ///
    /// **The same seven on every post, whatever its source** (`line`). A mark the post does not
    /// offer is drawn dim in its own glyph (`look`), and says why to the pointer, to VoiceOver
    /// and in the head of `…`; nothing is left out and no sentence stands in for the marks.
    static func marks(on item: DummyItem, acting: ItemActing, language: DummyLanguage? = nil) -> [RowMark] {
        // **Read once a call, and a row is a call each time it is drawn**: why the post offers
        // nothing, the two shapes a sentence is joined in, and each reason's word as it is met.
        let refused = refused(acting, language: language)
        let said = L10n.t("mark.dim.said", language: language)
        let whyShape = L10n.t("item.mark.why", language: language)
        var words: [DimReason: String] = [:]
        func made(_ kind: RowMark.Kind, _ mark: ShellMark, why: String? = nil) -> RowMark {
            var spoken = mark.name
            if case .dim(let reason) = mark.look {
                let word = words[reason] ?? L10n.t(reason.key, language: language)
                words[reason] = word
                spoken = String(format: said, mark.name, word)
            }
            let label = why.map { String(format: whyShape, spoken, $0) }
            return RowMark(kind: kind, mark: mark, label: label ?? spoken)
        }
        return line.map { kind in
            switch kind {
            case .act(let act):
                let shown = mark(act, on: item, acting: acting, language: language)
                let (look, why) = look(act, acting: acting, refused: refused)
                let count = (shown.count ?? 0) > 0 ? shown.count : nil
                return made(kind, ShellMark(shown.glyph, shown.spoken, look: look, on: shown.done, count: count), why: why)
            case .quote:
                let mark = ShellMark("quote.bubble", L10n.t("item.act.quote", language: language), look: .dim(.notNow))
                let label = String(format: said, mark.name, quoteLine(language: language))
                return RowMark(kind: kind, mark: mark, label: label)
            case .keep:
                let name = L10n.t(DummyItemRow.keepName(item), language: language)
                let look: MarkLook = acting.keep == nil ? .dim(.notNow) : .live
                return made(kind, ShellMark("archivebox", name, look: look, on: item.kept))
            case .more:
                return made(kind, ShellMark(ShellMore.symbol, L10n.t("mark.more", language: language), look: .live))
            }
        }
    }

    /// A press on one of the row's marks, sent where its look says it goes (`ShellMark.pressed`):
    /// a live mark acts, the one that must be asked again puts its question, and any other dim
    /// mark takes the press and does nothing. `…` is a menu and has no press of its own.
    ///
    /// **Never filled on a press**: filled is what the source last said, and kept is what the
    /// store holds, so nothing looks done that is not. Each act goes to the post the row shows,
    /// and on a reblog's row keeping alone is the reblog's (#290).
    static func press(_ mark: RowMark, acting: ItemActing) {
        switch mark.kind {
        case .act(let act):
            ShellMark.pressed(mark.mark.look, act: { acting.perform?(act) }, ask: asks(mark, acting: acting))
        case .keep:
            ShellMark.pressed(mark.mark.look, act: { acting.keep?() }, ask: nil)
        case .quote, .more:
            break
        }
    }

    /// What the row's `…` holds, and what a long press on the row offers — **one value for the
    /// two** (#306), so they cannot differ.
    ///
    /// The head is what the post is (`head`, ending with why it offers no act where it offers
    /// none), then each dim mark named under its reason (`ShellMore.reasons`), the only place a
    /// finger reads it — quoting under its own sentence. **Each reason is said once**: the six
    /// marks follow by name alone, the dim ones disabled, since the head has said why. Then the
    /// way out to the post's own page where there is one (`leave`); and, under the divider,
    /// taking the post back — **offered here and nowhere else, only on the reader's own post**,
    /// and only as `danger`, so the menu puts its question and nothing goes before a yes.
    static func more(
        on item: DummyItem, acting: ItemActing, here: Set<String>?, leave: (() -> Void)? = nil,
        language: DummyLanguage? = nil
    ) -> ShellMore {
        let marks = marks(on: item, acting: acting, language: language).filter { $0.kind != .more }
        var items = marks.map { mark in
            ShellMoreItem.plain(mark.mark, ask: asks(mark, acting: acting), act: { press(mark, acting: acting) }).underHead
        }
        if let leave {
            items.append(.plain("arrow.up.forward.app", item.outwardName, act: leave))
        }
        if acting.acts.offers(.withdraw), let withdraw = acting.withdraw {
            let standing = acting.standings[.withdraw]
            // **On its way it is dim and still the trash**: grey and not grey are one glyph, so
            // the hourglass an act's mark wears while it is out is not worn here.
            let onItsWay = standing == .onItsWay
            items.append(.danger(
                glyph(.withdraw, standing: onItsWay ? nil : standing),
                spoken(.withdraw, done: false, standing: standing, language: language),
                look: onItsWay ? .dim(.notNow) : .live,
                asks: withdraw.asks(), act: withdraw.yes
            ))
        }
        var shared: [ShellMark] = []
        var quoted: [String] = []
        for mark in marks {
            if mark.kind == .quote { quoted.append(mark.label) } else { shared.append(mark.mark) }
        }
        let head = head(for: item, here: here, refused: acting.acts.refused, language: language)
            + ShellMore.reasons(of: shared, language: language) + quoted
        return ShellMore(head: head, items: items)
    }

    /// The question a dim mark puts, on the row and in the menu alike, where there is one to
    /// put: only the act the sign-in must be asked again for (#285), and only in a list that can
    /// ask.
    private static func asks(_ mark: RowMark, acting: ItemActing) -> (() -> Void)? {
        guard case .act(let act) = mark.kind, acting.acts.asks(act), let ask = acting.ask else { return nil }
        return { ask(act) }
    }

    /// The gap a mark asks for before it: the marks that keep a post stand a little apart from
    /// the ones that pass it on, and the bookmark — on every row now — opens the group.
    static func gap(before mark: RowMark) -> CGFloat? {
        mark.isBookmark ? ShellSpace.room : nil
    }

    /// How many heads have been built: a count a test reads, to hold that a row drawn and
    /// never pressed builds none.
    #if DEBUG
    nonisolated(unsafe) static var headsBuilt = 0
    #endif

    /// What heads the row's menu (#306): what a pointer resting on the row's parts is told, for
    /// a reader with no pointer to rest — **in the words those parts already say**. Who
    /// reblogged it and when; exactly when it was published; who may read it; that it was
    /// changed, is gone at its source, or that its source has left; and the source.
    ///
    /// **Who wrote it first, by name and whole handle** — a narrow row draws the handle only
    /// where it has room (#302), and this is where a finger finds it. **And last, why no act is
    /// offered where none is** (`refused`): the sentence the row used to say under its marks,
    /// which the dim marks now say instead.
    static func head(
        for item: DummyItem, here: Set<String>?, refused: PostActRefusal? = nil, language: DummyLanguage? = nil
    ) -> [String] {
        #if DEBUG
        headsBuilt += 1
        #endif
        var lines: [String] = [DummyItemRow.spokenNames(item)]
        if let reblog = DummyItemRow.spokenReblog(item, language: language) {
            lines.append(reblog)
        } else if let arrived = DummyItemRow.reblogLine(item, language: language) {
            lines.append(arrived)
        }
        lines.append(DummyItemRow.exact(DummyItemRow.headerTime(item)))
        if let audience = item.audience { lines.append(DummyItemRow.spokenAudience(audience)) }
        if let editedAt = item.editedAt {
            lines.append(DummyItemRow.changedDetail(editedAt, earlier: item.earlier.count, language: language))
        }
        if item.postGone { lines.append(L10n.t("item.gone.detail", language: language)) }
        if DummyItemRow.sourceLeft(item, here: here) { lines.append(L10n.t("item.left.detail", language: language)) }
        lines.append(DummyItemRow.spokenSource(item, language: language))
        if let refused { lines.append(refusalLine(refused, language: language)) }
        return lines
    }
}
