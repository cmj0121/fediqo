import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #299: what the rule editor offers for each source — the scopes a rule may have, the
/// categories a source is picked by, the fields and their values — pinned for every kind of
/// source there is, **written against the editor as it stood while it still decided by the kind
/// of source**, and unchanged since. So the editor reading what a source offers instead is
/// shown here to offer exactly what it offered.
@Suite("What the rule editor offers, source by source")
struct RuleOffersPinTests {
    private static let mastodon = Source(
        host: "m.example", kind: .mastodon, lists: [ListSubscription(id: "7", name: "Friends"), ListSubscription(id: "3", name: "Work")]
    )
    private static let pleroma = Source(host: "p.example", kind: .pleroma)
    private static let discuz = Source(
        host: "z.example", kind: .discuz, boards: [BoardSubscription(fid: 42, name: "Dev"), BoardSubscription(fid: 2, name: "Chat")]
    )
    private static let discourse = Source(host: "d.example", kind: .discourse)
    private static let unknown = Source(host: "u.example", kind: .unknown)
    private static let all = [mastodon, pleroma, discuz, discourse, unknown]

    private static func scope(_ source: Source) -> RuleScope { .source(host: source.host) }

    private static func note(
        _ id: String, _ source: Source, _ categories: Set<FediqoCore.Category> = [], language: String? = nil, handle: String? = nil
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: handle ?? "@ada@\(source.host)", body: "x",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: categories, audience: .everyone,
            sensitive: false, spoiler: "", language: language
        )
    }

    @Test("The scopes a rule on a category may have: public and Home for every source, or any one with timelines; what is rising, or any one that has it; a board or a list its own source alone")
    func scopesOfACategory() {
        let s = Self.self
        #expect(RuleBuilder.scopes(for: .category(.public, on: "m.example"), sources: s.all) == [.every, s.scope(s.mastodon), s.scope(s.pleroma)])
        #expect(RuleBuilder.scopes(for: .category(.home, on: "m.example"), sources: s.all) == [.every, s.scope(s.mastodon), s.scope(s.pleroma)])
        #expect(RuleBuilder.scopes(for: .category(.trends, on: "m.example"), sources: s.all)
            == [.every, s.scope(s.mastodon), s.scope(s.pleroma), s.scope(s.discuz)])
        #expect(RuleBuilder.scopes(for: .category(.board(id: "42"), on: "z.example"), sources: s.all) == [s.scope(s.discuz)])
        #expect(RuleBuilder.scopes(for: .category(.list(id: "7"), on: "m.example"), sources: s.all) == [s.scope(s.mastodon)])
        #expect(RuleBuilder.scopes(for: .category(.public, on: "m.example"), sources: [s.discuz, s.discourse, s.unknown]) == [.every])
        #expect(RuleBuilder.scopes(for: .category(.trends, on: "z.example"), sources: [s.discourse, s.unknown]) == [.every])
    }

    @Test("The scopes a rule on an author may have: a forum's author is that forum's alone, on either forum; anybody else is for every source or any one; a source rule has none and a keyword every one")
    func scopesOfAnAuthor() {
        let s = Self.self
        let every = [RuleScope.every] + s.all.map(s.scope)
        #expect(RuleBuilder.scopes(for: .author("@kim@z.example"), sources: s.all) == [s.scope(s.discuz)])
        #expect(RuleBuilder.scopes(for: .author("Kim@D.example"), sources: s.all) == [s.scope(s.discourse)])
        #expect(RuleBuilder.scopes(for: .author("@kim@m.example"), sources: s.all) == every)
        #expect(RuleBuilder.scopes(for: .author("@kim@p.example"), sources: s.all) == every)
        #expect(RuleBuilder.scopes(for: .author("@kim@u.example"), sources: s.all) == every)
        #expect(RuleBuilder.scopes(for: .author("@kim@elsewhere.example"), sources: s.all) == every)
        #expect(RuleBuilder.scopes(for: .author("kim"), sources: s.all) == every)
        #expect(RuleBuilder.scopes(for: .keyword("cats"), sources: s.all) == every)
        #expect(RuleBuilder.scopes(for: .source("z.example"), sources: s.all).isEmpty)
    }

    @Test("The fields offered are those the reader's sources declare, each once and in their own order — a Mastodon's five, and none for any other kind; a rule on one is for every source or any one that declares it")
    func fieldsAndTheirScopes() {
        let s = Self.self
        let five = ["audience", "language", "covered", "reblog", "reblogOf"]
        #expect(RuleBuilder.fields(in: s.all).map(\.name) == five)
        #expect(RuleBuilder.fields(in: [s.discuz, s.mastodon, Source(host: "m2.example", kind: .mastodon)]).map(\.name) == five)
        for source in [s.pleroma, s.discuz, s.discourse, s.unknown] {
            #expect(RuleBuilder.fields(in: [source]).isEmpty, "\(source.kind)")
        }
        #expect(RuleBuilder.fields(in: []).isEmpty)
        for name in five {
            let value: FieldValue = name == "reblogOf" ? .text("@a@b.example") : .flag(true)
            #expect(RuleBuilder.scopes(for: .field(name, value), sources: s.all) == [.every, s.scope(s.mastodon)], "\(name)")
            #expect(RuleBuilder.scopes(for: .field(name, value), sources: [s.pleroma, s.discuz, s.discourse, s.unknown]) == [.every], "\(name)")
        }
        #expect(RuleBuilder.scopes(for: .field("mood", .flag(true)), sources: s.all) == [.every], "a field nobody declares")
    }

    @Test("The values offered for an open field are what held posts of sources that declare it say, most posts first; a fixed one its options; a yes-or-no its two; a handle the authors held, whoever's — never counted from a source that does not declare the field")
    func valuesOfAField() {
        let s = Self.self
        let notes = [
            s.note("1", s.mastodon, language: "ja"), s.note("2", s.mastodon, language: "ja"), s.note("3", s.mastodon, language: "en"),
            s.note("4", s.pleroma, language: "fr"), s.note("5", s.pleroma, language: "fr"), s.note("6", s.pleroma, language: "fr"),
            s.note("7", s.discuz, language: "de", handle: "kim@z.example"), s.note("8", s.discourse, language: "de"),
            s.note("9", s.unknown, language: "de"),
        ]
        #expect(RuleBuilder.values(of: .language, sources: s.all, notes: notes) == [.option("ja"), .option("en")])
        #expect(RuleBuilder.values(of: .language, sources: [s.pleroma, s.discuz, s.discourse, s.unknown], notes: notes).isEmpty)
        #expect(RuleBuilder.values(of: .audience, sources: s.all, notes: notes)
            == ["everyone", "unlisted", "followers", "mentioned"].map(FieldValue.option))
        #expect(RuleBuilder.values(of: .covered, sources: s.all, notes: notes) == [.flag(true), .flag(false)])
        #expect(RuleBuilder.values(of: .reblog, sources: [s.discuz], notes: notes) == [.flag(true), .flag(false)])
        #expect(RuleBuilder.values(of: .reblogOf, sources: s.all, notes: notes) == [
            .text("ada@m.example"), .text("ada@p.example"), .text("ada@d.example"), .text("ada@u.example"), .text("kim@z.example"),
        ])
    }

    @Test("The categories each source is picked by, in order: public, what is rising, Home where signed in, its lists, its boards, then any other its held posts arrived through by name — and a source with none is not listed")
    func categoriesOfEachSource() {
        let s = Self.self
        func listed(_ sources: [Source], notes: [Note] = [], signedIn: Set<String> = []) -> [String: [FediqoCore.Category]] {
            let groups = RuleBuilder.categories(in: sources, notes: notes, signedIn: signedIn.contains)
            #expect(groups.map(\.host) == sources.map(\.host).filter { host in groups.contains { $0.host == host } }, "in the sources' order")
            return Dictionary(uniqueKeysWithValues: groups.map { ($0.host, $0.categories) })
        }
        let out = listed(s.all)
        #expect(out["m.example"] == [.public, .trends, .list(id: "7"), .list(id: "3")])
        #expect(out["p.example"] == [.public, .trends])
        #expect(out["z.example"] == [.trends, .board(id: "42"), .board(id: "2")])
        #expect(out["d.example"] == nil && out["u.example"] == nil, "nothing to pick it by")
        #expect(RuleBuilder.categories(in: s.all, notes: [], signedIn: { _ in false }).map(\.host) == ["m.example", "p.example", "z.example"])

        let signed = listed(s.all, signedIn: ["m.example", "p.example", "z.example", "d.example", "u.example"])
        #expect(signed["m.example"] == [.public, .trends, .home, .list(id: "7"), .list(id: "3")])
        #expect(signed["p.example"] == [.public, .trends, .home])
        #expect(signed["z.example"] == [.trends, .board(id: "42"), .board(id: "2")], "a forum has no Home, signed in or not")
        #expect(signed["d.example"] == nil && signed["u.example"] == nil)

        // What held posts arrived through and the source no longer offers by itself: after
        // the rest, by name.
        let held = [
            s.note("1", s.mastodon, [.home, .list(id: "9"), .public]), s.note("2", s.discuz, [.board(id: "7"), .board(id: "42")]),
            s.note("3", s.discourse, [.board(id: "5")]), s.note("4", s.unknown, [.public]), s.note("5", s.pleroma, [.trends]),
            s.note("6", s.discuz, [.home]),
        ]
        let with = listed(s.all, notes: held)
        #expect(with["m.example"] == [.public, .trends, .list(id: "7"), .list(id: "3"), .home, .list(id: "9")])
        #expect(with["z.example"] == [.trends, .board(id: "42"), .board(id: "2"), .board(id: "7"), .home])
        #expect(with["d.example"] == [.board(id: "5")] && with["u.example"] == [.public])
        #expect(with["p.example"] == [.public, .trends])
        #expect(listed(s.all, notes: held, signedIn: ["m.example"])["m.example"]
            == [.public, .trends, .home, .list(id: "7"), .list(id: "3"), .list(id: "9")])
    }

    @Test("What the picker lists for each kind of rule is made of those: the sources, the authors held, the categories source by source, a field's values")
    @MainActor
    func whatThePickerLists() async {
        let s = Self.self
        let notes = [s.note("1", s.mastodon, [.public], language: "ja"), s.note("2", s.discuz, [.board(id: "42")], handle: "kim@z.example")]
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: s.all, notes: notes))
        await session.reloadFromStore()
        #expect(TimelineEditor.choices(for: RuleDraft(.source), in: session) == s.all.map { .source($0.host) })
        #expect(TimelineEditor.choices(for: RuleDraft(.category), in: session) == [
            .category(.public, on: "m.example"), .category(.trends, on: "m.example"),
            .category(.list(id: "7"), on: "m.example"), .category(.list(id: "3"), on: "m.example"),
            .category(.public, on: "p.example"), .category(.trends, on: "p.example"),
            .category(.trends, on: "z.example"), .category(.board(id: "42"), on: "z.example"), .category(.board(id: "2"), on: "z.example"),
        ])
        #expect(TimelineEditor.choices(for: RuleDraft(field: .language), in: session) == [.field("language", .option("ja"))])
        #expect(TimelineEditor.choices(for: RuleDraft(field: .covered), in: session) == [.field("covered", .flag(true)), .field("covered", .flag(false))])
        #expect(Set(TimelineEditor.choices(for: RuleDraft(.author), in: session)) == [.author("@ada@m.example"), .author("@kim@z.example")])
    }
}
