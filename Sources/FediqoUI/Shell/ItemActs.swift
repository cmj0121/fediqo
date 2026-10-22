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
    /// wait on a source or to fail. Nothing where the list cannot act, and then its mark is dim.
    var keep: (() -> Void)?
    /// The press on a mark whose act the sign-in must be asked again for (#285) — bookmarking,
    /// on a sign-in made before it was asked for. It raises the question and sends nothing.
    /// Nothing where the list cannot act, and then the dim mark's press goes nowhere.
    var ask: ((PostAct) -> Void)?
    /// What an act's mark says where the sign-in does not hold its part (#347): how the
    /// sign-in stands to it, as every place draws a standing (`PartWords.place`). Missing for
    /// an act that is offered, and for one whose part is not what keeps it from being.
    var locks: [PostAct: Lock] = [:]

    /// One act's lock: the standing's place, and the source whose sign-in it is about.
    struct Lock: Equatable {
        let place: PartWords.Place
        let host: String

        /// The place's line. Nothing where it was never asked: the dim mark's own reason
        /// says that, and says it once.
        func line(language: DummyLanguage? = nil) -> String? {
            place.kind == .unasked ? nil : String(format: L10n.t(place.key, language: language), host)
        }

        /// What a menu keeps of the lock for the press that says why its item is dim: its line,
        /// or the place's own words where it was never asked.
        func headLine(language: DummyLanguage? = nil) -> String {
            line(language: language) ?? String(format: L10n.t(place.key, language: language), host)
        }
    }
    /// Taking the post back (#109), which is never a mark: the question it asks and what its yes
    /// does, for a destructive item of the row's `…`. Nothing where the list cannot act,
    /// or the post does not offer it.
    var withdraw: Withdraw?
    /// A vote in the post's poll for the choices given, each by its place (#331). Nothing
    /// where the list cannot act or the post offers no vote: its poll is then read, and not
    /// voted in.
    var vote: (([Int]) -> Void)?
    /// The post's poll as the copy a vote goes through holds it (`ShellSession.poll(on:)`): what
    /// the poll is drawn from, so a merged row draws the poll its vote is checked against.
    /// Nothing where the list cannot act, and the row draws its own.
    var poll: Poll?
    /// The copy that poll is the post's on: the one a vote goes through, or the first an act
    /// would reach. Nothing on a row no copy of which carries a poll.
    var pollCopy: DummyItem?
    /// What the vote out on the post chose, while one is out: drawn as the reader's own.
    var chosen: [Int]?
    /// The post's poll read again: how it stands now. Nothing where the list cannot read.
    var readPoll: (() -> Void)?
    /// What the poll's place says where its sign-in does not hold what a vote needs (#331) —
    /// the acting part's standing, as every place draws one — and the press that asks for it.
    /// Nothing where a vote is offered, or no sign-in is held to ask.
    var voteLock: Lock?
    var askToVote: (() -> Void)?
    /// Reporting the post (#339): the item of the row's `…` that puts the report's sheet up, or —
    /// where the sign-in lacks what reporting needs — dim with that lock, its press asking.
    /// Nothing where the post is not one to report: no sign-in at its source, a kind of source
    /// with no reports, the reader's own, or one gone.
    var report: Report?
    /// Pinning, quieting, translating, and who boosted and favourited it (#334): items of the
    /// row's `…` (`ItemActs.postItems`), and the translation drawn beside its words. Nothing
    /// where its source has none of them, or the list cannot act.
    var post: PostMore?
    /// Changing the post (#332), an item of the own post's group (`ItemActs.ownItems`).
    var change: Change?
    /// The quote mark (#330): live, or dim with its one reason. Nothing where quoting is none of
    /// the post's source's, and the mark is dim as it always was.
    var quote: QuoteMark?
    /// Who may quote the reader's own post, and its quotes (#330): the own post's group.
    var ownQuotes: OwnQuotes?
    /// The preview of the page the post links to, where the row draws one (#335): previews on,
    /// a card, no media of its own — and its picture only where the gate lets it through. Nothing
    /// where the list cannot read, which draws no preview and asks nothing.
    var preview: LinkPreview?

    struct Report {
        var lock: Lock?
        let press: () -> Void
    }

    /// Why the row is drawn as hidden, where it is (#314): the person muted or blocked whoever
    /// made it, or their whole server, and chose that what this device held of them is hidden.
    /// Nothing for a row drawn as it is.
    var hidden: HiddenHere?

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
    /// **The glyph is replaced only where the act did not arrive.** A press still out is drawn
    /// as the act's own glyph, done or not as it was pressed (`mark`); a failure changes the
    /// shape, because a mark that changed only its colour would say nothing to a reader who
    /// cannot tell the two colours apart — and never to `ellipsis`, which on this row is the
    /// menu and nothing else.
    ///
    /// **Whether the act is offered is not asked**: a mark the source does not offer is the same
    /// glyph in the dim ink (`look`), so there is no second glyph for "must be asked first".
    static func glyph(_ act: PostAct, standing: ShellActStanding?) -> String {
        if standing == .failed { return "exclamationmark.triangle" }
        switch act {
        case .boost: return "arrow.2.squarepath"
        case .favourite: return "star"
        // An answer is never "done" on the post: the reader may answer as often as they like, and
        // the words they wrote are rows of their own in the thread.
        case .answer: return "arrowshape.turn.up.left"
        // Never "done": a post taken back is not on the row to be drawn.
        case .withdraw: return "trash"
        case .bookmark: return "bookmark"
        // Pressed from the poll and never a mark of the row's line (#331).
        case .vote: return "checklist"
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
        // A vote is not taken back: once done, there is nothing a press would do.
        case .vote: return L10n.t(done ? "item.act.voted" : "item.act.vote", language: language)
        }
    }

    /// The whole of what a reader using VoiceOver is owed about one mark: what a press does, and
    /// where the last press got to. A press still out adds nothing: the name already says what
    /// the next press does, which is what the mark is drawn as.
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
        case .failed: return name + " " + L10n.t("item.act.failed", language: language)
        case .pressed, nil: return name
        }
    }

    /// Everything one act's mark draws on one row: its glyph, whether it is done, the count
    /// beside it and the sentence a pointer and VoiceOver are given.
    ///
    /// `done` is what was pressed while the press is out, and what the source last said
    /// otherwise: a boost the reader made in another app reads as done here the moment this
    /// device has fetched the post. A press that moves the mark moves its count by one with it.
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
        var (done, count): (Bool, Int?) = switch act {
        case .boost: (copy.boosted == true, copy.counts.reblogs)
        case .favourite: (copy.favourited == true, copy.counts.favourites)
        case .answer: (false, copy.counts.replies)
        // Never a mark (`line`); here because the switch names every act.
        case .withdraw: (false, nil)
        // What the source the act goes through last said (#285); a source counts no bookmarks.
        case .bookmark: (copy.bookmarked == true, nil)
        // Whether the reader voted, and how many votes the poll has, where it says (#331).
        case .vote: (copy.poll?.voted == true, copy.poll?.votes)
        }
        if case .pressed(let to) = standing, act != .answer, act != .withdraw, act != .vote, to != done {
            count = count.map { max(0, $0 + (to ? 1 : -1)) }
            done = to
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

    /// Why a post offers none of #54's acts, as a sentence: what each dim mark tells a pointer and
    /// VoiceOver after its reason.
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
    /// pointer and VoiceOver are given.
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
        look(act, acting: acting, refused: refused(acting, language: language), language: language)
    }

    /// Why the post offers no act, where it offers none: the reason its marks are dim for, and
    /// the sentence that says which. Read once for the whole line of marks.
    private static func refused(
        _ acting: ItemActing, language: DummyLanguage?
    ) -> (reason: DimReason, line: String)? {
        acting.acts.refused.map { (reason($0), refusalLine($0, language: language)) }
    }

    /// **A mark whose part the sign-in does not hold is dim whatever its standing** — the
    /// mark does not change — **and the standing decides what it says and what a press
    /// does** (`ItemActing.locks`): never asked or refused on the source's page, the press
    /// asks; while the source is being asked, and where it has none, there is no press.
    private static func look(
        _ act: PostAct, acting: ItemActing, refused: (reason: DimReason, line: String)?, language: DummyLanguage?
    ) -> (look: MarkLook, why: String?) {
        if let lock = acting.locks[act] {
            let line = lock.line(language: language)
            switch lock.place.kind {
            case .unasked, .refused, .partly: return (.dim(.askAgain), line)
            case .asking: return (.dim(.notNow), line)
            case .none: return (.dim(.never), line)
            }
        }
        if acting.acts.asks(act) { return (.dim(.askAgain), nil) }
        if let refused { return (.dim(refused.reason), refused.line) }
        guard acting.acts.offers(act) else {
            return (.dim(acting.acts.offered.isEmpty ? .notNow : .never), nil)
        }
        return (acting.perform == nil ? .dim(.notNow) : .live, nil)
    }

    /// The marks under a post, in the order they are drawn. **The row's menu repeats none of
    /// them** (#385, `more`).
    ///
    /// **The same seven on every post, whatever its source** (`line`). A mark the post does not
    /// offer is drawn dim in its own glyph (`look`), and says why to the pointer and to VoiceOver;
    /// nothing is left out and no sentence stands in for the marks.
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
                let (look, why) = look(act, acting: acting, refused: refused, language: language)
                let count = (shown.count ?? 0) > 0 ? shown.count : nil
                return made(kind, ShellMark(shown.glyph, shown.spoken, look: look, on: shown.done, count: count), why: why)
            case .quote:
                if let quote = acting.quote {
                    let mark = ShellMark("quote.bubble", L10n.t("item.act.quote", language: language), look: quote.look)
                    return made(kind, mark, why: quote.why)
                }
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
    /// mark takes the press and does nothing — **and says why, beside it** (#385): whether the
    /// row is to show the mark's label is what this returns. `…` has a press of its own.
    ///
    /// **Filled at the press, over a store that has not moved** (`mark`): what the source last
    /// said is what is held, and a press it does not take is put back and said. Kept is what
    /// the store holds. Each act goes to the post the row shows,
    /// and on a reblog's row keeping alone is the reblog's (#290).
    @discardableResult
    static func press(_ mark: RowMark, acting: ItemActing) -> Bool {
        switch mark.kind {
        case .act(let act):
            return ShellMark.pressed(mark.mark.look, act: { acting.perform?(act) }, ask: asks(mark, acting: acting))
        case .keep:
            return ShellMark.pressed(mark.mark.look, act: { acting.keep?() }, ask: nil)
        case .quote:
            guard let quote = acting.quote else { return ShellMark.press(mark.mark.look) != .acts }
            return ShellMark.pressed(mark.mark.look, act: { quote.press?() }, ask: quote.look == .dim(.askAgain) ? quote.press : nil)
        case .more:
            return false
        }
    }

    /// What the row's `…` holds, and what a long press on the row offers — **one value for the
    /// two** (#306), so they cannot differ.
    ///
    /// **Only what the row's line of marks does not offer** (#385): answering, boosting, quoting,
    /// favouriting, bookmarking and keeping are the row's own marks, and a menu that repeated them
    /// would be the line again. **And no line about the post**: who wrote it, when, who may read it
    /// and where it came from are the row's to say. What is left: the way out to the post's own
    /// page where there is one (`leave`), what anybody may read of it, the own post's items, and —
    /// under the divider, red — reporting it, on the report's own sheet, and taking it back,
    /// **offered here and nowhere else, only on the reader's own post**, and only as `danger`, so
    /// the menu puts its question and nothing goes before a yes.
    static func more(
        on item: DummyItem, acting: ItemActing, leave: (() -> Void)? = nil, language: DummyLanguage? = nil
    ) -> ShellMore {
        var items: [ShellMoreItem] = []
        if let leave {
            items.append(.plain("arrow.up.forward.app", item.outwardName, act: leave))
        }
        items += postItems(acting.post, group: .reading, language: language)
        // Lane A's own-post items (Change it…, Who may quote it, Quotes of it) go here, before Pin and Quiet.
        items += ownItems(on: item, acting: acting, language: language)
        items += postItems(acting.post, group: .own, language: language)
        // Reporting it (#339): to those who answer for its source, asked on its sheet first.
        if let report = acting.report {
            let name = L10n.t("item.act.report", language: language)
            if let lock = report.lock {
                items.append(.locked(name: name, lock: lock, language: language, press: report.press))
            } else {
                items.append(.danger(PersonActing.reportSymbol, name, sheet: report.press))
            }
        }
        // **Not offered on a post already leaving**: its row is on no list to have a menu
        // (`ShellActs.leaving`), and where the post is still drawn — a conversation opened on
        // it — an item whose yes would be dropped is not shown as one to choose.
        let standing = acting.standings[.withdraw]
        if acting.acts.offers(.withdraw), let withdraw = acting.withdraw, standing == nil || standing == .failed {
            items.append(.danger(
                glyph(.withdraw, standing: standing),
                spoken(.withdraw, done: false, standing: standing, language: language),
                look: .live,
                asks: withdraw.asks(), act: withdraw.yes
            ))
        }
        return ShellMore(items: items)
    }

    /// The question a dim mark puts, on the row and in the menu alike, where there is one to
    /// put: only the act the sign-in must be asked again for (#285), and only in a list that can
    /// ask.
    private static func asks(_ mark: RowMark, acting: ItemActing) -> (() -> Void)? {
        // The quote mark's lock asks for the writing part (#330).
        if mark.kind == .quote, let quote = acting.quote, quote.look == .dim(.askAgain) { return quote.press }
        guard case .act(let act) = mark.kind, acting.acts.asks(act), let ask = acting.ask else { return nil }
        return { ask(act) }
    }

    /// The gap a mark asks for before it: the marks that keep a post stand a little apart from
    /// the ones that pass it on, and the bookmark — on every row now — opens the group.
    static func gap(before mark: RowMark) -> CGFloat? {
        mark.isBookmark ? ShellSpace.room : nil
    }
}
