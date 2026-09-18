import FediqoCore
import Foundation
import SwiftUI

/// The reader's own timelines from the shell's side (#27): the tabs they get, the editor's key,
/// and the three changes the editor can make — add or change on Done, remove after a question.
///
/// All and Trends never reach the editor (Decision 19), so nothing here can rename, move or
/// remove them.

/// One timeline being written. A copy: nothing it holds touches the stream until Done.
struct TimelineDraft: Identifiable, Equatable {
    let id: TimelineID
    let isNew: Bool
    var name: String
    var rules: [Rule]
    /// Where among the reader's timelines it goes, 0 being first after All and Trends.
    var position: Int
    /// How many places there are, this one included.
    let places: Int

    init(new places: Int) {
        id = UUID()
        isNew = true
        name = ""
        rules = []
        position = places - 1
        self.places = places
    }

    init(editing timeline: TimelineDefinition, at position: Int, of places: Int) {
        id = timeline.id
        isNew = false
        name = timeline.name
        rules = timeline.rules
        self.position = position
        self.places = places
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSave: Bool { !trimmedName.isEmpty }
    var canMoveEarlier: Bool { position > 0 }
    var canMoveLater: Bool { position < places - 1 }

    mutating func move(by step: Int) {
        position = min(max(position + step, 0), places - 1)
    }

    /// Rule order is definition order and decides which rule a hidden post is put down to
    /// (Decision 14), so a new rule goes last and nothing reorders them.
    mutating func add(_ rule: Rule) {
        rules.append(rule)
    }

    mutating func toggleEffect(of id: Rule.ID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].effect = rules[index].effect == .include ? .exclude : .include
    }

    mutating func remove(_ id: Rule.ID) {
        rules.removeAll { $0.id == id }
    }
}

/// A sentence the timeline shows for a moment. `tick` makes the same sentence twice two toasts.
struct ShellToast: Equatable {
    let tick: Int
    let text: String
}

/// The stream as last drawn, and what it was drawn from.
struct DrawnTimeline {
    struct Key: Equatable {
        let definition: TimelineDefinition
        let notesRevision: Int
        let latest: LatestDate?
    }

    let key: Key
    let items: [DummyItem]
}

/// Where Tab can land on the timeline: a query, or the pinned `[+]` pill after the last one.
enum TimelineTabStop: Hashable {
    case query(TimelineQuery)
    case add
}

extension ShellSession {
    /// All, Trends, the reader's in their order, then `[+]` — so adding stays keyboard-reachable.
    var tabStops: [TimelineTabStop] {
        queries.isEmpty ? [] : queries.map(TimelineTabStop.query) + [.add]
    }

    /// Tab and ⇧Tab on the timeline.
    @discardableResult
    func rotateTab(by step: Int) -> Bool {
        guard !queries.isEmpty else { return false }
        let current: TimelineTabStop = addFocused ? .add : .query(currentTimeline)
        switch DummyCommand.advanced(tabStops, from: current, by: step) {
        case .add: addFocused = true
        case .query(let query): timelineID = query
        }
        return true
    }

    /// What the stream draws: the query in front, through the one text index this session holds,
    /// stopped at the reader's latest date (#22).
    ///
    /// Kept until the definition in front, the notes or the latest date change, because one
    /// redraw reads it several times. Sources are no key: the stream compiles without them.
    func timelineItems(latest: LatestDate?) -> [DummyItem] {
        let definition = definition(of: currentTimeline)
        let key = DrawnTimeline.Key(definition: definition, notesRevision: notesRevision, latest: latest)
        if let drawnTimeline, drawnTimeline.key == key { return drawnTimeline.items }
        let readsText = definition.rules.contains { $0.kind.tag == .keyword || $0.kind.tag == .author }
        let items = currentTimeline.items(
            from: notes, among: written, index: readsText ? textIndex : TextIndex([]), latest: latest
        )
        drawnTimeline = DrawnTimeline(key: key, items: items)
        timelineEvaluations += 1
        return items
    }

    func definition(of query: TimelineQuery) -> TimelineDefinition {
        query.definition(among: written)
    }

    /// A tab's name: a written timeline's own, a built-in's from the strings.
    func name(of query: TimelineQuery) -> String {
        guard case .written(let id) = query, let timeline = written.first(where: { $0.id == id }) else {
            return query.name
        }
        return timeline.name
    }

    /// The line under the tabs.
    func rule(of query: TimelineQuery) -> String {
        guard case .written = query else { return query.rule }
        return L10n.count("timeline.rule.written", definition(of: query).rules.count)
    }

