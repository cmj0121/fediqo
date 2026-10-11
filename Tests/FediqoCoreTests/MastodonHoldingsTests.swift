import Foundation
import Testing
@testable import FediqoCore

/// #347 — what a sign-in holds, part by part, read off the table: the listing a source's row
/// and its page draw. A part stands by itself, so a sign-in that only reads may hold one that
/// acts, and nothing held may go unsaid.
@Suite("What a sign-in holds, part by part")
struct MastodonHoldingsTests {
    private typealias E = MastodonHoldings.Entry
    private static let reading = "read:statuses read:lists read:accounts"

    private func entries(_ scopes: String?) -> [MastodonHoldings.Entry] {
        MastodonParts.holdings(in: scopes).entries
    }

    @Test("Each state a sign-in can be held in lists exactly what it holds, in the table's order: nothing written down, reading alone, reading with a part that acts and no acting, everything, a part held in part, the act beside acting, the source's coarse words, and a word nobody here knows")
    func theHeldStates() {
        #expect(MastodonParts.holdings(in: nil) == MastodonHoldings(entries: [], other: []))
        #expect(MastodonParts.holdings(in: "") == MastodonHoldings(entries: [], other: []))
        #expect(entries(Self.reading) == [E.whole(.reading)])
        #expect(entries(Self.reading + " read:search") == [E.whole(.reading), .whole(.search)])
        // A part that acts, held by a sign-in that does not hold acting.
        #expect(entries(Self.reading + " write:bookmarks") == [E.whole(.reading), .whole(.bookmarks)])
        #expect(entries(Self.reading + " read:notifications") == [E.whole(.reading), .whole(.notices)])
        // Spelt out, and not the table's own list of everything: a part added later is none of these.
        let everything = MastodonParts.holdings(in: "read:statuses read:lists read:accounts read:search write:statuses write:favourites write:bookmarks read:notifications write:notifications")
        #expect(everything.entries == [E.whole(.reading), .whole(.search), .whole(.acting), .whole(.bookmarks), .whole(.notices), .beside(.notices)])
        #expect(everything.other.isEmpty)
        // Handed back in another order, the listing is the table's.
        #expect(entries("write:bookmarks read:accounts read:lists read:statuses") == [E.whole(.reading), .whole(.bookmarks)])
        #expect(entries("read:statuses read:lists") == [E.partly(.reading)])
        #expect(entries(Self.reading + " write:statuses") == [E.whole(.reading), .partly(.acting)])
        #expect(entries(Self.reading + " write:notifications") == [E.whole(.reading), .beside(.notices)])
        #expect(MastodonParts.holdings(in: "read write") == MastodonHoldings(entries: [], other: ["read", "write"]))
        #expect(MastodonParts.holdings(in: Self.reading + " push push") == MastodonHoldings(entries: [.whole(.reading)], other: ["push"]))
        #expect(entries("write:bookmarksplus").isEmpty, "a word that only contains one was read as it")
    }

    @Test("Every subset of the parts lists exactly those parts, whole and in the table's order, and nothing else")
    func everySubsetOfParts() {
        let parts = MastodonPart.allCases
        for mask in 0..<(1 << parts.count) {
            let chosen = parts.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let scopes = chosen.flatMap(\.words).reversed().joined(separator: " ")
            let holdings = MastodonParts.holdings(in: scopes)
            #expect(holdings.entries == chosen.map { E.whole($0) }, "\(scopes)")
            #expect(holdings.other.isEmpty)
        }
    }

    @Test("No held word goes unsaid: every word of a scope string belongs to a part listed, to an act beside acting listed, or to the words the table does not know")
    func everyWordIsAccountedFor() {
        let known = MastodonPart.allCases.flatMap { $0.words + $0.wordsBesideActing }
        let words = known + ["read", "write", "follow", "push", "admin:read"]
        // Each word alone, each pair, and all of them: enough to meet every part whole, in part and beside.
        var strings = words.map { [$0] } + [words]
        for first in words { for second in words where second != first { strings.append([first, second]) } }
        for held in strings {
            let holdings = MastodonParts.holdings(in: held.joined(separator: " "))
            var said = Set(holdings.other)
            for entry in holdings.entries {
                switch entry {
                case .whole(let part): said.formUnion(part.words)
                case .partly(let part): said.formUnion(part.words.filter(held.contains))
                case .beside(let part): said.formUnion(part.wordsBesideActing.filter(held.contains))
                }
            }
            #expect(said == Set(held), "\(held)")
            let partly: [MastodonPart] = holdings.entries.compactMap { if case .partly(let part) = $0 { part } else { nil } }
            for part in partly {
                let all: Bool = part.words.allSatisfy(held.contains)
                #expect(!all, "\(part) was listed as held in part with every word of it")
            }
        }
    }
}
