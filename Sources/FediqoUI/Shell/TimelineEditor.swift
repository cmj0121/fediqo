import FediqoCore
import SwiftUI

/// The sheet a timeline is written in (#27): its name, its place among the reader's timelines,
/// and its rules, grouped the way they are evaluated — any of a kind, and across kinds, hides
/// last — so the list reads as what the timeline does.
///
/// **Two tabs, one style each** (#237): the timeline — its name, description and place — and its
/// rules, a list whose every row opens the rule where it is changed or removed. Every control is
/// a glyph that names itself (`ShellIconButton`).
///
/// **A draft, applied on Done** (Decision 21). Cancel and Escape on the rules drop it, so a
/// half-built rule never touches the stream. Adding or changing a rule is a second stage in the
/// same frame, so the sheet never resizes: pick a kind, pick what it names from what this device
/// holds, then its effect and scope. **Every control has a key** (`EditorAction`), named in the
/// strip at the foot; a focused field keeps its letters.
struct TimelineEditor: View {
    @Bindable var session: ShellSession
    @State private var flow: EditorFlow
    @State private var confirmingRemove = false
    @FocusState private var focus: Focus?
    @Environment(\.colorScheme) private var colorScheme

    enum Focus: Hashable {
        case keys
        case name
        case desc
        case text
    }

    init(session: ShellSession, draft: TimelineDraft) {
        self.session = session
        _flow = State(initialValue: EditorFlow(draft: draft))
    }

