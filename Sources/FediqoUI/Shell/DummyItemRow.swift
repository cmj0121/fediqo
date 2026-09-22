import AVKit
import FediqoCore
import SwiftUI

/// One item, in four bands of a fixed shape: what happened to it, who wrote it and
/// what it arrived with, the words and the attachment, and what can be done to it.
struct DummyItemRow: View {
    let item: DummyItem
    /// Where a shortcode this post did not bring a picture for is looked up. The row holds the
    /// store rather than an alphabet: see `resolve`.
    let catalogues: EmojiCatalogueStore
    /// Whether this row's own server has answered about its catalogue yet. Set by the pane, which
    /// owns the wait; the row cannot do it itself — see `resolve`. Per host rather than a counter
    /// for the pane, so a slow instance cannot hold up a row reading through a quick one.
    var catalogueSettled: Bool = false
    /// Where a forum thread's opening post is fetched and kept — D30.
    ///
    /// Handed in rather than reached for as a shared instance, for the reason `ShellSession`
    /// holds the two picture caches: what Usage reports and what Clear empties have to be
    /// the same object by construction, and a preview or a test wired to its own cache would
    /// otherwise press one and draw the other.
    let posts: ForumPosts
    @Binding var marks: DummyMarks
    var selected: Bool = false
    /// Whether this row is the post the reader opened **in order to read** — the thread pane, and
    /// nowhere else.
    ///
    /// **The row's one height is not negotiable and this does not negotiate it.** It is a fact
    /// about a *list*: forty rows under a thumb, where a band that grows moves everything below
    /// it and a hostile instance sizing one row is a layout attack that lands on all of them. The
    /// timeline keeps every word of that, and `false` is what every call site there passes.
    ///
    /// The pane is the other case, and F6 already wrote down the answer for it one level down.
    /// `ForumReplyRow` is held to no height at all, and says why: "the timeline's one-height rule
    /// is about a list the reader is scrolling… this pane is what the reader opened in order to
    /// *read*". The opening post is the same case and was not given the same answer — so the post
    /// the reader pressed `Return` on was cut to three lines while the twenty replies under it ran
    /// to whatever length they liked, which is the complaint "the main thread does not load well".
    ///
    /// **It is also what `Return` has always promised.** `DummyCommand.expandPost` is called
    /// *expand* and the guide says "Open the thread"; before this, expanding a post showed the
    /// reader exactly the same three lines the row already had.
    ///
    /// Three things and no fourth: the words lose their line limit, the band stops being pinned
    /// to `Box.thumb` and clipped, and a forum post's quotation is drawn above them (#104) — all
    /// three for the one reason, that a list under a thumb and a post opened to be read are not
    /// the same surface. Everything else about the row — the four bands, the slot, the marks, the
    /// cover — is identical, because none of it was ever the problem.
    var inFull: Bool = false
    /// Which attachment is on top. It belongs to the app rather than to this view, so that a
    /// refresh that replaces the list leaves a reader who turned to the third one looking at the
    /// third one. See `ShellDecks`.
    var top: Int = 0
    /// Whether the reader has taken the author's cover off this row, for this run.
    var lifted: Bool = false
    /// The app's one player, handed to this row only while this row's card is the thing that is
    /// playing. Nothing otherwise — including while the viewer is playing the same file over the
    /// top of it. See `ShellPlayback`.
    var player: AVPlayer?
    var onSelect: (() -> Void)?
    /// Opening the conversation around this post — `Return`, and the second press of a finger on
    /// a row already lit (#33).
    ///
    /// **Held apart from `onSelect` for the one reader who cannot press twice.** A press is what
    /// the list decides between lighting and opening; a reader using VoiceOver lands on the row
    /// and activates it once, so the open has to be offered as a named action of its own. Nothing
    /// where there is nothing to open — the post an open thread is already about says so by
    /// passing nothing, rather than by announcing an action that would be refused.
    var onOpen: (() -> Void)?
    /// Opening whoever wrote this post — a press on their face, or on their name (#99).
    ///
    /// **Optional, and nothing is the honest answer twice over.** A row that names nobody has no
    /// person to open, and a list that is already this person's own page has nowhere to go: both
    /// pass nothing, and what the reader gets is a face that is a picture rather than a control
    /// they can press and be refused. Decision 4's rule — absent, not disabled.
    var onOpenPerson: ((DummyPerson) -> Void)?
    var onToggleCover: () -> Void = {}
    /// Starts or stops what is on top of the deck — the mark on the card's own way to the key `a`.
    var onPlay: () -> Void = {}
    /// Opens what is on top of the deck over the app: the card's own way to the key `v` (#33).
    var onView: () -> Void = {}
    /// Turns the deck: the counter's own way to the key `m` (#33).
    var onTurn: () -> Void = {}
    /// That the playing rectangle has left the screen, which the owner answers by stopping.
    var onEnded: () -> Void = {}
    var onToast: (String) -> Void

    @State private var hovering = false
    @State private var resolved = Written()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// A phone held upright, where the picture beside the words leaves the words a
    /// column four characters wide. Everywhere else the row keeps its full width.
    private var narrow: Bool { sizeClass == .compact }
    #else
    private var narrow: Bool { false }
    #endif

    /// The row's fittings, in points at the standard type size and scaled from there.
    /// They used to be fixed: the words grew with the reader's preference and the
    /// avatar, the thumbnail and every mark stayed exactly where they were, so at the
    /// largest size a row was big text wrapped around small furniture.
    @ShellMetric(relativeTo: .body) private var avatarSide: CGFloat = Box.avatar
    @ShellMetric(relativeTo: .body) private var thumbSide: CGFloat = Box.thumb
    /// The box the audience mark stands in. Tied to the mark's own role rather than to the
    /// caption beside it, so the box and the glyph in it climb together — `ShellMetric`'s
    /// whole point.
    @ShellMetric(relativeTo: .callout) private var vis: CGFloat = Box.vis
    /// The room inside the source pill, on the pill's own rung so the capsule grows with the
    /// host in it rather than closing round it as the letters climb.
    @ShellMetric(relativeTo: .caption2) private var pillSideways: CGFloat = Box.pillSideways
    @ShellMetric(relativeTo: .caption2) private var pillUpright: CGFloat = Box.pillUpright
    @ShellMetric(relativeTo: .caption) private var glyph: CGFloat = 17
    @ShellMetric(relativeTo: .caption) private var countBox: CGFloat = 20
    /// What a finger gets, whatever the glyph drawn inside it measures.
    @ShellMetric(relativeTo: .caption) private var touch: CGFloat = 32
    /// How far a covered row is smeared. Scaled with the words for the same reason every other
    /// fitting here is, and here the reason is not proportion but correctness: a fixed radius that
    /// hides the default size leaves the largest size legible, and a cover that can be read
    /// through is not a cover.
    @ShellMetric(relativeTo: .body) private var smear: CGFloat = 10
    /// How tall the cover is. **A fixed size, and that is the point of it**: a cover drawn around
    /// its contents is a cover that tells the reader how much is underneath, and it would be
    /// server text sizing a band again — the same defect as a row that grows with its post, one
    /// layer down. Whatever the author wrote and however long the post is, the cover is this.
    @ShellMetric(relativeTo: .body) private var coverBox: CGFloat = 44
    /// One body line: the least the notice line takes, so the cover mark standing alone with no
    /// warning beside it leaves the band where a one-line warning would.
    @ShellMetric(relativeTo: .body) private var noticeLine: CGFloat = 22

