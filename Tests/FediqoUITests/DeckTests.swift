import Foundation
import FediqoCore
import Testing
@testable import FediqoUI

@Suite("The deck in the slot")
struct DeckTests {
    private static let source = Source(host: "first.example", kind: .mastodon)
    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)

    private static func note(
        id: String = "n1",
        attachments: [FediqoCore.Attachment] = [],
        sensitive: Bool? = nil,
        spoiler: String? = nil
    ) -> Note {
        Note(
            id: id,
            source: source,
            author: "Ada",
            handle: "@ada@first.example",
            body: "words",
            postedAt: posted,
            origins: [.publicTimeline],
            attachments: attachments,
            sensitive: sensitive,
            spoiler: spoiler
        )
    }

    private static func picture(_ name: String) -> FediqoCore.Attachment {
        FediqoCore.Attachment(
            kind: .image,
            previewURL: URL(string: "https://first.example/\(name).jpg")
        )
    }

    @Test("m turns a deck of three, and comes back round to the first")
    func turningCycles() {
        var decks = ShellDecks()
        #expect(decks.top(of: "a", of: 3) == 0)
        for expected in [1, 2, 0] {
            let turned = decks.turn("a", of: 3)
            #expect(turned)
            #expect(decks.top(of: "a", of: 3) == expected)
        }
    }

    @Test("A deck of one does not turn, and neither does a row that brought nothing")
    func oneDoesNotTurn() {
        var decks = ShellDecks()
        let one = decks.turn("a", of: 1)
        let none = decks.turn("a", of: 0)
        #expect(!one)
        #expect(!none)
        #expect(decks.top(of: "a", of: 1) == 0)
        #expect(decks.top(of: "a", of: 0) == 0)
    }

    @Test("The position belongs to the row, so one row's turn is not another's")
    func positionIsPerRow() {
        var decks = ShellDecks()
        for _ in 0..<2 { _ = decks.turn("a", of: 3) }
        #expect(decks.top(of: "a", of: 3) == 2)
        #expect(decks.top(of: "b", of: 3) == 0)
    }

    // A refresh can bring the same post back carrying fewer things than it did. The position is
    // folded on the way out as well as on the way in, so what was the third of three does not
    // point past the end of a post that now has two.
    @Test("A position from a longer version of the post folds into the shorter one")
    func positionFoldsWhenThePostShrinks() {
        var decks = ShellDecks()
        for _ in 0..<2 { _ = decks.turn("a", of: 3) }
        #expect(decks.top(of: "a", of: 3) == 2)
        #expect(decks.top(of: "a", of: 2) == 0)
    }

    @Test("s goes both ways, one row at a time")
    func coveringIsPerRowAndGoesBothWays() {
        var decks = ShellDecks()
        #expect(!decks.isLifted("a"))
        let off = decks.toggleCover("a")
        #expect(off)
        #expect(decks.isLifted("a"))
        #expect(!decks.isLifted("b"))
        // Back again: a one-way key would leave a reader who uncovered by accident with no way
        // to put it back, and the on-screen control with nowhere to go.
        let on = decks.toggleCover("a")
        #expect(on)
        #expect(!decks.isLifted("a"))
    }

    // A rate is not a bound: these grow only where a reader pressed a key, which is slow, and a
    // collection that only grows slowly still only grows.
    @Test("Neither half of the deck state grows without a bound")
    func bothHalvesAreBounded() {
        var decks = ShellDecks()
        for n in 0...(ShellDecks.remembered * 2) {
            _ = decks.turn("row-\(n)", of: 4)
            _ = decks.toggleCover("row-\(n)")
        }
        // The entry just written is never the one dropped, so the row a reader is actually on
        // survives its own press.
        let last = "row-\(ShellDecks.remembered * 2)"
        #expect(decks.top(of: last, of: 4) == 1)
        #expect(decks.isLifted(last))
        // Counted from the outside, because what is held is the row's own business: a bound
        // asserted through a window opened for the test is a bound the test can be wrong about.
        let rows = (0...(ShellDecks.remembered * 2)).map { "row-\($0)" }
        #expect(rows.filter { decks.top(of: $0, of: 4) != 0 }.count <= ShellDecks.remembered)
        #expect(rows.filter { decks.isLifted($0) }.count <= ShellDecks.remembered)
    }

    @Test("sensitive, or a line to put in front of it, covers the row")
    func whatCoversARow() {
        #expect(DummyItem(Self.note(sensitive: true), among: []).covered)
        #expect(DummyItem(Self.note(spoiler: "Blood"), among: []).covered)
        #expect(DummyItem(Self.note(sensitive: false, spoiler: "Blood"), among: []).covered)
    }

    // `sensitive` has three answers and `note.sensitive ?? false` reads two of them the same.
    // Nothing is a source that never said, which is not a source that said no — but it is not a
    // cover either, or a timeline from a server with no such idea would be covered end to end.
    @Test("Nothing is not false, and neither of them is a cover on its own")
    func silenceIsNotAnAnswer() {
        let neverSaid = DummyItem(Self.note(), among: [])
        #expect(neverSaid.sensitive == nil)
        #expect(!neverSaid.covered)

        let saidNo = DummyItem(Self.note(sensitive: false), among: [])
        #expect(saidNo.sensitive == false)
        #expect(!saidNo.covered)

        #expect(neverSaid.sensitive != saidNo.sensitive)
        #expect(!DummyItem(Self.note(sensitive: false, spoiler: ""), among: []).covered)
    }

    @Test("A row carries what it needs to draw: the avatar's address, the cover, the stack")
    func theRowCarriesWhatItDraws() {
        let note = Note(
            id: "n2",
            source: Self.source,
            author: "Ada",
            handle: "@ada@first.example",
            body: "words",
            postedAt: Self.posted,
            origins: [.publicTimeline],
            avatarURL: URL(string: "https://first.example/a.png"),
            attachments: [Self.picture("one"), Self.picture("two")],
            sensitive: true,
            spoiler: "Blood"
        )
        let item = DummyItem(note, among: [])
        #expect(item.avatarURL == URL(string: "https://first.example/a.png"))
        #expect(item.hasAvatar)
        #expect(item.spoiler == "Blood")
        #expect(item.covered)
        #expect(item.attachments.count == 2)
        #expect(item.hasThumb)
    }

    // What a covered row is allowed to say about what is under it: the kind and the position,
    // and never the author's description of the picture — that would be the cover lifted for
    // exactly the reader who cannot lift it back.
    @Test("A covered row names what is under the cover without describing it")
    func aCoveredRowNamesButDoesNotDescribe() {
        let described = FediqoCore.Attachment(
            kind: .image,
            previewURL: URL(string: "https://first.example/a.jpg"),
            alt: "A spider eating a wasp"
        )
        let alone = AttachmentDeck.named([described], top: 0)
        #expect(alone == L10n.t("item.deck.image"))
        #expect(alone?.contains("spider") == false)

        let inADeck = AttachmentDeck.named([described, Self.picture("two")], top: 1)
        #expect(inADeck?.contains("spider") == false)
        #expect(inADeck?.contains("2") == true)
        #expect(AttachmentDeck.named([], top: 0) == nil)
    }

    // Unreachable today — the row only ever counts up from zero — and a trap rather than a wrong
    // answer if it ever stops being. `DummyCommand.advanced` already carries the safe form.
    @Test("A card index out of range folds back in, from either direction")
    func theIndexFolds() {
        #expect(AttachmentDeck.folded(0, of: 3) == 0)
        #expect(AttachmentDeck.folded(4, of: 3) == 1)
        #expect(AttachmentDeck.folded(-1, of: 3) == 2)
        #expect(AttachmentDeck.folded(-4, of: 3) == 2)
        #expect(AttachmentDeck.folded(7, of: 0) == 0)
    }

    @Test("Every kind of attachment has something to say for itself, in every language")
    func everyKindIsSpoken() {
        for language in [DummyLanguage.english, .taiwanese] {
            for kind in [FediqoCore.Attachment.Kind.image, .video, .audio, .unknown] {
                let key = "item.deck.\(kind.rawValue)"
                #expect(L10n.t(key, language: language) != key)
            }
        }
    }

    @Test("The cover and the counter are written in every language")
    func theCoverIsTranslated() {
        let keys = [
            "item.deck.position",
            "item.covered.title",
            "item.covered.show",
            "item.covered.hide",
            "item.covered.label",
            "item.lifted.label",
            "shortcut.reveal",
        ]
        for language in [DummyLanguage.english, .taiwanese] {
            for key in keys {
                #expect(L10n.t(key, language: language) != key)
            }
        }
    }

    // `%1$d` is two numbered arguments in either order, so a language can count "1 of 3" the
    // other way round. A translator who writes `%@` where `%1$d` belongs hands `String(format:)`
    // an `Int` where it expects a pointer — a crash only a reader in that language ever sees,
    // and one nothing else in the suite would catch. So it is formatted in every language here,
    // not only in the development one.
    @Test("The counter formats in every language, not only the one it was written in")
    func theCounterFormatsEverywhere() {
        for language in [DummyLanguage.english, .taiwanese] {
            let position = String(format: L10n.t("item.deck.position", language: language), 2, 3)
            #expect(position.contains("2"))
            #expect(position.contains("3"))
            #expect(!position.contains("%"))
        }
    }

    // The sheets behind the top card draw the pictures the reader has not turned to yet, so the
    // one thing that can go wrong silently is the `+ 1`: without it, sheet zero is the card's own
    // photograph drawn behind itself, which on a deck of two reads as a stack of one picture and
    // is invisible to anything that only checks a count.
    @Test("What is under the top card is the next one, never the one already on top")
    func theSheetsAreTheOnesNotYetTurnedTo() {
        // Three attachments, nothing turned: the top is 0, so the sheets are 1 then 2 then round.
        #expect(AttachmentDeck.beneath(0, depth: 0, of: 3) == 1)
        #expect(AttachmentDeck.beneath(0, depth: 1, of: 3) == 2)
        #expect(AttachmentDeck.beneath(0, depth: 2, of: 3) == 0)

        // Turned twice, so the top is 2 and the stack wraps rather than walking off the end.
        #expect(AttachmentDeck.beneath(2, depth: 0, of: 3) == 0)
        #expect(AttachmentDeck.beneath(2, depth: 1, of: 3) == 1)

        // Turned backwards past zero. `top` is the row's own running count and nothing clamps it,
        // so a negative one has to fold rather than trap on a subscript.
        #expect(AttachmentDeck.beneath(-1, depth: 0, of: 3) == 0)
        #expect(AttachmentDeck.beneath(-4, depth: 0, of: 3) == 0)

        // No sheet is drawn for a deck of one, and none at all for an empty one — the second is
        // the case that would otherwise index an empty array.
        #expect(AttachmentDeck.beneath(0, depth: 0, of: 1) == 0)
        #expect(AttachmentDeck.beneath(0, depth: 0, of: 0) == nil)
    }
}