    private var sources: [Source] { session.sources }
    private var draft: TimelineDraft { flow.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            header
            ShellTabs(EditorTab.allCases, selected: flow.tab) { select($0) }
            Rectangle().fill(ShellChrome.hairline(colorScheme)).frame(height: ShellSpace.hair)
            switch flow.tab {
            case .timeline: timelineTab
            case .rules: rulesTab
            }
            EditorKeyStrip(stage: flow.stage, changing: flow.changing != nil, tab: flow.tab)
        }
        .padding(ShellSpace.pad)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520, alignment: .topLeading)
        #else
        .presentationDetents([.large])
        #endif
        .background(ShellChrome.page(colorScheme))
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .keys)
        .onAppear { focus = draft.isNew ? .name : .keys }
        .onKeyPress(phases: .down) { press in
            let action = EditorAction.from(
                press.key.character,
                command: press.modifiers.contains(.command),
                option: press.modifiers.contains(.option),
                stage: flow.stage,
                fieldFocused: focus == .name || focus == .desc || focus == .text,
                keysHeld: focus == .keys || (flow.tab == .rules && flow.focusedRule != nil)
            )
            guard let action else { return .ignored }
            perform(action)
            return .handled
        }
        #if os(macOS)
        // A focused text field takes Escape as a cancel of its own; this is where it lands, and
        // the only place it does (`EditorAction.escapeIsExitCommand`).
        .onExitCommand { perform(EditorAction.escape(at: flow.stage)) }
        #endif
        .shellConfirm(
            $confirmingRemove, question: ShellQuestion.removeTimeline(named: session.removeName(of: draft))
        ) { _ in
            session.removeTimeline(draft.id)
        }
    }

    private func select(_ picked: EditorTab) {
        flow.select(picked)
        focus = .keys
    }

    private func perform(_ action: EditorAction) {
        switch action {
        case .cancel: session.editing = nil
        case .back:
            if flow.back() { focus = .keys } else { session.editing = nil }
        case .earlier: flow.draft.move(by: -1)
        case .later: flow.draft.move(by: 1)
        case .switchTab: select(flow.tab.other)
        case .addRule: flow.addRule()
        case .nextRule: flow.step(by: 1)
        case .previousRule: flow.step(by: -1)
        case .toggleRule: flow.toggleLit()
        case .removeRule:
            flow.removeRule()
            if flow.stage == .rules { focus = .keys }
        case .openRule:
            flow.openLit(sources: sources, choices: kindChoices)
            handFocus()
        case .removeTimeline:
            if !draft.isNew { confirmingRemove = true }
        case .focusName:
            flow.tab = .timeline
            handFocus(to: .name)
        case .pickKind(let tag):
            flow.pickKind(tag)
            handFocus()
        case .nextChoice: flow.adding.step(1, through: Self.choices(for: flow.adding, in: session), sources: sources)
        case .previousChoice: flow.adding.step(-1, through: Self.choices(for: flow.adding, in: session), sources: sources)
        case .toggleEffect: flow.adding.toggleEffect()
        case .nextScope: flow.adding.nextScope(sources)
        case .confirmRule:
            flow.confirm(sources: sources)
            if flow.stage == .rules { focus = .keys }
        }
    }

    /// What the lit rule's kind picks from, for opening it where the picker lists it.
    private var kindChoices: [RuleTarget] {
        guard let rule = flow.drawnRules.first(where: { $0.id == flow.focusedRule }) else { return [] }
        return Self.choices(for: RuleDraft(rule.kind.tag), in: session)
    }

    private func open(_ id: Rule.ID) {
        let choices = draft.rules.first { $0.id == id }.map { Self.choices(for: RuleDraft($0.kind.tag), in: session) }
        flow.open(id, sources: sources, choices: choices ?? [])
        handFocus()
    }

    /// The keys handed to the stage now in front — its field where it has one — once what it
    /// draws is there to take them.
    private func handFocus(to field: Focus? = nil) {
        let target = field ?? (flow.wantsField ? .text : .keys)
        Task { @MainActor in focus = target }
    }

    /// What `j` and `k` pick from on a kind's stage: this device's sources, the authors it holds
    /// posts by (narrowed by what is typed), or the categories its sources can be read by.
    static func choices(for draft: RuleDraft, in session: ShellSession) -> [RuleTarget] {
        switch draft.tag {
        case .source:
            return session.sources.map { .source($0.host) }
        case .author:
            let held = RuleBuilder.authors(in: session.notes)
            let key = Fold.handle(draft.typed)
            let narrowed = key.isEmpty || held.contains(key) ? held : held.filter { $0.contains(key) }
            return narrowed.prefix(30).map { .author("@" + $0) }
        case .keyword:
            return []
        case .category:
            return RuleBuilder.categories(in: session.sources, notes: session.notes, signedIn: session.isSignedIn)
                .flatMap { group in group.categories.map { RuleTarget.category($0, on: group.host) } }
        }
    }

    private var header: some View {
        HStack {
            ShellIconButton("xmark", name: "editor.cancel", help: "editor.cancel.help") { perform(.cancel) }
            Spacer()
            Text(L10n.t(draft.isNew ? "timeline.new.title" : "timeline.edit.title"))
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            ShellIconButton("checkmark", name: "timeline.done", help: "timeline.done.help", tone: .lit) {
                session.commit(draft)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!draft.canSave)
        }
    }

    private var timelineTab: some View {
        EditorTimelineTab(
            draft: $flow.draft,
            focus: $focus,
            onMove: { perform($0 < 0 ? .earlier : .later) },
            onRemove: { perform(.removeTimeline) }
        )
    }

    @ViewBuilder
    private var rulesTab: some View {
        switch flow.stage {
        case .rules:
            EditorRulesList(
                draft: draft,
                sources: sources,
                focusedRule: $flow.focusedRule,
                onOpen: open,
                onStep: { perform($0 < 0 ? .previousRule : .nextRule) },
                onAdd: { perform(.addRule) }
            )
        case .kinds:
            EditorKinds(onBack: { perform(.back) }, onPick: { perform(.pickKind($0)) })
        case .form:
            RuleForm(
                session: session,
                draft: $flow.adding,
                choices: Self.choices(for: flow.adding, in: session),
                changing: flow.changed,
                focus: $focus,
                onBack: { perform(.back) },
                onConfirm: { perform(.confirmRule) },
                onRemove: { perform(.removeRule) }
            )
        }
    }

    static func bandKey(_ tag: RuleKind.Tag) -> String {
        switch tag {
        case .source: "rule.band.source"
        case .author: "rule.band.author"
        case .keyword: "rule.band.keyword"
        case .category: "rule.band.category"
        }
    }

    static func kindKey(_ tag: RuleKind.Tag) -> String {
        switch tag {
        case .source: "rule.kind.source"
        case .author: "rule.kind.author"
        case .keyword: "rule.kind.keyword"
        case .category: "rule.kind.category"
        }
    }

    /// The glyph a kind of rule leads with, on its pill and on every rule of it in the list.
    static func kindSymbol(_ tag: RuleKind.Tag) -> String {
        switch tag {
        case .source: "server.rack"
        case .author: "person"
        case .keyword: "text.magnifyingglass"
        case .category: "tray.2"
        }
    }
}

