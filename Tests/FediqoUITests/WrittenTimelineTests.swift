import Foundation
@testable import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// #27: timelines the reader writes, keeps, orders and removes, beside All and Trends.
@Suite("Timelines you write")
@MainActor
struct WrittenTimelineTests {
    private let microblog = Source(host: "m.example", kind: .mastodon)
    private let forum = Source(host: "f.example", kind: .discuz, boards: [BoardSubscription(fid: 42, name: "Dev")])

    init() {
        L10n.language = .english
    }

    /// A store of its own that keeps its values in memory, so no test reads or writes the reader's
    /// and none leaves a plist behind — a removed suite's domain is still written back as an empty
    /// file after the test has gone.
    private func freshStore() -> WrittenTimelineStore {
        WrittenTimelineStore(defaults: MemoryDefaults())
    }

    private func session(_ store: WrittenTimelineStore? = nil) -> ShellSession {
        let session = ShellSession(http: FixtureHTTP([:]), timelines: store ?? freshStore())
        session.sources = [microblog, forum]
        session.rebuildQueries()
        return session
    }

    private func draft(_ name: String, _ rules: [Rule] = [], in session: ShellSession) -> TimelineDraft {
        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = name
        draft.rules = rules
        return draft
    }

    private func everyKind() throws -> [Rule] {
        [
            try #require(Rule.source("m.example")),
            try #require(Rule.author("@ada@m.example", in: .every, sources: [])),
            try #require(Rule.author("bob@x.example", in: .source(host: "m.example"), effect: .exclude, sources: [])),
            try #require(Rule.keyword("swift", in: .every)),
            try #require(Rule.keyword("spoiler", in: .source(host: "m.example"), effect: .exclude)),
            try #require(Rule.category(.trends, in: .every, sources: [])),
            try #require(Rule.category(.public, in: .source(host: "m.example"), sources: [])),
            try #require(Rule.category(.home, in: .every, sources: [])),
            try #require(Rule.category(.list(id: "7"), in: .source(host: "m.example"), sources: [])),
            try #require(Rule.category(.board(id: "42"), in: .source(host: "f.example"), effect: .exclude, sources: [])),
        ]
    }

    // MARK: Acceptance: add, rename, reorder, remove

    @Test("A timeline is added on Done, after All and Trends, and put in front")
    func add() {
        let session = session()
        var draft = draft("Swift folks", in: session)
        #expect(session.queries == [.all, .trends])
        session.editing = draft
        session.commit(draft)
        #expect(session.editing == nil)
        #expect(session.written.map(\.name) == ["Swift folks"])
        #expect(session.queries == [.all, .trends, .written(draft.id)])
        #expect(session.timelineID == .written(draft.id))

        draft.name = "   "
        #expect(!draft.canSave)
    }

    @Test("Renaming keeps the timeline, its id and its place; the tab shows the new name")
    func rename() throws {
        let session = session()
        let first = draft("One", in: session)
        session.commit(first)
        session.commit(draft("Two", in: session))
        session.timelineID = .written(first.id)
        #expect(session.editCurrentTimeline())
        var editing = try #require(session.editing)
        #expect(!editing.isNew)
        #expect(editing.position == 0)
        editing.name = "  Uno "
        session.commit(editing)
        #expect(session.written.map(\.name) == ["Uno", "Two"])
        #expect(session.written[0].id == first.id)
        #expect(session.name(of: .written(first.id)) == "Uno")
    }

    @Test("Earlier and Later move a timeline among yours and nowhere past them")
    func reorder() throws {
        let session = session()
        for name in ["A", "B", "C"] { session.commit(draft(name, in: session)) }
        let c = session.written[2].id
        session.timelineID = .written(c)
        session.editCurrentTimeline()
        var editing = try #require(session.editing)
        #expect(editing.places == 3 && editing.position == 2 && !editing.canMoveLater)
        editing.move(by: -1)
        editing.move(by: -1)
        editing.move(by: -1)
        #expect(editing.position == 0 && !editing.canMoveEarlier)
        session.commit(editing)
        #expect(session.written.map(\.name) == ["C", "A", "B"])
        #expect(session.queries.dropFirst(2).map(\.id) == session.written.map { TimelineQuery.written($0.id).id })
    }

    @Test("Moving is only on Done: Cancel leaves the order and the name as they were")
    func cancelChangesNothing() throws {
        let session = session()
        for name in ["A", "B"] { session.commit(draft(name, in: session)) }
        session.timelineID = .written(session.written[1].id)
        session.editCurrentTimeline()
        var editing = try #require(session.editing)
        editing.move(by: -1)
        editing.name = "Changed"
        session.editing = nil
        #expect(session.written.map(\.name) == ["A", "B"])
    }