    enum Box {
        /// The lamp is a lamp at every type size, and a corner is a corner.
        static let lamp: CGFloat = 2
        static let plate: CGFloat = 6
        /// The two fittings that hold a band open against whatever is drawn inside it, and so
        /// the two numbers "every row is the same height" actually rests on. Named here rather
        /// than written into the `@ScaledMetric` defaults above because a test measures a line
        /// against them: a picture standing in a line makes that line taller than the letters
        /// do, and what keeps it off the row is that neither band is sized by its text.
        ///
        /// True of the wide layout. The narrow one below keeps neither fitting — a phone in
        /// portrait sizes the words band to the words, as it did before any of this.
        static let avatar: CGFloat = 36
        static let thumb: CGFloat = 96
        /// What the audience mark is given. Named beside the two above and for the same
        /// reason: a test measures it, and it has to stay wide enough for the glyph the role
        /// below draws — a box that did not grow with the mark would clip it.
        static let vis: CGFloat = 20
        /// The room inside the source pill, sideways and upright.
        ///
        /// **Two numbers and not one, because the ends of a capsule are round.** Equal room on
        /// all four sides puts the first and last letters of the host under the curve, where
        /// the shape has already taken the room back — so a pill padded evenly still reads as
        /// a host against the wall. Twice as much sideways is what makes the room look equal.
        ///
        /// Both are steps off the shell's own scale rather than numbers chosen here. The pill
        /// carried `tight` sideways and two hairs upright, which is a capsule drawn round the
        /// letters rather than round the word.
        ///
        /// **The upright figure is the one with a ceiling.** The meta line stands in the
        /// avatar's band, and a pill taller than the face beside it makes the headline taller
        /// and every row in the list with it. `SourcePillTests` measures that rather than
        /// trusting it.
        static let pillSideways: CGFloat = ShellSpace.snug
        static let pillUpright: CGFloat = ShellSpace.tight
    }

    /// The role the audience mark is drawn in — **a rung up the scale from the line it stands
    /// in, and that is the whole of #97's first half.**
    ///
    /// It was `.meta`, which is the caption the handle beside it takes, at a medium weight. A
    /// glyph drawn at the size of the smallest writing on the row is a fact a reader has to hunt
    /// for, and who a post was written for is not a footnote to it.
    ///
    /// `.name` is the row's own callout — the size the author's name is set in — so the mark
    /// reads at a glance and still sits inside the avatar's band, which is what keeps it on the
    /// meta line rather than making the line taller.
    ///
    /// Named here rather than written into the view, because a test cannot reach inside a `View`
    /// body to ask what size something was drawn at, and "larger than the caption beside it" is
    /// an acceptance line that has to be measurable.
    static let visRole: ShellType = .name

