import FediqoCore
import SwiftUI

/// The sources this device reads. Empty, it is the first thing anyone sees, so it says
/// what the app is for before it asks for anything. Joined, it gets out of the way.
struct AccountPane: View {
    @Bindable var session: ShellSession
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private enum Metrics {
        /// The mark, at the size the mark is drawn rather than the size of an icon.
        static let mark: CGFloat = 72
        /// A field the width of a hostname. A pane is wider than anything typed into it.
        static let field: CGFloat = 520
        /// The promise is a sentence, not a row: it wraps where a sentence should.
        static let saying: CGFloat = 560
        static let fieldRadius: CGFloat = 6
        static let icon: CGFloat = 18
    }

    /// **The whole page scrolls, not a list inside it.** `PreferencesPane` is a `Form` and every
    /// other pane here scrolls as one thing; this one briefly did the opposite — a fixed `VStack`
    /// with the rows in an inner `ScrollView` — and that puts the masthead, the field, Browse, the
    /// section title, its paragraph and the footnote all ahead of the list for height. At 320pt in
    /// Chinese at a large Dynamic Type size the list is squeezed to a sliver or to nothing, and
    /// there is nothing the reader can scroll to reach it. No test can see that, which is the
    /// reason it is written down here.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShellSpace.room) {
            masthead
            adding
            // **Nothing at all where nothing is joined** — not a hairline, not a header, not an
            // empty state. The hero above already says what the app is for and names the next act,
            // and Browse is beside the field; a second invitation under a rule would be two of
            // them on one screen, with the mascot arguing against the other. `PreferencesPane`
            // draws its empty state and is right to, because it has no hero to be contradicted by.
            if !session.sources.isEmpty {
                hairline
                sources
            }
            }
            .padding(ShellSpace.pad)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: searchFocused) { _, on in
            session.searchFocused = on
        }
        .onDisappear { session.searchFocused = false }
    }

    @ViewBuilder
    private var masthead: some View {
        if session.sources.isEmpty { hero } else { standing }
    }

    /// Nothing has been joined yet. The octopus, the promise, and what it costs — and
    /// then the one control that does anything about it.
    private var hero: some View {
        HStack(alignment: .top, spacing: ShellSpace.pad) {
            Image("Mascot", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: Metrics.mark, height: Metrics.mark)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                Text(L10n.t("account.hero.promise"))
                    .font(ShellType.display)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t("account.hero.detail"))
                    .font(ShellType.body)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: Metrics.saying, alignment: .leading)
        }
    }

    /// Something is joined. The page says which, and stops selling itself.
    private var standing: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Text(L10n.t("shell.account.title"))
                .font(ShellType.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            SourceMarkRow(sources: session.sources.map(Self.mark))
        }
    }

    private var adding: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            if !session.sources.isEmpty {
                Text(L10n.t("account.add.detail"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
            fieldRow
            if statusVisible { status }
        }
    }

    /// The field, and the way in for a reader who does not have a hostname to type.
    ///
    /// **`layoutPriority` on the field, and the button allowed to wrap.** At 320pt with a long
    /// translation the right failure is a Browse that takes two lines, not a field that collapses.
    private var fieldRow: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            searchField
                .layoutPriority(1)
            Button(L10n.t("account.browse")) { browse() }
                .font(ShellType.body)
                .disabled(busy)
                .help(L10n.t("account.browse.label"))
                .accessibilityLabel(L10n.t("account.browse.label"))
        }
    }

    /// Whether the top half is out of the reader's hands: something on the wire, or the sheet up.
    ///
    /// **The sheet counts, which is PLAN risk 8.** `checking` is false the whole time a preview
    /// is on screen, so a gate asking only about it would leave the field and both buttons live
    /// behind an open sheet — and a second look would overwrite the stage under a reader who is
    /// reading the first one.
    private var busy: Bool {
        session.checking || session.stage != nil
    }

    private var searchField: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            TextField(L10n.t("account.search.placeholder"), text: $session.hostname)
                .font(ShellType.body)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .disabled(busy)
                .onSubmit { Task { await typedHost() } }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .accessibilityLabel(L10n.t("account.search.placeholder"))
            Button {
                Task { await typedHost() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(ShellType.body.weight(.semibold))
                    .frame(width: Metrics.icon, height: Metrics.icon)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel(L10n.t("account.search"))
            .help(L10n.t("account.search"))
        }
        .padding(.horizontal, ShellSpace.step)
        .padding(.vertical, ShellSpace.snug)
        .frame(maxWidth: Metrics.field, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: ShellSpace.hair)
        }
    }

    /// Whether the pane has anything to say under the field.
    ///
    /// **A partial pick is one of the things it has to say.** A pick where some boards read and
    /// some did not sets no `refuse` — it was not a failed join, the source is in the list and
    /// its tabs are in the rail — so a gate asking only about `checking` and `refuse` would build
    /// the sentence naming the boards that failed and then never draw it. That is the exact shape
    /// this branch keeps writing down: the answer exists and nobody is asked for it.
    private var statusVisible: Bool {
        session.checking || session.refuse != nil || !session.unread.isEmpty
    }

    @ViewBuilder
    private var status: some View {
        if session.checking {
            HStack(spacing: ShellSpace.snug) {
                ProgressView()
                Text(String(format: L10n.t("account.detect.progress"), session.progressHost))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
            }
        } else if let refuse = session.refuse {
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                Text(refuse)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.alarm(colorScheme))
                // Where *every* board failed there is no list to draw — Core threw the first
                // board's reason and kept none — so what can still be said is how much the
                // sentence above is about.
                if session.unreadAll > 0 {
                    Text(String(format: L10n.t("board.unread.all"), session.unreadAll))
                        .font(ShellType.mark)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                offer
            }
        } else if !session.unread.isEmpty {
            unreadReport
        }
    }

    /// Boards the reader picked that could not be read.
    ///
    /// **A partial pick is not a silence.** They chose these off a list this app drew for them,
    /// and some of them did not answer — `install-a.example` board 37 has 114,662 threads and serves
    /// them as picture cards with no date on any, so it fails and is not subscribed to. Leaving
    /// it out of the rail with no sentence would leave the reader counting tabs to work out which
    /// of their choices went missing, and guessing why.
    ///
    /// Drawn where the refusal is drawn, because the reader pressed Add here and this is the rest
    /// of that answer. Not in alarm: the boards that worked did work, and this is the footnote to
    /// a success rather than a failure of its own.
    @ViewBuilder
    private var unreadReport: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(String(format: L10n.t("board.unread.some"), session.unread.count))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(session.unread, id: \.board.fid) { entry in
                Text(ShellSession.unreadMessage(entry))
                    .font(ShellType.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one thing a reader can do about a server that turned this app away.
    ///
    /// This branch recorded the hole and left it open — the refusal message "tells the reader
    /// what happened and offers them nothing to do about it". A reader with an account on that
    /// forum *is* somebody it can be opened for, and the honest route is the one the forum's
    /// owner controls: their own sign-in page, in a real browser engine, with them typing into
    /// it. Offered only after a refusal, never beside a typo.
    @ViewBuilder
    private var offer: some View {
        if let host = session.offerSignIn {
            Button(String(format: L10n.t("account.refuse.signin"), host)) {
                Task { await offeredSignIn(host) }
            }
            .font(ShellType.meta)
            .accessibilityLabel(Text(String(format: L10n.t("account.refuse.signin.label"), host)))
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(ShellChrome.hairline(colorScheme))
            .frame(height: ShellSpace.hair)
            .accessibilityHidden(true)
    }

    /// The sources this device reads, one row each.
    ///
    /// **This list and `PreferencesPane`'s answer different questions and are kept visibly apart.**
    /// This one is *what am I reading, and what is it* — identity: protocol, shape, boards, and the
    /// one figure the server stated about itself. That one is *what is this device holding* — an
    /// inventory, every line of it with a byte count or a date. So **no byte figure and no date
    /// appears on a row here, ever**, the shape glyph appears only here, and the footnote below
    /// names the other list and its job rather than repeating it. Clear is in both, which is one
    /// act reached from two questions and not a duplicate; Remove is only here, because removing is
    /// about what you read and not about what is held.
    private var sources: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            // `name` and not `pane`: `pane` is documented as a page's own title, one per page, and
            // this page's is "Account".
            Text(L10n.t("account.sources.title"))
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
            // The sentence that says which question this list answers and what Remove costs,
            // before the reader meets a Remove button.
            Text(L10n.t("account.sources.detail"))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            // **A plain stack, because the page is the thing that scrolls.** A `ScrollView` here
            // would be the inner one the page comment above is about.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(session.rows) { row in
                    SourceRowView(
                        row: row,
                        signedIn: session.forums.reachedSignIn(host: row.source.host),
                        signIn: { Task { await press(row) } },
                        clear: { Task { await clear(row) } },
                        remove: { askRemove(row) }
                    )
                    // **Between rows and not after every one.** A rule under the last row is a
                    // list that looks cut off rather than finished, with the footnote below it
                    // hanging off the end of a table.
                    if row.id != session.rows.last?.id { hairline }
                }
            }
            Text(L10n.t("account.sources.held"))
                .font(ShellType.mark)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - What every control on this page actually does
    //
    // **One named method per interactive element, and no logic in any closure.** This page shipped
    // a search field whose button called `ShellSession.search()`, which trimmed the text and
    // cleared the error and *never looked anything up* — with the Add button gone into the sheet,
    // there was no way left to add a source by typing its hostname, and 436 UI tests were green
    // because every one of them called `session.add()` directly. That is the third time on this
    // branch that a rule was pinned at the session while the thing that calls it was reachable
    // from nothing. So each control below is a method a test can call, and the closures in the
    // body do nothing but call one.

    /// The reader typed a hostname and asked for it — the field's Return, and the magnifier.
    ///
    /// **Both look, and it is the same act.** A reader who has typed `mastodon.social` and pressed
    /// Return has asked for that server; a magnifying glass beside a field is the same request
    /// made with the mouse. Neither is a catalogue filter any more — the directory's filter lives
    /// in the sheet, next to the list it filters — so a control here that only tidied the text was
    /// a control pretending to be one.
    ///
    /// Nothing is added by this. `add()` looks and opens the preview, and the reader still has to
    /// press Subscribe; every guard that press has — the duplicate check, the parse, the sheet
    /// already being up — is `look`'s and applies unchanged.
    func typedHost() async {
        await session.add()
    }

    /// Browse pressed. The catalogue is fetched here and not on the page appearing (decision 10).
    func browse() {
        session.browse()
    }

    /// The sign-in a refusal offered, taken.
    func offeredSignIn(_ host: String) async {
        await session.signIn(host: host)
    }

    /// A row's sign-in toggle, either way round.
    ///
    /// **Which way it goes is `reachedSignIn`'s answer and not this view's** — see its doc comment
    /// for why "signed in" here can only ever mean as far as this device last saw.
    func press(_ row: SourceRow) async {
        if session.forums.reachedSignIn(host: row.source.host) {
            await session.signOut(host: row.source.host)
        } else {
            await session.signIn(host: row.source.host)
        }
    }

    /// A row's Clear. The same act, and the same key, as the one on Preferences.
    func clear(_ row: SourceRow) async {
        await session.clear(host: row.source.host)
    }

    /// A row's Remove. **Destroys nothing** — it raises the question, and only the dialog's
    /// confirm reaches `remove(host:)`.
    func askRemove(_ row: SourceRow) {
        session.removing = row.source.host
    }

    /// The mark a joined source is drawn with. Internal rather than private only so that
    /// `AccountMarkTests` can pin it: the globe it used to draw over every forum was invisible
    /// to the suite, because a view's private helper is reachable from nothing.
    static func mark(_ source: Source) -> DummySource {
        // The shape the timeline already gives this protocol, rather than the `.microblog` that
        // a deleted default argument used to supply here — which is why **both** a joined
        // Discourse and a joined Discuz! drew with the globe icon, a microblog's mark over a
        // forum. The source page reworks this row properly.
        .unsigned(source.host, kind: DummyItem.shape(of: source.kind))
    }
}
