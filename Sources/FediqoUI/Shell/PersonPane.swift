import AVKit
import FediqoCore
import SwiftUI

/// Somebody, opened: who they are, and what this device already holds of theirs (#99).
///
/// ## What it is, and the two things it is not
///
/// **Not a source.** The shape is the thread pane's — a way back, a heading, then a list — and
/// that is where the likeness stops. A source has a sign-in, boards, a Clear button and a place on
/// the rail; a person has a face, a name, and whatever of theirs happens to be here. Giving this
/// page any of the first list would make it the source page wearing somebody's face, which #99
/// rules out in as many words.
///
/// **Not a protocol's own profile replayed.** Nothing here is fetched: what is drawn is the store
/// this device already has, filtered to them. A page that asked their instance for the rest would
/// be 0.5.0 arriving early, and it would turn a face into a request to a server the reader did not
/// press anything to reach.
///
/// ## The rows open, and the face on them does not
///
/// A row here opens the conversation that post belongs to, the way a row anywhere else in the
/// app does (#122). It could not, for as long as a person was a layer that sat over the thread:
/// a conversation may not open under the layer it is under, so the one list made of somebody's
/// own posts was the one place where a post was a thing to look at and not a thing to read. The
/// two are one walk now — `ShellWalk` — and leaving the conversation gives this page back,
/// standing on the row it was opened from.
///
/// **The face is still not a press here**, and that is the one thing this page does differently
/// from every other list: it is already this person's page, so a face that opened it would be a
/// control that promises a journey and stands still. Absent, rather than drawn and refused.
struct PersonPane: View {
    let person: DummyPerson
    /// What this device already holds of theirs, newest first. Worked out by
    /// `DummyPerson.held(of:in:)` and handed down, rather than filtered here: the pane draws, and
    /// what counts as theirs is a rule a test can drive without a screen.
    let items: [DummyItem]
    /// Passed through to every row, exactly as the thread pane passes them: a person's list draws
    /// the same four bands the stream does.
    let catalogues: EmojiCatalogueStore
    var catalogueSettled: Bool = false
    let posts: ForumPosts
    @Binding var selectedID: String?
    var marks: (DummyItem) -> Binding<DummyMarks>
    /// Each row's share of #54's acts, asked of the pane above rather than worked out here: the
    /// session holds what decides them and this pane has no session. See `ItemActing`.
    var acting: (DummyItem) -> ItemActing = { _ in ItemActing() }
    @Binding var decks: ShellDecks
    let playback: ShellPlayback
    var onPlayRow: (DummyItem) -> Void
    var onViewRow: (DummyItem) -> Void
    var onTurnRow: (DummyItem) -> Void
    /// A press on a row: the conversation that post belongs to, answered by the root under the
    /// walk's own rule (#122) — the same closure the stream's rows are given.
    var onOpenThread: (String) -> Void
    var jumpToTop: Int
    var onToast: (String) -> Void
    var onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The face at the head of the page. Larger than a row's, because here it is the subject
    /// rather than a fitting beside the words — and scaled with the letters, for the reason every
    /// other fitting in this shell is.
    @ShellMetric(relativeTo: .body) private var faceSide: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            ShellRule()
            heading
            ShellRule()
            list
        }
    }

    /// The way back and the way out of the page, on the line the thread pane puts them on — one
    /// bar, so a reader who has learnt to leave a conversation has learnt to leave this.
    private var bar: some View {
        HStack(spacing: ShellSpace.snug) {
            ShellBackButton("person.back", action: onBack)
            Spacer()
            Text(L10n.t("person.leaveHint"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
    }

    /// Who they are: their face, the name they wrote for themselves, the handle where the shape
    /// has one, and the server this device met them on.
    ///
    /// **The host is named rather than drawn as a way in.** It is the honest answer to "whose
    /// page is this" — a handle is only a name once you know where — and naming it is exactly as
    /// far as a person page may go towards a source without becoming one.
    private var heading: some View {
        HStack(alignment: .center, spacing: ShellSpace.step) {
            face
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                // Their own writing, pictures and all — the same view the row draws a name with,
                // so a name written in emoji reads the same in both places.
                EmojiText(person.name, emojis: person.emojis, host: person.host, role: .name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .lineLimit(1)
                if let handle = person.handle {
                    Text(handle)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(String(format: L10n.t("person.through"), person.host))
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(Self.heldLine(items.count))
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .accessibilityElement(children: .combine)
    }

    /// How much of theirs is here. **A count of what this device holds and never of what they
    /// have written** — the second is a figure only their server could give, and this page does
    /// not ask anybody anything.
    ///
    /// A `static func` over the count rather than a property over `items`, so the sentence can be
    /// asked for without building a pane: a line spelled inside a `View` is a line no test reads.
    static func heldLine(_ count: Int) -> String { L10n.count("person.held", count) }

    /// Their picture, and the plate where the post carried none — the row's own two cases, at the
    /// size this page draws them.
    private var face: some View {
        Group {
            if let url = person.avatarURL {
                RemoteImage(
                    url: url,
                    tier: .deck,
                    // The server this device met them on, never their own instance: decision 14,
                    // and the same reading `DummyItemRow.avatar` makes about the same address.
                    host: person.host,
                    standing: .avatar,
                    alt: nil,
                    speaks: false,
                    radius: DummyItemRow.Box.plate
                )
            } else {
                ShellVacant(standing: .avatar, radius: DummyItemRow.Box.plate)
            }
        }
        .frame(width: faceSide, height: faceSide)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            // **The honest sentence, and it is about this device rather than about them.** A page
            // that said "they have written nothing" would be this app speaking for somebody whose
            // server it has not asked.
            Text(L10n.t("person.none"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(ShellSpace.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            rows
        }
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .id(item.id)
                        if index < items.count - 1 { ShellRule() }
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jumpToTop) { _, _ in
                guard let first = items.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    /// One of theirs.
    ///
    /// **One closure is deliberately nothing.** `onOpenPerson` is nothing because this *is*
    /// their page — a face that opened the page it is already on is a control that promises a
    /// journey and stands still, so it is absent rather than drawn and refused.
    private func row(_ item: DummyItem) -> some View {
        DummyItemRow(
            item: item,
            catalogues: catalogues,
            catalogueSettled: catalogueSettled,
            posts: posts,
            marks: marks(item),
            acting: acting(item),
            selected: item.id == selectedID,
            top: decks.top(of: item.id, of: item.attachments.count),
            lifted: decks.isLifted(item.id),
            player: playback.rowPlayer(for: item, decks: decks),
            // A press lights the row; a second press on the row it is already on opens the
            // conversation, which is `DummyCommand.tapped` and is exactly what a press does on
            // the stream (#122). This page used to answer only the first half.
            onSelect: {
                switch DummyCommand.tapped(item.id, selected: selectedID) {
                case .select: selectedID = item.id
                case .open: onOpenThread(item.id)
                }
            },
            // Lit and opened in one, for the reader who activates a row once.
            onOpen: { onOpenThread(item.id) },
            onOpenPerson: nil,
            onToggleCover: { _ = decks.toggleCover(item.id) },
            onPlay: { onPlayRow(item) },
            onView: { onViewRow(item) },
            onTurn: { onTurnRow(item) },
            onEnded: { playback.stop() },
            onToast: onToast
        )
    }
}
