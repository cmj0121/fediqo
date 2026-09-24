import FediqoCore
import Foundation

/// Where the timeline editor is, and every move it makes (#237) — the draft, the tab in front,
/// the stage of the rules tab, the rule the lamp is on, and the rule being added or changed.
///
/// **A value, not a view's scattered state**, so what a key or a press does to the editor is
/// worked out here and read back by a test, and the view only draws it and hands the keyboard
/// to where it now belongs.
struct EditorFlow: Equatable {
    var draft: TimelineDraft
    var tab: EditorTab
    var stage: EditorStage = .rules
    /// The rule the form was opened on, where it is changing one rather than adding.
    var changing: Rule.ID?
    /// Where `j` and `k` rest: `x` and ⌫ act on this rule, and Return opens it.
    var focusedRule: Rule.ID?
    var adding = RuleDraft(.source)

    init(draft: TimelineDraft) {
        self.draft = draft
        tab = EditorTab.first(isNew: draft.isNew)
    }

    /// Every rule in the order it is drawn, which is the order `j` and `k` walk.
    var drawnRules: [Rule] { EditorBands(draft.rules).bands.flatMap(\.rules) }

    /// Whether the stage in front has a field of its own the keyboard belongs in.
    var wantsField: Bool {
        stage == .form(.author) || stage == .form(.keyword)
    }

    /// The rule being changed, as it was kept.
    var changed: Rule? {
        changing.flatMap { id in draft.rules.first { $0.id == id } }
    }

    /// A tab chosen. Leaving the rules mid-way through a rule drops that rule, as Escape would;
    /// the timeline's draft is kept.
    mutating func select(_ picked: EditorTab) {
        guard picked != tab else { return }
        tab = picked
        stage = .rules
        changing = nil
    }

    /// One stage back: from a rule to its kinds, or to the list where a rule was opened from it.
    /// False where there is nowhere back to go and the edit is to be cancelled.
    mutating func back() -> Bool {
        defer { changing = nil }
        switch stage {
        case .rules: return false
        case .kinds: stage = .rules
        case .form: stage = changing == nil ? .kinds : .rules
        }
        return true
    }

    mutating func addRule() {
        tab = .rules
        changing = nil
        stage = .kinds
    }

    mutating func pickKind(_ tag: RuleKind.Tag) {
        adding = RuleDraft(tag)
        stage = .form(tag)
    }

    /// `j` or `k`, bringing the rules in front where they were not.
    mutating func step(by step: Int) {
        tab = .rules
        focusedRule = DummyCommand.stepped(drawnRules.map(\.id), from: focusedRule, by: step)
    }

    /// `x`. From the timeline tab the rules are only brought in front: a rule is not switched
    /// where it cannot be seen.
    mutating func toggleLit() {
        guard tab == .rules else { return tab = .rules }
        if stage == .rules, let focusedRule { draft.toggleEffect(of: focusedRule) }
    }

    /// ⌫: the rule open in the form, or the lit rule of the list. From the timeline tab the
    /// rules are only brought in front.
    mutating func removeRule() {
        guard tab == .rules else { return tab = .rules }
        if case .form = stage, let changing {
            remove(changing)
            self.changing = nil
            stage = .rules
        } else if stage == .rules, let focusedRule {
            remove(focusedRule)
        }
    }

    /// Takes a rule out of the draft, and puts the lamp on its neighbour — the next, or the one
    /// before where it was the last.
    private mutating func remove(_ removed: Rule.ID) {
        let ids = drawnRules.map(\.id)
        focusedRule = DummyCommand.stepped(ids, from: removed, by: 1).flatMap { $0 == removed ? nil : $0 }
            ?? DummyCommand.stepped(ids, from: removed, by: -1).flatMap { $0 == removed ? nil : $0 }
        draft.remove(removed)
    }

    /// Return on the list: the lit rule opened.
    mutating func openLit(sources: [Source], choices: [RuleTarget]) {
        guard tab == .rules else { return tab = .rules }
        if stage == .rules, let focusedRule { open(focusedRule, sources: sources, choices: choices) }
    }

    /// A rule of the list, opened in the form it was added through. `choices` are what its kind
    /// can pick from, so a category for every source is shown where the picker lists it.
    mutating func open(_ id: Rule.ID, sources: [Source], choices: [RuleTarget]) {
        guard let rule = draft.rules.first(where: { $0.id == id }) else { return }
        tab = .rules
        focusedRule = id
        changing = id
        adding = RuleDraft(editing: rule, sources: sources, choices: choices)
        stage = .form(rule.kind.tag)
    }

    /// Add or Change. A changed rule keeps its id and its place; either way the lamp is on it.
    mutating func confirm(sources: [Source]) {
        if let changing {
            guard let rule = adding.rule(sources, id: changing) else { return }
            draft.replace(changing, with: rule)
            focusedRule = rule.id
        } else {
            guard let rule = adding.rule(sources) else { return }
            draft.add(rule)
            focusedRule = rule.id
        }
        changing = nil
        stage = .rules
    }
}
