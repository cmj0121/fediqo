import Foundation
import Testing
@testable import FediqoCore

/// #347, #313 — the follows part as the table has it: its own two words and no other part's,
/// asked of any sign-in that reads, and never a reason to call a sign-in one that acts.
///
/// Every expected string is written out here and not read off the table it is held against.
@Suite("The follows part of a Mastodon sign-in")
struct MastodonFollowsPartTests {
    private static let r = "read:statuses read:lists read:accounts"
    private static let s = "read:search"
    private static let w = "write:statuses write:favourites"
    private static let b = "write:bookmarks"
    private static let n = "read:notifications"
    private static let d = "write:notifications"
    private static let f = "read:follows write:follows"

    private func held(_ scopes: String?, asked: String? = nil, refused: String? = nil) -> MastodonHeld {
        MastodonHeld(scopes: scopes, asked: asked, refused: refused)
    }

    @Test("Follows is its own pair of words and nothing else's: reading how the reader stands to someone, and following — no word of muting or blocking, none asked beside acting; it rides on no other question, and stands without the acting part")
    func theEntry() {
        let part = MastodonPart.follows
        #expect(part.words == ["read:follows", "write:follows"])
        #expect(part.wordsBesideActing.isEmpty)
        #expect(!part.rider, "follows rode along on the read-or-act question")
        #expect(!part.needsActing, "a sign-in that only reads could not be asked for follows")
        #expect(MastodonPart.allCases.last == .follows, "a part added later is not the last of the table")
        #expect(MastodonPart.allCases.filter(\.needsActing) == [.bookmarks])
        #expect(MastodonPart.allCases.filter(\.rider) == [.search, .bookmarks])
    }

    @Test("The page that asks a sign-in for follows carries what the sign-in holds and the two words of follows, and nothing else — whatever is held: reading alone, with search, acting, with bookmarks, with notices, with dismissing, a word nobody here knows, and the source's coarse words")
    func thePageForEachHeldState() {
        let (r, s, w, b, n, d, f) = (Self.r, Self.s, Self.w, Self.b, Self.n, Self.d, Self.f)
        let pages: [(held: String?, page: String)] = [
            (r, "\(r) \(f)"),
            ("\(r) \(s)", "\(r) \(s) \(f)"),
            ("\(r) \(s) \(w)", "\(r) \(s) \(w) \(f)"),
            ("\(r) \(s) \(w) \(b)", "\(r) \(s) \(w) \(b) \(f)"),
            ("\(r) \(s) \(n)", "\(r) \(s) \(n) \(f)"),
            // Holding acting and notices and never asked to dismiss: follows does not ask it.
            ("\(r) \(s) \(w) \(n)", "\(r) \(s) \(w) \(n) \(f)"),
            ("\(r) \(s) \(w) \(b) \(n) \(d)", "\(r) \(s) \(w) \(b) \(n) \(d) \(f)"),
            // Held already, in whole or in part: the same page.
            ("\(r) \(f)", "\(r) \(f)"),
            ("\(r) read:follows", "\(r) \(f)"),
            ("write:follows \(r)", "\(r) \(f)"),
            // A word this build does not use is on no page.
            ("\(r) push read:mutes", "\(r) \(f)"),
            ("read write", f),
            (nil, f),
        ]
        for (held, page) in pages {
            #expect(MastodonParts.page(held: held, ticked: [.follows]) == page, "\(held ?? "nothing")")
        }
    }

    @Test("Asked beside the read-or-act question, follows is kept or dropped as any part is: read and act keeps both its words, and read only keeps the one that reads and drops the one that follows")
    func readOnlyKeepsTheWordThatReads() {
        let (r, s, w, f) = (Self.r, Self.s, Self.w, Self.f)
        let reads: Set<MastodonPart> = [.reading, .search]
        #expect(MastodonParts.page(held: "\(r) \(s) \(w) \(f)", ticked: reads, readOnly: true) == "\(r) \(s) read:follows")
        #expect(MastodonParts.page(held: "\(r) \(s) \(f)", ticked: reads.union([.acting])) == "\(r) \(s) \(w) \(f)")
        #expect(MastodonParts.page(held: nil, ticked: [.follows], readOnly: true) == "read:follows")
    }

    @Test("No sign-in choice of today asks for follows: reading, acting, each with notices, and each without search or bookmarks ask exactly the words they asked")
    func noOrdinarySignInAsksForFollows() {
        for writing in [false, true] {
            for notices in [false, true] {
                for search in [false, true] {
                    for bookmarks in [false, true] {
                        let page = MastodonOAuth.scopes(search: search, writing: writing, bookmarks: bookmarks, notices: notices)
                        #expect(!page.contains("follows"), "\(page)")
                    }
                }
            }
        }
        #expect(MastodonOAuth.scopes(writing: false) == "\(Self.r) \(Self.s)")
        #expect(MastodonOAuth.scopes(writing: true, notices: true) == "\(Self.r) \(Self.s) \(Self.w) \(Self.b) \(Self.n) \(Self.d)")
    }