    /// Four bands, and every row has all four whether or not it has anything to put
    /// in them:
    ///
    ///     [decorator                                                            ]
    ///     [avatar][name                   ]     [source][visibility][timestamp  ]
    ///     [words                          ]                        [ attachment ]
    ///     [marks                                                                ]
    ///
    var body: some View {
        // Worked out once for the pass and handed down, not read by each band that wants a
        // piece of it: before the hop below has answered, `written` builds the post's own
        // alphabet and scans every line, and four readers made that four dictionaries and
        // sixteen scans where one and four will do.
        content(written)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.step)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ShellChrome.floatFill(colorScheme) : .clear)
            .overlay(alignment: .leading) { lamp }
            .animation(.easeInOut(duration: 0.18), value: selected)
            .contentShape(Rectangle())
            .onTapGesture { onSelect?() }
            .onHover { hovering = $0 }
            .wayOut(named: item.outwardName, to: item.outwardURL)
            .accessibilityElement(children: .contain)
            .task(id: Asked(item: item, settled: catalogueSettled)) { await resolve() }
    }

    // MARK: - The pictures this post is written in

    /// The pictures each of this row's lines is written in, one short list per line.
    ///
    /// Per line rather than one list for the row, because a line's pictures are decoded at that
    /// line's own ink height: a name and the words are two sizes, and handing both lists to both
    /// would decode every picture twice for the size it is never drawn at.
    ///
    /// **Four lines, and the cover is `item.spoiler`.** Where the author wrote no warning, nothing
    /// is drawn in its place and there is nothing for an alphabet to answer for.
    struct Written: Equatable {
        /// Which post this was resolved for. See `written` for why an unstamped answer is not
        /// good enough.
        var id: String = ""
        var name: [CustomEmoji] = []
        var handle: [CustomEmoji] = []
        var body: [CustomEmoji] = []
        var cover: [CustomEmoji] = []

        init() {}

        init(_ alphabet: EmojiAlphabet, of item: DummyItem) {
            id = item.id
            name = alphabet.emojis(in: item.author)
            handle = alphabet.emojis(in: item.handle ?? "")
            body = alphabet.emojis(in: item.body)
            cover = alphabet.emojis(in: item.spoiler ?? "")
        }
    }

    /// What the row re-asks on: a different post, or this server's catalogue having landed.
    private struct Asked: Equatable {
        let item: DummyItem
        let settled: Bool
    }

    /// The source this post was read through — never the author's own instance. It is what the
    /// reader's per-server Clear button reaches these pictures by, and an emoji address usually
    /// points at a CDN that cannot be read back as a host.
    private var host: String { item.source.host }

    /// What this row's lines are written in: the catalogue's answer once it has one, and the
    /// post's own pictures until then.
    ///
    /// **The own-only half is derived here, in `body`, and that is deliberate.** It needs no
    /// actor — `item.emojis` came with the post — so making it wait for a task dispatch would
    /// draw `:blobcat:` for a frame on every row entry. A `LazyVStack` tears a row down when it
    /// scrolls away and gives it fresh `@State` on the way back, so "one frame" means every time
    /// the reader scrolls past, and it would defeat `EmojiText.pictures(for:)`, which unit 5
    /// built precisely so a line whose pictures are already cached draws them on its first pass.
    /// An empty list leaves that pre-read nothing to find.
    ///
    /// **The own half only.** A shortcode the post brought a picture for is drawn on the first
    /// pass; one that only the reading server's catalogue can answer for still appears after the
    /// hop, because nothing in hand can resolve it. That is unavoidable and right — what the fix
    /// removes is the flash on pictures the post was already carrying.
    ///
    /// The stamp is what makes a stale answer harmless: a resolution belongs to the post it was
    /// made for, so one arriving late for a row that has since been handed a different item is
    /// ignored rather than drawn over it.
    var written: Written {
        resolved.id == item.id ? resolved : Written(EmojiAlphabet(own: item.emojis), of: item)
    }

    /// Asks the store what this server's catalogue adds to the post's own pictures.
    ///
    /// **One actor hop and no waiting.** An earlier version awaited `settle(host:)` here, which
    /// is a bug this row cannot afford: `settle` awaits a `Task<Void, Never>`, and awaiting one
    /// of those ignores the *waiting* task's cancellation, so a row that scrolled away stayed
    /// parked until the server answered — and nothing on this branch sets a request timeout. One
    /// suspended task per row ever drawn, for the life of the process, on a server that drips.
    /// The wait belongs to the pane, which lives as long as the place does; `catalogueSettled` is
    /// how its answer gets back here.
    ///
    /// The order — the post's own pictures first, the server's catalogue behind them — is
    /// `EmojiAlphabet`'s and is not repeated here. This asks; it does not decide.
    private func resolve() async {
        let next = Written(await catalogues.alphabet(own: item.emojis, host: host), of: item)
        // A catalogue that added nothing to this row must not redraw it. A timeline is a hundred
        // rows and most posts spell no name the reading server had to answer for.
        if next != resolved { resolved = next }
    }

    /// Where the reader is. Two points in the row's own margin, and no geometry of its
    /// own — walking the list with j and k must not move the list.
    @ViewBuilder
    private var lamp: some View {
        if selected {
            Rectangle()
                .fill(ShellChrome.phosphor(colorScheme))
                .frame(width: Box.lamp)
        }
    }

    /// The row being read. Its marks come up one notch; nothing appears or disappears.
    private var reading: Bool { selected || hovering }

    private func content(_ written: Written) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            decorator
            // The row itself is an accessibility container, and a container is not an
            // element — a trait put on it is announced to nobody. The headline is the
            // row's identity, so it is the element that carries the selection.
            headline(written)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? .isSelected : [])
                // **On the headline and not on the row**, for the reason stated three lines up:
                // the row is a container, and a container is not an element. A custom action put
                // there is offered to nobody, which is a control that exists in the source and
                // not on the screen — the exact defect this milestone has shipped three times.
                .accessibilityActions {
                    outwardAction
                    openAction
                    personAction
                }
            mainBox(written)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What happened to this post before it got here — that it is a reply, that
    /// somebody passed it on. Drawn only when there is something to say: an empty
    /// line held open on every row costs the list a line per post to say nothing.
    @ViewBuilder
    private var decorator: some View {
        if item.answering != .nothing || item.boostedBy != nil {
            HStack(spacing: ShellSpace.snug) {
                if item.answering != .nothing { answered }
                if let who = item.boostedBy { boosted(by: who) }
            }
            .shellFont(.mark)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .lineLimit(1)
        }
    }

    private var answered: some View {
        HStack(spacing: ShellSpace.tight) {
            Image(systemName: "arrowshape.turn.up.left")
            switch item.answering {
            case .handle(let handle):
                Text(String(format: L10n.t("item.replyingTo"), handle))
            default:
                Text(L10n.t("item.isReply"))
            }
        }
    }

    private func boosted(by who: String) -> some View {
        HStack(spacing: ShellSpace.tight) {
            Image(systemName: "arrow.2.squarepath")
            Text(String(format: L10n.t("item.boostedBy"), who))
        }
    }

    /// Who wrote it at one end, what it arrived with at the other, on one line. The
    /// name gives up letters before the line gives up the meta: where a post came from
    /// and when is what a reader scans down the list for, and a name they can only
    /// half read is still a name they recognise.
    ///
    /// **The face and the name are one control each, and the meta line is not** (#99). Who wrote
    /// a post is a person the reader can open; where it came through and when are facts about the
    /// post, and a press on the host that opened somebody would be the row answering a question
    /// nobody asked.
    private func headline(_ written: Written) -> some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            pressingPerson(avatar)
            pressingPerson(names(written))
            Spacer(minLength: ShellSpace.snug)
            meta
        }
    }

    /// The name is what the row is; the handle is how to find it again. When there is
    /// not room for both, the handle loses its middle rather than the row losing its
    /// edge — an author clipped by the screen is an author nobody can read at all.
    ///
    /// Both are somebody else's writing and both may be written partly in pictures, so both are
    /// drawn by `EmojiText`, which sets the role's own font — `.name` and `.meta` are the two
    /// tokens these lines were already drawn in. Everything else here still comes from outside:
    /// a colour, a line limit and where the truncation falls are facts about this column.
    private func names(_ written: Written) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            EmojiText(item.author, emojis: written.name, host: host, role: .name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
                .layoutPriority(1)
            if let handle = item.handle {
                EmojiText(handle, emojis: written.handle, host: host, role: .meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Nothing in here is pinned to a width any more, but nothing may overflow
    /// either: the host gives way first and truncates, and the age — the one reading
    /// that is useless half-drawn — keeps its own size and its place at the end.
    private var meta: some View {
        HStack(spacing: ShellSpace.snug) {
            sourcePill
                .layoutPriority(0)
            visibility
            postedAgo
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }

    /// The author's own picture, and the plate where there is none.
    ///
    /// Filled rather than fitted: a face in a small square is a face, and the parts of it outside
    /// the square are the parts nobody looks at. That is the opposite of the slot's rule and for
    /// the opposite reason — the slot holds a photograph somebody composed, and this holds a head.
    ///
    /// **The cover does not reach here.** One cover over the row means the author's words and what
    /// they attached; who wrote it is not what `sensitive` is a fact about, and a timeline of
    /// blurred faces would say something about the authors that nobody said.
    ///
    /// **Which address, and where a forum's comes from.** The post's own wherever it brought one,
    /// and for a Discuz! thread it never does: the thread table carries no avatar, so
    /// `DummyItem.avatarURL` is `nil` for every row on every forum this app reads — the reader's
    /// "the user's avatar does not loaded". The picture is on the thread *page*, and D30 already
    /// fetches that page when the row is scrolled to, so it arrives in an answer this row was
    /// waiting for anyway. `ForumPosts.avatar(of:)` is the reader; `DiscuzPost.avatarURL` is where
    /// it was parsed from, on six templates that spell it six ways.
    ///
    /// **Read in `body`, like every other cache read on this row** — `avatar(of:)` stamps
    /// interest, and a read moved out of the body is the I8 failure. The order is the post's own
    /// first: a forum that ever does start sending an avatar with its thread table should win over
    /// a page this device may not have fetched yet, and a microblog row never reaches the second
    /// term at all because it has no `thread`.
    var avatarURL: URL? {
        if let url = item.avatarURL { return url }
        guard let thread else { return nil }
        return posts.avatar(of: thread)
    }

    private var avatar: some View {
        Group {
            if let url = avatarURL {
                RemoteImage(
                    url: url,
                    tier: .deck,
                    // **The source the post arrived through, not the author's own instance.** The
                    // Clear button can only ever name a server the reader added, and an author's
                    // home instance generally is not one — filing an avatar under it would make
                    // exactly the entry no Clear can reach that I10 exists to prevent.
                    host: item.source.host,
                    standing: .avatar,
                    alt: nil,
                    // The row already speaks as a post; an arriving face must not shout too.
                    speaks: false,
                    radius: Box.plate
                )
            } else {
                // Nothing to draw and nothing on its way: the bare plate, which is what this row
                // has always drawn for an author who sent no picture.
                RoundedRectangle(cornerRadius: Box.plate, style: .continuous)
                    .fill(ShellChrome.well(colorScheme))
            }
        }
        .frame(width: avatarSide, height: avatarSide)
    }

    private var postedAgo: some View {
        Text(item.postedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .lineLimit(1)
            .help(exactPostedAt)
            .accessibilityLabel(exactPostedAt)
    }

    private var exactPostedAt: String {
        item.postedAt.formatted(.dateTime.year().month().day().hour().minute().second())
    }

    /// Who the author wrote it for: the glyph says which audience, the colour says how far the
    /// post travels, and the name of it is what a pointer and a screen reader are given.
    ///
    /// **The name is said twice on purpose and read from one place.** `help` is the pointer's
    /// and `accessibilityLabel` is VoiceOver's, and neither can be dropped in favour of the
    /// other — but a glyph is nothing to a listener, so the two must never be allowed to say
    /// different things. `spokenAudience(_:)` is where they both get the string.
    private var visibility: some View {
        Group {
            if let audience = item.audience {
                Image(systemName: audience.symbolName)
                    .shellFont(Self.visRole)
                    .foregroundStyle(ShellChrome.vis(audience, colorScheme))
                    .help(Self.spokenAudience(audience))
                    .accessibilityLabel(Self.spokenAudience(audience))
            }
        }
        .frame(width: vis, height: vis)
    }

    /// What the audience mark is called, in the shell's own language.
    ///
    /// A named function rather than a string built in the view body, for the reason the way out
    /// is one: a label spelled inside a `View` is reachable from no test, and "VoiceOver still
    /// names the audience" is something this branch has to be able to prove rather than assert.
    static func spokenAudience(_ audience: DummyAudience) -> String {
        L10n.t("item.visibility.\(audience.rawValue)")
    }

    /// The servers this row came through: the one it is drawn as, and how many more (#114).
    ///
    /// **Named, and not listed.** A post three servers carried says `first.example +2` rather than
    /// three capsules, because a row is one height and a list of servers along its meta line is
    /// the thing #114 said the row must not become. Every one of them is still named — to a
    /// pointer by `help`, and to a listener by the label — so the count is a shortening of the
    /// drawing and never of the fact. A post one server carried draws its host alone, as it
    /// always has.
    ///
    /// **The room inside it is `Box.pillSideways` and `Box.pillUpright`** — see there for why
    /// the two are different numbers. What is worth saying here is what the room must not do:
    /// the padding is applied to the letters and the capsule is drawn behind the result, so a
    /// row too narrow for the whole host takes it out of the host and never out of the room.
    /// That order is what keeps `lineLimit(1)`'s truncation the thing that gives way.
    ///
    /// **No width and no `fixedSize`, deliberately.** The pill hugs the host it names, so a
    /// short one is not stretched to a size it has nothing to put in, and a long one gives way
    /// before the age does — which is what `layoutPriority(0)` on the meta line says.
    private var sourcePill: some View {
        Text(Self.drawnSource(item))
            .shellFont(.mark)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .padding(.horizontal, pillSideways)
            .padding(.vertical, pillUpright)
            .background(
                Capsule(style: .continuous)
                    .fill(ShellChrome.well(colorScheme))
            )
            .help(Self.spokenSource(item))
            .accessibilityLabel(Self.spokenSource(item))
    }

    /// What the pill names, and so what a listener hears where the headline combines it in.
    ///
    /// The host and nothing else — not the board a forum row sits in, not the protocol drawn as
    /// a page. A named function rather than a string reached for inside the view body, so that
    /// "the pill still names the source" is a sentence a test can put a question to; the same
    /// reason `spokenAudience(_:)` is one.
    ///
    /// **Every source, by name, where a post came through more than one** (#114): a listener
    /// cannot see a count and look further, so what the drawing shortens this says in full.
    static func spokenSource(_ item: DummyItem, language: DummyLanguage? = nil) -> String {
        let others = item.otherCopies.map(\.source.host)
        guard !others.isEmpty else { return item.source.host }
        return String(
            format: L10n.t("item.source.also", language: language),
            item.source.host, others.joined(separator: L10n.t("item.source.join", language: language))
        )
    }

    /// What the pill draws: the host, and how many other servers carried the same post.
    static func drawnSource(_ item: DummyItem, language: DummyLanguage? = nil) -> String {
        guard !item.otherCopies.isEmpty else { return item.source.host }
        return String(
            format: L10n.t("item.source.more", language: language), item.source.host, item.otherCopies.count
        )
    }

    /// What came attached sits beside the words, never under them, and against the
    /// right edge of the row. A picture below the text pushes the next post off the
    /// screen; out on the edge it is a column you can run your eye down.
    /// Two columns of a fixed size. The attachment slot is drawn on every row whether
    /// or not the post brought one, so the words start and stop at the same place all
    /// the way down the list — a column that moves with the content is a column the
    /// eye has to find again on every row.
    ///
    /// A phone has no room for the second column, so it keeps the stack, and an empty
    /// slot there would be most of a screen of nothing.
    @ViewBuilder
    private func mainBox(_ written: Written) -> some View {
        if narrow {
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                // **A post that arrives with the list may size its row; a post that arrives
                // after the row is on screen may not.** That is the whole of the rule, and it is
                // what splits these two branches.
                //
                // A phone in portrait sizes the words band to the words — deliberately, and
                // since before any of this: there is no room for a second column, and a long
                // post has always made a tall row here. That is harmless because the row is
                // drawn once, at its final height, before the reader ever sees it.
                //
                // A forum thread's opening post is the case where it stops being harmless. It
                // lands a beat after the row is on screen, under the thumb that is scrolling the
                // list, and a band that grew when it landed would push everything below it —
                // which is the one thing this unit is not allowed to do. So this kind of row
                // takes the wide layout's fitting on a phone as well: the same `Box.thumb` band,
                // held open and clipped, so the four states measure one height on every
                // platform. The cost, stated: a long first post is truncated on a phone where a
                // long microblog post is not, and the rest of it is one press away in the
                // thread — which is what `bodyLines` says about the wide layout too.
                // **`inFull` is the pane, and the pane is not a list under a thumb.** The
                // sentence above — a post that arrives after the row is on screen may not size
                // it — is a rule about the timeline; in the thread pane there is one post, the
                // reader opened it to read it, and holding it to 96pt on a phone would truncate
                // the one thing they asked for. See `inFull`.
                if thread != nil, !inFull {
                    coveredWords(written)
                        .frame(height: thumbSide, alignment: .top)
                        .clipped()
                } else {
                    coveredWords(written)
                }
                if item.hasThumb { coveredThumb }
            }
        } else if inFull {
            // The two columns, and neither of them pinned. Top-aligned rather than height-locked,
            // so the words run to their own length beside a slot that keeps its square.
            HStack(alignment: .top, spacing: ShellSpace.step) {
                coveredWords(written)
                coveredThumb
            }
        } else {
            HStack(alignment: .top, spacing: ShellSpace.step) {
                coveredWords(written)
                coveredThumb
            }
            .frame(height: thumbSide, alignment: .top)
            // The frame fixes what this band *takes*; this fixes what it can *draw*. A fixed
            // frame does not stop a child rendering outside it, so the worst case the line limit
            // still allows — the longest warning an instance may send, with the words under it —
            // would have drawn over the marks below rather than made the row taller. Both halves
            // are needed for "server text never changes a row's height" to mean anything.
            .clipped()
        }
    }

    /// Whether the blur is on: the author put a cover here and the reader has not taken it off.
    /// Distinct from `item.covered`, which is whether there is a cover at all — the notice is
    /// drawn in both states and only this one blurs anything.
    private var covered: Bool { item.covered && !lifted }

    /// The author's line above, the words below.
    ///
    /// **A band, not an overlay, and it does not go away when the row is lifted.** The spoiler
    /// line is the author's own text and belongs on the post either way. Putting the cover back is
    /// still `s`; this band does not print a second label for that.
    ///
    /// **Blurred words are still words.** A `Text` behind a blur is in the accessibility tree and
    /// on the pasteboard, so a cover made of blur alone hides the post from the reader who can see
    /// it and from nobody else. The blur is what a covered row *looks* like; the two lines under
    /// it are what it *is*. `textSelection` is set even though nothing here turns selection on
    /// today: it is a standing answer, so that enabling selection somewhere above this row cannot
    /// quietly make the covered ones copyable.
    ///
    /// **The wrapper is enough, and that was measured rather than argued.** The words are an
    /// `EmojiText` now, which names itself — `.accessibilityElement(children: .ignore)` and a
    /// label of what the author typed — so this modifier is one put *round* a view that asked to
    /// be an element, which is the shape this branch has twice found to discard something real.
    /// It was checked against the running app: on one covered row, with no leaf hide compiled in
    /// at all, the words were absent from the tree while covered and present the moment the row
    /// was lifted. So `accessibilityHidden` does reach a self-naming leaf, and `coveredThumb`
    /// below — `RemoteImage` self-names identically — is covered by the same finding rather than
    /// by luck. **Measured on macOS only**: no iOS test runs on this branch.
    ///
    /// The blur itself, and the clipping a blur needs, are `cover`'s below: what this function
    /// owns is the order of the two bands and which of them is drawn.
    @ViewBuilder
    private func coveredWords(_ written: Written) -> some View {
        if item.covered {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                notice(written)
                if covered { cover(written) } else { stitched(written) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            words(written)
        }
    }

    /// The cover: one rectangle of a fixed size with the words smeared inside it, and nothing
    /// drawn over them.
    ///
    /// **Nothing is printed on the cover, by the reader's own call.** A key cap centred on the
    /// smear was drawn here first; what it cost was that the one shape whose whole job is to say
    /// *you are not meant to read this yet* had a control sitting in the middle of it. A cover
    /// says more with nothing on it.
    ///
    /// **The whole rectangle is the way in instead.** Pressing a covered post to uncover it is
    /// what every other client of this network does, so it is the gesture a reader arrives
    /// already knowing — and it is not decoration that can be removed later without thought: on a
    /// phone there is no `s` to fall back on, and the band's accessibility action reaches only a
    /// reader using assistive technology. Without this, a covered post on a phone could not be
    /// opened at all.
    ///
    /// **And the words under it are letters, not prose.** `words` draws them from the label cut
    /// while the cover is on — see `EmojiText.words` — so there is no link run, no context menu
    /// and no tooltip behind the blur. Without that the sentence above was not true: a `Text`
    /// carrying an address is hit-tested by the text layer before the `Button` round it, so a
    /// press meant to lift the cover opened the author's page, and a secondary press listed the
    /// hosts the warning was put in front of and offered to open them. Both are the author's
    /// choice, made out of a post the reader had said they were not ready to read.
    ///
    /// **Pressed but not spoken.** The band above is already one element carrying the whole of
    /// `spokenCover` and the action that works it, so announcing this too would offer the same
    /// cover twice over. The blur keeps `accessibilityHidden` for its own reason — the words
    /// behind it must not be readable out of a cover the author put there.
    ///
    /// Clipped twice over, and both are wanted: the rounded shape is what the eye reads as a
    /// panel rather than a smudge against the margin, and `clipped` is the standing answer to a
    /// blur painting outside the box it was given.
    private func cover(_ written: Written) -> some View {
        Button(action: onToggleCover) {
            words(written)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .blur(radius: smear)
                .accessibilityHidden(true)
                .textSelection(.disabled)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity)
        .frame(height: coverBox)
        .background(ShellChrome.well(colorScheme))
        // The guard plate's hatch over the smear, and still nothing printed on it. It takes no
        // press, so the rectangle stays the way in.
        .overlay {
            Hatch()
                .stroke(ShellChrome.hatch(colorScheme), lineWidth: ShellSpace.hair)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Box.plate, style: .continuous))
        .clipped()
    }

    /// The words once the reader has lifted the cover, with a 2pt hatch-ink rule down their
    /// leading edge: which part was under the cover. Not the row lamp, which is phosphor at the
    /// row's own edge and means where the reader is.
    private func stitched(_ written: Written) -> some View {
        words(written)
            .padding(.leading, ShellSpace.snug)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(ShellChrome.hatch(colorScheme))
                    .frame(width: Box.lamp)
                    .accessibilityHidden(true)
            }
    }

    /// The slot, smeared with the same hand as the words. One cover over the row means one
    /// radius: two blurs of different strengths would read as two covers.
    ///
    /// Clipped back to the card's own corner rather than to a rectangle. A blur takes the rounded
    /// edge with it, and what was left was a hard-cornered smudge against the row's margin — a
    /// covered picture should still look like the picture it is covering.
    @ViewBuilder
    private var coveredThumb: some View {
        if covered {
            thumb
                .blur(radius: smear)
                .clipShape(RoundedRectangle(cornerRadius: Box.plate, style: .continuous))
                // The same hatch as the words' cover, so a covered picture reads as covered with
                // no words beside it. Only over a picture: an empty slot hatched would be a
                // cover over nothing.
                .overlay { if item.hasThumb { hatchedPlate } }
                // And hidden, for the same reason the words are. What the author wrote for
                // somebody who cannot see the picture describes the picture — read out from
                // behind the cover, it is the cover lifted for exactly the reader who cannot
                // lift it back. The notice names what is under there without describing it.
                .accessibilityHidden(true)
                // And unpressable. The play mark on the card is a real button, and behind a blur
                // it would start a film the reader has not agreed to see — the same fault as
                // reading the alt text out from behind the cover, arriving through the pointer
                // instead of through the screen reader.
                .allowsHitTesting(false)
        } else {
            thumb
        }
    }

    private var hatchedPlate: some View {
        let plate = RoundedRectangle(cornerRadius: Box.plate, style: .continuous)
        return Hatch()
            .stroke(ShellChrome.hatchOverPicture, lineWidth: ShellSpace.hair)
            .clipShape(plate)
            .overlay { plate.strokeBorder(ShellChrome.hatch(colorScheme), lineWidth: ShellSpace.hair) }
    }

    /// The mark that says covered, the author's warning beside it where they wrote one, and the
    /// key that takes the cover off or puts it back.
    ///
    /// **Where the author wrote no warning, the mark stands alone.** A sentence of ours in that
    /// place reads as the author's own words, which is what it used to do. The line is held to one
    /// body line's height either way, so a mark alone does not change the band.
    ///
    /// One control with two labels. It is a button as well as a key: a reader who never touches
    /// the keyboard would otherwise be told which key works and have no way to press it, and on a
    /// phone there is no `s` to be told about at all.
    private func notice(_ written: Written) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                CoverChip(lifted: !covered)
                if coverIsTheAuthors { warning(written) }
            }
            .frame(minHeight: noticeLine, alignment: .leading)
            // Covered, nothing is drawn: the smear below is itself the way in, and printing a
            // control over the one shape that means "not yet" undoes what the shape says. Lifted,
            // `s` still puts the cover back; this band does not say so.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Ignored rather than combined, and then said properly: combining would read the key cap
        // out as the letter "s" in the middle of a sentence.
        //
        // **Ignoring the children throws the real button's activation away with them**, and a
        // hand-added `.isButton` trait with nothing behind it is a control that announces itself
        // and then does nothing when it is pressed. On a phone there is no `s` to fall back on,
        // so without this action a reader using VoiceOver could not uncover a post at all — the
        // one reader decision 6 is most for, with no way in.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenCover)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { onToggleCover() }
    }

    /// How many lines the author's line may have: two fewer than the words are allowed, because
    /// the cover below takes a fixed bite of the band. Derived from the words' own rule rather
    /// than chosen, so the two cannot drift apart — and one line shorter than it was, because the
    /// cover is now a rectangle of its own rather than whatever space the warning left over.
    ///
    /// It was two fewer when the key cap was centred on the cover as well, and it stays two fewer
    /// now that nothing is printed there: what the bite pays for is the rectangle, not what used
    /// to be drawn in it, and the four measured heights are all still one number.
    ///
    /// **Server text never changes a row's height. Only a reader's own action does.** A
    /// `spoiler_text` is up to five hundred characters that a hostile instance picks, so any rule
    /// that lets it size a row is a layout attack that lands on every row of a timeline at once —
    /// which is a stronger reason for the limit than rows looking uniform. What is left over is a
    /// warning long enough that it has stopped being a warning and become the post; a reader who
    /// wants all of it uncovers, and a screen reader is given every character regardless.
    private var coverLines: Int { max(1, bodyLines - 2) }

    /// What the row says out loud: covered or was covered, the author's warning **in full** where
    /// they wrote one, what is under the cover named but not described, and the way to work the
    /// control.
    ///
    /// **The full `spoiler_text`, never the truncated string.** A visual limit is a fact about
    /// this column's height and about nothing else; inheriting it here would hide from a screen
    /// reader exactly the text that exists to let somebody decide.
    ///
    /// The middle clause is the one that is easy to leave out. While the row is covered the words
    /// and the attachment are both out of the accessibility tree, so without it a covered row
    /// carrying four photographs announces a warning and nothing else, and a reader cannot tell
    /// there is anything there to uncover. `AttachmentDeck.named` carries the kind and the count
    /// and never the alt text, which is what keeps the cover a cover. Once the row is lifted the
    /// deck speaks for itself and the clause would only say it twice.
    ///
    /// It opens with the state — covered, or was covered — because the chip that says so is
    /// hidden, and a warning read out with nothing before it is the post's own words to a
    /// listener, the same confusion the drawn row used to make.
    var spokenCover: String {
        let mark = L10n.t(covered ? "item.covered.mark" : "item.lifted.mark")
        let warning = coverIsTheAuthors
            ? String(format: L10n.t("item.covered.warning"), item.spoiler ?? "")
            : nil
        let attached = covered ? AttachmentDeck.named(item.attachments, top: top) : nil
        let how = covered ? L10n.t("item.covered.label") : nil
        return [mark, warning, attached, how].compactMap { $0 }.joined(separator: ". ")
    }

    /// The author's warning, drawn as a label and not as the body: the words' size, a medium
    /// weight and the dimmer ink, against the body's regular weight in full ink. No italic — a
    /// CJK italic is a synthetic oblique and looks broken. It is a stranger's text and may be
    /// written partly in pictures, so it stays an `EmojiText`.
    private func warning(_ written: Written) -> some View {
        EmojiText(item.spoiler ?? "", emojis: written.cover, host: host)
            .fontWeight(.medium)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(coverLines)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Whether the author wrote a warning. Where they did not, the mark stands alone and nothing
    /// is said in their place.
    var coverIsTheAuthors: Bool { !(item.spoiler ?? "").isEmpty }

    private func words(_ written: Written) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            if item.source.kind == .board, let board = item.board {
                Text(board)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            if let title = item.title {
                Text(title)
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .lineLimit(1)
            }
            // **A forum thread's words are not in hand and are fetched; everything else's came
            // with the post.** The two are drawn by different views because they are different
            // facts: a microblog post's body is a string that is either empty or is the words,
            // and a thread's is one of five states — not here yet, the words, withheld, no words
            // at all, or a reason there are none. See `ForumPostBand`.
            //
            // **No custom-emoji list inside that band.** A Discuz! post carries none and the
            // forum has no `/api/v1/custom_emojis` for a catalogue to answer out of, so scanning
            // a stranger's post for shortcodes that can never resolve would be work with no
            // possible result — and would put a picture in a line on the strength of a colon
            // somebody typed. It draws the words as prose all the same: an address in a forum
            // post is an address a reader wants to follow exactly as much as one in a microblog
            // post, and #34 says so in as many words.
            if let thread {
                ForumPostBand(
                    thread: thread, posts: posts, lines: wordLines, inFull: inFull,
                    linked: !covered
                )
            } else {
                // **Prose, which is the cut that grows links — unless a cover stands in front of
                // these words.** This is the one line on the row the author wrote as writing; the
                // name, the handle and the cover line above are labels they chose, and
                // `EmojiText`'s two initialisers say why that difference is not a matter of
                // taste. `covered` is read here rather than passed in because every call site of
                // this function already agrees with it: `cover` draws only while it is true and
                // `stitched` only while it is false.
                EmojiText.words(item.body, emojis: written.body, host: host, covered: covered)
                    .foregroundStyle(
                        item.title == nil ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme)
                    )
                    .lineLimit(narrow ? nil : wordLines)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The thread this row stands on, where it stands on one this device can go and read.
    ///
    /// Nothing for a microblog post, and nothing for a Discourse thread: both forums draw as
    /// `.forum` because the shape is where the protocol stops mattering, but a `tid` is Discuz!'s
    /// number and `DiscuzClient` is what answers for it. See `ForumThreadRef`.
    var thread: ForumThreadRef? { ForumThreadRef(item) }

    /// How many lines the words actually get: the slot's worth in a list, all of them in the pane.
    ///
    /// Named apart from `bodyLines` so that the *fitting* and the *decision to apply it* stay two
    /// things. `bodyLines` is arithmetic about how much room the slot leaves once a title and a
    /// board name have taken their line; this is the one question a call site answers. A test can
    /// then assert the arithmetic without a screen and the rule without arithmetic.
    var wordLines: Int? { inFull ? nil : bodyLines }

    /// What fits in the slot's height beside it. A row that grows to whatever somebody
    /// wrote makes the list a series of unrelated heights; the rest of the post is a
    /// press away, which is what the thread is for.
    var bodyLines: Int {
        var lines = 4
        if item.title != nil { lines -= 1 }
        if item.source.kind == .board, item.board != nil { lines -= 1 }
        return max(1, lines)
    }

    /// The slot every row keeps open. Filled when the post brought something, and
    /// otherwise nothing at all: what the slot is for is holding the words' column
    /// still, and a box drawn around a space that is empty on purpose says the
    /// picture is missing rather than absent.
    @ViewBuilder
    private var thumb: some View {
        if item.hasThumb {
            AttachmentDeck(
                attachments: item.attachments,
                top: top,
                side: thumbSide,
                host: item.source.host,
                radius: Box.plate,
                player: player,
                onPlay: onPlay,
                onOpen: onView,
                onTurn: onTurn,
                onEnded: onEnded
            )
            .frame(width: thumbSide, height: thumbSide)
        } else {
            Color.clear
                .frame(width: thumbSide, height: thumbSide)
                .accessibilityHidden(true)
        }
    }

    /// Every mark is a press, and a press has a floor it cannot be squeezed below. On
    /// a narrow row the two groups take a line each rather than the last of them
    /// sliding off the edge.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ShellSpace.room) { passOn; keep; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: ShellSpace.tight) { passOn; keep }
        }
    }

    private var passOn: some View {
        HStack(spacing: ShellSpace.snug) {
            counted("arrowshape.turn.up.left", count: item.counts.replies,
                    label: "item.act.reply", on: false) {
                onToast(L10n.t("item.toast.reply"))
            }
            counted("arrow.2.squarepath", count: item.counts.reblogs,
                    label: "item.act.reblog", on: false) {
                onToast(L10n.t("item.toast.reblog"))
            }
            mark("quote.bubble", label: "item.act.quote", on: false) {
                onToast(L10n.t("item.toast.quote"))
            }
            counted(marks.favourited ? "star.fill" : "star",
                    count: item.counts.favourites,
                    label: "item.act.favourite", on: marks.favourited) {
                marks.favourited.toggle()
                onToast(L10n.t(marks.favourited ? "item.toast.favourite.on" : "item.toast.favourite.off"))
            }
        }
    }

    private var keep: some View {
        HStack(spacing: ShellSpace.snug) {
            mark(marks.bookmarked ? "bookmark.fill" : "bookmark",
                 label: "item.act.bookmark", on: marks.bookmarked) {
                marks.bookmarked.toggle()
                onToast(L10n.t(marks.bookmarked ? "item.toast.bookmark.on" : "item.toast.bookmark.off"))
            }
            mark(marks.kept ? "archivebox.fill" : "archivebox",
                 label: "item.act.kept", on: marks.kept) {
                marks.kept.toggle()
                onToast(L10n.t(marks.kept ? "item.toast.kept.on" : "item.toast.kept.off"))
            }
            mark("ellipsis", label: "item.act.more", on: false) {
                onToast(L10n.t("item.toast.more"))
            }
        }
    }

    /// Nothing is not a reading. A count of zero is left off rather than drawn as a
    /// nought beside every glyph in the list.
    private func counted(_ symbol: String, count: Int?, label: String, on: Bool,
                         action: @escaping () -> Void) -> some View {
        let shown = (count ?? 0) > 0 ? count : nil
        return DummyMarkButton(symbol: symbol, count: shown, labelKey: label,
                               on: on, quiet: !reading, glyph: glyph,
                               countWidth: countBox, touch: touch, action: action)
    }

    private func mark(_ symbol: String, label: String, on: Bool,
                      action: @escaping () -> Void) -> some View {
        DummyMarkButton(symbol: symbol, count: nil, labelKey: label,
                        on: on, quiet: !reading, glyph: glyph,
                        countWidth: countBox, touch: touch, action: action)
    }

    // MARK: - The way out

    /// Leaves the app for the server this row came from.
    ///
    /// **A named method and not the closure it used to want to be.** Three controls in this
    /// milestone were wired inside a `View` body, where no test can call them, and all three
    /// stayed green while doing the wrong thing — once a `Back` button that went nowhere under
    /// 405 passing tests. What this does is one line; where it lives is the whole point of it.
    ///
    /// **It asks `outwardURL` again rather than being handed an address.** The two callers below
    /// are the menu item and the VoiceOver action, and a method that took a `URL` would let a
    /// third be written that passed `item.url` straight through — the check skipped by a caller
    /// that did not know there was one. Reading the checked address here means the press and the
    /// decision to offer the press cannot disagree.
    private func openOutward() {
        guard let url = item.outwardURL else { return }
        openURL(url)
    }

    /// The way out, as a reader using VoiceOver reaches it.
    ///
    /// A context menu is a gesture — a secondary click, or a long press — and a reader who makes
    /// neither would otherwise have no way to this at all. Offered as a named action on the
    /// headline element, so it is announced with the row rather than hidden behind a press that
    /// has to be discovered.
    ///
    /// **Nothing where there is nowhere to go**, which is the same rule the menu keeps: an action
    /// announced and then refused is worse than an action never announced.
    /// The conversation, as a reader using VoiceOver reaches it.
    ///
    /// The press a finger makes is the row's own and is decided by `DummyCommand.tapped`: one
    /// press lights, the next opens. A reader landing on this element activates it once, so the
    /// second half is offered here by name — the same shape `outwardAction` above uses, and for
    /// the same reason. It says what the written-down key says.
    @ViewBuilder
    private var openAction: some View {
        if let onOpen {
            Button(L10n.t("shortcut.expand"), action: onOpen)
        }
    }

    @ViewBuilder
    private var outwardAction: some View {
        if item.outwardURL != nil {
            Button(item.outwardName) { openOutward() }
        }
    }

    // MARK: - Whoever wrote it

    /// Whoever wrote this post, where the row names somebody. Nothing where it does not, which is
    /// what makes the face a picture rather than a dead control on such a row.
    var person: DummyPerson? { DummyPerson(item) }

    /// Whether a press on the face or the name goes anywhere — both halves in one place, so the
    /// picture, the letters and the spoken action cannot come to disagree about it.
    private var opensPerson: Bool { onOpenPerson != nil && person != nil }

    /// The press itself. Named rather than written inline at three call sites, for the reason
    /// `openOutward` is named: a control wired inside a `View` body is a control no test can
    /// press, and this milestone has shipped three of them wired to the wrong thing.
    private func openPerson() {
        guard let person, let onOpenPerson else { return }
        onOpenPerson(person)
    }

    /// What opening them is called, to a pointer and to a listener alike: their own name, in a
    /// sentence of ours. A bare "Open" beside forty faces says which verb and never which person.
    static func spokenPerson(_ person: DummyPerson) -> String {
        String(format: L10n.t("item.person.open"), person.name.isEmpty ? person.handle ?? "" : person.name)
    }

    /// Opening them, as a reader using VoiceOver reaches it.
    ///
    /// **A named action and not a button they land on.** The headline is `.combine`d into one
    /// element, so the two buttons inside it are not separately reachable — a face wired only as
    /// a `Button` would be a control that exists for a pointer and for nobody else, which is the
    /// defect this file records shipping three times.
    @ViewBuilder
    private var personAction: some View {
        if opensPerson, let person {
            Button(Self.spokenPerson(person)) { openPerson() }
        }
    }

    /// Whatever is handed in, made pressable where there is somebody to open and left exactly as
    /// it was where there is not.
    ///
    /// **Nothing is hidden and nothing is relabelled.** What goes through here is the face and
    /// the author's own name, and the name is most of what the headline says out loud — a wrapper
    /// that took it out of the tree would buy a press at the price of a row that no longer names
    /// its author. `.plain` keeps the letters and the picture exactly as they were drawn, so the
    /// control is a press and not a new appearance.
    ///
    /// The pointer is told whose page this is; a listener is told by `personAction`, which is the
    /// one announced on the combined element a reader actually lands on.
    @ViewBuilder
    private func pressingPerson(_ content: some View) -> some View {
        if opensPerson, let person {
            Button(action: openPerson) { content }
                .buttonStyle(.plain)
                .help(Self.spokenPerson(person))
        } else {
            content
        }
    }
}

