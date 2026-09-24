import FediqoCore
import SwiftUI

/// Usage's Sources tab (#234): one `ShellListRow` a source, its posts as the figure and its
/// pictures as the brief — and entering a row opens `UsageSourceDetail`, where everything this
/// device holds from that source is read out and cleared.
///
/// **The readings are handed in, not read here.** `UsagePane` owns the catalogue and disk reads
/// and their `.task`, so the list and the detail are answers about the same reading.
struct UsageSourceList: View {
    let session: ShellSession
    let onDisk: [String: Int]?

    /// The row the lamp is on. Opening is the session's (`usageOpened`), so Escape can close it.
    @State private var lit: String?

    var body: some View {
        Section {
            ForEach(session.sources) { source in
                ShellListRow(
                    id: source.host, title: source.host,
                    brief: UsagePane.picturesLine(source, in: session, onDisk: onDisk),
                    figure: UsagePane.postsLine(session.holdings.posts(host: source.host)),
                    selection: $lit,
                    onOpen: { session.usageOpened = source.host },
                    onStep: step
                ) {
                    UsageSourceMark(source: source)
                }
                .listRowInsets(EdgeInsets())
            }
        } header: {
            Text(L10n.t("prefs.cache"))
        } footer: {
            UsageFooter(line: "usage.cache.line", help: "prefs.cache.footer", about: L10n.t("prefs.cache"))
        }
    }

    /// ↑ and ↓ move the lamp through the sources, and stop at either end.
    private func step(_ by: Int) {
        let hosts = session.sources.map(\.host)
        guard !hosts.isEmpty else { return }
        let at = lit.flatMap { hosts.firstIndex(of: $0) } ?? (by > 0 ? -1 : hosts.count)
        lit = hosts[max(0, min(hosts.count - 1, at + by))]
    }
}

/// Everything this device holds from one source, and the Clear that lets it go (#234).
///
/// **Clear asks, rather than fires** (decision 29): it sets `session.clearing`, the one presenter
/// on `FediqoRootView`, so a Clear here and on Account are one question. The password line is
/// drawn above the press, so a reader has been told a password goes with it before they ask.
///
/// Nothing here is a stranger's words but the **host**, which went through `Host.parse` — see
/// `UsagePane`'s note on the emoji-height rule.
struct UsageSourceDetail: View {
    let session: ShellSession
    let source: Source
    let catalogue: UsagePane.Reading?
    /// Whether the catalogues have been read at all; before then no line is drawn.
    let cataloguesRead: Bool
    let onDisk: [String: Int]?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section { masthead }
        Section {
            if cataloguesRead { catalogueLine }
            reading(Text(UsagePane.postsLine(session.holdings.posts(host: source.host))))
            reading(Text(UsagePane.picturesLine(source, in: session, onDisk: onDisk)))
            postLine
            passwordLine
        } header: {
            Text(L10n.t("prefs.cache"))
        } footer: {
            UsageFooter(line: "usage.cache.line", help: "prefs.cache.footer", about: L10n.t("prefs.cache"))
        }
    }

    /// Back, the source's mark and host, and Clear.
    private var masthead: some View {
        HStack(spacing: ShellSpace.snug) {
            ShellIconButton("chevron.left", name: "usage.source.back") { session.usageOpened = nil }
            UsageSourceMark(source: source)
            Text(source.host)
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: ShellSpace.snug)
            ShellIconButton("trash", name: "prefs.cache.clear", help: "usage.source.clear.help", tone: .alarm) {
                session.clearing = source.host
            }
        }
    }

    /// How many names this server registered and when they were read, in the shell's locale.
    @ViewBuilder
    private var catalogueLine: some View {
        if let catalogue {
            reading(
                Text(String(format: L10n.t("prefs.cache.catalogue"), catalogue.count))
                    + Text(verbatim: " ")
                    + Text(catalogue.fetchedAt, format: .relative(presentation: .named))
            )
        } else {
            reading(Text(L10n.t("prefs.cache.catalogue.none")))
        }
    }

    /// The forum posts held from this server — drawn only for a Discuz!, the one kind this cache
    /// can hold anything for (`ForumThreadRef`). Read off this session's cache, as Clear is.
    @ViewBuilder
    private var postLine: some View {
        if source.kind == .discuz {
            let held = session.posts.holding(host: source.host)
            if held.count == 0 {
                reading(Text(L10n.t("prefs.cache.posts.none")))
            } else {
                reading(
                    Text(L10n.count("prefs.cache.posts", held.count))
                        + Text(verbatim: " · ")
                        + Text(UsagePane.size(held.bytes))
                )
            }
        }
    }

    /// A password held for this server, and a Forget of its own for a reader who wants only that.
    /// Read off `savedHosts` through the session, not off the Keychain, on every draw.
    @ViewBuilder
    private var passwordLine: some View {
        if session.forums.hasPassword(host: source.host) {
            HStack(spacing: ShellSpace.snug) {
                reading(Text(L10n.t("prefs.password.held")))
                Spacer(minLength: ShellSpace.snug)
                ShellIconButton("key.slash", name: "prefs.password.forget", tone: .alarm) {
                    session.forums.forgetPassword(host: source.host)
                }
            }
        }
    }

    private func reading(_ text: Text) -> some View {
        text
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
    }
}

/// A source's mark in Usage: the protocol's drawing where there is one, its shape's glyph where
/// not — the pair Account's rows ask, so one server is one picture on both pages.
struct UsageSourceMark: View {
    let source: Source
    @Environment(\.displayScale) private var displayScale
    @ShellMetric(relativeTo: .callout) private var glyph: CGFloat = 16

    var body: some View {
        SourceMark.drawing(
            source.kind, shape: DummyItem.shape(of: source.kind), points: glyph, scale: displayScale,
            signedIn: false
        )
        .frame(width: glyph, height: glyph)
        .accessibilityHidden(true)
    }
}

/// A section's footer on Usage: one short line, and the long explanation behind its (?).
struct UsageFooter: View {
    let line: String
    let help: String
    let about: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(L10n.t(line))
            .shellFont(.mark)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .shellHelp(help, about: about)
    }
}