    /// Whether a rule of this query names something this device no longer holds.
    func hasMissingRule(_ query: TimelineQuery) -> Bool {
        let compiled = CompiledTimeline(definition(of: query), sources: sources)
        return compiled.definition.rules.contains { compiled.status(of: $0) != .present }
    }

    func showToast(_ text: String) {
        toast = ShellToast(tick: (toast?.tick ?? 0) + 1, text: text)
    }

    /// `e`. Opens the editor on the timeline in front, or a new one where Tab is on `[+]`. All and
    /// Trends answer with a toast and open nothing.
    @discardableResult
    func editCurrentTimeline() -> Bool {
        guard !queries.isEmpty else { return false }
        if addFocused {
            newTimeline()
            return true
        }
        guard case .written(let id) = currentTimeline,
              let index = written.firstIndex(where: { $0.id == id })
        else {
            showToast(L10n.t("timeline.edit.fixed"))
            return true
        }
        edit(TimelineDraft(editing: written[index], at: index, of: written.count))
        return true
    }

    /// The name the remove question asks about: the draft's, or the kept one where the draft's
    /// has been emptied.
    func removeName(of draft: TimelineDraft) -> String {
        draft.canSave ? draft.trimmedName : (written.first { $0.id == draft.id }?.name ?? "")
    }

    /// The `[+]` pill, pressed or reached with Tab and `e`.
    func newTimeline() {
        guard !timelinesUnreadable else {
            showToast(L10n.t("timeline.unreadable"))
            return
        }
        edit(TimelineDraft(new: written.count + 1))
    }

    /// The editor up over `draft`. It owns the keys, so a running reload — which Esc could no
    /// longer reach — is stopped.
    private func edit(_ draft: TimelineDraft) {
        reload.stop()
        editing = draft
    }

    /// Done. The draft replaces its timeline, or joins the reader's, at its place; the tabs follow
    /// and it is put in front.
    func commit(_ draft: TimelineDraft) {
        guard draft.canSave, !timelinesUnreadable else { return }
        var timelines = written.filter { $0.id != draft.id }
        let timeline = TimelineDefinition(id: draft.id, name: draft.trimmedName, rules: draft.rules)
        timelines.insert(timeline, at: min(draft.position, timelines.count))
        keep(timelines)
        editing = nil
        timelineID = .written(draft.id)
    }

    /// Removes one of the reader's timelines. Its posts stay under All; the tab to its left is
    /// put in front where it was.
    func removeTimeline(_ id: TimelineID) {
        guard !timelinesUnreadable, written.contains(where: { $0.id == id }) else { return }
        let removed = TimelineQuery.written(id)
        let left = queries.firstIndex(of: removed).flatMap { $0 > 0 ? queries[$0 - 1] : nil }
        let wasInFront = timelineID == removed
        keep(written.filter { $0.id != id })
        editing = nil
        if wasInFront, let left, queries.contains(left) { timelineID = left }
    }

    private func keep(_ timelines: [TimelineDefinition]) {
        written = timelines
        timelineStore?.save(timelines)
        rebuildQueries()
    }
}

/// One rule being added: what it names, typed or picked, and its effect and scope. Only the
/// factories make the rule, so Add has nothing to offer until they return one.
struct RuleDraft: Equatable {
    let tag: RuleKind.Tag
    var target: RuleTarget?
    var typed = ""
    var effect: RuleEffect = .include
    var scope: RuleScope = .every

    init(_ tag: RuleKind.Tag) {
        self.tag = tag
    }

    func scopes(_ sources: [Source]) -> [RuleScope] {
        target.map { RuleBuilder.scopes(for: $0, sources: sources) } ?? []
    }

    func rule(_ sources: [Source]) -> Rule? {
        target.flatMap { RuleBuilder.rule($0, scope: scope, effect: effect, sources: sources) }
    }

    /// Picks a target, keeping the scope where it is still one of its choices. A category is
    /// picked under one source's heading, so it is that source's to begin with — public, trends
    /// and home too, which every Mastodon offers; `o` widens it.
    mutating func pick(_ picked: RuleTarget, sources: [Source]) {
        target = picked
        if case .author(let handle) = picked { typed = handle }
        let choices = RuleBuilder.scopes(for: picked, sources: sources)
        if case .category(_, let host) = picked, choices.contains(.source(host: host)) {
            scope = .source(host: host)
        } else if !choices.contains(scope) {
            scope = choices.first ?? .every
        }
    }

    mutating func type(_ text: String, sources: [Source]) {
        typed = text
        switch tag {
        case .author: pick(.author(text), sources: sources)
        case .keyword: pick(.keyword(text), sources: sources)
        case .source, .category: break
        }
    }