    @Test("Holding follows is not acting: a sign-in that reads and holds follows is read as one that reads — it writes, bookmarks and dismisses nothing, its source's row reads, and no post offers it an act", arguments: [
        "read:statuses read:lists read:accounts read:follows write:follows",
        "read:statuses read:lists read:accounts read:search read:follows write:follows",
        "read:statuses read:lists read:accounts read:search read:notifications read:follows write:follows",
        "write:follows read:follows read:accounts read:lists read:statuses",
        "read:statuses read:lists read:accounts write:follows",
    ])
    func holdingFollowsIsNotActing(_ scopes: String) {
        #expect(!MastodonOAuth.writes(scopes))
        #expect(!MastodonOAuth.bookmarks(scopes))
        #expect(!MastodonOAuth.dismisses(scopes))
        #expect(MastodonGrant.of(scopes: scopes) == .reading)
        let record = held(scopes, asked: scopes)
        #expect(record.grant == .reading)
        #expect(!record.bookmarks)
        #expect(!record.dismisses)
        let writing = SourceWriting.of(kind: .mastodon, grant: record.grant, refused: false)
        #expect(writing == .reads)
        for nameable in [false, true] {
            for mine in [false, true] {
                for bookmarks in BookmarkStanding.allCases {
                    let acts = PostActs.on(writing, nameable: nameable, mine: mine, bookmarks: bookmarks)
                    #expect(acts.offered.isEmpty)
                    #expect(acts.asking.isEmpty)
                    #expect(acts.refused == .notSignedIn)
                }
            }
        }
        // And no page built over it comes to ask for an act because follows is held.
        let page = MastodonParts.page(held: scopes, ticked: [.notices])
        #expect(!page.contains("write:notifications"), "\(page)")
        #expect(!page.contains("write:statuses"), "\(page)")
    }

    @Test("A sign-in stands to follows as to any part: never asked where no page asked its words — every sign-in made before it; held by both words; partly by one; refused where the page was; and asked and not given otherwise")
    func standings() {
        typealias P = MastodonParts
        let (r, f) = (Self.r, Self.f)
        #expect(P.standing(.follows, of: held(nil)) == .unasked)
        #expect(P.standing(.follows, of: held(r, asked: r)) == .unasked)
        #expect(P.standing(.follows, of: held("\(r) \(Self.w) \(Self.b) \(Self.n) \(Self.d)", asked: "\(r) \(Self.w) \(Self.b) \(Self.n) \(Self.d)")) == .unasked)
        #expect(P.standing(.follows, of: held("\(r) \(f)", asked: "\(r) \(f)")) == .held)
        #expect(P.standing(.follows, of: held("\(r) read:follows", asked: "\(r) read:follows")) == .partly)
        #expect(P.standing(.follows, of: held(r, asked: "\(r) \(f)", refused: f)) == .refused)
        #expect(P.standing(.follows, of: held(r, asked: "\(r) \(f)")) == .notGiven)
        // Another part's refusal is not this one's.
        #expect(P.standing(.follows, of: held(r, asked: "\(r) \(Self.n)", refused: Self.n)) == .unasked)
    }

    @Test("What a sign-in holds lists follows by itself, beside a sign-in that only reads: whole with both words, in part with one, and its words are no longer ones this build does not know")
    func holdings() {
        typealias E = MastodonHoldings.Entry
        let (r, f) = (Self.r, Self.f)
        #expect(MastodonParts.holdings(in: "\(r) \(f)") == MastodonHoldings(entries: [.whole(.reading), .whole(.follows)], other: []))
        #expect(MastodonParts.holdings(in: "\(r) read:follows").entries == [E.whole(.reading), .partly(.follows)])
        #expect(MastodonParts.holdings(in: "\(r) write:follows").entries == [E.whole(.reading), .partly(.follows)])
        #expect(MastodonParts.unknown(in: "\(r) \(f) read:mutes") == ["read:mutes"])
        #expect(MastodonParts.holds(.follows, in: "write:follows read:follows"))
        #expect(!MastodonParts.holds(.follows, in: "read:follows"))
        #expect(!MastodonParts.holds(.follows, in: "follow read write"), "the source's older word for it was read as the part")
    }

    /// What this app registered for before follows was a part: every registration kept from
    /// an earlier build of this story holds exactly these.
    private static let before = "read:statuses read:lists read:accounts read:search write:statuses write:favourites "
        + "write:bookmarks read:notifications write:notifications"

    @Test("The registration gains the two words of follows after every word it had, in the order it had them; one kept from before carries every page it carried and no page that asks for follows, so it is made again at that press and at no other")
    func theRegistrationWidens() {
        #expect(MastodonRegistration.superset() == "\(Self.before) \(Self.f)")
        let lacking: Set<String> = Set(Self.before.split(separator: " ").map(String.init))
        #expect(MastodonRegistration.superset(listed: lacking) == Self.before, "a host whose list has no follows is registered with as before")

        let reading = "\(Self.r) \(Self.s)"
        let asked = "\(reading) \(Self.f)"
        #expect(!MastodonRegistration.holds(asked, on: Self.before))
        #expect(MastodonRegistration.page(asked, on: Self.before) == nil, "a page was opened on a registration that cannot carry it")
        #expect(MastodonRegistration.holds(asked, on: MastodonRegistration.superset()))
        for page in [reading, "\(reading) \(Self.w) \(Self.b)", "\(reading) \(Self.n)", Self.before] {
            #expect(MastodonRegistration.holds(page, on: Self.before), "\(page)")
        }
    }
}
