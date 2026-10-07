import FediqoCore
import SwiftUI

/// Usage's Sources tab (#234): one `ShellListRow` a source — **its mark, its host and the
/// chevron, and nothing else at any width.** The chevron is the way in to the rest: entering a
/// row opens `UsageSourceDetail`, where everything this device holds from that source is read out
/// and cleared.
///
/// **No figure on the row, and the figures are not lost.** How many posts and pictures a source
/// holds is the detail's to say, line by line; the row says them only to VoiceOver (`spoken`),
/// whose reader does not see a chevron and should not have to enter a row to learn it is empty.
/// A host too long for the row loses its middle, so its start and its end are both still read.
///
/// **The readings are handed in, not read here.** `UsagePane` owns the catalogue and disk reads
/// and their `.task`, so the list and the detail are answers about the same reading.
struct UsageSourceList: View {
    let session: ShellSession
    let onDisk: [String: Int]?

    /// The row the lamp is on. Opening is the session's (`usageOpened`), so Escape can close it.
    @State private var lit: String?
    /// The host last opened, handed back by the detail so the lamp is where the reader left.
    let returning: String?

    var body: some View {
        Section {
            ForEach(session.sources) { source in
                row(source, removed: false)
            }
            // The sources removed whose posts stayed (#250), after the ones here: one row each,
            // so the rows still sum to the total on Time. That a source is removed is its
            // detail's to say, with what it holds and how it goes.
            ForEach(Self.removed(session)) { source in
                row(source, removed: true)
            }
            .onAppear { if let returning { lit = returning } }
        } header: {
            ShellSectionHead(title: "prefs.cache", line: "usage.cache.line", help: "prefs.cache.footer")
        }
    }

    /// One source's row: the same three things whether the source is here or removed.
    private func row(_ source: Source, removed: Bool) -> some View {
        ShellListRow(
            id: source.host, title: source.host,
            spoken: Self.spoken(source, in: session, onDisk: onDisk, removed: removed),
            cut: .middle,
            selection: $lit,
            onOpen: { session.usageOpened = source.host },
            onStep: step
        ) {
            UsageSourceMark(source: source)
        }
    }

    /// What VoiceOver hears for a row, since the row draws only the host: the host, then what the
    /// detail would say first — the posts held and the pictures, or, of a source removed, that it
    /// was and the posts that stayed.
    static func spoken(_ source: Source, in session: ShellSession, onDisk: [String: Int]?, removed: Bool) -> String {
        let posts = UsagePane.postsLine(session.holdings.posts(host: source.host))
        let rest = removed
            ? [L10n.t("item.left"), posts]
            : [posts, UsagePane.picturesLine(source, in: session, onDisk: onDisk)]
        return ([source.host] + rest).joined(separator: L10n.t("mark.dim.names"))
    }

    /// The sources no longer here that this device still holds posts from (#250), by host: the
    /// hosts the count knows (`holdings.bySource`, #194) that are not
    /// among the sources, each with the kind its notes were stamped with — nothing else
    /// remembers a removed source. Sorted by host, since nothing else orders them.
    static func removed(_ session: ShellSession) -> [Source] {
        let here = Set(session.sources.map(\.host))
        let kinds = Dictionary(
            (session.notes + session.heldReplies).map { ($0.source.host, $0.source.kind) },
            uniquingKeysWith: { first, _ in first }
        )
        return session.holdings.bySource.keys
            .filter { !here.contains($0) }
            .sorted()
            .map { Source(host: $0, kind: kinds[$0] ?? .unknown) }
    }

    /// The source `host` names on this list: one here, or one removed whose posts stayed.
    static func source(_ host: String, in session: ShellSession) -> Source? {
        session.sources.first { $0.host == host } ?? removed(session).first { $0.host == host }
    }

    /// ↑ and ↓ move the lamp through the sources, and stop at either end.
    private func step(_ by: Int) {
        lit = ShellListStep.stepped(
            session.sources.map(\.host) + Self.removed(session).map(\.host), from: lit, by: by
        )
    }
}

/// What this device holds from a source removed whose posts stayed (#250): that it was removed,
/// the posts, and how they go. **Nothing to do here, so no `…` is drawn** — Remove took
/// everything else with the source, and the posts go by the window, or by a later limit, like
/// any other post.
struct UsageRemovedSourceDetail: View {
    let session: ShellSession
    let source: Source

    var body: some View {
        Section {
            ShellDetailHead(source.host, back: "usage.source.back", onBack: { session.usageOpened = nil }) {
                UsageSourceMark(source: source)
            }
        }
        Section {
            ShellReadingLine(Text(UsagePane.postsLine(session.holdings.posts(host: source.host))))
            ShellReadingLine(Text(L10n.t("usage.removed.line")))
        } header: {
            ShellSectionHead(title: "prefs.cache", line: "item.left", help: "usage.removed.help")
        }
    }
}

