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
    var onBack: () -> Void
    /// What their source says of them, where it is one that says who people are (#310). **Handed
    /// none, this page is the page it always was** — what this device holds of theirs, read
    /// through a host, with nothing asked of anybody — and it never asks which it was handed by
    /// looking at the source: the caller knows, and this draws what it was given.
    var said: PersonSaid?
    /// "Try again", where the source could not be asked who they are.
    var onAskAgain: () -> Void = {}
    /// Where their source has not heard of them and they live elsewhere (#319): the press that
    /// asks that source to look them up, where the asking stands, or why there is none.
    var lookUp: SearchLookUpLine?
    var onLookUp: (SearchLookUpLine.Press) -> Void = { _ in }
    /// The foot's press: the stretch of their posts older than what is drawn.
    var onReadOn: () -> Void = {}
    /// The press beside "They moved to …": the page of the account the source says they went
    /// to, asked of that same source.
    var onOpenMoved: ((Person.Moved) -> Void)?
    /// A figure that counts a list of people, pressed (#311): that list's page, answered by
    /// the root as one more step of the walk.
    var onOpenList: ((PeopleList) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    /// Under a finger one press on a row opens it (#303); the lamp here is where the walk left it.
    @Environment(\.shellTouch) private var touch

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
            if let said { saidList(said) } else { list }
        }
    }

    /// The way back and the way out of the page, on the line the thread pane puts them on — one
    /// bar, so a reader who has learnt to leave a conversation has learnt to leave this.
    private var bar: some View {
        HStack(spacing: ShellSpace.snug) {
            ShellBackButton("person.back", action: onBack)
            Spacer()
            ShellKeyHint("person.leaveHint")
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
        let named = Self.named(person, said: said)
        return HStack(alignment: .center, spacing: ShellSpace.step) {
            face
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                // Their own writing, pictures and all — the same view the row draws a name with,
                // so a name written in emoji reads the same in both places. **Once the source
                // has said who they are, the heading is its word and not the row's**: the name,
                // the handle and the face the answer carried — so an answer about somebody else
                // shows as somebody else.
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                    EmojiText(named.name, emojis: named.emojis, host: person.host, role: .name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .lineLimit(1)
                    if said?.person?.locked == true {
                        Image(systemName: "lock")
                            .shellFont(.mark)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .help(PersonSaid.locked())
                            .accessibilityLabel(PersonSaid.locked())
                    }
                }
                if let handle = named.handle {
                    Text(handle)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(Self.viewLine(of: person, said: said))
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .lineLimit(said == nil ? 1 : 2)
            }
            Spacer(minLength: 0)
            // How much of theirs this device holds: the figure of a page that draws what it
            // holds. A page drawing what the source gave says the source's own figures instead.
            if let held = Self.heldLine(items.count, said: said) {
                Text(held)
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .lineLimit(1)
            }
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

    /// The held figure at the heading's far end, or nothing on a page handed what a source says.
    static func heldLine(_ count: Int, said: PersonSaid?) -> String? {
        said == nil ? heldLine(count) : nil
    }

    /// The heading's third line: the host this device read them through, or — on a page handed
    /// what a source says — whose view the page is.
    static func viewLine(of person: DummyPerson, said: PersonSaid?, language: DummyLanguage? = nil) -> String {
        said.map { PersonSaid.whoseView($0.source, person: $0.person, language: language) }
            ?? String(format: L10n.t("person.through", language: language), person.host)
    }

    /// Their picture, and the plate where the post carried none — the row's own two cases, at the
    /// size this page draws them.
    private var face: some View {
        Group {
            if let url = Self.face(of: person, said: said) {
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

    /// Who the heading names: the source's word once it has said who they are — the name and
    /// the handle made fit for a line, and the pictures the name is written in — and what their
    /// row carried until then.
    static func named(_ person: DummyPerson, said: PersonSaid?) -> (name: String, handle: String?, emojis: [CustomEmoji]) {
        guard let subject = said?.person else { return (person.name, person.handle, person.emojis) }
        return (subject.lineName, subject.lineHandle, subject.emojis)
    }

    /// The face the heading draws: the source's own word once it has said who they are —
    /// which may be that they have none — and the one their row carried until then.
    static func face(of person: DummyPerson, said: PersonSaid?) -> URL? {
        said?.person.map(\.avatarURL) ?? person.avatarURL
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

    // MARK: - As the source says

    /// What a page handed the source's word draws under its heading, top to bottom, as one list
    /// that scrolls together: where the asking stands, what the source says of them, their
    /// posts, and what stands under those.
    ///
    /// **Their posts are the source's once it has answered, and what this device holds until
    /// then** — and for good where it did not answer, or has not heard of them: a failure takes
    /// nothing away.
    private func saidList(_ said: PersonSaid) -> some View {
        let shown = said.posts ?? items
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.head).accessibilityHidden(true)
                    if let line = said.stateLine(of: person.handle ?? person.name) {
                        stateLine(line, said: said)
                        ShellRule()
                    }
                    if let lookUp {
                        SearchLookUpView(line: lookUp, onPress: onLookUp)
                            .padding(.horizontal, ShellSpace.pad)
                            .padding(.vertical, ShellSpace.snug)
                        ShellRule()
                    }
                    if let subject = said.person {
                        PersonSaidBlock(
                            person: subject, source: said.source, onOpenMoved: onOpenMoved,
                            lit: selectedID, onOpenList: onOpenList
                        )
                        ShellRule()
                    }
                    if let sentence = Self.emptyLine(said, held: items.count) {
                        quiet(sentence)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .id(item.id)
                        if index < shown.count - 1 { ShellRule() }
                    }
                    if let foot = said.foot {
                        ShellRule()
                        PersonFootRow(foot: foot, source: said.source, onPress: onReadOn)
                    }
                }
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            // The top of the page is what the source says of them, and the first row the keys
            // walk is there (#311): `g` brings that back, and not their first post alone.
            .onChange(of: jumpToTop) { _, _ in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(Self.head, anchor: .top) }
            }
        }
    }

    /// The head of the list a page handed the source's word scrolls: what `g` scrolls back to.
    private static let head = "person.head"

    /// Where the asking stands, and beside a failure the press that asks again.
    private func stateLine(_ line: String, said: PersonSaid) -> some View {
        WordsThenPress(
            words: Text(line)
                .shellFont(.meta)
                .foregroundStyle(said.reading == .asking ? ShellChrome.inkFaint(colorScheme) : ShellChrome.ink(colorScheme)),
            press: Group {
                if said.offersAgain {
                    ShellLinkButton(L10n.t("person.retry"), action: onAskAgain)
                        .disabled(said.askingPosts)
                        .fixedSize()
                }
            }
        )
    }

    /// What stands where posts would and none are drawn, or nothing where some are, or where
    /// their newest are still being asked for. About the source where the source answered with
    /// none, about this device where what it holds is all there is to draw.
    static func emptyLine(_ said: PersonSaid, held: Int, language: DummyLanguage? = nil) -> String? {
        if let posts = said.posts {
            // A suspended account's line has said why already; a stretch that did not come is
            // the foot's to say.
            guard posts.isEmpty, said.foot == nil, said.person?.suspended != true else { return nil }
            return PersonSaid.gaveNone(said.source, counted: said.person?.tally.posts, language: language)
        }
        guard held == 0, said.reading == .unheardOf || said.reading == .failed else { return nil }
        return L10n.t("person.none", language: language)
    }

    private func quiet(_ sentence: String) -> some View {
        Text(sentence)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(ShellSpace.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            acting: acting(item),
            selected: item.id == selectedID,
            top: decks.top(of: item.id, of: item.attachments.count),
            lifted: decks.isLifted(item.id),
            player: playback.rowPlayer(for: item, decks: decks),
            // A press lights the row; a second press on the row it is already on opens the
            // conversation, which is `DummyCommand.tapped` and is exactly what a press does on
            // the stream (#122). This page used to answer only the first half.
            onSelect: {
                switch DummyCommand.tapped(item.id, selected: selectedID, touch: touch) {
                case .select: selectedID = item.id
                case .open: onOpenThread(item.id)
                }
            },
            // Lit and opened in one, for the reader who activates a row once.
            onOpen: { onOpenThread(item.id) },
            onOpenPerson: nil,
            quoteLifted: decks.isQuoteLifted(of: item),
            onToggleQuoteCover: { decks.toggleQuoteCover(of: item) },
            onToggleCover: { _ = decks.toggleCover(item.id) },
            onPlay: { onPlayRow(item) },
            onView: { onViewRow(item) },
            onViewAt: { at in
                decks.show(item.id, at: at, of: item.attachments.count)
                onViewRow(item)
            },
            onTurn: { onTurnRow(item) },
            onEnded: { playback.stop() }
        )
    }
}