    /// `j` and `k`: the next or previous of the choices shown, picked.
    mutating func step(_ by: Int, through choices: [RuleTarget], sources: [Source]) {
        guard let next = DummyCommand.stepped(choices, from: target, by: by) else { return }
        pick(next, sources: sources)
    }

    mutating func toggleEffect() {
        effect = effect == .include ? .exclude : .include
    }

    /// `o`: the next scope this target can have, round again after the last.
    mutating func nextScope(_ sources: [Source]) {
        let choices = scopes(sources)
        guard !choices.isEmpty else { return }
        scope = DummyCommand.advanced(choices, from: choices.contains(scope) ? scope : choices[0], by: 1)
    }
}

/// Where in the editor the reader is: the rules, the kinds, or adding one rule of a kind.
enum EditorStage: Equatable {
    case rules
    case kinds
    case form(RuleKind.Tag)
}

/// What a key does inside the editor. The shell's keys never reach the sheet, so these are its own.
enum EditorAction: Equatable {
    case cancel
    case back
    case earlier
    case later
    case addRule
    case nextRule
    case previousRule
    case toggleRule
    case removeRule
    case removeTimeline
    /// The name field, to rename the timeline.
    case focusName
    case pickKind(RuleKind.Tag)
    case nextChoice
    case previousChoice
    case toggleEffect
    case nextScope
    case confirmRule

    /// Escape: one stage back, and on the rules the whole edit cancelled.
    static func escape(at stage: EditorStage) -> EditorAction {
        stage == .rules ? .cancel : .back
    }

    /// Whether Escape reaches the editor as the exit command rather than as a key press. On
    /// macOS a focused field sends the exit command for Escape, so the key press leaves Escape
    /// alone there and every Escape is one step back, never two.
    static let escapeIsExitCommand: Bool = {
        #if os(macOS)
        true
        #else
        false
        #endif
    }()

    /// **A focused field owns every letter**; only Escape and ⌥O go past it — ⌥O so a rule's
    /// scope can be changed while its author or keyword is still being typed. With ⌥ held the
    /// key may arrive as the letter it composes, `ø`.
    static func from(
        _ key: Character, command: Bool = false, option: Bool = false, stage: EditorStage, fieldFocused: Bool
    ) -> EditorAction? {
        if key == KeyEquivalent.escape.character { return escapeIsExitCommand ? nil : escape(at: stage) }
        if option, !command, case .form = stage, key == "o" || key == "ø" { return .nextScope }
        if fieldFocused || option { return nil }
        if command {
            return stage == .rules && key == KeyEquivalent.delete.character ? .removeTimeline : nil
        }
        let down = key == "j" || key == KeyEquivalent.downArrow.character
        let up = key == "k" || key == KeyEquivalent.upArrow.character
        switch stage {
        case .rules:
            switch key {
            case "[": return .earlier
            case "]": return .later
            case "n": return .addRule
            case "m": return .focusName
            case "x": return .toggleRule
            case KeyEquivalent.delete.character: return .removeRule
            default: return down ? .nextRule : up ? .previousRule : nil
            }
        case .kinds:
            guard let digit = key.wholeNumberValue, (1...RuleKind.Tag.allCases.count).contains(digit) else {
                return nil
            }
            return .pickKind(RuleKind.Tag.allCases[digit - 1])
        case .form:
            switch key {
            case "x": return .toggleEffect
            case "o": return .nextScope
            case KeyEquivalent.return.character: return .confirmRule
            default: return down ? .nextChoice : up ? .previousChoice : nil
            }
        }
    }

    /// The keycap strip under each stage: the caps, and the key naming what they do.
    static func strip(for stage: EditorStage) -> [(caps: String, key: String)] {
        switch stage {
        case .rules:
            [("m", "editor.keys.name"), ("[ ]", "editor.keys.move"), ("n", "editor.keys.add"), ("j k", "editor.keys.rule"),
             ("x", "editor.keys.effect"), ("⌫", "editor.keys.remove"), ("⌘⌫", "editor.keys.removeTimeline"),
             ("⌘↩", "editor.keys.done"), ("esc", "editor.keys.cancel")]
        case .kinds:
            [("1–4", "editor.keys.kind"), ("esc", "editor.keys.back")]
        case .form:
            [("j k", "editor.keys.pick"), ("x", "editor.keys.effect"), ("o ⌥O", "editor.keys.scope"),
             ("↩", "editor.keys.confirm"), ("esc", "editor.keys.back")]
        }
    }
}