    @Test("Removing a timeline takes its tab and lands on the tab to its left")
    func remove() {
        let session = session()
        for name in ["A", "B", "C"] { session.commit(draft(name, in: session)) }
        let b = session.written[1].id
        session.timelineID = .written(b)
        session.removeTimeline(b)
        #expect(session.written.map(\.name) == ["A", "C"])
        #expect(!session.queries.contains(.written(b)))
        #expect(session.timelineID == .written(session.written[0].id))

        let a = session.written[0].id
        session.timelineID = .written(a)
        session.removeTimeline(a)
        #expect(session.timelineID == .trends)
    }

    @Test("All and Trends cannot be removed or edited: e says so, and opens nothing")
    func builtInsAreFixed() {
        let session = session()
        session.commit(draft("Mine", in: session))
        for query in [TimelineQuery.all, .trends] {
            session.timelineID = query
            session.toast = nil
            #expect(session.editCurrentTimeline())
            #expect(session.editing == nil)
            #expect(session.toast?.text == L10n.t("timeline.edit.fixed"))
        }
        #expect(L10n.t("timeline.edit.fixed").contains("can't be edited"))
        session.removeTimeline(TimelineDefinition.all.id)
        session.removeTimeline(TimelineDefinition.trends.id)
        #expect(session.queries.prefix(2) == [.all, .trends])
        #expect(session.written.count == 1)
    }

    // MARK: Acceptance: Tab order and the key

    @Test("Tab goes All, Trends, yours in your order, then [+], and round again")
    func tabOrder() {
        let session = session()
        for name in ["A", "B"] { session.commit(draft(name, in: session)) }
        session.timelineID = .all
        var visited: [String] = []
        for _ in 0..<6 {
            session.rotateTab(by: 1)
            visited.append(session.addFocused ? "+" : session.name(of: session.currentTimeline))
        }
        #expect(visited == ["Trends", "A", "B", "+", "All", "Trends"])

        session.timelineID = .all
        session.rotateTab(by: -1)
        #expect(session.addFocused)
        session.rotateTab(by: -1)
        #expect(!session.addFocused && session.currentTimeline == .written(session.written[1].id))
    }

    @Test("e on [+] opens a new timeline; a click on a tab takes the focus off [+]")
    func eOnAdd() throws {
        let session = session()
        session.timelineID = .trends
        session.rotateTab(by: 1)
        #expect(session.addFocused)
        #expect(session.editCurrentTimeline())
        let editing = try #require(session.editing)
        #expect(editing.isNew && editing.name.isEmpty && editing.position == 0)
        session.editing = nil
        session.timelineID = .all
        #expect(!session.addFocused)
    }

    @Test("e is the editor key and the keys list names it under Timeline")
    func editorKeyIsListed() throws {
        #expect(DummyCommand.from("e") == .editTimeline)
        #expect(DummyCommand.from("e", typing: true) == nil)
        #expect(DummyCommand.from("e", fieldFocused: true) == nil)
        let line = try #require(DummyShortcut.all.first { $0.commands == [.editTimeline] })
        #expect(line.keys == ["e"])
        #expect(line.group == .timeline)
        #expect(line.detail == "Write or change this timeline")
        #expect(L10n.t("shortcut.edit", language: .taiwanese) == "寫或改這條時間軸")
    }

    // MARK: Acceptance: after a relaunch

    @Test("After a relaunch, your timelines, their rules and their order are still there")
    func relaunch() throws {
        let store = freshStore()
        let before = session(store)
        before.commit(draft("First", try everyKind(), in: before))
        before.commit(draft("Second", in: before))
        before.timelineID = .written(before.written[1].id)
        before.editCurrentTimeline()
        var editing = try #require(before.editing)
        editing.move(by: -1)
        before.commit(editing)

        let after = session(store)
        #expect(after.written == before.written)
        #expect(after.written.map(\.name) == ["Second", "First"])
        #expect(after.queries == before.queries)
        #expect(after.written[1].rules.count == 10)
    }

    @Test("Every rule kind round-trips through what is kept, ids and effects included")
    func everyKindRoundTrips() throws {
        let store = freshStore()
        let timeline = TimelineDefinition(name: "All kinds", rules: try everyKind())
        store.save([timeline])
        #expect(store.load() == .timelines([timeline]))
    }