/// Everything this device holds from one source (#234), each figure a line of its own: its
/// posts, its pictures, its emoji names, a forum's first posts, and that a password is held.
/// Its posts are everything the store holds from it, and the ones no timeline shows are said
/// apart (#194).
///
/// **What takes something away is behind the masthead's `…`, and asks first.** Clear puts the
/// question a source row's Clear puts on Account (`ShellSession.clearQuestion`), so the two
/// are one question; Forget password puts its own (`ShellQuestion.forgetPassword`), and is drawn
/// dim on a source that holds none. Neither is a button of its own. The password line is drawn
/// on the page, so a reader has been told a password goes with a Clear before they ask.
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

    var body: some View {
        Section { masthead }
        Section {
            if cataloguesRead { catalogueLine }
            ShellReadingLine(Text(UsagePane.postsLine(session.holdings.posts(host: source.host))))
            ShellReadingLine(Text(UsagePane.picturesLine(source, in: session, onDisk: onDisk)))
            postLine
            passwordLine
        } header: {
            ShellSectionHead(title: "prefs.cache")
        }
    }

    /// Back, the source's mark and host, and `…`.
    private var masthead: some View {
        ShellDetailHead(source.host, back: "usage.source.back", onBack: { session.usageOpened = nil }) {
            UsageSourceMark(source: source)
        } trailing: {
            ShellMoreButton(Self.more(source, in: session))
        }
    }

    /// The masthead's `…`: Clear, and Forget password — both take something away, so both are
    /// destructive items that ask first, and a yes is the only way to either act.
    ///
    /// Forget password is always listed: the menu is the same two items on every source, as a
    /// row's marks are. **Dim for one of two reasons, and each is said as itself.** A kind that
    /// never saves a password says this source has none. A forum, which can, and holds none
    /// just now says at the head that no password is saved for it — "this source has none"
    /// would read there as the forum having no such thing.
    static func more(_ source: Source, in session: ShellSession, language: DummyLanguage? = nil) -> ShellMore {
        let host = source.host
        let held = session.forums.hasPassword(host: host)
        let unsaved = !held && savesPassword(source.kind)
        let clear = ShellMoreItem.danger(
            SourceRow.symbol(.clear), L10n.t("prefs.cache.clear", language: language),
            asks: session.clearQuestion(host: host),
            act: { Task { await session.clear(host: host) } }
        )
        let forget = ShellMoreItem.danger(
            "key.slash", L10n.t("prefs.password.forget", language: language),
            look: held ? .live : unsaved ? .dim(.notNow) : .dim(.never),
            asks: ShellQuestion.forgetPassword(host: host, language: language),
            act: { session.forums.forgetPassword(host: host) }
        )
        return .ending(
            in: forget, dimFor: unsaved ? L10n.t("prefs.password.none", language: language) : nil,
            after: [clear]
        )
    }

    /// Whether a source of this kind can have a password saved on this device: a forum signed in
    /// to on its own page (`ForumSessions`), the one kind `postLine` holds anything else for too.
    static func savesPassword(_ kind: ProtocolKind) -> Bool {
        kind == .discuz
    }

    /// How many names this server registered and when they were read, in the shell's locale.
    @ViewBuilder
    private var catalogueLine: some View {
        if let catalogue {
            ShellReadingLine(
                Text(String(format: L10n.t("prefs.cache.catalogue"), catalogue.count))
                    + Text(verbatim: " ")
                    + Text(catalogue.fetchedAt, format: .relative(presentation: .named))
            )
        } else {
            ShellReadingLine(Text(L10n.t("prefs.cache.catalogue.none")))
        }
    }

    /// The forum posts held from this server — drawn only for a Discuz!, the one kind this cache
    /// can hold anything for (`ForumThreadRef`). Read off this session's cache, as Clear is.
    @ViewBuilder
    private var postLine: some View {
        if source.kind == .discuz {
            let held = session.posts.holding(host: source.host)
            if held.count == 0 {
                ShellReadingLine(Text(L10n.t("prefs.cache.posts.none")))
            } else {
                ShellReadingLine(
                    Text(L10n.count("prefs.cache.posts", held.count))
                        + Text(verbatim: " · ")
                        + Text(UsagePane.size(held.bytes))
                )
            }
        }
    }

    /// That a password is held for this server: a line, and no press beside it — forgetting it
    /// is behind `…`. Read off `savedHosts` through the session, not off the Keychain, on every
    /// draw.
    @ViewBuilder
    private var passwordLine: some View {
        if session.forums.hasPassword(host: source.host) {
            ShellReadingLine(Text(L10n.t("prefs.password.held")))
        }
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
