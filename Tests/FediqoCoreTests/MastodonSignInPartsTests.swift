import Foundation
import Testing
@testable import FediqoCore

/// #347: the table of what a Mastodon sign-in may be asked for, and the one function that
/// makes a page's words from it.
///
/// Held against the strings a sign-in asks today (`MastodonOAuth.scopes`), which every kept
/// registration and every kept token was made with: the table has to give them back byte for
/// byte, or a sign-in made before it would read as another one.
@Suite("The parts a Mastodon sign-in may be asked for")
struct MastodonSignInPartsTests {
    private typealias Part = MastodonPart

    private static func words(_ scopes: String) -> [String] {
        scopes.split(separator: " ").map(String.init)
    }

    /// The table as it shipped. **A line here is changed only by adding one**: a part's words
    /// are what a held sign-in is read by.
    private static let shipped: [(Part, own: String, besideActing: String)] = [
        (.reading, "read:statuses read:lists read:accounts", ""),
        (.search, "read:search", ""),
        (.acting, "write:statuses write:favourites", ""),
        (.bookmarks, "write:bookmarks", ""),
        (.notices, "read:notifications", "write:notifications"),
    ]

    @Test("Every part's words are the ones it shipped with, in the order it shipped; no word belongs to two parts; and they are the words a sign-in asks today")
    func theTableHasNotMoved() {
        #expect(Part.allCases == Self.shipped.map(\.0))
        for (part, own, beside) in Self.shipped {
            #expect(part.words == Self.words(own), "\(part)")
            #expect(part.wordsBesideActing == Self.words(beside), "\(part)")
        }
        let every = Part.allCases.flatMap { $0.words + $0.wordsBesideActing }
        #expect(Set(every).count == every.count)

        #expect((Part.reading.words + Part.search.words).joined(separator: " ") == MastodonOAuth.reading)
        #expect(Part.reading.words.joined(separator: " ") == MastodonOAuth.readingWithoutSearch)
        #expect(Part.acting.words.joined(separator: " ") == MastodonOAuth.writing)
        #expect(Part.bookmarks.words == [MastodonOAuth.bookmarking])
        #expect(Part.notices.words == [MastodonOAuth.noticing])
        #expect(Part.notices.wordsBesideActing == [MastodonOAuth.dismissing])
    }