/// The row's way out to the web, on the one gesture that does not take the row's own press.
///
/// ## Why a context menu, and why the same one on both platforms
///
/// **A press on a row opens the thread, and that stays the primary act.** Anything that shares
/// the primary press is a race the reader loses some of the time; a context menu is the secondary
/// press on both platforms this app ships — a right or control click on macOS, a long press on
/// iOS — so one modifier is the whole of it and neither platform is given a lesser affordance
/// than the other. macOS is the primary target and iOS shares this view; this is the one shape
/// where that sharing costs nothing.
///
/// **Not a fifth mark in the marks band.** `DummyThreadPane.outward` refused exactly that and its
/// three reasons are still the reasons: the row is four fixed bands and one height, a control
/// multiplying in the marks band is the thing this branch keeps writing down that it will not do,
/// and forty small glyphs under a pointer are forty chances to leave the app by accident. A menu
/// costs the row no pixels and no height, and cannot be pressed by mistake.
///
/// **Not a hover affordance**, which exists on one platform, and which the cover's own note
/// already calls "a control half the readers of this row cannot find". **Not a swipe**, which
/// exists on the other platform and is not available here at all: these rows are a `LazyVStack`
/// inside a `ScrollView`, not a `List`, so `swipeActions` would draw nothing.
///
/// ## Absent, not disabled
///
/// Where `to` is nothing, no menu is added rather than a menu with a dead item in it — decision
/// 4's rule on this repo's controls. The condition sits on the modifier instead of inside the
/// menu's builder because an empty menu builder is still a menu, and a right click that opens an
/// empty grey rectangle is the disabled control wearing a different hat.
///
/// ## Why it takes no action to perform
///
/// It used to take an `open` closure beside the address, and QA was right that the pair could
/// disagree: a caller passing an unchecked address as `to:` while the closure opened a checked
/// one would draw a menu that did nothing — the same shape of defect as the three controls this
/// milestone shipped wired to the wrong thing, arriving through a signature instead of through a
/// closure. There is now one address. What decides whether the menu exists is the value the menu
/// opens, so the two cannot disagree, and no caller is given the chance to make them.
extension View {
    func wayOut(named name: String, to url: URL?) -> some View {
        modifier(WayOut(name: name, url: url))
    }
}

