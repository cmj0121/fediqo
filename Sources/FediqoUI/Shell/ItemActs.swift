import FediqoCore
import SwiftUI

// How one of #54's acts is drawn and said on a row: the glyph, the name a pointer reads, the
// sentence VoiceOver hears, and the line a row says where the act is not offered at all.
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
/// behind it. It offers nothing and says nothing, which is `PostActs.none`.
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
    /// Boosting the post to its source, or taking the boost back (#106).
    var boost: (() -> Void)?
    /// Favouriting the post on its source, or taking the favourite back (#107).
    var favourite: (() -> Void)?
    /// Answering the post (#108): from a timeline, opening the conversation it belongs to, since
    /// that is where an answer is written; from inside the conversation, opening the answer.
    /// Nothing where the list can do neither — somebody's page — and then no mark is drawn.
    var answer: (() -> Void)?
    /// Asking to take the post back (#109). Only ever the question — nothing goes on this press.
    var withdraw: (() -> Void)?
}

/// What one act's mark draws on one row — `ItemActs.mark`'s answer.
struct ItemMark: Equatable {
    let symbol: String
    /// What the source the act goes through last said.
    let done: Bool
    let count: Int?
    /// The mark's name to a pointer and to VoiceOver.
    let spoken: String
}

/// The vocabulary of the acts a reader performs on a post.
enum ItemActs {
    /// The glyph the mark draws.
    ///
    /// **The act's own glyph is replaced while the act is not settled, and that is the whole of
    /// "the mark shows the act is on its way".** A mark that kept its shape and changed only its
    /// colour would say nothing to a reader who cannot tell the two colours apart, and a mark that
    /// kept its shape entirely would say nothing to anybody. Three states, three shapes — four
    /// for the favourite, whose star fills when it is done.
    ///
    /// `done` is what the source last said, never what was pressed: a boost the reader made in
    /// another app reads as done here the moment this device has fetched the post.
    static func symbol(_ act: PostAct, done: Bool, standing: ShellActStanding?) -> String {
        switch standing {
        case .onItsWay: return "ellipsis"
        case .failed: return "exclamationmark.triangle"
        case nil: break
        }
        // Settled, the glyph is the act's own and **whether it is done is carried by the mark's
        // colour**, which is what `DummyMarkButton(on:)` already does for every other mark on the
        // row. `arrow.2.squarepath` has no filled twin to swap to, and inventing a second glyph
        // for the done state would make boosting the one act on the row that changes shape when
        // it is done — a difference a reader would read as meaning something.
        switch act {
        case .boost: return "arrow.2.squarepath"
        // The star is the one act that does have a filled twin, and it has always been drawn
        // filled when done — kept, so the favourite reads as it did before it went to the source.
        case .favourite: return done ? "star.fill" : "star"
        // An answer is never "done" on the post: the reader may answer as often as they like, and
        // the words they wrote are rows of their own in the thread.
        case .answer: return "arrowshape.turn.up.left"
        // Never "done": a post taken back is not on the row to be drawn.
        case .withdraw: return "trash"
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
        case .withdraw: (false, nil)
        }
        let host = item.otherCopies.isEmpty ? nil : copy.source.host
        return ItemMark(
            symbol: symbol(act, done: done, standing: standing),
            done: done,
            count: count,
            spoken: spoken(act, done: done, standing: standing, through: host, language: language)
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

    /// What a row says where it offers no acts at all.
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
}
