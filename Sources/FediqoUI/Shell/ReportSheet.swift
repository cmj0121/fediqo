import FediqoCore
import SwiftUI

/// The sheet a report is written on (#339), drawn from its value: what kind it is, which of the
/// server's rules it breaks as the server words them, which posts show it, a few words, and —
/// of somebody of another server — whether that server is told too; then Send, or Cancel, which
/// sends nothing. Once sent: what the source said, and what the person may do themselves.
struct ReportSheet: View {
    let said: ReportSaid
    @Binding var draft: ReportDraft
    var onSend: () -> Void
    var onClose: () -> Void
    var onRulesAgain: () -> Void
    var onAfterwards: (PersonAct) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShellSpace.pad) {
                Text(said.title())
                    .shellFont(.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                quiet(said.told())
                if said.isSent {
                    sent
                } else {
                    writing
                }
            }
            .padding(ShellSpace.room)
        }
        .background(ShellChrome.page(colorScheme))
        .frame(minWidth: 340, idealWidth: 460, minHeight: 360, idealHeight: 620)
    }

    @ViewBuilder
    private var writing: some View {
        section(L10n.t("report.category")) {
            ForEach(ReportCategory.allCases, id: \.self) { category in
                ReportChoice(
                    words: ReportSaid.category(category), line: ReportSaid.categoryLine(category),
                    chosen: draft.category == category, many: false
                ) { draft.category = category }
            }
        }
        if said.asksRules {
            section(L10n.t("report.rules")) {
                if let line = said.rulesLine() {
                    HStack(alignment: .firstTextBaseline) {
                        quiet(line)
                        if said.rules == .failed { ShellLinkButton(L10n.t("servers.again"), action: onRulesAgain).fixedSize() }
                    }
                }
                ForEach(said.ruleList) { rule in
                    ReportChoice(words: rule.text, line: rule.hint, chosen: draft.rules.contains(rule.id), many: true) {
                        if draft.rules.contains(rule.id) { draft.rules.remove(rule.id) } else { draft.rules.insert(rule.id) }
                    }
                }
            }
        }
        section(said.postsLine()) {
            ForEach(said.posts) { post in
                ReportChoice(
                    words: post.line.isEmpty ? L10n.t("report.posts.this") : post.line, line: nil,
                    chosen: draft.posts.contains(post.id), many: true
                ) {
                    if draft.posts.contains(post.id) { draft.posts.remove(post.id) } else { draft.posts.insert(post.id) }
                }
            }
        }
        section(L10n.t("report.words")) {
            TextEditor(text: $draft.words)
                .shellFont(.body)
                .scrollContentBackground(.hidden)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: ShellRadius.field).stroke(ShellChrome.hairline(colorScheme)))
                .accessibilityLabel(L10n.t("report.words"))
                .accessibilityValue(said.wordsCount())
            quiet(said.wordsCount())
        }
        if let forward = said.forwardWords() {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Toggle(forward, isOn: $draft.forward)
                    .shellFont(.reading)
                if let line = said.forwardLine() { quiet(line) }
            }
        }
        if let line = said.stageLine() {
            Text(line)
                .shellFont(.meta)
                .foregroundStyle(failed ? ShellChrome.alarm(colorScheme) : ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: ShellSpace.snug) {
            Spacer(minLength: 0)
            Button(L10n.t("board.choose.cancel"), role: .cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(L10n.t("report.send"), action: onSend)
                .tint(ShellChrome.selectInk(colorScheme))
                .disabled(!said.sends)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private var sent: some View {
        if let line = said.stageLine() { quiet(line) }
        if !said.afterwards.isEmpty {
            quiet(L10n.t("report.afterwards"))
        }
        HStack(spacing: ShellSpace.snug) {
            ForEach(said.afterwards, id: \.self) { act in
                Button(PersonActing.name(act)) { onAfterwards(act) }
            }
            Spacer(minLength: 0)
            Button(L10n.t("servers.close"), action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var failed: Bool {
        if case .failed = said.stage { true } else { false }
    }

    private func quiet(_ line: String) -> some View {
        Text(line)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(title)
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// One answer among several: a mark whose shape says whether it is chosen — a round one where
/// only one may be, a square one where several may — its words, and a line under them.
private struct ReportChoice: View {
    let words: String
    let line: String?
    let chosen: Bool
    let many: Bool
    let onChoose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var symbol: String {
        many ? (chosen ? "checkmark.square.fill" : "square") : (chosen ? "largecircle.fill.circle" : "circle")
    }

    var body: some View {
        Button(action: onChoose) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Image(systemName: symbol)
                    .foregroundStyle(chosen ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(words)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let line, !line.isEmpty {
                        Text(line)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .shellFont(.reading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}

/// The report's sheet put up and taken down: **in a modifier of its own**, never in the root's
/// chain of presenters (`test-before-push`).
struct ReportSheetPresenter: ViewModifier {
    let people: ShellPersonPages
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(item: shown, onDismiss: { people.reports.dismissed(people: people, in: session) }) { _ in
            if let said = people.reports.said(people: people, in: session) {
                ReportSheet(
                    said: said, draft: draft,
                    onSend: { Task { await people.reports.send(people: people, in: session) } },
                    onClose: { people.reports.close() },
                    onRulesAgain: { Task { await people.reports.rulesAgain(in: session) } },
                    onAfterwards: { act in people.reports.afterwards(act, people: people, in: session) }
                )
            }
        }
    }

    private var shown: Binding<ShellReports.Open?> {
        Binding(get: { people.reports.open }, set: { if $0 == nil { people.reports.close() } })
    }

    private var draft: Binding<ReportDraft> {
        Binding(get: { people.reports.draft }, set: { people.reports.draft = $0 })
    }
}
