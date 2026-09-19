import FediqoCore
import SwiftUI

/// The sheet a timeline is written in (#27): its name, its place among the reader's timelines,
/// and its rules, grouped the way they are evaluated — any of a kind, and across kinds, hides
/// last — so the list reads as what the timeline does.
///
/// **A draft, applied on Done** (Decision 21). Cancel and Escape on the rules drop it, so a
/// half-built rule never touches the stream. Adding a rule is a second stage in the same frame, so
/// the sheet never resizes: pick a kind, pick what it names from what this device holds, then its
/// effect and scope. **Every control has a key** (`EditorAction`), named in the strip at the foot;
/// a focused field keeps its letters.
struct TimelineEditor: View {
    @Bindable var session: ShellSession
    @State private var draft: TimelineDraft
    @State private var stage: EditorStage = .rules
    @State private var adding = RuleDraft(.source)
    @State private var focusedRule: Rule.ID?
    @State private var confirmingRemove = false
    @FocusState private var focus: Focus?
    @Environment(\.colorScheme) private var colorScheme

    enum Focus: Hashable {
        case keys
        case name
        case text
    }

    init(session: ShellSession, draft: TimelineDraft) {
        self.session = session
        _draft = State(initialValue: draft)
    }

    private var sources: [Source] { session.sources }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            header
            TextField(L10n.t("timeline.name.placeholder"), text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .name)
                .onSubmit { focus = .keys }
            placeLine
            Rectangle().fill(ShellChrome.hairline(colorScheme)).frame(height: ShellSpace.hair)
            switch stage {
            case .rules: rulesStage
            case .kinds: kindsStage
            case .form: RuleForm(
                session: session,
                draft: $adding,
                choices: Self.choices(for: adding, in: session),
                focus: $focus,
                onBack: { perform(.back) },
                onAdd: { perform(.confirmRule) }
            )
            }
            keyStrip
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
                stage: stage,
                fieldFocused: focus == .name || focus == .text
            )
            guard let action else { return .ignored }
            perform(action)
            return .handled
        }
        #if os(macOS)
        // A focused text field takes Escape as a cancel of its own; this is where it lands, and
        // the only place it does (`EditorAction.escapeIsExitCommand`).
        .onExitCommand { perform(EditorAction.escape(at: stage)) }
        #endif
        .confirmationDialog(
            Text(String(format: L10n.t("timeline.remove.title"), session.removeName(of: draft))),
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button(L10n.t("timeline.remove.confirm"), role: .destructive) {
                session.removeTimeline(draft.id)
            }
            Button(L10n.t("board.choose.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("timeline.remove.detail"))
        }
    }

    /// Every rule in the order it is drawn, which is the order `j` and `k` walk.
    private var drawnRules: [Rule] { bands.flatMap(\.rules) }

    private func perform(_ action: EditorAction) {
        switch action {
        case .cancel: session.editing = nil
        case .back:
            switch stage {
            case .rules: session.editing = nil
            case .kinds: stage = .rules
            case .form: stage = .kinds
            }
            focus = .keys
        case .earlier: draft.move(by: -1)
        case .later: draft.move(by: 1)
        case .addRule: stage = .kinds
        case .nextRule: focusedRule = DummyCommand.stepped(drawnRules.map(\.id), from: focusedRule, by: 1)
        case .previousRule: focusedRule = DummyCommand.stepped(drawnRules.map(\.id), from: focusedRule, by: -1)
        case .toggleRule:
            if let focusedRule { draft.toggleEffect(of: focusedRule) }
        case .removeRule:
            guard let removed = focusedRule else { return }
            let ids = drawnRules.map(\.id)
            focusedRule = DummyCommand.stepped(ids, from: removed, by: 1).flatMap { $0 == removed ? nil : $0 }
                ?? DummyCommand.stepped(ids, from: removed, by: -1).flatMap { $0 == removed ? nil : $0 }
            draft.remove(removed)
        case .removeTimeline:
            if !draft.isNew { confirmingRemove = true }
        case .focusName: focus = .name
        case .pickKind(let tag):
            adding = RuleDraft(tag)
            stage = .form(tag)
            focus = tag == .author || tag == .keyword ? .text : .keys
        case .nextChoice: adding.step(1, through: Self.choices(for: adding, in: session), sources: sources)
        case .previousChoice: adding.step(-1, through: Self.choices(for: adding, in: session), sources: sources)
        case .toggleEffect: adding.toggleEffect()
        case .nextScope: adding.nextScope(sources)
        case .confirmRule:
            guard let rule = adding.rule(sources) else { return }
            draft.add(rule)
            focusedRule = rule.id
            stage = .rules
            focus = .keys
        }
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
            Button(L10n.t("board.choose.cancel")) { perform(.cancel) }
            Spacer()
            Text(L10n.t(draft.isNew ? "timeline.new.title" : "timeline.edit.title"))
                .font(ShellType.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            Spacer()
            Button(L10n.t("timeline.done")) { session.commit(draft) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!draft.canSave)
        }
    }

    /// Where it sits among the reader's timelines, and the two moves. Reordering lives here only
    /// (Decision 22).
    private var placeLine: some View {
        HStack(spacing: ShellSpace.snug) {
            Text(String(format: L10n.t("timeline.place"), draft.position + 1, draft.places))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
            Spacer()
            Button(L10n.t("timeline.earlier")) { perform(.earlier) }
                .disabled(!draft.canMoveEarlier)
            Button(L10n.t("timeline.later")) { perform(.later) }
                .disabled(!draft.canMoveLater)
        }
        .font(ShellType.meta)
    }

    private var rulesStage: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: ShellSpace.snug) {
                        if draft.rules.isEmpty {
                            Text(L10n.t("timeline.rules.empty"))
                                .font(ShellType.meta)
                                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        }
                        ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                            bandView(band, joined: index > 0 && band.key != "rule.band.hide")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: focusedRule) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            HStack {
                if !draft.isNew {
                    Button(L10n.t("timeline.remove")) { perform(.removeTimeline) }
                        .buttonStyle(.plain)
                        .font(ShellType.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
                Spacer()
                Button(L10n.t("rule.add")) { perform(.addRule) }
            }
        }
    }

    private struct Band {
        let key: String
        let rules: [Rule]
    }

    /// One band per kind that has includes, in the order they are tried, then the hides.
    private var bands: [Band] {
        var bands = RuleKind.Tag.allCases.compactMap { tag -> Band? in
            let rules = draft.rules.filter { $0.effect == .include && $0.kind.tag == tag }
            return rules.isEmpty ? nil : Band(key: Self.bandKey(tag), rules: rules)
        }
        let hides = draft.rules.filter { $0.effect == .exclude }
        if !hides.isEmpty { bands.append(Band(key: "rule.band.hide", rules: hides)) }
        return bands
    }

    static func bandKey(_ tag: RuleKind.Tag) -> String {
        switch tag {
        case .source: "rule.band.source"
        case .author: "rule.band.author"
        case .keyword: "rule.band.keyword"
        case .category: "rule.band.category"
        }
    }

    private func bandView(_ band: Band, joined: Bool) -> some View {
        let compiled = CompiledTimeline(
            TimelineDefinition(id: draft.id, name: draft.name, rules: draft.rules), sources: sources
        )
        return VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text((joined ? L10n.t("rule.band.and") + " " : "") + L10n.t(band.key))
                .textCase(.uppercase)
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .padding(.horizontal, ShellSpace.snug)
                .padding(.vertical, ShellSpace.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ShellChrome.well(colorScheme), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityAddTraits(.isHeader)
            ForEach(band.rules) { rule in
                RuleRowView(
                    rule: rule,
                    status: compiled.status(of: rule),
                    sources: sources,
                    focused: rule.id == focusedRule,
                    onToggle: { draft.toggleEffect(of: rule.id) },
                    onRemove: { draft.remove(rule.id) }
                )
                .id(rule.id)
            }
        }
    }

    private var kindsStage: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            Button("‹ " + L10n.t("rule.back")) { perform(.back) }
                .buttonStyle(.plain)
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
            HStack(spacing: ShellSpace.tight) {
                ForEach(Array(RuleKind.Tag.allCases.enumerated()), id: \.element) { index, tag in
                    Button { perform(.pickKind(tag)) } label: {
                        Text("\(index + 1)  " + L10n.t(Self.kindKey(tag)))
                            .font(ShellType.meta)
                            .foregroundStyle(ShellChrome.ink(colorScheme))
                            .padding(.horizontal, ShellSpace.snug)
                            .padding(.vertical, ShellSpace.tight)
                            .background(Capsule(style: .continuous).fill(ShellChrome.well(colorScheme)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t(Self.kindKey(tag)))
                }
            }
            Spacer()
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

    /// The keys this stage answers, as the keys list draws them.
    private var keyStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ShellSpace.snug) { keyCaps }
            ScrollView(.horizontal) { HStack(spacing: ShellSpace.snug) { keyCaps } }
                .scrollIndicators(.never)
        }
        .accessibilityHidden(true)
    }

    private var keyCaps: some View {
        ForEach(EditorAction.strip(for: stage), id: \.caps) { line in
            HStack(spacing: ShellSpace.tight) {
                Text(line.caps)
                    .font(ShellType.reading)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .padding(.horizontal, ShellSpace.tight)
                    .background(Capsule(style: .continuous).fill(ShellChrome.well(colorScheme)))
                Text(L10n.t(line.key))
                    .font(ShellType.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            .fixedSize()
        }
    }
}

/// Adding one rule of one kind: what it names, from what this device holds, then its effect and
/// its scope. Add stays off until the factory returns a rule.
private struct RuleForm: View {
    let session: ShellSession
    @Binding var draft: RuleDraft
    let choices: [RuleTarget]
    var focus: FocusState<TimelineEditor.Focus?>.Binding
    var onBack: () -> Void
    var onAdd: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var sources: [Source] { session.sources }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            Button("‹ " + L10n.t(TimelineEditor.kindKey(draft.tag))) { onBack() }
                .buttonStyle(.plain)
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
            if draft.tag == .author || draft.tag == .keyword { field }
            ScrollViewReader { proxy in
                ScrollView { picker.frame(maxWidth: .infinity, alignment: .leading) }
                    .onChange(of: draft.target) { _, target in
                        if let target { proxy.scrollTo(target) }
                    }
            }
            foot
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            TextField(
                draft.tag == .author ? "@user@instance" : L10n.t("rule.keyword.placeholder"),
                text: Binding(get: { draft.typed }, set: { draft.type($0, sources: sources) })
            )
            .textFieldStyle(.roundedBorder)
            .focused(focus, equals: .text)
            .onSubmit {
                // Return adds where the rule is whole, and otherwise hands the keys back.
                if draft.rule(sources) != nil { onAdd() } else { focus.wrappedValue = .keys }
            }
            if draft.tag == .keyword {
                Text(L10n.t("rule.keyword.hint"))
                    .font(ShellType.mark)
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
                        .font(ShellType.name)
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
                Text(label(choice)).font(ShellType.body).foregroundStyle(ShellChrome.ink(colorScheme))
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

    private var foot: some View {
        let scopes = draft.scopes(sources)
        return VStack(alignment: .leading, spacing: ShellSpace.snug) {
            HStack(spacing: ShellSpace.tight) {
                pill(RuleText.effect(.include), on: draft.effect == .include) { draft.effect = .include }
                pill(RuleText.effect(.exclude), on: draft.effect == .exclude) { draft.effect = .exclude }
            }
            if scopes.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: ShellSpace.tight) {
                        ForEach(scopes, id: \.self) { choice in
                            pill(Self.scopeLabel(choice), on: draft.scope == choice) { draft.scope = choice }
                        }
                    }
                }
                .scrollIndicators(.never)
            } else if let only = scopes.first, let host = RuleText.host(of: only) {
                Text(String(format: L10n.t("rule.scope.forced"), host))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            HStack {
                Spacer()
                Button(L10n.t("rule.add.confirm"), action: onAdd)
                    .disabled(draft.rule(sources) == nil)
            }
        }
    }

    static func scopeLabel(_ scope: RuleScope) -> String {
        switch scope {
        case .every: L10n.t("rule.scope.pill.every")
        case .source(let host): String(format: L10n.t("rule.scope.pill.one"), host)
        }
    }

    private func pill(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .lineLimit(1)
                .fixedSize()
                .font(ShellType.meta.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
                .padding(.horizontal, ShellSpace.snug)
                .padding(.vertical, ShellSpace.tight)
                .background(
                    Capsule(style: .continuous)
                        .fill(on ? ShellChrome.selectFill(colorScheme) : ShellChrome.well(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
