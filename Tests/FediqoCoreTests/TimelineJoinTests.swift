import Foundation
import Testing
@testable import FediqoCore

@Suite("A source joining the timelines already written")
struct TimelineJoinTests {
    private static let a = Source(host: "a.example", kind: .mastodon)
    private static let y = Source(host: "y.example", kind: .mastodon, lists: [ListSubscription(id: "l1", name: "Friends")])
    private static let forum = Source(host: "f.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "Swift")])
    private static let sources = [a, y, forum]
    private static let host = y.host

    private static func note(_ id: String, _ source: Source, _ categories: Set<FediqoCore.Category>, by handle: String = "@ada@a.example") -> Note {
        Note(id: id, source: source, author: "Someone", handle: handle, body: "hello",
             postedAt: Date(timeIntervalSince1970: 0), categories: categories)
    }

    /// One note of every division the timelines below take or leave.
    private static let held: [Note] = [
        note("a-public", a, [.public]),
        note("a-home", a, [.home]),
        note("y-public", y, [.public]),
        note("y-home", y, [.home]),
        note("y-list", y, [.list(id: "l1")]),
        note("y-old", y, [.list(id: "old")]),
        note("y-trends", y, [.trends]),
        note("y-ada", y, [.public], by: "@ada@y.example"),
        note("f-33", forum, [.board(id: "33")]),
        note("f-12", forum, [.board(id: "12")]),
    ]

    private static func timeline(_ rules: [Rule?]) -> TimelineDefinition {
        TimelineDefinition(name: "Mine", rules: rules.map { $0! })
    }

    private static func category(_ category: FediqoCore.Category, _ scope: RuleScope, effect: RuleEffect = .include) -> Rule? {
        Rule.category(category, in: scope, effect: effect, sources: sources)
    }

    private static func offer(
        _ timeline: TimelineDefinition, host: String = host, signedIn: Bool = true, sources: [Source] = sources
    ) -> TimelineJoinOffer? {
        TimelineJoin.offers(for: host, in: [timeline], sources: sources, signedIn: signedIn, marks: false, directs: false).first
    }

    private static func division(_ category: FediqoCore.Category, locked: Bool = false) -> TimelineJoinDivision {
        TimelineJoinDivision(category: category, locked: locked)
    }

    /// The joined timeline holds the rules of the one written with Y from the start, once each, shows the same held
    /// notes, and asks the same sources for the same things.
    private static func expectSame(_ joined: TimelineDefinition, as written: TimelineDefinition, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(joined.rules.count == written.rules.count, sourceLocation: sourceLocation)
        #expect(Set(joined.rules.map(\.kind)) == Set(written.rules.map(\.kind)), sourceLocation: sourceLocation)
        let index = TextIndex(held)
        let left = CompiledTimeline(joined, sources: sources)
        let right = CompiledTimeline(written, sources: sources)
        #expect(left.shown(held, index).map(\.id) == right.shown(held, index).map(\.id), sourceLocation: sourceLocation)
        #expect(left.sourcesToAsk() == right.sourcesToAsk(), sourceLocation: sourceLocation)
    }

    // MARK: - The shapes a timeline can have

    @Test("A timeline of sources only takes the whole source, whatever divisions are named")
    func sourceOnly() throws {
        let mine = Self.timeline([.source("a.example")])
        let offer = try #require(Self.offer(mine))
        #expect(offer.divisions.isEmpty)
        #expect(offer.addsSource && offer.joinsAsIs)
        let joined = mine.joining(Self.host, categories: [.public], sources: Self.sources)
        Self.expectSame(joined, as: Self.timeline([.source("a.example"), .source("y.example")]))
        #expect(CompiledTimeline(joined, sources: Self.sources).shown(Self.held, TextIndex(Self.held)).map(\.id)
            == ["a-public", "a-home", "y-public", "y-home", "y-list", "y-old", "y-trends", "y-ada"])
    }

