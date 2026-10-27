import FediqoCore
import SwiftUI

/// What the sheet of conversations at one source draws, as a value.
struct DirectsSaid: Equatable {
    enum Reading: Equatable { case asking, said, failed }
    enum Foot: Equatable { case more, failed }

    let host: String
    var reading: Reading = .asking
    var lines: [DirectLine] = []
    var old: Set<String> = []
    var removeFailed: Set<String> = []
    var foot: Foot?
    var asking = false
    var failedBanner = false
    /// How the sign-in stands where it cannot mark one read or remove one.
    var lock: PartWords.Place?

    func title(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("conversations.title", language: language), host)
    }

    func secrecy(language: DummyLanguage? = nil) -> String {
        L10n.t("conversations.secrecy", language: language)
    }

    func line(language: DummyLanguage? = nil) -> String? {
        if failedBanner { return String(format: L10n.t("conversations.failed", language: language), host) }
        switch reading {
        case .asking: return asking || lines.isEmpty ? String(format: L10n.t("conversations.asking", language: language), host) : nil
        case .failed: return String(format: L10n.t("conversations.failed", language: language), host)
        case .said: return lines.isEmpty ? L10n.t("conversations.empty", language: language) : nil
        }
    }

    func lockWords(language: DummyLanguage? = nil) -> String? {
        lock.map { String(format: L10n.t($0.key, language: language), host) }
    }

    func footWords(language: DummyLanguage? = nil) -> String? {
        switch foot {
        case .more: L10n.t("people.foot.more", language: language)
        case .failed: String(format: L10n.t("conversations.failed", language: language), host)
        case nil: nil
        }
    }

    func words(of line: DirectLine, language: DummyLanguage? = nil) -> String {
        line.words.isEmpty ? L10n.t("conversations.noWords", language: language) : line.words
    }

    func who(_ line: DirectLine) -> String {
        let names = line.names.joined(separator: ", ")
        return names.isEmpty ? host : names
    }

    func openSpoken(_ line: DirectLine, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("conversations.open", language: language), who(line))
    }
}

/// The `…` of one conversation: Remove from the list, asked first — or, where the sign-in cannot
/// change the list, the same glyph dim, saying why.
@MainActor
enum DirectsMenu {
    static func question(language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: SourceRow.directsSymbol,
            title: L10n.t("conversations.remove.ask.title", language: language),
            line: L10n.t("conversations.remove.ask.line", language: language),
            help: nil,
            choices: [.init(ShellQuestion.yes, L10n.t("conversations.remove", language: language), role: .destructive)]
        )
    }

    static func more(
        _ line: DirectLine, lock: PartWords.Place?, host: String, onRemove: @escaping () -> Void,
        onAsk: @escaping () -> Void, language: DummyLanguage? = nil
    ) -> ShellMore {
        let name = L10n.t("conversations.remove", language: language)
        guard let lock else {
            return ShellMore(items: [.danger(SourceRow.directsSymbol, name, asks: question(language: language), act: onRemove)])
        }
        let mark = ShellMark(SourceRow.directsSymbol, name, look: .dim(lock.asks ? .askAgain : .notNow))
        let reason = String(format: L10n.t(lock.key, language: language), host)
        return ShellMore(items: [ShellMoreItem.plain(mark, ask: lock.asks ? onAsk : nil, act: {}).because(reason)])
    }
}

/// The sheet of conversations at one source (#326): each a line naming who is in it and its
/// latest words, the foot that reads on, and what stands where there is nothing to list.
struct DirectsSheet: View {
    let said: DirectsSaid
    var onOpen: (String) -> Void
    var onRemove: (String) -> Void
    var onReadOn: () -> Void
    var onAgain: () -> Void
    var onAsk: () -> Void
    var onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(said.title())
                    .shellFont(.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: ShellSpace.step)
                Button(L10n.t("servers.close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(ShellSpace.room)
            ShellRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(said.secrecy())
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(ShellSpace.pad)
                    if let words = said.lockWords(), let lock = said.lock {
                        Button(action: onAsk) {
                            Label(words, systemImage: SourceRow.directsSymbol)
                                .shellFont(.meta)
                                .foregroundStyle(ShellChrome.markDim(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(!lock.asks)
                        .padding(ShellSpace.pad)
                        .accessibilityLabel(words)
                    }
                    if let line = said.line() { quiet(line, again: said.reading == .failed || said.failedBanner) }
                    ForEach(said.lines) { line in
                        row(line)
                        ShellRule()
                    }
                    if let foot = said.footWords() {
                        Button(action: said.foot == .more || said.foot == .failed ? onReadOn : {}) {
                            Text(foot)
                                .shellFont(.meta)
                                .foregroundStyle(said.foot == .more ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkFaint(colorScheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(!(said.foot == .more || said.foot == .failed))
                        .padding(ShellSpace.pad)
                        .accessibilityLabel(foot)
                    }
                }
            }
        }
        .background(ShellChrome.page(colorScheme))
        .frame(minWidth: 320, idealWidth: 420, minHeight: 320, idealHeight: 480)
    }

    private func quiet(_ line: String, again: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(line)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if again { ShellLinkButton(L10n.t("servers.again"), action: onAgain).fixedSize() }
        }
        .padding(ShellSpace.pad)
    }

    private func row(_ line: DirectLine) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: { if line.statusRow != nil { onOpen(line.id) } }) {
                    VStack(alignment: .leading, spacing: ShellSpace.tight) {
                        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
                            Image(systemName: SourceRow.directsSymbol)
                                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                                .accessibilityHidden(true)
                            Text(said.who(line))
                                .shellFont(.reading)
                                .foregroundStyle(ShellChrome.ink(colorScheme))
                            if line.unread {
                                Text(L10n.t("conversations.unread"))
                                    .shellFont(.meta)
                                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            }
                        }
                        Text(said.words(of: line))
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(line.statusRow == nil)
                .accessibilityLabel(said.openSpoken(line))
                ShellMoreButton(DirectsMenu.more(
                    line, lock: said.lock, host: said.host,
                    onRemove: { onRemove(line.id) }, onAsk: onAsk
                ))
            }
            if said.old.contains(line.id) {
                Text(L10n.t("conversations.old"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if said.removeFailed.contains(line.id) {
                Text(L10n.t("conversations.removeFailed"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.alarm(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ShellSpace.pad)
        .accessibilityElement(children: .contain)
    }
}

/// The sheet put up and taken down inside the people presenter's group, never as its own line of
/// the root's chain.
struct DirectsPresenter: ViewModifier {
    let directs: ShellDirects
    let session: ShellSession
    var onOpen: (String) -> Void = { _ in }

    func body(content: Content) -> some View {
        content.sheet(item: shown) { open in
            if let said = directs.said(at: open.id, in: session) {
                DirectsSheet(
                    said: said,
                    onOpen: { id in Task { await directs.open(id, at: open.id, in: session, then: onOpen) } },
                    onRemove: { id in Task { await directs.remove(id, at: open.id, in: session) } },
                    onReadOn: { Task { await directs.readOn(open.id, in: session) } },
                    onAgain: { Task { await directs.again(open.id, in: session) } },
                    onAsk: { session.askFor([.conversations], host: open.id) },
                    onClose: { directs.close() }
                )
            }
        }
    }

    private struct Open: Identifiable {
        let id: String
    }

    private var shown: Binding<Open?> {
        Binding(get: { directs.shown.map { Open(id: $0) } }, set: { if $0 == nil { directs.close() } })
    }
}
