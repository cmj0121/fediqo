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
    var desc: String
    var rules: [Rule]
    /// Where among the reader's timelines it goes, 0 being first after All and Trends.
    var position: Int
    /// How many places there are, this one included.
    let places: Int

    init(new places: Int) {
        id = UUID()
        isNew = true
        name = ""
        desc = ""
        rules = []
        position = places - 1
        self.places = places
    }

    init(editing timeline: TimelineDefinition, at position: Int, of places: Int) {
        id = timeline.id
        isNew = false
        name = timeline.name
        desc = timeline.desc ?? ""
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
extension TimelineDefinition {
    /// Whether any rule reads a post's words or its author, which is what needs the folded text.
    /// All and Trends read none, so drawing or searching them folds nothing.
    var readsText: Bool {
        rules.contains { $0.kind.tag == .keyword || $0.kind.tag == .author }
    }
}

struct DrawnTimeline {
    struct Key: Equatable {
        let definition: TimelineDefinition
        let notesRevision: Int
        let latest: LatestDate?
    }

    let key: Key
    let items: [DummyItem]
}

/// One person's page as last drawn, and what it was drawn from.
///
/// **Keyed on every name `DummyPerson.wrote(_:)` reads**, not on `DummyPerson.id` alone: the id
/// joins the handle *or* the name, so a person known by a handle and a stranger whose bare name
/// spells the same would share one — and one page's posts would be drawn on the other's.
struct HeldByPerson {
    struct Key: Equatable {
        let host: String
        let handle: String?
        let name: String
        let notesRevision: Int
    }

    let key: Key
    let items: [DummyItem]
}

/// One tab's missing-rule mark, and what it was worked out from.
struct MissingRules {
    struct Key: Equatable {
        let definition: TimelineDefinition
        let sources: [Source]
    }

    let key: Key
    let missing: Bool
}

extension ShellSession {
    /// Tab and ⇧Tab on the timeline: All, Trends, then yours. `[+]` is a press, not a stop.
    @discardableResult
    func rotateTab(by step: Int) -> Bool {
        guard !queries.isEmpty else { return false }
        timelineID = DummyCommand.advanced(queries, from: currentTimeline, by: step)
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
        let items = currentTimeline.items(
            from: notes, among: written, index: definition.readsText ? textIndex : TextIndex([]), latest: latest
        )
        drawnTimeline = DrawnTimeline(key: key, items: items)
        timelineEvaluations += 1
        return items
    }

    /// What this device holds under one hashtag, newest first — every timeline's rows and what
    /// is held aside alike (#124) — kept until either changes, for `heldPosts(of:)`'s reason.
    func heldPosts(under tag: PostTag) -> [DummyItem] {
        let key = HeldTag.Key(tag: HeldUnderTag.folded(tag), heldRevision: heldRevision)
        if let drawnTag, drawnTag.key == key { return drawnTag.items }
        let items = HeldUnderTag.held(under: tag, in: searchable)
        drawnTag = HeldTag(key: key, items: items)
        return items
    }

    /// What this device holds of one person, newest first — `DummyPerson.held(of:in:)`, kept
    /// until the notes change, because the page and the keys each read it on every redraw and
    /// every one of those used to walk everything held.
    func heldPosts(of person: DummyPerson) -> [DummyItem] {
        let key = HeldByPerson.Key(
            host: person.host, handle: person.handle, name: person.name, notesRevision: notesRevision
        )
        if let drawnPerson, drawnPerson.key == key { return drawnPerson.items }
        let items = DummyPerson.held(of: person, in: notes)
        drawnPerson = HeldByPerson(key: key, items: items)
        return items
    }

    /// What the open search finds in the timeline in front (#145), or nothing while none is open.
    ///
    /// **One call for the list and the keys.** The pane draws this and `j`, `k` and Return walk
    /// it; two readers each spelling the timeline, the notes and the text index out for
    /// themselves would be two answers to "what did the search find" that could come apart.
    ///
    /// **What is held aside too** (#176): what a search brought back from the sources is held
    /// aside so All does not grow by it, and is found here — through the same rules — with the
    /// network on or off.
    func searched(_ search: ShellSearch, latest: LatestDate?) -> [DummyItem]? {
        search.items(
            in: definition(of: currentTimeline),
            text: searchTextIndex,
            from: searchable,
            revision: heldRevision,
            sources: sources,
            latest: latest
        )
    }

    func definition(of query: TimelineQuery) -> TimelineDefinition {
        query.definition(among: written)
    }

    /// A tab's name: a written timeline's own, a built-in's from the strings.
    func name(of query: TimelineQuery) -> String {
        query.name(among: written)
    }

    /// The line beside the tabs. Empty description keeps the generated rule line, so a
    /// timeline kept before descriptions still has one.
    func rule(of query: TimelineQuery) -> String {
        guard case .written = query else { return query.rule }
        let definition = definition(of: query)
        if let desc = definition.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return desc
        }
        return L10n.count("timeline.rule.written", definition.rules.count)
    }

    /// Whether a rule of this query names something this device no longer holds. Asked for every
    /// tab on every redraw, so the answer is kept per tab until its definition or the sources
    /// change.
    func hasMissingRule(_ query: TimelineQuery) -> Bool {
        let key = MissingRules.Key(definition: definition(of: query), sources: sources)
        if let kept = missingRules[query], kept.key == key { return kept.missing }
        let compiled = CompiledTimeline(key.definition, sources: sources)
        let missing = compiled.definition.rules.contains { compiled.status(of: $0) != .present }
        missingRules[query] = MissingRules(key: key, missing: missing)
        missingRuleEvaluations += 1
        return missing
    }

    func showToast(_ text: String) {
        toast = ShellToast(tick: (toast?.tick ?? 0) + 1, text: text)
    }

    /// `e`. Opens the editor on the timeline in front. All and Trends answer with a toast and
    /// open nothing. Adding is the `[+]` pill, pressed, not a Tab stop.
    @discardableResult
    func editCurrentTimeline() -> Bool {
        guard !queries.isEmpty else { return false }
        guard case .written(let id) = currentTimeline,
              let index = written.firstIndex(where: { $0.id == id })
        else {
            showToast(L10n.t("timeline.edit.fixed"))
            return true
        }
        edit(TimelineDraft(editing: written[index], at: index, of: written.count))
        return true
    }

    /// A pointer on a tab — double-click or long-press — puts it in front, then the same as `e`.
    func editTimeline(_ query: TimelineQuery) {
        timelineID = query
        _ = editCurrentTimeline()
    }

    /// The name the remove question asks about: the draft's, or the kept one where the draft's
    /// has been emptied.
    func removeName(of draft: TimelineDraft) -> String {
        draft.canSave ? draft.trimmedName : (written.first { $0.id == draft.id }?.name ?? "")
    }

    /// The `[+]` pill, pressed.
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
        let timeline = TimelineDefinition(
            id: draft.id, name: draft.trimmedName, rules: draft.rules, desc: draft.desc
        )
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