    @Test("A timeline of categories only is offered each division, and adds no source rule")
    func categoryOnly() throws {
        let mine = Self.timeline([Self.category(.public, .source(host: "a.example"))])
        let offer = try #require(Self.offer(mine))
        #expect(offer.divisions == [Self.division(.public), Self.division(.home), Self.division(.list(id: "l1"))])
        #expect(!offer.addsSource && !offer.joinsAsIs)
        #expect(mine.joining(Self.host, categories: [], sources: Self.sources) == mine)
        Self.expectSame(
            mine.joining(Self.host, categories: [.home, .list(id: "l1")], sources: Self.sources),
            as: Self.timeline([
                Self.category(.public, .source(host: "a.example")),
                Self.category(.home, .source(host: Self.host)),
                Self.category(.list(id: "l1"), .source(host: Self.host)),
            ])
        )
    }

    @Test("A timeline of sources and categories gains the source with the divisions; signed out, no home")
    func sourceAndCategory() throws {
        let mine = Self.timeline([.source("a.example"), Self.category(.public, .source(host: "a.example"))])
        let offer = try #require(Self.offer(mine, signedIn: false))
        #expect(offer.divisions == [Self.division(.public), Self.division(.list(id: "l1"))])
        #expect(offer.addsSource && !offer.joinsAsIs)
        Self.expectSame(
            mine.joining(Self.host, categories: [.public], sources: Self.sources),
            as: Self.timeline([
                .source("a.example"), .source("y.example"),
                Self.category(.public, .source(host: "a.example")), Self.category(.public, .source(host: Self.host)),
            ])
        )
        // Nothing of Y's let through by the categories: the source alone would add nothing.
        #expect(mine.joining(Self.host, categories: [], sources: Self.sources) == mine)
    }

    @Test("A category for every source is already on: ticked and locked, never added again")
    func everyCategory() throws {
        let mine = Self.timeline([Self.category(.public, .every), Self.category(.home, .source(host: "a.example"))])
        let offer = try #require(Self.offer(mine))
        #expect(offer.divisions == [Self.division(.public, locked: true), Self.division(.home), Self.division(.list(id: "l1"))])
        #expect(!offer.addsSource && !offer.joinsAsIs)
        Self.expectSame(
            mine.joining(Self.host, categories: [.public, .home], sources: Self.sources),
            as: Self.timeline([
                Self.category(.public, .every), Self.category(.home, .source(host: "a.example")),
                Self.category(.home, .source(host: Self.host)),
            ])
        )
    }

    @Test("A division hidden for Y or for every source is not offered")
    func excludedDivisions() throws {
        let mine = Self.timeline([
            .source("a.example"), Self.category(.public, .source(host: "a.example")),
            Self.category(.home, .every, effect: .exclude),
            Self.category(.list(id: "l1"), .source(host: Self.host), effect: .exclude),
        ])
        let offer = try #require(Self.offer(mine))
        #expect(offer.divisions == [Self.division(.public)])
        // Named anyway, the hidden ones add nothing.
        let joined = mine.joining(Self.host, categories: [.public, .home, .list(id: "l1")], sources: Self.sources)
        Self.expectSame(joined, as: Self.timeline([
            .source("a.example"), .source("y.example"),
            Self.category(.public, .source(host: "a.example")), Self.category(.public, .source(host: Self.host)),
            Self.category(.home, .every, effect: .exclude),
            Self.category(.list(id: "l1"), .source(host: Self.host), effect: .exclude),
        ]))
    }

    @Test("A division hidden where Y already reads in is neither offered nor added")
    func excludedDivisionWhereYReads() throws {
        let mine = Self.timeline([
            .source("a.example"), .source(Self.host), Self.category(.public, .source(host: Self.host)),
            Self.category(.home, .every, effect: .exclude),
        ])
        let offer = try #require(Self.offer(mine))
        #expect(offer.divisions == [Self.division(.public, locked: true), Self.division(.list(id: "l1"))])
        #expect(mine.joining(Self.host, categories: [.home], sources: Self.sources) == mine)
    }

