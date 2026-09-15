import FediqoCore
import SwiftUI

/// Language, theme, and type — and what this device is holding from each server the reader added.
///
/// The cache section is decision 14's screen. Three caches hold a server's copy between them and
/// none of them is visible from anywhere else in the app, so this is the only place a reader can
/// see what has accumulated in their name, and the only place they can drop it. Each row is an
/// instrument readout rather than a storage-management control: the host, two figures in the type
/// scale's monospaced `reading` role so a column of servers lines up and a fall to zero reads as
/// the column moving, and one button.
///
/// **The section says what it is, in its header, because the figures under it would otherwise
/// lie.** "read 3 hours ago" is a true statement about a catalogue that vanishes the moment the
/// app closes, and it reads as a false one — as though this were a disk cache with a policy —
/// unless the reader is told the run is the whole of its life. Decision 12 is in the header and
/// decision 13's fixed day is in the footer, which is where the reader looks once and not on
/// every row.
///
/// **Clear empties; it does not remove.** The server stays added and its timeline stays the
/// reader's; what goes is this device's copy, and the pictures are read again as they are wanted.
/// See `ShellPictures`, "What Clear means", for why a row still drawn may put a source straight
/// back and why that is the same answer rather than a hole in it.
///
/// The one thing drawn here that a stranger writes is a **host**, and a host goes through
/// `Host.parse` and is not a post's words. That keeps this pane on the safe side of the branch's
/// emoji-height rule: nothing here hugs text that can carry a custom emoji, and no height here is
/// set by text at all. The day anything routes a display name or a server summary through this
/// pane, it joins the at-risk list and any height assertion on it needs a fixture with an emoji.
struct PreferencesPane: View {
    @Environment(DummyPrefs.self) private var prefs
    @Environment(\.colorScheme) private var colorScheme

    /// Optional because the pickers above do not need one and because this pane is reachable
    /// without it — a preview, or a test of language and theme alone. Where there is no session
    /// there are no sources, and a section listing nothing is not drawn.
    @Environment(ShellSession.self) private var session: ShellSession?

    /// The catalogue store is an actor, and a view body cannot await one. Same shape the row
    /// takes: the view owns a little state and its own `.task` fills it, so nothing here reaches
    /// across an isolation boundary while SwiftUI is asking for a body.
    ///
    /// **Optional, and that is not tidiness.** An empty dictionary would say "no server has a
    /// catalogue", which is a different fact from "nobody has looked yet" — and on the first pass
    /// the second is the true one, because the body always draws before the task can run. Drawing
    /// "No emoji names read yet" beside a server whose 154 names are held is a false statement
    /// that corrects itself a frame later, which is the kind of true-looking lie this whole
    /// section was designed against. Until the first read lands, the line is simply not drawn.
    @State private var catalogues: [String: Reading]?

    /// What a screen needs from a catalogue, and nothing that resolves a shortcode —
    /// `EmojiCatalogue.lookup` is deliberately not public, and copying its three public facts out
    /// is what keeps this pane on the right side of that door.
    private struct Reading: Equatable {
        let fetchedAt: Date
        let count: Int
    }

    /// What the catalogue readings are asked again for: a source list that changed, or a Clear.
    ///
    /// **This used to claim nothing else could move them, "because nothing else in this app
    /// fetches a catalogue while Preferences is the page". That was false**, and falsified by
    /// this unit's own header: on iOS compact the pages are tabs and the timeline's tree is alive
    /// behind this one, and on either platform a catalogue commissioned by a join can still be on
    /// the wire when the reader walks here. Neither moves `hosts` or `cleared`, so the reading
    /// would have said "No emoji names held" beside a server whose names landed a second later,
    /// for as long as the pane stayed open.
    ///
    /// What closes it is not a finer `Probe` but `readCatalogues` waiting on the work: see there.
    private struct Probe: Equatable {
        let hosts: [String]
        let cleared: Int
    }