/// The rules, grouped the way they are evaluated: one band per kind that has includes, in the
/// order they are tried, then the hides.
struct EditorBands {
    struct Band {
        let key: String
        let rules: [Rule]
    }

    let bands: [Band]

    init(_ rules: [Rule]) {
        var bands = RuleKind.Tag.allCases.compactMap { tag -> Band? in
            let kind = rules.filter { $0.effect == .include && $0.kind.tag == tag }
            return kind.isEmpty ? nil : Band(key: TimelineEditor.bandKey(tag), rules: kind)
        }
        let hides = rules.filter { $0.effect == .exclude }
        if !hides.isEmpty { bands.append(Band(key: "rule.band.hide", rules: hides)) }
        self.bands = bands
    }
}

/// The timeline tab: what it is called, what it is about, where it sits among the reader's
/// timelines and the two moves — reordering lives here only (Decision 22) — and, for one already
/// kept, its removal.
private struct EditorTimelineTab: View {
    @Binding var draft: TimelineDraft
    var focus: FocusState<TimelineEditor.Focus?>.Binding
    let onMove: (Int) -> Void
    let onRemove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            // A field is read and typed into like everything around it, so it moves with the
            // rest of the scale (#96).
            TextField(L10n.t("timeline.name.placeholder"), text: $draft.name)
                .shellFont(.body)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .name)
                .onSubmit { focus.wrappedValue = .keys }
            TextField(L10n.t("timeline.desc.placeholder"), text: $draft.desc)
                .shellFont(.body)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .desc)
                .onSubmit { focus.wrappedValue = .keys }
            placeLine
            Spacer(minLength: 0)
            if !draft.isNew {
                ShellIconButton("trash", name: "timeline.remove", help: "timeline.remove.help", tone: .alarm) {
                    onRemove()
                }
            }
        }
    }

    private var placeLine: some View {
        HStack(spacing: ShellSpace.tight) {
            Text(String(format: L10n.t("timeline.place"), draft.position + 1, draft.places))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
            Spacer()
            ShellIconButton("arrow.backward", name: "timeline.earlier") { onMove(-1) }
                .disabled(!draft.canMoveEarlier)
            ShellIconButton("arrow.forward", name: "timeline.later") { onMove(1) }
                .disabled(!draft.canMoveLater)
        }
    }
}

