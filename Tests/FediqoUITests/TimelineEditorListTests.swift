import Foundation
@testable import FediqoCore
import SwiftUI
import Testing
@testable import FediqoUI

/// #237: the timeline editor says the least first — the timeline and its rules on two tabs, each
/// rule a row that opens where it is changed or removed.
@Suite("A timeline's rules are a list, each opening where it is changed", .serialized)
@MainActor
struct TimelineEditorListTests {
    private let microblog = Source(host: "m.example", kind: .mastodon)
    private let forum = Source(host: "f.example", kind: .discuz, boards: [BoardSubscription(fid: 42, name: "Dev")])
    private var sources: [Source] { [microblog, forum] }

    private func rules() throws -> [Rule] {
        [
            try #require(Rule.source("m.example")),
            try #require(Rule.author("@ada@m.example", in: .every, effect: .exclude, sources: sources)),
            try #require(Rule.author("bob@f.example", in: .every, sources: sources)),
            try #require(Rule.keyword("swift", in: .source(host: "m.example"))),
            try #require(Rule.keyword("#rust", in: .every, effect: .exclude)),
            try #require(Rule.category(.public, in: .every, sources: sources)),
            try #require(Rule.category(.home, in: .source(host: "m.example"), sources: sources)),
            try #require(Rule.category(.trends, in: .source(host: "f.example"), sources: sources)),
            try #require(Rule.category(.board(id: "42"), in: .source(host: "f.example"), sources: sources)),
        ]
    }

    // MARK: Opening a rule

    @Test("Every rule opened in the form and confirmed untouched is the rule it was, id and all")
    func openedRuleRoundTrips() throws {
        for rule in try rules() {
            let opened = RuleDraft(editing: rule, sources: sources)
            #expect(opened.tag == rule.kind.tag)
            #expect(opened.rule(sources, id: rule.id) == rule, "\(rule.kind)")
        }
    }

    @Test("An opened rule changed keeps its place and its id; the others are untouched")
    func changedRuleKeepsItsPlace() throws {
        let kept = try rules()
        var draft = TimelineDraft(new: 1)
        draft.rules = kept
        var opened = RuleDraft(editing: kept[3], sources: sources)
        opened.toggleEffect()
        opened.nextScope(sources)
        let changed = try #require(opened.rule(sources, id: kept[3].id))
        draft.replace(kept[3].id, with: changed)
        #expect(draft.rules.map(\.id) == kept.map(\.id))
        #expect(draft.rules[3].effect == .exclude)
        #expect(draft.rules[3].kind == .keyword("swift", in: .source(host: "f.example")))
        #expect(Array(draft.rules[..<3]) == Array(kept[..<3]))
        #expect(Array(draft.rules[4...]) == Array(kept[4...]))
    }

    @Test("An opened author or keyword shows what was typed, so the field reads the rule")
    func openedFieldReadsTheRule() throws {
        let all = try rules()
        #expect(RuleDraft(editing: all[1], sources: sources).typed == "@ada@m.example")
        #expect(RuleDraft(editing: all[4], sources: sources).typed == "#rust")
    }

    // MARK: Keys