    @Test("A timeline that hides source Y is not offered, and joining it changes nothing")
    func excludesTheSource() {
        let mine = Self.timeline([
            Self.category(.public, .every), Self.category(.home, .source(host: "a.example")),
            .source(Self.host, effect: .exclude),
        ])
        #expect(Self.offer(mine) == nil)
        #expect(mine.joining(Self.host, categories: [.home], sources: Self.sources) == mine)
        let plain = Self.timeline([Self.category(.public, .source(host: "a.example")), .source(Self.host, effect: .exclude)])
        let result = TimelineJoin.apply([plain.id: [.home], mine.id: [.home]], of: Self.host, to: [plain, mine], sources: Self.sources)
        #expect(result.changed.isEmpty)
        #expect(result.timelines == [plain, mine])
    }

    @Test("A category on every source that Y hides lets nothing in: joining as is adds no source rule")
    func everyCategoryHiddenForY() {
        let mine = Self.timeline([
            .source("a.example"), Self.category(.public, .every),
            Self.category(.public, .source(host: Self.host), effect: .exclude),
        ])
        let result = TimelineJoin.apply([mine.id: []], of: Self.host, to: [mine], sources: Self.sources)
        #expect(result.changed.isEmpty)
        #expect(result.timelines == [mine])
        let noLists = [Self.a, Source(host: Self.host, kind: .mastodon)]
        #expect(Self.offer(mine, signedIn: false, sources: noLists) == nil)
        // Hidden for Y, public on every source is not on for Y: never drawn locked.
        #expect(Self.offer(mine, sources: noLists)?.divisions == [Self.division(.home)])
    }

    @Test("A timeline Y still could not reach once joined is not offered; an author on every source is")
    func scopedAuthor() throws {
        let scoped = Self.timeline([
            .source("a.example"), .author("ada@a.example", in: .source(host: "a.example"), sources: Self.sources),
        ])
        #expect(Self.offer(scoped) == nil)
        #expect(scoped.joining(Self.host, categories: [.public], sources: Self.sources) == scoped)
        let everywhere = Self.timeline([.source("a.example"), .author("ada@y.example", in: .every, sources: Self.sources)])
        let offer = try #require(Self.offer(everywhere))
        #expect(offer.joinsAsIs)
        Self.expectSame(
            everywhere.joining(Self.host, categories: [], sources: Self.sources),
            as: Self.timeline([.source("a.example"), .source("y.example"), .author("ada@y.example", in: .every, sources: Self.sources)])
        )
    }

    @Test("A timeline with no include already takes every source, so it is not offered")
    func noInclude() {
        #expect(Self.offer(Self.timeline([])) == nil)
        #expect(Self.offer(Self.timeline([.keyword("spoilers", in: .every, effect: .exclude)])) == nil)
        #expect(Self.offer(Self.timeline([.keyword("swift", in: .every)])) == nil)
    }

    @Test("A timeline already taking Y is offered only what it lacks")
    func alreadyIncluding() throws {
        #expect(Self.offer(Self.timeline([.source(Self.host)])) == nil)
        let mine = Self.timeline([
            .source("a.example"), .source(Self.host),
            Self.category(.public, .source(host: "a.example")), Self.category(.public, .source(host: Self.host)),
        ])
        let offer = try #require(Self.offer(mine))
        #expect(offer.divisions == [Self.division(.public, locked: true), Self.division(.home), Self.division(.list(id: "l1"))])
        #expect(!offer.addsSource && !offer.joinsAsIs)
        Self.expectSame(mine.joining(Self.host, categories: [.public, .home], sources: Self.sources), as: Self.timeline([
            .source("a.example"), .source(Self.host),
            Self.category(.public, .source(host: "a.example")), Self.category(.public, .source(host: Self.host)),
            Self.category(.home, .source(host: Self.host)),
        ]))
    }