    private var sources: [Source] { session?.sources ?? [] }

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Picker(L10n.t("prefs.language"), selection: $prefs.language) {
                ForEach(DummyLanguage.allCases) { language in
                    Text(L10n.t("prefs.language.\(language.labelKey)")).tag(language)
                }
            }
            Picker(L10n.t("prefs.theme"), selection: $prefs.theme) {
                ForEach(DummyTheme.allCases) { theme in
                    Text(L10n.t("prefs.theme.\(theme.rawValue)")).tag(theme)
                }
            }
            Picker(L10n.t("prefs.fontSize"), selection: $prefs.fontSize) {
                ForEach(DummyFontSize.allCases) { size in
                    Text(L10n.t("prefs.fontSize.\(size.rawValue)")).tag(size)
                }
            }
            held
        }
        .formStyle(.grouped)
        .padding(ShellSpace.snug)
        .task(id: Probe(hosts: sources.map(\.host), cleared: session?.cleared ?? 0)) {
            await readCatalogues()
        }
    }

    @ViewBuilder
    private var held: some View {
        // **Nothing at all, rather than an empty state, when there is no session.** A `Section`
        // always draws, so falling through to the empty branch here would tell a reader who has
        // joined a server to go and add one — under a header promising a readout of what that
        // server left behind, and with the rail summary pointing them at it. The empty state is
        // for a reader who genuinely has no sources; "the shell has not handed this pane its
        // session" is not that, and this pane must not guess which it is looking at.
        if let session { section(session) }
    }

    /// Takes the session rather than reading the optional again, so that everything below it is
    /// written against a session that exists. The nil case is decided once, above.
    @ViewBuilder
    private func section(_ session: ShellSession) -> some View {
        Section {
            if session.sources.isEmpty {
                Text(L10n.t("prefs.cache.empty"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            } else {
                ForEach(session.sources) { source in row(source, in: session) }
            }
        } header: {
            Text(L10n.t("prefs.cache"))
        } footer: {
            Text(L10n.t("prefs.cache.footer"))
                .font(ShellType.mark)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
    }

    private func row(_ source: Source, in session: ShellSession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(source.host)
                    .font(ShellType.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                catalogueLine(for: source)
                pictureLine(source, in: session)
            }
            Spacer(minLength: ShellSpace.snug)
            // No `.accessibilityElement(children: .ignore)` on the row around it. A container
            // collapsed to one element swallows the button's activation, and this branch has
            // shipped that defect twice — announcing a control that does nothing, and leaving a
            // reader with no keyboard no way to act at all.
            Button(L10n.t("prefs.cache.clear")) {
                Task { await session.clear(host: source.host) }
            }
            .accessibilityLabel(
                Text(String(format: L10n.t("prefs.cache.clear.label"), source.host))
            )
        }
        .padding(.vertical, ShellSpace.tight)
    }

    /// How many names this server registered and when they were read. The relative date is a
    /// `Text` format rather than a formatted `String` so it follows the locale the shell is set
    /// to, which is the reader's preference and not the device's.
    @ViewBuilder
    private func catalogueLine(for source: Source) -> some View {
        if let catalogues {
            if let held = catalogues[source.host] {
                reading(
                    Text(String(format: L10n.t("prefs.cache.catalogue"), held.count))
                        + Text(verbatim: " ")
                        + Text(held.fetchedAt, format: .relative(presentation: .named))
                )
            } else {
                reading(Text(L10n.t("prefs.cache.catalogue.none")))
            }
        }
    }

    /// Both picture caches in one figure, because the reader was promised one thing: the pictures
    /// this server's posts are drawn with. Which cache an avatar and a `:blobcat:` happen to live
    /// in is this app's business and not theirs.
    ///
    /// Read off **this session's** caches rather than off `.shared`, so the figures and the
    /// button beside them are answers about the same two objects — see `ShellSession.pictures`.
    @ViewBuilder
    private func pictureLine(_ source: Source, in session: ShellSession) -> some View {
        let shell = session.pictures.holding(host: source.host)
        let emoji = session.emojis.holding(host: source.host)
        let count = shell.count + emoji.count
        let bytes = Int64(shell.bytes + emoji.bytes)
        if count == 0 {
            reading(Text(L10n.t("prefs.cache.pictures.none")))
        } else {
            reading(
                Text(String(format: L10n.t("prefs.cache.pictures"), count))
                    + Text(verbatim: " · ")
                    + Text(bytes, format: .byteCount(style: .memory))
            )
        }
    }

    private func reading(_ text: Text) -> some View {
        text
            .font(ShellType.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
    }

    /// Reads each source's catalogue, **waiting first on a fetch already on its way for it**.
    ///
    /// The wait is what makes this reading true rather than true-at-the-instant-it-ran. A
    /// catalogue is commissioned by the join and lands whenever the server answers — a big
    /// instance's is the largest of the four answers it sends — so it can easily still be on the
    /// wire when the reader walks to this pane, and nothing here would ever look again. `settle`
    /// on a host with nothing in flight is not a wait, so this costs nothing in the ordinary
    /// case; and it cannot hang the pane, because the fetch it waits on is the one the join
    /// already started and its failure is dropped rather than thrown.
    private func readCatalogues() async {
        guard let session else { return }
        var next: [String: Reading] = [:]
        for source in session.sources {
            await session.emoji.settle(host: source.host)
            guard let held = await session.emoji.catalogue(host: source.host) else { continue }
            next[source.host] = Reading(fetchedAt: held.fetchedAt, count: held.count)
        }
        catalogues = next
    }
}
