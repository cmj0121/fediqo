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
    var standings: [PostAct: ShellActStanding] = [:]
    /// Boosting the post to its source, or taking the boost back (#106).
    var boost: (() -> Void)?
    /// Favouriting the post on its source, or taking the favourite back (#107).
    var favourite: (() -> Void)?
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
        }
    }

    /// The whole of what a reader using VoiceOver is owed about one mark: what a press does, and
    /// where the last press got to.
    ///
    /// **One reader for the glyph and the listener**, which is #97's arrangement and for its
    /// reason: a mark and a sentence built from two derivations of one fact are two things that
    /// can be told different stories about one post.
    static func spoken(
        _ act: PostAct, done: Bool, standing: ShellActStanding?, language: DummyLanguage? = nil
    ) -> String {
        let name = name(act, done: done, language: language)
        switch standing {
        case .onItsWay: return name + " " + L10n.t("item.act.onItsWay", language: language)
        case .failed: return name + " " + L10n.t("item.act.failed", language: language)
        case nil: return name
        }
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