    @Test("Y removed and added again: its leftover rules are on, and nothing more is offered signed out with no list")
    func reAddedWithLeftovers() throws {
        let mine = Self.timeline([
            .source("a.example"), .source(Self.host),
            Self.category(.public, .source(host: "a.example")), Self.category(.public, .source(host: Self.host)),
        ])
        #expect(Self.offer(mine, sources: [Self.a, Self.forum]) == nil)
        let noLists = [Self.a, Source(host: Self.host, kind: .mastodon), Self.forum]
        #expect(Self.offer(mine, signedIn: false, sources: noLists) == nil)
        let signedIn = try #require(Self.offer(mine))
        #expect(signedIn.divisions.filter(\.locked).map(\.category) == [.public])
        Self.expectSame(mine.joining(Self.host, categories: [.list(id: "l1")], sources: Self.sources), as: Self.timeline([
            .source("a.example"), .source(Self.host),
            Self.category(.public, .source(host: "a.example")), Self.category(.public, .source(host: Self.host)),
            Self.category(.list(id: "l1"), .source(host: Self.host)),
        ]))
    }

    @Test("Home on every source: joining with nothing new ticked adds the source alone")
    func asIsWithEveryHome() throws {
        let mine = Self.timeline([.source("a.example"), Self.category(.home, .every)])
        let offer = try #require(Self.offer(mine))
        #expect(offer.divisions == [Self.division(.public), Self.division(.home, locked: true), Self.division(.list(id: "l1"))])
        #expect(offer.addsSource && offer.joinsAsIs)
        let result = TimelineJoin.apply([mine.id: []], of: Self.host, to: [mine], sources: Self.sources)
        #expect(result.changed == [mine.id])
        let joined = try #require(result.timelines.first)
        Self.expectSame(joined, as: Self.timeline([.source("a.example"), .source("y.example"), Self.category(.home, .every)]))
        #expect(CompiledTimeline(joined, sources: Self.sources).shown(Self.held, TextIndex(Self.held)).map(\.id)
            == ["a-home", "y-home"])
    }

    @Test("A division joined later adds its category and never a second source rule")
    func secondDivisionLater() throws {
        let mine = Self.timeline([.source("a.example"), Self.category(.public, .source(host: "a.example"))])
        let first = mine.joining(Self.host, categories: [.public], sources: Self.sources)
        let offer = try #require(Self.offer(first))
        #expect(offer.divisions == [Self.division(.public, locked: true), Self.division(.home), Self.division(.list(id: "l1"))])
        #expect(!offer.addsSource && !offer.joinsAsIs)
        let second = first.joining(Self.host, categories: [.public, .home], sources: Self.sources)
        #expect(second.rules.filter { $0.kind == .source(host: Self.host) }.count == 1)
        Self.expectSame(second, as: Self.timeline([
            .source("a.example"), .source("y.example"),
            Self.category(.public, .source(host: "a.example")), Self.category(.public, .source(host: Self.host)),
            Self.category(.home, .source(host: Self.host)),
        ]))
    }

    /// A stale list or board is absent by how the offer is built: only the lists and boards chosen now are Y's divisions.
    @Test("A list or board no longer chosen counts as absent: it locks nothing and is not offered")
    func staleRule() throws {
        let board = Self.timeline([
            .source("a.example"), Self.category(.public, .source(host: "a.example")),
            Self.category(.board(id: "12"), .source(host: "f.example")),
        ])
        let forumOffer = try #require(Self.offer(board, host: "f.example"))
        #expect(forumOffer.divisions == [Self.division(.board(id: "33"))])
        #expect(forumOffer.addsSource && !forumOffer.joinsAsIs)
        Self.expectSame(
            board.joining("f.example", categories: [.board(id: "33")], sources: Self.sources),
            as: Self.timeline([
                .source("a.example"), .source("f.example"),
                Self.category(.public, .source(host: "a.example")),
                Self.category(.board(id: "12"), .source(host: "f.example")), Self.category(.board(id: "33"), .source(host: "f.example")),
            ])
        )

        let list = Self.timeline([Self.category(.public, .source(host: "a.example")), Self.category(.list(id: "old"), .source(host: Self.host))])
        let listOffer = try #require(Self.offer(list))
        #expect(listOffer.divisions == [Self.division(.public), Self.division(.home), Self.division(.list(id: "l1"))])
    }

    @Test("A source group naming only a gone host still takes Y as a whole, or by its divisions")
    func goneHost() throws {
        let sources = Self.timeline([.source("gone.example")])
        let whole = try #require(Self.offer(sources))
        #expect(whole.divisions.isEmpty && whole.addsSource && whole.joinsAsIs)
        Self.expectSame(sources.joining(Self.host, categories: [], sources: Self.sources),
                        as: Self.timeline([.source("gone.example"), .source("y.example")]))

        let divided = Self.timeline([.source("gone.example"), Self.category(.public, .source(host: "gone.example"))])
        let offer = try #require(Self.offer(divided, signedIn: false))
        #expect(offer.divisions == [Self.division(.public), Self.division(.list(id: "l1"))] && offer.addsSource)
        Self.expectSame(
            divided.joining(Self.host, categories: [.public], sources: Self.sources),
            as: Self.timeline([
                .source("gone.example"), .source("y.example"),
                Self.category(.public, .source(host: "gone.example")), Self.category(.public, .source(host: Self.host)),
            ])
        )
    }

    @Test("Each added rule stands after the last include of its kind, not at the end")
    func ruleOrder() {
        let mine = Self.timeline([
            .source("a.example"), Self.category(.public, .source(host: "a.example")),
            .author("ada@y.example", in: .every, sources: Self.sources),
            .keyword("spoilers", in: .every, effect: .exclude),
        ])
        let joined = mine.joining(Self.host, categories: [.list(id: "l1"), .public], sources: Self.sources)
        #expect(joined.rules.map(\.kind) == [
            .source(host: "a.example"), .source(host: Self.host),
            .category(.public, in: .source(host: "a.example")),
            .category(.public, in: .source(host: Self.host)), .category(.list(id: "l1"), in: .source(host: Self.host)),
            .author(handle: "ada@y.example", in: .every),
            .keyword("spoilers", in: .every),
        ])
    }

    // MARK: - Many timelines at once

    @Test("Offers keep the timelines' order and leave out the ones with nothing to add")
    func offersInOrder() {
        let first = Self.timeline([.source("a.example")])
        let skipped = Self.timeline([.source(Self.host)])
        let last = Self.timeline([Self.category(.public, .source(host: "a.example"))])
        let offers = TimelineJoin.offers(for: "Y.EXAMPLE", in: [first, skipped, last], sources: Self.sources,
                                         signedIn: false, marks: false, directs: false)
        #expect(offers.map(\.id) == [first.id, last.id])
        #expect(TimelineJoin.offers(for: "nowhere.example", in: [first], sources: Self.sources,
                                    signedIn: true, marks: false, directs: false).isEmpty)
    }

    @Test("Applying changes only the chosen timelines that gain something, and says which")
    func applyChanges() {
        let chosen = Self.timeline([.source("a.example")])
        let untouched = Self.timeline([Self.category(.public, .source(host: "a.example"))])
        let nothing = Self.timeline([.source("a.example"), Self.category(.public, .source(host: "a.example"))])
        let result = TimelineJoin.apply([chosen.id: [], nothing.id: []], of: Self.host,
                                        to: [chosen, untouched, nothing], sources: Self.sources)
        #expect(result.changed == [chosen.id])
        #expect(result.timelines.map(\.id) == [chosen.id, untouched.id, nothing.id])
        #expect(result.timelines[1] == untouched && result.timelines[2] == nothing)
        #expect(result.timelines[0].rules.map(\.kind) == [.source(host: "a.example"), .source(host: Self.host)])
    }
}
