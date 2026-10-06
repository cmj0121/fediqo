import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A rule can ask what only one kind of source says about a post (#287), from the kept shape up
/// to the editor.
///
/// What a test can reach: how a rule on a field is kept and read back, and that a build from
/// before it reads none of it; what the editor offers and with which values; the keys that pick
/// a field; the words a rule is said in, in both languages; a timeline made of one through the
/// session. What it cannot: the pills and the form drawn in light and dark, on a Mac and a phone.
@MainActor
@Suite("A rule on a field, kept and edited")
struct FieldRuleEditorTests {
    private static let mastodon = Source(host: "m.example", kind: .mastodon)
    private static let forum = Source(host: "f.example", kind: .discuz, boards: [BoardSubscription(fid: 42, name: "Dev")])

    private static func note(
        _ id: String, _ source: Source = mastodon, language: String? = nil, audience: Audience? = .everyone,
        sensitive: Bool? = false
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@\(source.host)", body: "words \(id)",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public], audience: audience,
            sensitive: sensitive, spoiler: sensitive == nil ? nil : "", language: language
        )
    }

    private static let held: [Note] = [
        note("ja1", language: "ja"), note("ja2", language: "ja"), note("en", language: "en"),
        note("none"), note("covered", language: "ja", sensitive: true),
        note("thread", forum, language: "de", audience: nil, sensitive: nil),
    ]

    private func session(
        _ store: WrittenTimelineStore, sources: [Source] = [mastodon, forum], notes: [Note] = held
    ) async -> ShellSession {
        let session = ShellSession(
            http: FixtureHTTP([:]), store: ItemStore(sources: sources, notes: notes), timelines: store
        )
        await session.reloadFromStore()
        return session
    }

    private func fieldRules() throws -> [Rule] {
        [
            try #require(Rule.field("language", is: .option("ja"), in: .every)),
            try #require(Rule.field("audience", is: .option("followers"), in: .source(host: "m.example"))),
            try #require(Rule.field("covered", is: .flag(true), in: .every, effect: .exclude)),
            try #require(Rule.field("covered", is: .flag(false), in: .every)),
        ]
    }

    // MARK: - Kept

    @Test("A rule on a field is kept as its field's name, its value's type and its value, and comes back the same rule")
    func keptAndReadBack() throws {
        let store = WrittenTimelineStore(defaults: KeptInMemory())
        let timeline = TimelineDefinition(name: "Fields", rules: try fieldRules())
        store.save([timeline])
        #expect(store.load() == .timelines([timeline]))

        let data = try #require(store.defaults.data(forKey: store.key))
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(top["version"] as? Int == 3)
        let rules = try #require((top["timelines"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]])
        #expect(rules.map { $0["kind"] as? String } == ["field", "field", "field", "field"])
        #expect(rules.map { $0["field"] as? String } == ["language", "audience", "covered", "covered"])
        #expect(rules.map { $0["type"] as? String } == ["option", "option", "flag", "flag"])
        #expect(rules.map { $0["value"] as? String } == ["ja", "followers", "yes", "no"])
        #expect(rules.map { $0["host"] as? String } == [nil, "m.example", nil, nil])
        #expect(rules.map { $0["effect"] as? String } == ["include", "include", "exclude", "include"])
    }

    /// What the build before this one reads of what is kept: its own version range, the fields it
    /// knew of a rule, and the kinds it could name — frozen here as that build had them.
    private static func buildBeforeReads(_ data: Data) -> Bool {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = top["version"] as? Int, (1...2).contains(version),
              let timelines = top["timelines"] as? [[String: Any]]
        else { return false }
        for timeline in timelines {
            guard let rules = timeline["rules"] as? [[String: Any]] else { return false }
            for rule in rules {
                guard Set(rule.keys).isSubset(of: ["id", "effect", "kind", "value", "category", "host"]),
                      let kind = rule["kind"] as? String, ["source", "author", "keyword", "category"].contains(kind)
                else { return false }
            }
        }
        return true
    }

    @Test("A build from before this does not read timelines that hold such a rule, by its version, by its fields and by its kind — it says they cannot be read rather than dropping the rule")
    func theBuildBeforeRefusesIt() throws {
        let store = WrittenTimelineStore(defaults: KeptInMemory())
        store.save([TimelineDefinition(name: "Fields", rules: try fieldRules())])
        let kept = try #require(store.defaults.data(forKey: store.key))
        #expect(!Self.buildBeforeReads(kept))

        // Each of the three alone is enough: the version put back to what it read, and then the
        // fields it did not know taken off, still leave a kind it cannot name.
        var top = try #require(try JSONSerialization.jsonObject(with: kept) as? [String: Any])
        top["version"] = 2
        #expect(!Self.buildBeforeReads(try JSONSerialization.data(withJSONObject: top)), "the fields alone did not stop it")
        var timelines = try #require(top["timelines"] as? [[String: Any]])
        timelines[0]["rules"] = (timelines[0]["rules"] as? [[String: Any]])?.map { rule in
            rule.filter { $0.key != "field" && $0.key != "type" }
        }
        top["timelines"] = timelines
        #expect(!Self.buildBeforeReads(try JSONSerialization.data(withJSONObject: top)), "the kind alone did not stop it")

        // And what it does read, it reads: the check is not one that refuses everything.
        #expect(Self.buildBeforeReads(Data(#"{"version":2,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"include","kind":"keyword","value":"a"}]}]}"#.utf8)))
    }

    @Test("A kept rule on a field this build cannot be asked of, or cannot read, leaves the timelines unreadable and unwritten, not shorter",
          arguments: [
            #"{"kind":"field","field":"favourites","type":"number","value":"10"}"#,
            #"{"kind":"field","field":"note","type":"text","value":"hello"}"#,
            #"{"kind":"field","field":"when","type":"date","value":"2026-01-01T00:00:00Z"}"#,
            #"{"kind":"field","field":"language","type":"regex","value":"j."}"#,
            #"{"kind":"field","field":"covered","type":"flag","value":"maybe"}"#,
            #"{"kind":"field","type":"option","value":"ja"}"#,
            #"{"kind":"field","field":"language","value":"ja"}"#,
            #"{"kind":"field","field":"language","type":"option"}"#,
            // A value its field cannot hold: it would load as a rule that can never match.
            #"{"kind":"field","field":"covered","type":"option","value":"yes"}"#,
            #"{"kind":"field","field":"audience","type":"flag","value":"yes"}"#,
            #"{"kind":"field","field":"audience","type":"option","value":"friends"}"#,
            #"{"kind":"field","field":"language","type":"option","value":"ja jp"}"#,
            #"{"kind":"field","field":"language","type":"option","value":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
            #"{"kind":"field","field":"language","type":"flag","value":"yes"}"#,
            // Whose post it reblogs holds a handle, folded, and nothing else.
            #"{"kind":"field","field":"reblogOf","type":"text","value":"ada"}"#,
            #"{"kind":"field","field":"reblogOf","type":"text","value":""}"#,
            #"{"kind":"field","field":"reblogOf","type":"text","value":"a@b@c"}"#,
            #"{"kind":"field","field":"reblogOf","type":"option","value":"ada@m.example"}"#,
            #"{"kind":"field","field":"reblogOf","type":"flag","value":"yes"}"#,
          ])
    func aKeptRuleItCannotAskFailsClosed(rule: String) async {
        let store = WrittenTimelineStore(defaults: KeptInMemory())
        let body = String(rule.dropFirst())
        let kept = Data((#"{"version":3,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"include","# + body + "]}]}").utf8)
        store.defaults.set(kept, forKey: store.key)
        #expect(store.load() == .unreadable)
        store.save([])
        #expect(store.defaults.data(forKey: store.key) == kept)
        #expect(await session(store).timelinesUnreadable)
    }

    @Test("A kept rule on a field no kind of source declares still loads, and is marked missing rather than refused")
    func anUnknownFieldStillLoads() async throws {
        let store = WrittenTimelineStore(defaults: KeptInMemory())
        let kept = Data(#"{"version":3,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"exclude","kind":"field","field":"mood","type":"option","value":"glad"}]}]}"#.utf8)
        store.defaults.set(kept, forKey: store.key)
        guard case .timelines(let read) = store.load() else {
            Issue.record("a field this build has no name for cost the reader their timelines")
            return
        }
        let rule = try #require(read.first?.rules.first)
        #expect(rule.kind == .field(name: "mood", is: .option("glad"), in: .every) && rule.effect == .exclude)
        let session = await session(store)
        #expect(CompiledTimeline(read[0], sources: session.sources).status(of: rule) == .missingField)
    }

    @Test("Tab is never taken on the kinds, so a pill with no digit is still walked to; and no digit past nine picks one")
    func aPillPastTheDigits() {
        let many = (0..<9).map { "field\($0)" }
        func key(_ character: Character) -> EditorAction? {
            EditorAction.from(character, stage: .kinds, fieldFocused: false, fields: many)
        }
        #expect(key(KeyEquivalent.tab.character) == nil, "the kinds took Tab from the focus")
        #expect(key("\u{19}") == nil)
        #expect(key("9") == .pickField("field4"), "the ninth pill is the last a digit reaches")
        #expect(key("0") == nil)
        #expect(key(KeyEquivalent.return.character) == nil && key(" ") == nil, "the press of a focused pill is the system's")
    }

    @Test("The rule survives a relaunch: a timeline made of it is kept, and shows after it what it showed before")
    func survivesARelaunch() async throws {
        let store = WrittenTimelineStore(defaults: KeptInMemory())
        let first = await session(store)
        var draft = TimelineDraft(new: 1)
        draft.name = "日本語"
        draft.rules = [
            try #require(Rule.field("language", is: .option("ja"), in: .every)),
            try #require(Rule.field("covered", is: .flag(true), in: .every, effect: .exclude)),
        ]
        first.commit(draft)
        let shown = first.timelineItems(latest: nil).map(\.noteID).sorted()
        #expect(shown == ["ja1", "ja2"], "only what says Japanese, and not what its author covered")

        let again = await session(store)
        switch store.load() {
        case .timelines(let kept): again.written = kept
        case .unreadable: Issue.record("the kept timelines could not be read back")
        }
        again.rebuildQueries()
        again.timelineID = .written(draft.id)
        #expect(again.written.first?.rules == draft.rules)
        #expect(again.timelineItems(latest: nil).map(\.noteID).sorted() == shown)
    }

    @Test("A rule on whose post it reblogs is kept in the shape every rule on a field is — its field's name, the text type, the handle — and comes back the same rule; a handle kept in another spelling comes back folded")
    func aHandleIsKeptAndReadBack() throws {
        let store = WrittenTimelineStore(defaults: KeptInMemory())
        let rule = try #require(Rule.field("reblogOf", is: .text("@Ada@M.example"), in: .source(host: "m.example"), effect: .exclude))
        let timeline = TimelineDefinition(name: "Fields", rules: [rule])
        store.save([timeline])
        #expect(store.load() == .timelines([timeline]))
        let data = try #require(store.defaults.data(forKey: store.key))
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(top["version"] as? Int == 3, "no new version: the text type was in the shape from the start")
        let kept = try #require(((top["timelines"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]])?.first)
        #expect(Set(kept.keys) == ["id", "effect", "kind", "field", "type", "value", "host"])
        #expect(kept["kind"] as? String == "field" && kept["field"] as? String == "reblogOf")
        #expect(kept["type"] as? String == "text" && kept["value"] as? String == "ada@m.example")
        #expect(kept["host"] as? String == "m.example" && kept["effect"] as? String == "exclude")

        let spelled = Data(#"{"version":3,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[{"id":"00000000-0000-0000-0000-000000000001","effect":"include","kind":"field","field":"reblogOf","type":"text","value":"@ADA@m.example"}]}]}"#.utf8)
        store.defaults.set(spelled, forKey: store.key)
        guard case .timelines(let read) = store.load() else {
            Issue.record("a handle in another spelling is still a handle")
            return
        }
        #expect(read.first?.rules.first?.kind == .field(name: "reblogOf", is: .text("ada@m.example"), in: .every))
    }

    @Test("Whose post it reblogs is offered as the fifth field and takes a handle the way an author rule does: typed, narrowed from the authors held, confirmed as the rule; opened again it is the same rule, and ⌫ there is a slip back into the text")
    func theFormTakesAHandle() async throws {
        let session = await session(WrittenTimelineStore(defaults: KeptInMemory()))
        let fields = RuleBuilder.fields(in: session.sources).map(\.name)
        #expect(EditorAction.from("9", stage: .kinds, fieldFocused: false, fields: fields) == .pickField("reblogOf"))
        var flow = EditorFlow(draft: TimelineDraft(new: 1))
        flow.addRule()
        flow.pickField(.reblogOf)
        #expect(flow.stage == .form(.field) && flow.adding.takesHandle && flow.wantsField, "the keyboard belongs in its field")
        #expect(flow.adding.rule(session.sources) == nil)
        // What is offered is the author rule's own list, read the same way.
        let authors = TimelineEditor.choices(for: RuleDraft(.author), in: session)
        let offered = TimelineEditor.choices(for: flow.adding, in: session)
        #expect(offered == [.field("reblogOf", .text("@ada@m.example")), .field("reblogOf", .text("@ada@f.example"))])
        #expect(offered.count == authors.count)

        flow.adding.type("ada", sources: session.sources)
        #expect(flow.adding.rule(session.sources) == nil, "a name with no instance is no handle")
        #expect(TimelineEditor.choices(for: flow.adding, in: session) == offered, "narrowed to the handles holding what is typed")
        flow.adding.type("m.ex", sources: session.sources)
        #expect(TimelineEditor.choices(for: flow.adding, in: session) == [.field("reblogOf", .text("@ada@m.example"))])
        flow.adding.type(" @Cyd@Elsewhere.example ", sources: session.sources)
        #expect(flow.adding.scopes(session.sources) == [.every, .source(host: "m.example")], "a Mastodon's field: never a forum's")
        flow.adding.toggleEffect()
        flow.confirm(sources: session.sources)
        let rule = try #require(flow.draft.rules.first)
        #expect(rule.kind == .field(name: "reblogOf", is: .text("cyd@elsewhere.example"), in: .every) && rule.effect == .exclude)

        flow.open(rule.id, sources: session.sources, choices: [])
        #expect(flow.stage == .form(.field) && flow.wantsField)
        #expect(flow.adding.typed == "@cyd@elsewhere.example")
        #expect(flow.adding.rule(session.sources, id: rule.id) == rule)
        #expect(!EditorAction.removesFromForm(flow.stage, typed: flow.adding.takesHandle))
        #expect(EditorAction.from(KeyEquivalent.delete.character, stage: flow.stage, fieldFocused: false, typed: true) == nil)
        #expect(EditorAction.from(KeyEquivalent.delete.character, stage: flow.stage, fieldFocused: false) == .removeRule, "a field with values to pick is removed by ⌫, as before")
        // A picked handle fills the field.
        flow.adding.step(1, through: offered, sources: session.sources)
        #expect(flow.adding.typed == "@ada@m.example" && flow.adding.rule(session.sources)?.kind == .field(name: "reblogOf", is: .text("ada@m.example"), in: .every))
    }

    @Test("A rule on whose post it reblogs is said in words, with the handle as a handle", arguments: [DummyLanguage.english, .taiwanese])
    func theHandleInWords(language: DummyLanguage) throws {
        let rule = try #require(Rule.field("reblogOf", is: .text("ada@m.example"), in: .every, effect: .exclude))
        let english = language == .english
        #expect(RuleText.fieldName("reblogOf", language: language) == (english ? "Whose post it reblogs" : "轉發誰的貼文"))
        #expect(RuleText.valueName(.text("ada@m.example"), of: "reblogOf", language: language) == "@ada@m.example")
        #expect(RuleText.phrase(rule, sources: [Self.mastodon], language: language) == (english ? "reblogs of @ada@m.example" : "轉發 @ada@m.example 的貼文"))
        #expect(RuleText.target(rule, sources: [Self.mastodon], language: language).contains("@ada@m.example"))
        let spoken = RuleText.spoken(rule, status: .present, sources: [Self.mastodon], language: language)
        #expect(!spoken.contains("%") && !spoken.contains("rule."))
    }

    // MARK: - What the editor offers

    @Test("A field is offered only where one of the reader's sources declares it, each once")
    func offeredOnlyWhereDeclared() {
        #expect(RuleBuilder.fields(in: [Self.forum]).isEmpty)
        #expect(RuleBuilder.fields(in: []).isEmpty)
        #expect(RuleBuilder.fields(in: [Self.forum, Self.mastodon]).map(\.name) == ["audience", "language", "covered", "reblog", "reblogOf"])
        let two = [Self.mastodon, Source(host: "second.example", kind: .mastodon)]
        #expect(RuleBuilder.fields(in: two).map(\.name) == ["audience", "language", "covered", "reblog", "reblogOf"])
    }

    @Test("Only values the reader's sources can give are offered: every audience, a yes and a no, and the languages held posts say — most posts first, and never a forum's")
    func onlyValuesTheSourcesCanGive() {
        let sources = [Self.mastodon, Self.forum]
        #expect(RuleBuilder.values(of: .audience, sources: sources, notes: Self.held)
            == Audience.allCases.map { .option($0.rawValue) })
        #expect(RuleBuilder.values(of: .covered, sources: sources, notes: Self.held) == [.flag(true), .flag(false)])
        #expect(RuleBuilder.values(of: .reblog, sources: sources, notes: Self.held) == [.flag(true), .flag(false)], "offered as covered is: a yes and a no")
        #expect(RuleBuilder.scopes(for: .field("reblog", .flag(true)), sources: sources) == [.every, .source(host: "m.example")])
        #expect(RuleBuilder.values(of: .language, sources: sources, notes: Self.held) == [.option("ja"), .option("en")],
                "a language no held Mastodon post says, or one only a forum's post carries, was offered")
        #expect(RuleBuilder.values(of: .language, sources: sources, notes: []).isEmpty)
        #expect(RuleBuilder.values(of: .language, sources: [Self.forum], notes: Self.held).isEmpty)
        // A source may scope it only where it declares the field.
        #expect(RuleBuilder.scopes(for: .field("language", .option("ja")), sources: sources)
            == [.every, .source(host: "m.example")])
        // Bounded, however many languages are held.
        let many = (0..<200).map { Self.note("n\($0)", language: "x\($0)") }
        #expect(RuleBuilder.values(of: .language, sources: sources, notes: many).count == RuleBuilder.valuesOffered)
    }

    @Test("The kinds are the four every source has, then each declared field by the next number; a number past them picks nothing")
    func theKeysPickAField() {
        let fields = ["audience", "language", "covered"]
        func key(_ character: Character, _ fields: [String]) -> EditorAction? {
            EditorAction.from(character, stage: .kinds, fieldFocused: false, fields: fields)
        }
        #expect(key("4", fields) == .pickKind(.category))
        #expect(key("5", fields) == .pickField("audience"))
        #expect(key("6", fields) == .pickField("language"))
        #expect(key("7", fields) == .pickField("covered"))
        #expect(key("8", fields) == nil)
        #expect(key("8", fields + ["reblog"]) == .pickField("reblog"), "the fourth field a Mastodon declares takes the next number")
        #expect(key("9", fields + ["reblog"]) == nil)
        #expect(key("5", []) == nil, "a field was offered where no source declares one")
        #expect(key("0", fields) == nil)
        #expect(EditorAction.strip(for: .kinds, fields: 3).first?.caps == "1–7")
        #expect(EditorAction.strip(for: .kinds).first?.caps == "1–4")
        #expect(!EditorAction.kinds.contains(.field), "a rule on a field is offered by its field")
    }

    @Test("Picking a field opens its values; a value picked and confirmed is the rule; opened again it is the same rule, and ⌫ removes it from there")
    func theFormMakesTheRule() async throws {
        let session = await session(WrittenTimelineStore(defaults: KeptInMemory()))
        var flow = EditorFlow(draft: TimelineDraft(new: 1))
        flow.addRule()
        flow.pickField(.language)
        #expect(flow.stage == .form(.field) && flow.adding.field == "language")
        #expect(!flow.wantsField, "there is nothing to type")
        #expect(flow.adding.rule(session.sources) == nil, "nothing is picked yet")

        let choices = TimelineEditor.choices(for: flow.adding, in: session)
        #expect(choices == [.field("language", .option("ja")), .field("language", .option("en"))])
        flow.adding.step(1, through: choices, sources: session.sources)
        #expect(flow.adding.target == .field("language", .option("ja")))
        #expect(flow.adding.scopes(session.sources) == [.every, .source(host: "m.example")])
        flow.adding.nextScope(session.sources)
        flow.adding.toggleEffect()
        flow.confirm(sources: session.sources)

        let rule = try #require(flow.draft.rules.first)
        #expect(rule.kind == .field(name: "language", is: .option("ja"), in: .source(host: "m.example")))
        #expect(rule.effect == .exclude)
        #expect(flow.stage == .rules && flow.focusedRule == rule.id)

        // Opened again where it is changed: the same field, value, effect and scope, and its choices.
        flow.open(rule.id, sources: session.sources, choices: TimelineEditor.choices(for: RuleDraft(kindOf: rule), in: session))
        #expect(flow.stage == .form(.field))
        #expect(flow.adding.target == .field("language", .option("ja")) && flow.adding.effect == .exclude)
        #expect(flow.adding.rule(session.sources, id: rule.id) == rule, "opened and confirmed untouched, it is another rule")
        #expect(TimelineEditor.choices(for: flow.adding, in: session) == choices)
        #expect(EditorAction.removesFromForm(flow.stage))
        flow.removeRule()
        #expect(flow.draft.rules.isEmpty && flow.stage == .rules)

        // A yes-or-no field offers its two answers.
        flow.addRule()
        flow.pickField(.covered)
        #expect(TimelineEditor.choices(for: flow.adding, in: session) == [.field("covered", .flag(true)), .field("covered", .flag(false))])
    }

    @Test("Rules are grouped in the editor as they are asked: each field a band of its own, after the kinds, and the hides last")
    func theBands() throws {
        let rules = try fieldRules() + [try #require(Rule.keyword("swift", in: .every))]
        let bands = EditorBands(rules).bands
        #expect(bands.map(\.field) == [String?.none, "language", "audience", "covered", nil])
        #expect(bands.map(\.rules.count) == [1, 1, 1, 1, 1])
        #expect(bands.last?.key == "rule.band.hide")
        for language in [DummyLanguage.english, .taiwanese] {
            let titles = bands.map { $0.title(language: language) }
            #expect(Set(titles).count == titles.count, "two bands read alike: \(titles)")
            #expect(titles.allSatisfy { !$0.contains("%") && !$0.contains("rule.band") })
            #expect(titles[1].contains(RuleText.fieldName("language", language: language)))
        }
    }

    // MARK: - Said in words

    @Test("A rule on a field is said by its field's name and its value's, in the language asked for", arguments: [DummyLanguage.english, .taiwanese])
    func theWords(language: DummyLanguage) throws {
        let sources = [Self.mastodon, Self.forum]
        for rule in try fieldRules() {
            guard case .field(let name, let value, _) = rule.kind else { continue }
            let title = RuleText.target(rule, sources: sources, language: language)
            let field = RuleText.fieldName(name, language: language)
            let said = RuleText.valueName(value, of: name, language: language)
            #expect(field != name && !field.contains("rule.field"), "\(name) has no word in \(language)")
            #expect(title.contains(field) && title.contains(said))
            let spoken = RuleText.spoken(rule, status: .present, sources: sources, language: language)
            #expect(!spoken.contains("%") && !spoken.contains("rule."), "\(spoken)")
            let missing = RuleText.spoken(rule, status: .missingField, sources: sources, language: language)
            #expect(missing.hasSuffix(L10n.t("rule.missing.spoken", language: language)))
        }
        // A language is named for the reader where the system can name it, and by its code where it cannot.
        #expect(RuleText.valueName(.option("ja"), of: "language", language: language) != "ja")
        #expect(!RuleText.valueName(.option("qqq-not-a-language"), of: "language", language: language).isEmpty)
        // How far a post was sent is said as the composer says it.
        #expect(RuleText.valueName(.option("followers"), of: "audience", language: language)
            == L10n.t(ComposerSheet.visibilityKey(.followers), language: language))
        #expect(RuleText.valueName(.flag(true), of: "covered", language: language) != RuleText.valueName(.flag(false), of: "covered", language: language))
        // A field this build has no word for is said by its own name, never as a missing key.
        #expect(RuleText.fieldName("mood", language: language) == "mood")
        #expect(RuleText.fieldPhrase("mood", .option("glad"), language: language).contains("glad"))
        for key in ["rule.kind.field", "rule.band.field", "rule.field.title", "rule.field.phrase"] {
            #expect(L10n.t(key, language: language) != key)
        }
    }

    @Test("In English a language rule reads “posts in Japanese”, and a covered one says who covered it")
    func theEnglishSentences() throws {
        let rules = try fieldRules()
        let spoken = rules.map { RuleText.spoken($0, status: .present, sources: [Self.mastodon], language: .english) }
        #expect(spoken[0] == "Show posts in Japanese, on every source.")
        #expect(spoken[1] == "Show posts sent to \(L10n.t(ComposerSheet.visibilityKey(.followers), language: .english)), only on m.example.")
        #expect(spoken[2] == "Hide posts their author covered, on every source.")
        #expect(spoken[3] == "Show posts their author did not cover, on every source.")
        #expect(RuleText.target(rules[0], sources: [], language: .english) == "Language: Japanese")
    }

    // MARK: - A field nobody here declares any more

    @Test("With the last source that declares it removed, the rule stays, its tab is marked, and its form offers no value")
    func missingWhenItsSourcesGo() async throws {
        let store = WrittenTimelineStore(defaults: KeptInMemory())
        let session = await session(store)
        var draft = TimelineDraft(new: 1)
        draft.name = "Japanese"
        let rule = try #require(Rule.field("language", is: .option("ja"), in: .every))
        draft.rules = [rule]
        session.commit(draft)
        #expect(!session.hasMissingRule(.written(draft.id)))

        await session.remove(host: Self.mastodon.host, keepingPosts: true)

        #expect(session.written.first?.rules == [rule], "the rule went with its source")
        #expect(session.hasMissingRule(.written(draft.id)))
        let compiled = CompiledTimeline(try #require(session.written.first), sources: session.sources)
        #expect(compiled.status(of: rule) == .missingField)
        #expect(TimelineEditor.choices(for: RuleDraft(kindOf: rule), in: session).isEmpty)
        #expect(RuleBuilder.fields(in: session.sources).isEmpty)
        // It still applies to the posts held.
        #expect(session.timelineItems(latest: nil).map(\.noteID).sorted() == ["covered", "ja1", "ja2"])
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class KeptInMemory: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
