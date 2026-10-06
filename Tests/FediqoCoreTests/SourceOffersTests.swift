import Foundation
import Testing
@testable import FediqoCore

/// #299: what a kind of source offers is said once. Pinned here kind by kind, exactly as each
/// offered it before the facts were gathered — so a change to one is a change somebody made on
/// purpose, and a kind added later fails here until it says what it offers.
@Suite("What a kind of source offers")
struct SourceOffersTests {
    private static let microblogs: [ProtocolKind] = [.pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica, .gotosocial]

    @Test("Each kind offers exactly what it offered: a Mastodon everything a microblog has, its five fields, loads, the reader's marks, quotes and writing; every other microblog its timelines and what is rising; a Discuz! its boards and its ranking lists; a Discourse its boards; an unknown kind nothing")
    func eachKind() {
        #expect(ProtocolKind.mastodon.offers == SourceOffers(
            timelines: true, trends: true, writes: true,
            fields: [.audience, .language, .covered, .reblog, .reblogOf],
            loadsReferences: true, saysReaderMarks: true, saysQuotes: true
        ))
        for kind in Self.microblogs {
            #expect(kind.offers == SourceOffers(timelines: true, trends: true), "\(kind)")
        }
        #expect(ProtocolKind.discuz.offers == SourceOffers(trends: true, boards: true, authorsAreItsOwn: true))
        #expect(ProtocolKind.discourse.offers == SourceOffers(boards: true, authorsAreItsOwn: true))
        #expect(ProtocolKind.unknown.offers == SourceOffers())
        #expect(Set([ProtocolKind.mastodon, .discuz, .discourse, .unknown] + Self.microblogs) == Set(ProtocolKind.allCases), "every kind is pinned above")
    }

    @Test("The names the package already asks by read the one value, for every kind")
    func thePredicatesReadIt() {
        for kind in ProtocolKind.allCases {
            let offers = kind.offers
            #expect(kind.hasTimelines == offers.timelines && kind.hasTrends == offers.trends, "\(kind)")
            #expect(kind.isForum == offers.authorsAreItsOwn && kind.isForum == offers.boards, "\(kind)")
            #expect(kind.canWrite == offers.writes && kind.fields == offers.fields, "\(kind)")
            #expect(kind.loadsReferences == offers.loadsReferences, "\(kind)")
            #expect(kind.saysReaderMarks == offers.saysReaderMarks && kind.saysQuotes == offers.saysQuotes, "\(kind)")
            for field in offers.fields { #expect(offers.field(named: field.name) == field && kind.field(named: field.name) == field) }
            #expect(offers.field(named: "mood") == nil)
        }
        // As they were, spelled out: the lists these facts used to be.
        #expect(ProtocolKind.allCases.filter(\.hasTimelines) == [.mastodon] + Self.microblogs)
        #expect(ProtocolKind.allCases.filter(\.hasTrends) == [.mastodon] + Self.microblogs + [.discuz])
        #expect(ProtocolKind.allCases.filter(\.isForum) == [.discourse, .discuz])
        for only in [\ProtocolKind.canWrite, \.loadsReferences, \.saysReaderMarks, \.saysQuotes] {
            #expect(ProtocolKind.allCases.filter { $0[keyPath: only] } == [.mastodon])
        }
        #expect(ProtocolKind.allCases.filter { !$0.fields.isEmpty } == [.mastodon])
    }

    @Test("Which kinds of category can mean a source: public, Home and a list where it has timelines; what is rising where it has that; a board where it has boards")
    func whatACategoryCanMean() {
        let every: [FediqoCore.Category] = [.public, .trends, .home, .list(id: "7"), .board(id: "2")]
        func served(_ kind: ProtocolKind) -> [FediqoCore.Category] { every.filter(kind.offers.serves) }
        #expect(served(.mastodon) == [.public, .trends, .home, .list(id: "7")])
        #expect(served(.pleroma) == [.public, .trends, .home, .list(id: "7")])
        #expect(served(.discuz) == [.trends, .board(id: "2")])
        #expect(served(.discourse) == [.board(id: "2")])
        #expect(served(.unknown).isEmpty)
    }

    @Test("The categories one source can be read by now are completed by who holds them: the lists and boards chosen on it, and whether somebody is signed in — in the order they are offered; making the value asks nobody anything")
    func completedByTheCaller() {
        let lists = [ListSubscription(id: "7", name: "Friends"), ListSubscription(id: "3", name: "Work")]
        let boards = [BoardSubscription(fid: 42, name: "Dev"), BoardSubscription(fid: 2, name: "Chat")]
        let mastodon = Source(host: "m.example", kind: .mastodon, lists: lists)
        #expect(mastodon.kind.offers.categories(of: mastodon, signedIn: true) == [.public, .trends, .home, .list(id: "7"), .list(id: "3")])
        #expect(mastodon.kind.offers.categories(of: mastodon, signedIn: false) == [.public, .trends, .list(id: "7"), .list(id: "3")])
        #expect(ProtocolKind.mastodon.offers.categories(of: Source(host: "m.example", kind: .mastodon), signedIn: false) == [.public, .trends])
        let discuz = Source(host: "f.example", kind: .discuz, boards: boards)
        #expect(discuz.kind.offers.categories(of: discuz, signedIn: true) == [.trends, .board(id: "42"), .board(id: "2")])
        let discourse = Source(host: "d.example", kind: .discourse)
        #expect(discourse.kind.offers.categories(of: discourse, signedIn: true).isEmpty, "its front page is its one read, and has no name")
        #expect(ProtocolKind.unknown.offers.categories(of: Source(host: "x.example", kind: .unknown), signedIn: true).isEmpty)
        // The same value for every source of a kind, at every moment.
        #expect(mastodon.kind.offers == ProtocolKind.mastodon.offers)
    }
}
