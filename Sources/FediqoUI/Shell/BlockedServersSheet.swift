import FediqoCore
import SwiftUI

/// What the sheet of the servers blocked at one source draws, as a value.
struct BlockedServersSaid: Equatable {
    enum Reading: Equatable { case asking, said, failed }
    enum Foot: Equatable { case more, end, failed, stopped }

    let host: String
    var reading: Reading = .asking
    var servers: [String] = []
    /// The rows whose unblocking did not arrive.
    var missed: Set<String> = []
    var foot: Foot?
    var asking = false
    /// How the sign-in stands where it holds less than muting and blocking need.
    var lock: PartWords.Place?
    /// Whether a row offers Unblock.
    var unblocks = false

    func title(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("servers.title", language: language), host)
    }

    /// What stands where rows would, or over them.
    func line(language: DummyLanguage? = nil) -> String? {
        switch reading {
        case .asking: return asking ? String(format: L10n.t("servers.asking", language: language), host) : nil
        case .failed: return String(format: L10n.t("servers.failed", language: language), host)
        case .said: return servers.isEmpty && foot == .end ? String(format: L10n.t("servers.none", language: language), host) : nil
        }
    }

    func lockWords(language: DummyLanguage? = nil) -> String? {
        lock.map { String(format: L10n.t($0.key, language: language), host) }
    }

    func footWords(language: DummyLanguage? = nil) -> String? {
        switch foot {
        case .more: L10n.t("people.foot.more", language: language)
        case .end: String(format: L10n.t("servers.end", language: language), host)
        case .failed: String(format: L10n.t("servers.foot.failed", language: language), host)
        case .stopped: String(format: L10n.t("people.foot.stopped", language: language), host)
        case nil: nil
        }
    }

    func missedWords(_ server: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("servers.unblock.failed", language: language), server, host)
    }

    func unblockSpoken(_ server: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("servers.unblock.spoken", language: language), server, host)
    }
}

/// The sheet of the servers the reader blocks at one source (#314): each a row with its Unblock,
/// the foot that reads on, and what stands where there is nothing to list.
struct BlockedServersSheet: View {
    let said: BlockedServersSaid
    var onUnblock: (String) -> Void
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
                    if let lock = said.lock, let words = said.lockWords() {
                        Button(action: onAsk) {
                            Label(words, systemImage: SourceRow.permissionSymbol)
                                .shellFont(.meta)
                                .foregroundStyle(ShellChrome.markDim(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(!lock.asks)
                        .padding(ShellSpace.pad)
                    }
                    if let line = said.line() { quiet(line, again: said.reading == .failed) }
                    ForEach(said.servers, id: \.self) { server in
                        row(server)
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

    private func row(_ server: String) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: PersonActing.serverBlockedSymbol)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .accessibilityHidden(true)
                Text(server)
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Spacer(minLength: ShellSpace.step)
                if said.unblocks {
                    ShellLinkButton(L10n.t("servers.unblock")) { onUnblock(server) }
                        .accessibilityLabel(said.unblockSpoken(server))
                        .help(said.unblockSpoken(server))
                        .fixedSize()
                }
            }
            if said.missed.contains(server) {
                Text(said.missedWords(server))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.alarm(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ShellSpace.pad)
        .accessibilityElement(children: .contain)
    }
}

/// The sheet put up and taken down: **in a modifier of its own**, never in the root's chain of
/// presenters (`test-before-push`).
struct BlockedServersPresenter: ViewModifier {
    let servers: ShellBlockedServers
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(item: shown) { open in
            if let said = servers.said(at: open.host, in: session) {
                BlockedServersSheet(
                    said: said,
                    onUnblock: { server in Task { await servers.unblock(server, at: open.host, in: session) } },
                    onReadOn: { Task { await servers.readOn(open.host, in: session) } },
                    onAgain: { Task { await servers.again(open.host, in: session) } },
                    onAsk: { session.askFor([.blocks], host: open.host) },
                    onClose: { servers.open = nil }
                )
            }
        }
    }

    private struct Open: Identifiable {
        let host: String
        var id: String { host }
    }

    private var shown: Binding<Open?> {
        Binding(get: { servers.open.map(Open.init) }, set: { if $0 == nil { servers.open = nil } })
    }
}