private struct WayOut: ViewModifier {
    let name: String

    /// **Filtered here, whoever built it.** This modifier is the one door to `openURL` in the
    /// package, and the check is about what will be handed to the system browser rather than
    /// about who wrote the address — which is the argument `DummyItem.outwardURL` already makes
    /// about itself. `ForumReplyRow` handed over a built address that was checked only by
    /// `DiscuzPost.url(onHost:)` two files away, which is the shape `ShellSession.remove`'s own
    /// comment names as how a class of bug reached fourteen places. A third way-out surface
    /// inherits the check rather than having to remember it.
    let url: URL?
    private var checked: URL? {
        guard let url, Host.allowsFetch(url) else { return nil }
        return url
    }

    /// Read here rather than taken from the caller. The environment is the one way out of the
    /// app this package uses, and a modifier that held a caller's closure instead is the
    /// disagreement this shape exists to make impossible.
    @Environment(\.openURL) private var openURL

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url = checked {
            content.contextMenu {
                Button {
                    openURL(url)
                } label: {
                    Label(name, systemImage: "arrow.up.forward.app")
                }
            }
        } else {
            content
        }
    }
}

private struct DummyMarkButton: View {
    let symbol: String
    let count: Int?
    let labelKey: String
    let on: Bool
    /// True on every row but the one being read. Emphasis only — the control is always
    /// here, always the same size, and always reachable.
    let quiet: Bool
    let glyph: CGFloat
    let countWidth: CGFloat
    /// The smallest a press is allowed to be. The glyph stays the size it is drawn;
    /// what grows is the area a finger can land on.
    let touch: CGFloat
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: ShellSpace.hair * 2) {
                Image(systemName: symbol)
                    .font(.system(size: glyph, weight: .medium))
                    .frame(width: glyph, height: glyph)
                if let count {
                    Text(String(count))
                        .shellFont(.reading)
                        .frame(minWidth: countWidth, alignment: .leading)
                }
            }
            .frame(minWidth: touch, minHeight: touch, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .animation(.easeInOut(duration: 0.15), value: quiet)
        .help(L10n.t(labelKey))
        .accessibilityLabel(L10n.t(labelKey))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var tint: Color {
        if on { return ShellChrome.filament(colorScheme) }
        return quiet ? ShellChrome.inkFaint(colorScheme) : ShellChrome.inkDim(colorScheme)
    }
}