    @Test("Return opens the lit rule, Tab or t turns the tabs, and ⌫ in an opened rule removes it")
    func keys() {
        #expect(EditorAction.from("\r", stage: .rules, fieldFocused: false) == .openRule)
        for key: Character in ["\t", "\u{19}", "t"] {
            #expect(EditorAction.from(key, stage: .rules, fieldFocused: false) == .switchTab)
            #expect(EditorAction.from(key, stage: .rules, fieldFocused: true) == nil, "a field keeps its letters")
        }
        #expect(EditorAction.from("t", stage: .kinds, fieldFocused: false) == nil)
        #expect(EditorAction.from(KeyEquivalent.delete.character, stage: .form(.source), fieldFocused: false) == .removeRule)
        #expect(EditorAction.from(KeyEquivalent.delete.character, stage: .form(.keyword), fieldFocused: true) == nil)
        // The existing flow is as it was.
        #expect(EditorAction.from(KeyEquivalent.delete.character, command: true, stage: .rules, fieldFocused: false)
            == .removeTimeline)
        #expect(EditorAction.from("n", stage: .rules, fieldFocused: false) == .addRule)
        #expect(EditorAction.from("m", stage: .rules, fieldFocused: false) == .focusName)
    }

    @Test("The strip names opening and the tabs on the list, and removal and change on an opened rule")
    func strip() {
        let list = EditorAction.strip(for: .rules)
        #expect(list.contains { $0.key == "editor.keys.open" })
        #expect(list.contains { $0.key == "editor.keys.tab" })
        let changing = EditorAction.strip(for: .form(.keyword), changing: true)
        #expect(changing.contains { $0.key == "editor.keys.remove" && $0.caps == "⌫" })
        #expect(changing.contains { $0.key == "editor.keys.change" })
        #expect(!EditorAction.strip(for: .form(.keyword)).contains { $0.key == "editor.keys.remove" })
        for line in list + changing {
            #expect(L10n.t(line.key, language: .english) != line.key)
            #expect(L10n.t(line.key, language: .taiwanese) != line.key)
        }
    }

    // MARK: Tabs and words

    @Test("A new timeline opens on its name, one already kept on its rules; each tab has a glyph and a name")
    func tabs() {
        #expect(EditorTab.first(isNew: true) == .timeline)
        #expect(EditorTab.first(isNew: false) == .rules)
        #expect(EditorTab.timeline.other == .rules && EditorTab.rules.other == .timeline)
        #expect(Set(EditorTab.allCases.map(\.symbol)).count == EditorTab.allCases.count)
        for tab in EditorTab.allCases {
            #expect(L10n.t(tab.titleKey, language: .english) != tab.titleKey)
            #expect(L10n.t(tab.titleKey, language: .taiwanese) != tab.titleKey)
        }
    }

    @Test("Every glyph-only press of the editor names itself in both languages")
    func pressesNameThemselves() {
        let keys = [
            "editor.cancel", "editor.cancel.help", "timeline.done", "timeline.done.help",
            "timeline.earlier", "timeline.later", "timeline.remove", "timeline.remove.help",
            "rule.add", "rule.add.help", "rule.back", "rule.back.kinds", "rule.add.confirm",
            "rule.change.confirm", "rule.action.remove", "rule.remove.help",
        ]
        for key in keys {
            let english = L10n.t(key, language: .english)
            #expect(english != key)
            #expect(L10n.t(key, language: .taiwanese) != key)
            #expect(!english.contains("‹") && !english.contains("›") && !english.hasPrefix("+"), "a glyph is drawn, not typed")
        }
    }

    @Test("A row's brief is the effect and the scope, and a source rule's is its effect alone")
    func brief() throws {
        let all = try rules()
        #expect(RuleText.brief(all[0], language: .english) == "Show")
        #expect(RuleText.brief(all[1], language: .english) == "Hide, on every source")
        #expect(RuleText.brief(all[3], language: .english) == "Show, only on m.example")
        #expect(RuleText.brief(all[3], language: .taiwanese) != RuleText.brief(all[3], language: .english))
    }

    @Test("Bands keep the order rules are tried in: includes by kind, then every hide")
    func bands() throws {
        let bands = EditorBands(try rules()).bands
        #expect(bands.map(\.key) == [
            "rule.band.source", "rule.band.author", "rule.band.keyword", "rule.band.category", "rule.band.hide",
        ])
        #expect(bands.last?.rules.allSatisfy { $0.effect == .exclude } == true)
    }

    // MARK: Drawn

    private func session() -> ShellSession {
        let session = ShellSession(http: FixtureHTTP([:]))
        session.sources = [microblog]
        session.rebuildQueries()
        return session
    }

    @Test("The editor draws on either tab, in light and dark and at the largest type")
    func draws() throws {
        let session = session()
        var kept = TimelineDraft(new: 1)
        kept = TimelineDraft(
            editing: TimelineDefinition(id: kept.id, name: "Swift", rules: try rules()), at: 0, of: 1
        )
        let cases: [(TimelineDraft, ColorScheme, DynamicTypeSize)] = [
            (TimelineDraft(new: 1), .light, .large),
            (kept, .dark, .large),
            (kept, .light, .accessibility5),
        ]
        for (draft, scheme, size) in cases {
            let renderer = ImageRenderer(
                content: TimelineEditor(session: session, draft: draft)
                    .environment(\.colorScheme, scheme)
                    .dynamicTypeSize(size)
                    .frame(width: 380, height: 600)
            )
            let image = try #require(renderer.cgImage)
            #expect(image.width > 0 && image.height > 0)
        }
    }
}