    @Test("The kept shape is frozen: these kind, effect and category strings read back")
    func frozenShape() throws {
        let store = freshStore()
        let json = #"""
        {"version":1,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"Frozen","rules":[
          {"id":"00000000-0000-0000-0000-000000000001","effect":"include","kind":"source","host":"m.example"},
          {"id":"00000000-0000-0000-0000-000000000002","effect":"exclude","kind":"author","value":"ada@m.example","host":null},
          {"id":"00000000-0000-0000-0000-000000000003","effect":"include","kind":"keyword","value":"swift","host":"m.example"},
          {"id":"00000000-0000-0000-0000-000000000004","effect":"include","kind":"category","category":{"kind":"board","id":"42"},"host":"f.example"},
          {"id":"00000000-0000-0000-0000-000000000005","effect":"include","kind":"category","category":{"kind":"trends"}}
        ]}]}
        """#
        store.defaults.set(Data(json.utf8), forKey: store.key)
        guard case .timelines(let read) = store.load() else {
            Issue.record("the frozen shape did not read")
            return
        }
        let kinds = try #require(read.first).rules.map(\.kind)
        #expect(kinds == [
            .source(host: "m.example"),
            .author(handle: "ada@m.example", in: .every),
            .keyword("swift", in: .source(host: "m.example")),
            .category(.board(id: "42"), in: .source(host: "f.example")),
            .category(.trends, in: .every),
        ])
        #expect(read[0].rules[1].effect == .exclude)
    }

    @Test("What is written carries version 1 and nothing but the known fields")
    func savedIsVersioned() throws {
        let store = freshStore()
        store.save([TimelineDefinition(name: "V", rules: try everyKind())])
        let data = try #require(store.defaults.data(forKey: store.key))
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(top["version"] as? Int == 1)
        #expect(Set(top.keys) == ["version", "timelines"])
    }

    // MARK: Fail closed

    @Test("A version, field or kind this build does not know leaves the kept timelines unreadable, not shorter",
          arguments: [
            #"{"version":1,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"include","kind":"regex","value":"a.*"}]}]}"#,
            #"{"version":1,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"mute","kind":"keyword","value":"a"}]}]}"#,
            #"{"version":1,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"include","kind":"category","category":{"kind":"channel","id":"1"}}]}]}"#,
            #"{"version":1,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"include","kind":"category","category":{"kind":"board","id":"1"}}]}]}"#,
            #"{"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[]}]}"#,
            #"{"version":2,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[]}]}"#,
            #"{"version":0,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[]}]}"#,
            #"{"version":1,"timelines":[],"pinned":true}"#,
            #"{"version":1,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[],"colour":"red"}]}"#,
            #"{"version":1,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"include","kind":"keyword","value":"a","regex":true}]}]}"#,
            #"{"version":1,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"include","kind":"category","category":{"kind":"trends","since":1}}]}]}"#,
            #"[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[]}]"#,
            #"{"not":"a list"}"#,
          ])
    func unknownFailsClosed(json: String) {
        let store = freshStore()
        let kept = Data(json.utf8)
        store.defaults.set(kept, forKey: store.key)
        #expect(store.load() == .unreadable)

        let session = session(store)
        #expect(session.timelinesUnreadable)
        #expect(session.written.isEmpty)
        #expect(session.queries == [.all, .trends])

        // Nothing is written over what is kept, by any route.
        session.newTimeline()
        #expect(session.editing == nil)
        #expect(session.toast?.text == L10n.t("timeline.unreadable"))
        session.commit(draft("Would overwrite", in: session))
        session.removeTimeline(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        #expect(store.defaults.data(forKey: store.key) == kept)
        #expect(session.written.isEmpty)
    }

    @Test("A value of another type under the key is unreadable, not nothing kept, and is never written over")
    func otherTypeIsUnreadable() {
        let store = freshStore()
        store.defaults.set("not data", forKey: store.key)
        #expect(store.load() == .unreadable)
        store.save([TimelineDefinition(id: UUID(), name: "Would overwrite", rules: [])])
        #expect(store.defaults.object(forKey: store.key) as? String == "not data")
        #expect(session(store).timelinesUnreadable)
    }

    @Test("The store itself refuses to write over what it cannot read, whoever asks")
    func saveRefusesOverUnreadable() {
        let store = freshStore()
        let kept = Data(#"{"version":2,"timelines":[]}"#.utf8)
        store.defaults.set(kept, forKey: store.key)
        store.save([TimelineDefinition(id: UUID(), name: "Would overwrite", rules: [])])
        #expect(store.defaults.data(forKey: store.key) == kept)

        let readable = freshStore()
        readable.save([TimelineDefinition(id: UUID(), name: "Kept", rules: [])])
        guard case .timelines(let timelines) = readable.load() else {
            Issue.record("what was saved reads back")
            return
        }
        #expect(timelines.map(\.name) == ["Kept"])
    }

    @Test("Nothing kept yet is no timelines, and is not unreadable")
    func nothingKept() {
        #expect(freshStore().load() == .timelines([]))
        #expect(!session().timelinesUnreadable)
    }

    // MARK: The editor builds only what can mean something

    @Test("Every scope offered builds a rule; the ones the factories refuse are never offered")
    func offeredScopesAreValid() {
        let sources = [microblog, forum, Source(host: "p.example", kind: .pleroma)]
        let targets: [RuleTarget] = [
            .source("m.example"), .source("f.example"),
            .author("@ada@m.example"), .author("@kim@f.example"),
            .keyword("swift"),
            .category(.public, on: "m.example"), .category(.trends, on: "m.example"),
            .category(.home, on: "m.example"), .category(.list(id: "7"), on: "m.example"),
            .category(.board(id: "42"), on: "f.example"),
        ]
        for target in targets {
            let scopes = RuleBuilder.scopes(for: target, sources: sources)
            for scope in scopes.isEmpty ? [.every] : scopes {
                for effect in [RuleEffect.include, .exclude] {
                    #expect(RuleBuilder.rule(target, scope: scope, effect: effect, sources: sources) != nil,
                            "\(target) \(scope)")
                }
            }
        }
    }

    @Test("A board or list is only for its own source; trends never offers a forum; a forum author is forced")
    func refusedScopesNotOffered() {
        let sources = [microblog, forum]
        let board = RuleBuilder.scopes(for: .category(.board(id: "42"), on: "f.example"), sources: sources)
        #expect(board == [.source(host: "f.example")])
        #expect(Rule.category(.board(id: "42"), in: .every, sources: sources) == nil)

        #expect(RuleBuilder.scopes(for: .category(.list(id: "7"), on: "m.example"), sources: sources)
            == [.source(host: "m.example")])
        #expect(Rule.category(.list(id: "7"), in: .every, sources: sources) == nil)

        let trends = RuleBuilder.scopes(for: .category(.trends, on: "m.example"), sources: sources)
        #expect(trends == [.every, .source(host: "m.example")])
        #expect(Rule.category(.trends, in: .source(host: "f.example"), sources: sources) == nil)

        #expect(RuleBuilder.scopes(for: .author("@kim@f.example"), sources: sources) == [.source(host: "f.example")])
        #expect(RuleBuilder.scopes(for: .source("m.example"), sources: sources).isEmpty)

        // What cannot mean anything builds nothing, so Add stays off.
        #expect(RuleBuilder.rule(.keyword("  "), scope: .every, effect: .include, sources: sources) == nil)
        #expect(RuleBuilder.rule(.author("ada"), scope: .every, effect: .include, sources: sources) == nil)
    }

    @Test("Targets come from what this device holds: its sources, their boards, held categories and authors")
    func targetsFromTheStore() {
        let notes = [
            Note(id: "1", source: microblog, author: "Ada", handle: "@ada@m.example", body: "a",
                 postedAt: Date(timeIntervalSince1970: 0), categories: [.public, .home]),
            Note(id: "2", source: microblog, author: "Ada", handle: "@Ada@M.example", body: "b",
                 postedAt: Date(timeIntervalSince1970: 1), categories: [.public]),
            Note(id: "3", source: forum, author: "Kim", handle: "@kim@f.example", body: "c",
                 postedAt: Date(timeIntervalSince1970: 2), categories: [.board(id: "42")]),
        ]
        let groups = RuleBuilder.categories(in: [microblog, forum], notes: notes, signedIn: { _ in false })
        #expect(groups.map(\.host) == ["m.example", "f.example"])
        // Home is not offered for a signed-out source, but it is where held posts came through it.
        #expect(groups[0].categories == [.public, .trends, .home])
        #expect(groups[1].categories == [.board(id: "42")])
        #expect(RuleText.categoryName(.board(id: "42"), host: "f.example", sources: [forum]) == "Dev")
        #expect(RuleBuilder.authors(in: notes) == ["ada@m.example", "kim@f.example"])
    }

    @Test("Home is offered where the Mastodon is signed in, and every chosen list by its name")
    func homeAndLists() throws {
        let listed = Source(host: "m.example", kind: .mastodon,
                            lists: [ListSubscription(id: "7", name: "Friends"), ListSubscription(id: "9", name: "Work")])
        let sources = [listed, forum]
        let out = RuleBuilder.categories(in: sources, notes: [], signedIn: { _ in false })
        #expect(out[0].categories == [.public, .trends, .list(id: "7"), .list(id: "9")])
        let signedIn = RuleBuilder.categories(in: sources, notes: [], signedIn: { $0 == "m.example" })
        #expect(signedIn[0].categories == [.public, .trends, .home, .list(id: "7"), .list(id: "9")])
        #expect(signedIn[1].categories == [.board(id: "42")])

        #expect(RuleText.categoryName(.list(id: "7"), host: "m.example", sources: sources) == "Friends")
        let friends = try #require(Rule.category(.list(id: "7"), in: .source(host: "m.example"), sources: sources))
        #expect(RuleText.spoken(friends, status: .present, sources: sources, language: .english)
            == "Show posts that arrived through Friends, only on m.example.")

        // A list no longer chosen falls back to its id and is drawn missing.
        let gone = try #require(Rule.category(.list(id: "3"), in: .source(host: "m.example"), sources: sources))
        let status = CompiledTimeline(TimelineDefinition(name: "x", rules: [gone]), sources: sources).status(of: gone)
        #expect(status == .missingCategory)
        #expect(RuleText.spoken(gone, status: status, sources: sources, language: .english)
            == "Show posts that arrived through List 3, only on m.example. Missing: it still applies to posts this device holds.")
    }

    // MARK: Missing targets

    @Test("A tab's missing mark is worked out once per definition and sources, not on every redraw")
    func missingMarkKept() throws {
        let session = session()
        let gone = try #require(Rule.source("gone.example"))
        session.commit(draft("Old", [gone], in: session))
        let query = TimelineQuery.written(session.written[0].id)
        #expect(session.hasMissingRule(query))
        #expect(session.hasMissingRule(query))
        #expect(session.missingRuleEvaluations == 1)
        session.sources.append(Source(host: "gone.example", kind: .mastodon))
        #expect(!session.hasMissingRule(query), "the source came back")
        #expect(session.missingRuleEvaluations == 2)
        let here = try #require(Rule.keyword("swift", in: .every))
        var edited = try #require(session.editCurrentTimeline() ? session.editing : nil)
        edited.rules = [here]
        session.commit(edited)
        #expect(!session.hasMissingRule(query))
        #expect(session.missingRuleEvaluations == 3)
    }

    @Test("A rule whose source is gone stays, marks its tab, and says missing")
    func missingTarget() throws {
        let session = session()
        let gone = try #require(Rule.source("gone.example"))
        let board = try #require(Rule.category(.board(id: "99"), in: .source(host: "f.example"), sources: []))
        let here = try #require(Rule.keyword("swift", in: .every))
        session.commit(draft("Old", [gone, board, here], in: session))
        let query = TimelineQuery.written(session.written[0].id)
        #expect(session.hasMissingRule(query))
        #expect(!session.hasMissingRule(.all))
        let compiled = CompiledTimeline(session.written[0], sources: session.sources)
        #expect(compiled.status(of: gone) == .missingSource(host: "gone.example"))
        #expect(compiled.status(of: board) == .missingCategory)
        #expect(RuleText.spoken(gone, status: compiled.status(of: gone), sources: session.sources)
            == "Show posts from gone.example. Missing: it still applies to posts this device holds.")
        #expect(L10n.t("rule.missing") == "missing")
        #expect(L10n.t("rule.missing", language: .taiwanese) == "已不在")
    }

    // MARK: Words

    @Test("A rule row reads as one sentence, in English and in 繁體中文")
    func spoken() throws {
        let hide = try #require(Rule.keyword("spoiler", in: .every, effect: .exclude))
        let author = try #require(Rule.author("@ada@m.example", in: .source(host: "m.example"), sources: []))
        let board = try #require(Rule.category(.board(id: "42"), in: .source(host: "f.example"), sources: []))
        let sources = [microblog, forum]
        #expect(RuleText.spoken(hide, status: .present, sources: sources, language: .english)
            == "Hide posts containing “spoiler”, on every source.")
        #expect(RuleText.spoken(author, status: .present, sources: sources, language: .english)
            == "Show posts by @ada@m.example, only on m.example.")
        #expect(RuleText.spoken(board, status: .present, sources: sources, language: .english)
            == "Show posts that arrived through Dev, only on f.example.")
        #expect(RuleText.spoken(hide, status: .present, sources: sources, language: .taiwanese)
            == "隱藏含有「spoiler」的貼文，所有來源。")
        #expect(RuleText.spoken(author, status: .present, sources: sources, language: .taiwanese)
            == "顯示@ada@m.example 的貼文，只在 m.example。")
    }

    @Test("A written tab shows its own name and a rule line of its own")
    func writtenLabels() throws {
        let session = session()
        session.commit(draft("Swift folks", [try #require(Rule.keyword("swift", in: .every))], in: session))
        let query = TimelineQuery.written(session.written[0].id)
        #expect(session.name(of: query) == "Swift folks")
        #expect(session.name(of: .all) == "All")
        #expect(session.rule(of: query) == "1 rule of yours, in time order.")
        #expect(session.rule(of: .trends) == L10n.t("timeline.rule.trends"))
    }

    // MARK: One text index per session

    @Test("The session folds each note once, and only when a timeline reads text")
    func sessionHoldsOneIndex() throws {
        let session = session()
        let notes = [
            Note(id: "1", source: microblog, author: "Ada", handle: "@ada@m.example", body: "SWIFT news",
                 postedAt: Date(timeIntervalSince1970: 1), categories: [.public]),
            Note(id: "2", source: microblog, author: "Bob", handle: "@bob@m.example", body: "other",
                 postedAt: Date(timeIntervalSince1970: 0), categories: [.public]),
        ]
        session.notes = notes
        // All reads no text, so drawing it folds nothing.
        #expect(session.timelineItems(latest: nil).map(\.noteID) == ["1", "2"])
        #expect(!session.textIndexIsCurrent)
        session.commit(draft("Trends only", [try #require(Rule.category(.trends, in: .every, sources: []))], in: session))
        _ = session.timelineItems(latest: nil)
        #expect(!session.textIndexIsCurrent)

        session.commit(draft("Swift", [try #require(Rule.keyword("swift", in: .every))], in: session))
        #expect(session.timelineItems(latest: nil).map(\.noteID) == ["1"])
        #expect(session.textIndexIsCurrent)
        #expect(session.textIndex.folded == 2)
        _ = session.timelineItems(latest: nil)
        #expect(session.textIndex.folded == 2)
        session.notes = notes
        #expect(!session.textIndexIsCurrent)
        #expect(session.textIndex.folded == 0)
    }

    @Test("A redraw reads the stream as drawn; each thing it was drawn from draws it again")
    func streamIsDrawnOnce() throws {
        let session = session()
        let notes = [
            Note(id: "1", source: microblog, author: "Ada", handle: "@ada@m.example", body: "swift news",
                 postedAt: Date(timeIntervalSince1970: 86_400 * 400), categories: [.public]),
            Note(id: "2", source: microblog, author: "Bob", handle: "@bob@m.example", body: "other",
                 postedAt: Date(timeIntervalSince1970: 0), categories: [.public]),
        ]
        session.notes = notes
        #expect(session.timelineItems(latest: nil).map(\.noteID) == ["1", "2"])
        _ = session.timelineItems(latest: nil)
        _ = session.timelineItems(latest: nil)
        #expect(session.timelineEvaluations == 1)

        // The notes, even the same ones assigned again.
        session.notes = notes + [
            Note(id: "3", source: microblog, author: "Cy", handle: "@cy@m.example", body: "swift too",
                 postedAt: Date(timeIntervalSince1970: 86_400 * 200), categories: [.public]),
        ]
        #expect(session.timelineItems(latest: nil).map(\.noteID) == ["1", "2", "3"])
        #expect(session.timelineEvaluations == 2)

        // The latest date.
        let latest = try #require(LatestDate("1970-12-31"))
        #expect(session.timelineItems(latest: latest).map(\.noteID) == ["2", "3"])
        #expect(session.timelineEvaluations == 3)

        // The timeline in front: a new one, then its definition edited.
        session.commit(draft("Swift", [try #require(Rule.keyword("swift", in: .every))], in: session))
        #expect(session.timelineItems(latest: latest).map(\.noteID) == ["3"])
        #expect(session.timelineEvaluations == 4)
        let id = session.written[0].id
        var edit = TimelineDraft(editing: session.written[0], at: 0, of: 1)
        edit.rules = [try #require(Rule.keyword("other", in: .every))]
        session.commit(edit)
        #expect(session.timelineID == .written(id))
        #expect(session.timelineItems(latest: latest).map(\.noteID) == ["2"])
        #expect(session.timelineEvaluations == 5)

        // Back to All, which it drew before but no longer holds.
        session.timelineID = .all
        #expect(session.timelineItems(latest: latest).map(\.noteID) == ["2", "3"])
        _ = session.timelineItems(latest: latest)
        #expect(session.timelineEvaluations == 6)

        // Sources are not read by the stream, so a change to them draws nothing again.
        session.sources = [microblog]
        _ = session.timelineItems(latest: latest)
        #expect(session.timelineEvaluations == 6)
    }

    @Test("A written timeline drawn through the session stops at the latest date, after its rules")
    func writtenStopsAtLatestDate() throws {
        let session = session()
        let day: TimeInterval = 86_400
        let june = Date(timeIntervalSince1970: 19_875 * day)     // 2024-06-01
        let january = Date(timeIntervalSince1970: 19_723 * day)  // 2024-01-01
        session.notes = [
            Note(id: "new", source: microblog, author: "Ada", handle: "@ada@m.example", body: "swift, later",
                 postedAt: june, categories: [.public]),
            Note(id: "old", source: microblog, author: "Ada", handle: "@ada@m.example", body: "swift, earlier",
                 postedAt: january, categories: [.public]),
            Note(id: "other", source: microblog, author: "Bob", handle: "@bob@m.example", body: "other",
                 postedAt: january, categories: [.public]),
        ]
        session.commit(draft("Swift", [try #require(Rule.keyword("swift", in: .every))], in: session))
        let march = try #require(LatestDate("2024-03-01"))
        #expect(session.timelineItems(latest: nil).map(\.noteID) == ["new", "old"])
        #expect(session.timelineItems(latest: march).map(\.noteID) == ["old"])
        session.timelineID = .all
        #expect(session.timelineItems(latest: march).map(\.noteID).sorted() == ["old", "other"])
    }

    // MARK: The editor's keys

    @Test("Inside the editor, [ ] move the timeline, n adds a rule, and the rule keys act on the focused row")
    func editorRulesKeys() {
        func key(_ c: Character, command: Bool = false) -> EditorAction? {
            EditorAction.from(c, command: command, stage: .rules, fieldFocused: false)
        }
        #expect(key("[") == .earlier)
        #expect(key("]") == .later)
        #expect(key("n") == .addRule)
        #expect(key("j") == .nextRule)
        #expect(key("k") == .previousRule)
        #expect(key("x") == .toggleRule)
        #expect(key(KeyEquivalent.delete.character) == .removeRule)
        #expect(key(KeyEquivalent.delete.character, command: true) == .removeTimeline)
        #expect(key("m") == .focusName)
        #expect(EditorAction.escape(at: .rules) == .cancel)
        #expect(key("z") == nil)
    }

    @Test("Kinds are picked by 1–4; a rule's effect, scope, choice and Add have keys; Esc steps back")
    func editorFormKeys() {
        for (index, tag) in RuleKind.Tag.allCases.enumerated() {
            #expect(EditorAction.from(Character("\(index + 1)"), stage: .kinds, fieldFocused: false) == .pickKind(tag))
        }
        #expect(EditorAction.from("5", stage: .kinds, fieldFocused: false) == nil)
        #expect(EditorAction.escape(at: .kinds) == .back)
        let form = EditorStage.form(.category)
        #expect(EditorAction.from("x", stage: form, fieldFocused: false) == .toggleEffect)
        #expect(EditorAction.from("o", stage: form, fieldFocused: false) == .nextScope)
        #expect(EditorAction.from("j", stage: form, fieldFocused: false) == .nextChoice)
        #expect(EditorAction.from("k", stage: form, fieldFocused: false) == .previousChoice)
        #expect(EditorAction.from("\r", stage: form, fieldFocused: false) == .confirmRule)
        #expect(EditorAction.escape(at: form) == .back)
    }

    @Test("A focused field keeps every letter; only Escape and ⌥O go past it")
    func editorFieldKeepsLetters() {
        for stage in [EditorStage.rules, .kinds, .form(.keyword)] {
            for c: Character in ["[", "]", "n", "m", "x", "o", "j", "k", "1", "\u{7F}", "\r"] {
                #expect(EditorAction.from(c, stage: stage, fieldFocused: true) == nil, "\(c) \(stage)")
            }
        }
        #expect(EditorAction.escape(at: .rules) == .cancel)
        #expect(EditorAction.escape(at: .form(.keyword)) == .back)
    }

    @Test("⌥O changes a rule's scope while its author or keyword field has the keys, and nowhere else")
    func optionOScopesFromTheField() {
        for tag in [RuleKind.Tag.author, .keyword] {
            for focused in [true, false] {
                #expect(EditorAction.from("o", option: true, stage: .form(tag), fieldFocused: focused) == .nextScope)
                #expect(EditorAction.from("ø", option: true, stage: .form(tag), fieldFocused: focused) == .nextScope)
            }
        }
        #expect(EditorAction.from("o", option: true, stage: .rules, fieldFocused: false) == nil)
        #expect(EditorAction.from("m", option: true, stage: .rules, fieldFocused: false) == nil)
        #expect(EditorAction.from("o", command: true, option: true, stage: .form(.keyword), fieldFocused: true) == nil)
    }

    @Test("m puts the keys in the name field, to rename the timeline")
    func mRenames() {
        #expect(EditorAction.from("m", stage: .rules, fieldFocused: false) == .focusName)
        #expect(EditorAction.from("m", stage: .rules, fieldFocused: true) == nil, "typed into the field")
        #expect(EditorAction.from("m", stage: .kinds, fieldFocused: false) == nil)
    }

    @Test("Escape reaches the editor once: on macOS only as the exit command, never also as a key press")
    func escapeOnce() {
        let escape = KeyEquivalent.escape.character
        for stage in [EditorStage.rules, .kinds, .form(.keyword)] {
            for focused in [true, false] {
                let pressed = EditorAction.from(escape, stage: stage, fieldFocused: focused)
                #if os(macOS)
                #expect(EditorAction.escapeIsExitCommand)
                #expect(pressed == nil, "the exit command is the one path on macOS")
                #else
                #expect(pressed == EditorAction.escape(at: stage))
                #endif
            }
        }
    }

    @Test("The keycap strip names a key for every stage, and each is in both languages")
    func editorStrip() {
        for stage in [EditorStage.rules, .kinds, .form(.source)] {
            let strip = EditorAction.strip(for: stage)
            #expect(!strip.isEmpty)
            for line in strip {
                #expect(L10n.t(line.key, language: .english) != line.key)
                #expect(L10n.t(line.key, language: .taiwanese) != line.key)
            }
        }
        #expect(EditorAction.strip(for: .rules).map(\.caps).contains("[ ]"))
        #expect(EditorAction.strip(for: .rules).map(\.caps).contains("n"))
        #expect(EditorAction.strip(for: .rules).map(\.caps).contains("m"))
        #expect(EditorAction.strip(for: .form(.keyword)).map(\.caps).contains("o ⌥O"))
    }

    @Test("By keys alone a rule is picked, switched to Hide, scoped and built")
    func ruleDraftByKeys() throws {
        let sources = [microblog, forum]
        var adding = RuleDraft(.category)
        let choices: [RuleTarget] = [.category(.public, on: "m.example"), .category(.board(id: "42"), on: "f.example")]
        #expect(adding.rule(sources) == nil)
        adding.step(1, through: choices, sources: sources)
        #expect(adding.target == choices[0])
        #expect(adding.scope == .source(host: "m.example"), "picked under m.example's heading")
        adding.nextScope(sources)
        #expect(adding.scope == .every)
        adding.nextScope(sources)
        #expect(adding.scope == .source(host: "m.example"))
        adding.toggleEffect()
        #expect(adding.effect == .exclude)
        adding.step(1, through: choices, sources: sources)
        // A board is its forum's, so the scope moves to the only one it can have.
        #expect(adding.scope == .source(host: "f.example"))
        let rule = try #require(adding.rule(sources))
        #expect(rule.kind == .category(.board(id: "42"), in: .source(host: "f.example")))
        #expect(rule.effect == .exclude)

        var keyword = RuleDraft(.keyword)
        keyword.type("  ", sources: sources)
        #expect(keyword.rule(sources) == nil)
        keyword.type("swift", sources: sources)
        #expect(keyword.rule(sources)?.kind == .keyword("swift", in: .every))
    }

    @Test("Public, trends and home picked under one host's heading are that host's until o widens them")
    func sharedCategoryDefaultsToItsHost() {
        let other = Source(host: "n.example", kind: .mastodon)
        let sources = [microblog, other, forum]
        for category in [FediqoCore.Category.public, .trends, .home] {
            var adding = RuleDraft(.category)
            adding.pick(.category(category, on: "n.example"), sources: sources)
            #expect(adding.scope == .source(host: "n.example"), "\(category)")
            #expect(adding.rule(sources)?.kind == .category(category, in: .source(host: "n.example")))
            adding.nextScope(sources)
            #expect(adding.scope == .every)
        }
    }

    @Test("The remove question names the kept timeline when the draft's name is emptied")
    func removeNameFallsBack() throws {
        let session = session()
        session.commit(draft("Kept", in: session))
        session.editCurrentTimeline()
        var editing = try #require(session.editing)
        #expect(session.removeName(of: editing) == "Kept")
        editing.name = "  "
        #expect(session.removeName(of: editing) == "Kept")
        editing.name = "Renamed"
        #expect(session.removeName(of: editing) == "Renamed")
    }

    @Test("The unreadable line says the timelines are left untouched and claims no newer version")
    func unreadableWords() {
        #expect(!L10n.t("timeline.unreadable", language: .english).contains("newer"))
        #expect(L10n.t("timeline.unreadable", language: .english).contains("untouched"))
        #expect(!L10n.t("timeline.unreadable", language: .taiwanese).contains("較新"))
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