/// The rules tab's list: a band heading per group, a row per rule, each row opening its rule.
private struct EditorRulesList: View {
    let draft: TimelineDraft
    let sources: [Source]
    @Binding var focusedRule: Rule.ID?
    let onOpen: (Rule.ID) -> Void
    let onStep: (Int) -> Void
    let onAdd: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            ScrollViewReader { proxy in
                ScrollView { list }
                    .onChange(of: focusedRule) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
            }
            HStack {
                Spacer()
                ShellIconButton("plus", name: "rule.add", help: "rule.add.help") { onAdd() }
            }
        }
    }

    private var list: some View {
        let compiled = CompiledTimeline(
            TimelineDefinition(id: draft.id, name: draft.name, rules: draft.rules), sources: sources
        )
        let bands = EditorBands(draft.rules).bands
        return VStack(alignment: .leading, spacing: ShellSpace.snug) {
            if draft.rules.isEmpty {
                Text(L10n.t("timeline.rules.empty"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                heading(band, joined: index > 0 && band.key != "rule.band.hide")
                ForEach(band.rules) { rule in
                    RuleRowView(
                        rule: rule,
                        status: compiled.status(of: rule),
                        sources: sources,
                        selection: $focusedRule,
                        onOpen: { onOpen(rule.id) },
                        onStep: onStep
                    )
                    .id(rule.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ band: EditorBands.Band, joined: Bool) -> some View {
        Text((joined ? L10n.t("rule.band.and") + " " : "") + L10n.t(band.key))
            .textCase(.uppercase)
            .shellFont(.name)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .padding(.horizontal, ShellSpace.snug)
            .padding(.vertical, ShellSpace.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShellChrome.well(colorScheme), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityAddTraits(.isHeader)
    }
}

/// Which kind of rule to add: a pill per kind, each led by the kind's glyph.
private struct EditorKinds: View {
    let onBack: () -> Void
    let onPick: (RuleKind.Tag) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            ShellIconButton("chevron.backward", name: "rule.back") { onBack() }
            ScrollView(.horizontal) {
                HStack(spacing: ShellSpace.tight) {
                    ForEach(RuleKind.Tag.allCases, id: \.self) { tag in
                        ShellTabPill(
                            L10n.t(TimelineEditor.kindKey(tag)),
                            symbol: TimelineEditor.kindSymbol(tag),
                            selected: false
                        ) { onPick(tag) }
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer()
        }
    }
}

/// The keys this stage answers, as the keys list draws them.
private struct EditorKeyStrip: View {
    let stage: EditorStage
    let changing: Bool
    let tab: EditorTab
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ShellSpace.snug) { caps }
            ScrollView(.horizontal) { HStack(spacing: ShellSpace.snug) { caps } }
                .scrollIndicators(.never)
        }
        .accessibilityHidden(true)
    }

    private var caps: some View {
        ForEach(EditorAction.strip(for: stage, changing: changing, tab: tab), id: \.caps) { line in
            HStack(spacing: ShellSpace.tight) {
                Text(line.caps)
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .padding(.horizontal, ShellSpace.tight)
                    .background(Capsule(style: .continuous).fill(ShellChrome.well(colorScheme)))
                Text(L10n.t(line.key))
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            .fixedSize()
        }
    }
}

/// Adding one rule of one kind, or changing one already written: what it names, from what this
/// device holds, then its effect and its scope. The confirm press stays off until the factory
/// returns a rule. A rule being changed can be removed from here, and the press says which rule.
private struct RuleForm: View {
    let session: ShellSession
    @Binding var draft: RuleDraft
    let choices: [RuleTarget]
    /// The rule as it was kept, where one is being changed.
    let changing: Rule?
    var focus: FocusState<TimelineEditor.Focus?>.Binding
    var onBack: () -> Void
    var onConfirm: () -> Void
    var onRemove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var sources: [Source] { session.sources }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            HStack(spacing: ShellSpace.tight) {
                ShellIconButton("chevron.backward", name: changing == nil ? "rule.back.kinds" : "rule.back") { onBack() }
                Label(L10n.t(TimelineEditor.kindKey(draft.tag)), systemImage: TimelineEditor.kindSymbol(draft.tag))
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .accessibilityAddTraits(.isHeader)
            }
            if draft.tag == .author || draft.tag == .keyword { field }
            ScrollViewReader { proxy in
                ScrollView { picker.frame(maxWidth: .infinity, alignment: .leading) }
                    .onChange(of: draft.target) { _, target in
                        if let target { proxy.scrollTo(target) }
                    }
            }
            RuleFormFoot(draft: $draft, sources: sources, changing: changing, onConfirm: onConfirm, onRemove: onRemove)
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            TextField(
                draft.tag == .author ? "@user@instance" : L10n.t("rule.keyword.placeholder"),
                text: Binding(get: { draft.typed }, set: { draft.type($0, sources: sources) })
            )
            .shellFont(.body)
            .textFieldStyle(.roundedBorder)
            .focused(focus, equals: .text)
            .onSubmit {
                // Return confirms where the rule is whole, and otherwise hands the keys back.
                if draft.rule(sources) != nil { onConfirm() } else { focus.wrappedValue = .keys }
            }
            if draft.tag == .keyword {
                Text(L10n.t("rule.keyword.hint"))
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        }
        .background {
            // ⌥O as a key equivalent, which is seen before the focused field would type `ø`.
            Button("") { draft.nextScope(sources) }
                .keyboardShortcut("o", modifiers: .option)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var picker: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                if case .category(_, let host) = choice, index == 0 || Self.host(of: choices[index - 1]) != host {
                    Text(host)
                        .shellFont(.name)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .accessibilityAddTraits(.isHeader)
                }
                row(choice)
            }
        }
    }

    private static func host(of target: RuleTarget) -> String? {
        if case .category(_, let host) = target { return host }
        return nil
    }

    private func label(_ target: RuleTarget) -> String {
        switch target {
        case .source(let host): host
        case .author(let handle): handle
        case .keyword(let text): text
        case .category(let category, let host): RuleText.categoryName(category, host: host, sources: sources)
        }
    }

    private func row(_ choice: RuleTarget) -> some View {
        let picked = draft.target == choice
        return Button { draft.pick(choice, sources: sources) } label: {
            HStack {
                Text(label(choice)).shellFont(.body).foregroundStyle(ShellChrome.ink(colorScheme))
                Spacer()
                if picked {
                    Image(systemName: "checkmark").foregroundStyle(ShellChrome.phosphor(colorScheme))
                }
            }
            .padding(.horizontal, ShellSpace.snug)
            .padding(.vertical, ShellSpace.hair)
            .background(picked ? ShellChrome.floatFill(colorScheme) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(choice)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The foot of the rule form: its effect, its scope, the confirm press, and — for a rule being
/// changed — its removal, beside the rule it removes.
private struct RuleFormFoot: View {
    @Binding var draft: RuleDraft
    let sources: [Source]
    let changing: Rule?
    let onConfirm: () -> Void
    let onRemove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let scopes = draft.scopes(sources)
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            HStack(spacing: ShellSpace.tight) {
                effectPill(.include, symbol: "eye")
                effectPill(.exclude, symbol: "eye.slash")
            }
            if scopes.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: ShellSpace.tight) {
                        ForEach(scopes, id: \.self) { choice in
                            ShellTabPill(
                                Self.scopeLabel(choice), symbol: Self.scopeSymbol(choice), selected: draft.scope == choice
                            ) { draft.scope = choice }
                        }
                    }
                }
                .scrollIndicators(.never)
            } else if let only = scopes.first, let host = RuleText.host(of: only) {
                Text(String(format: L10n.t("rule.scope.forced"), host))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            HStack(alignment: .center, spacing: ShellSpace.snug) {
                if let changing { removal(changing) }
                Spacer()
                ShellIconButton(
                    changing == nil ? "plus" : "checkmark",
                    name: changing == nil ? "rule.add.confirm" : "rule.change.confirm",
                    tone: .lit,
                    action: onConfirm
                )
                .disabled(draft.rule(sources) == nil)
            }
        }
    }

    private func effectPill(_ effect: RuleEffect, symbol: String) -> some View {
        ShellTabPill(RuleText.effect(effect), symbol: symbol, selected: draft.effect == effect) {
            draft.effect = effect
        }
    }

    /// The bin, and the rule it takes away as it was kept — one element to VoiceOver, so the
    /// press is heard with what it removes.
    private func removal(_ rule: Rule) -> some View {
        HStack(spacing: ShellSpace.tight) {
            ShellIconButton("trash", name: "rule.action.remove", help: "rule.remove.help", tone: .alarm, action: onRemove)
            Text(RuleText.spoken(rule, status: .present, sources: sources))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    static func scopeLabel(_ scope: RuleScope) -> String {
        switch scope {
        case .every: L10n.t("rule.scope.pill.every")
        case .source(let host): String(format: L10n.t("rule.scope.pill.one"), host)
        }
    }

    static func scopeSymbol(_ scope: RuleScope) -> String {
        switch scope {
        case .every: "globe"
        case .source: "server.rack"
        }
    }
}