    @Test("A first sign-in's page is byte for byte the string asked today, for every choice and every rung a sign-in could be asked on: reading with and without search, acting with and without bookmarks, each with and without notices")
    func aFirstSignInAsksWhatItAskedBefore() {
        for search in [true, false] {
            let reads: Set<Part> = search ? [.reading, .search] : [.reading]
            let reading = search ? MastodonOAuth.reading : MastodonOAuth.readingWithoutSearch
            for notices in [true, false] {
                let more: Set<Part> = notices ? [.notices] : []
                #expect(MastodonParts.page(held: nil, ticked: reads.union(more))
                    == MastodonOAuth.scopes(reading: reading, writing: false, notices: notices))
                #expect(MastodonParts.page(held: nil, ticked: reads.union(more).union([.acting, .bookmarks]))
                    == MastodonOAuth.scopes(reading: reading, writing: true, notices: notices))
                #expect(MastodonParts.page(held: nil, ticked: reads.union(more).union([.acting]))
                    == MastodonOAuth.scopes(reading: reading, writing: true, bookmarks: false, notices: notices))
            }
        }
        #expect(MastodonParts.page(held: nil, ticked: []) == "")
    }

    @Test("A page that widens a sign-in asks for what it holds and what was ticked, in the table's order whichever brought the word — so a sign-in reached in two steps asks the string one reached in one does")
    func aWiderPageIsOneStringHoweverReached() {
        let reading = MastodonOAuth.scopes(writing: false)
        let acting = MastodonOAuth.scopes(writing: true)
        let actingBare = MastodonOAuth.scopes(writing: true, bookmarks: false)
        let noticing = MastodonOAuth.scopes(writing: false, notices: true)
        let everything = MastodonOAuth.scopes(writing: true, notices: true)

        #expect(MastodonParts.page(held: reading, ticked: [.acting, .bookmarks]) == acting)
        #expect(MastodonParts.page(held: actingBare, ticked: [.bookmarks]) == acting)
        #expect(MastodonParts.page(held: reading, ticked: [.notices]) == noticing)
        #expect(MastodonParts.page(held: acting, ticked: [.notices]) == everything)
        #expect(MastodonParts.page(held: noticing, ticked: [.acting, .bookmarks]) == everything)
        #expect(MastodonParts.page(held: MastodonOAuth.readingWithoutSearch, ticked: [.search]) == reading)

        // Held in another order, or ticking what is held: the same string.
        let turned = Self.words(acting).reversed().joined(separator: " ")
        #expect(MastodonParts.page(held: turned, ticked: [.reading, .notices]) == everything)
        #expect(MastodonParts.page(held: acting, ticked: []) == acting)
    }

    @Test("Nothing rides along: a rider never answered is not added by a page about another part, and dismissing is asked only where notices or acting is what was ticked and both are then held")
    func nothingRidesAlong() {
        let actingBare = MastodonOAuth.scopes(writing: true, bookmarks: false)
        let withoutSearch = MastodonOAuth.readingWithoutSearch
        #expect(MastodonParts.page(held: actingBare, ticked: [.notices])
            == MastodonOAuth.scopes(writing: true, bookmarks: false, notices: true), "no bookmarks unticked")
        #expect(MastodonParts.page(held: withoutSearch, ticked: [.notices]) == "\(withoutSearch) read:notifications", "no search unticked")

        // Reading alone is never asked to dismiss.
        #expect(!MastodonOAuth.dismisses(MastodonParts.page(held: MastodonOAuth.reading, ticked: [.notices])))
        // Holding both, and never asked to dismiss: a page about something else does not ask.
        let both = "\(actingBare) read:notifications"
        #expect(MastodonParts.page(held: both, ticked: [.bookmarks]) == "\(MastodonOAuth.scopes(writing: true)) read:notifications")
        // Half of acting is not acting.
        let half = "\(MastodonOAuth.reading) write:statuses"
        #expect(MastodonParts.page(held: half, ticked: [.notices]) == "\(half) read:notifications")
        // Once held it is carried, as every held word is.
        let dismissing = MastodonOAuth.scopes(writing: true, bookmarks: false, notices: true)
        #expect(MastodonParts.page(held: dismissing, ticked: [.bookmarks]) == MastodonOAuth.scopes(writing: true, notices: true))
    }

    @Test("A held word the table does not know is on no page — the whole of reading, as a source names what an older or another app's token holds, among them — and no page names a word that is neither held nor a ticked part's")
    func anUnknownHeldWordIsLeftOut() {
        let reading = MastodonOAuth.reading
        #expect(MastodonParts.page(held: "\(reading) read:follows write:nonsense", ticked: [.notices]) == "\(reading) read:notifications")
        #expect(MastodonParts.page(held: "read write", ticked: [.reading]) == MastodonOAuth.readingWithoutSearch)
        // What a real source said a sign-in for everything holds (`MastodonSignInCaptures.wholeInfo`).
        #expect(MastodonParts.page(held: "read write", ticked: []) == "")

        let known = Set(Part.allCases.flatMap { $0.words + $0.wordsBesideActing })
        let helds: [String?] = [nil, reading, MastodonOAuth.scopes(writing: true), MastodonOAuth.scopes(writing: true, notices: true), "read write:statuses"]
        let ticks: [Set<Part>] = [[], [.reading], [.search], [.acting], [.bookmarks], [.notices], [.acting, .notices], Set(Part.allCases)]
        for held in helds {
            let had = Set(Self.words(held ?? ""))
            for ticked in ticks {
                let named = Set(ticked.flatMap { $0.words + $0.wordsBesideActing })
                let page = Set(Self.words(MastodonParts.page(held: held, ticked: ticked)))
                let allowed = had.intersection(known).union(named)
                #expect(page.isSubset(of: allowed), "\(held ?? "nothing") + \(ticked.map(\.rawValue).sorted())")
                let carried = had.intersection(known)
                #expect(page.isSuperset(of: carried), "nothing held and known is dropped")
            }
        }
    }
}
