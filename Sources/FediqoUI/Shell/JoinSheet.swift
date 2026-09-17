import FediqoCore
import SwiftUI

/// Which of the two surfaces draws a stage.
///
/// **Derived from the stage and never stored beside it** — decision 20. Two presenters read it:
/// `FediqoRootView` puts the sheet up at `.sheet`, `AccountPane` draws the block in the page at
/// `.pane`. They cannot both fire, because a function cannot disagree with its own input.
enum JoinSurface: Equatable {
    /// Over everything, dismissable by a swipe or Escape.
    case sheet
    /// Drawn into `AccountPane` between the field and the sources list, beside the field rather
    /// than over it.
    case pane
}

/// Where a preview was reached from.
///
/// **Per-case rather than a field on the stage, so an illegal pairing cannot be written.** There
/// is no such thing as browsing-from-the-field, and a single origin beside the stage would let
/// somebody spell it.
enum PreviewOrigin: Equatable {
    /// The reader typed a hostname on `AccountPane` and pressed Return or the magnifier. Drawn in
    /// the page, beside the field they typed into.
    case field
    /// The reader pressed a row in the directory. The directory is behind them, so this stays in
    /// the sheet the directory is in.
    case directory
}

/// What the reader was doing when they arrived at a forum's board list.
///
/// The two are different errands and the sheet has to tell them apart: one is a join with a
/// preview behind it, the other is a reader restating what they already read.
enum BoardsOrigin: Equatable {
    /// A join in progress. Carries the preview — decision 12 — so Back costs no second request,
    /// and the origin of *that* preview.
    ///
    /// **The origin is load-bearing and not a note about where the reader came from.**
    /// `backToPreview()` does not restore a stage, it **reconstructs** one:
    /// `.previewing(preview, from: origin)`. Drop the origin here and there is nothing to
    /// reconstruct it from, so Back would have to guess — and either guess is a reader thrown onto
    /// the wrong surface. Guess `.field` and a preview picked off the directory comes back as a
    /// block in the page, for somebody who never typed anything and whose sheet has just vanished.
    /// Guess `.directory` and a typed host's Back opens a sheet over the page that is still
    /// drawing that same preview underneath it.
    ///
    /// It is also what `JoinStage.inlinePreview` reads to keep the page's block drawn while this
    /// sheet stands over it, which is the more visible of the two but the weaker reason.
    case preview(SourcePreview, from: PreviewOrigin)
    /// A source the reader already has, whose boards they are changing. Carries what they are
    /// subscribed to now, because `ItemStore.subscribe(host:to:)` **replaces** the set — a picker
    /// that opened empty would silently unsubscribe the eight boards they had (decision 25).
    ///
    /// **Nothing constructs this yet.** It is defined here so that the exhaustive switches below
    /// name it, and the unit that draws the row's boards control fills it in.
    case joined(subscribed: [BoardSubscription])
}

/// Where the reader is in adding a source: looking for one, looking *at* one, or picking what of
/// it to read.
///
/// **Three stages, one piece of state, and the stage says which surface draws it.** Three sheets
/// driven by three optionals is what this replaces, and on iOS two `.sheet` modifiers that can
/// both be active means the second is silently ignored.
///
/// **The entrance travels in the case** — decision 20. It used to be a `@State` inside `JoinSheet`
/// called `cameFromBrowsing`: a view-local flag no test could reach, which is the shape this
/// branch has shipped a defect in twice. Carried here, `surface`, `inlinePreview`,
/// `admitsASecondLook` and `leading(for:)` are all pure functions of one value, and every one of
/// them is driven by a test.
///
/// **`.choosingBoards` carries the preview it came from** — decision 12. It is what lets the
/// boards stage draw a Back button at all, and Back without a second request is the reader-visible
/// gain of merging the three sheets.
enum JoinStage: Identifiable, Equatable {
    /// A list of servers to look at. Nothing has been typed and nothing detected.
    case browsing
    /// One server, and what it says about itself. **Nothing added.**
    case previewing(SourcePreview, from: PreviewOrigin)
    /// D28's pause: the forum's boards, and what the reader was doing when they got here.
    case choosingBoards(JoinOffer, from: BoardsOrigin)

    var id: String {
        switch self {
        case .browsing: "browsing"
        case .previewing(let preview, _): "previewing:\(preview.host)"
        case .choosingBoards(let offer, _): "choosingBoards:\(offer.host)"
        }
    }

    /// The server this stage is about, where it is about one.
    ///
    /// **`.browsing` is about none, and that is a fact rather than a gap.** A reader with the
    /// directory open has not named a host yet, so a caller asking "is this stage about the
    /// server that just went away" gets the true answer of no.
    var host: String? {
        switch self {
        case .browsing: nil
        case .previewing(let preview, _): preview.host
        case .choosingBoards(let offer, _): offer.host
        }
    }

    /// Which surface draws this stage. **Derived, never stored** — decision 20.
    ///
    /// A typed hostname's preview belongs beside the field the reader typed into; one reached from
    /// the directory belongs in the sheet the directory is in, because the directory is what is
    /// behind it. Everything else is the sheet.
    ///
    /// **No `default:`**, and the `.previewing` cases are split rather than folded: a fourth
    /// entrance has to say where it draws rather than inherit somebody else's answer.
    var surface: JoinSurface {
        switch self {
        case .browsing: .sheet
        case .previewing(_, .field): .pane
        case .previewing(_, .directory): .sheet
        case .choosingBoards: .sheet
        }
    }

    /// Which preview the *page* is showing, if any.
    ///
    /// True at `.previewing` whose origin is the field, **and also** while the boards sheet stands
    /// over it: the page is what the reader steps back onto, so it does not stop being drawn while
    /// something is drawn on top of it. A pane that asked `if case .previewing` would blank the
    /// block the moment the sheet opened and rebuild it on Back — which is the page throwing the
    /// reader somewhere and then throwing them back.
    ///
    /// **No `default:`**, so the boards origins each answer for themselves.
    var inlinePreview: SourcePreview? {
        switch self {
        case .browsing: nil
        case .previewing(let preview, .field): preview
        case .previewing(_, .directory): nil
        case .choosingBoards(_, .preview(let preview, .field)): preview
        case .choosingBoards(_, .preview(_, .directory)): nil
        case .choosingBoards(_, .joined): nil
        }
    }

    /// Whether the reader may start a second look — type another hostname, or press Browse —
    /// while this stage is up.
    ///
    /// **This is the other half of splitting `busy`, and leaving it out makes the first half a
    /// lie.** An inline preview does not cover the field, so the field is re-enabled beside it;
    /// a field that is live and whose Return is refused by a guard three files away is a control
    /// that does nothing, which is exactly the defect unit 5b closed and risk 12 names.
    ///
    /// `.browsing` admits one because the directory's own rows *are* looks. A preview in the sheet
    /// and a board list do not, because the reader cannot see past them to know they replaced
    /// something.
    ///
    /// **No `default:`**, in the house style of `hasTrends` and `canSignIn`.
    var admitsASecondLook: Bool {
        switch self {
        case .browsing: true
        case .previewing(_, .field): true
        case .previewing(_, .directory): false
        case .choosingBoards: false
        }
    }
}

/// The one sheet adding a source is done in, at whichever of its three stages the reader is on.
///
/// **Presented over `.sheet(isPresented:)`, and the `id` is exactly why.** A stable identity is
/// what stops SwiftUI re-presenting a sheet, so `.sheet(item:)` would leave whether the content
/// builder re-runs for a same-id change to version-dependent behaviour rather than to contract —
/// and the likely outcome on a device is the preview still on screen while the session says
/// boards. `isPresented` plus the switch below has neither problem: `ShellSession` is
/// `@Observable`, this body reads `session.stage`, and a change of stage is a redraw.
///
/// The frame is `BoardPickerSheet`'s, which is this house's reference sheet: header, hairline,
/// scrolling body, hairline, footer. The sizing modifiers live here and **only** here, so the
/// window does not resize as the reader moves between stages.
struct JoinSheet: View {
    @Bindable var session: ShellSession

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    @AccessibilityFocusState private var headerFocused: Bool

    private enum Metrics {
        static let fieldRadius: CGFloat = 6
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            body(for: session.stage)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            hairline
            footer
        }
        .background(ShellChrome.page(colorScheme))
        // Nothing is added until the reader says so, so a swipe is a complete cancel — except
        // while something is actually on the wire, where leaving would strand the press.
        .interactiveDismissDisabled(session.checking)
        .onChange(of: session.stage) { _, stage in
            headerFocused = true
            let next = Self.ticks(Ticks(picked: picked, host: pickedHost), movingTo: stage)
            picked = next.picked
            pickedHost = next.host
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var hairline: some View {
        Rectangle()
            .fill(ShellChrome.hairline(colorScheme))
            .frame(height: ShellSpace.hair)
            .accessibilityHidden(true)
    }

    // MARK: - The frame

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            switch session.stage {
            case .browsing:
                titled(L10n.t("join.browse.title"), L10n.t("join.browse.detail"))
                filterField
            // **The one block this sheet shares with the page, in the sheet's own header slot.**
            // It stays pinned above the hairline here and scrolls with the block there, which is
            // why it is placed by each surface rather than carried inside the shared body.
            case .previewing(let preview, _):
                SourcePreviewView.Header(preview: preview, surface: .sheet)
                    .accessibilityFocused($headerFocused)
            case .choosingBoards(let offer, _):
                titled(
                    String(format: L10n.t("board.choose.title"), offer.host),
                    L10n.t("board.choose.detail")
                )
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
    }

    private func titled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(title)
                .font(ShellType.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($headerFocused)
            Text(detail)
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What a preview's header says out loud: the host, the protocol, and the shape — the same
    /// sentence the source row says about the same server, from the same key.
    static func spoken(_ preview: SourcePreview) -> String {
        String(
            format: L10n.t("source.spoken"),
            preview.host,
            preview.kind.displayName,
            DummyItem.shapeWord(DummyItem.shape(of: preview.kind))
        )
    }

    @ViewBuilder
    private func body(for stage: JoinStage?) -> some View {
        switch stage {
        case .browsing:
            browsing
        case .previewing(let preview, _):
            // **The `ScrollView` is the sheet's and not the shared view's.** `AccountPane` is
            // already one scroller and nesting a second inside it is the failure that pane's own
            // comment records: the list squeezed to a sliver at 320pt with nothing to scroll.
            ScrollView { SourcePreviewView(preview: preview, surface: .sheet) }
        case .choosingBoards(let offer, _):
            BoardPickerList(offer: offer, picked: $picked)
        case nil:
            EmptyView()
        }
    }

    /// The boards this reader has ticked, by `fid`, and **which forum they ticked them on**.
    ///
    /// Held here rather than inside the list, because the footer's Subscribe reads it and the
    /// footer belongs to the sheet — one frame for three stages means the count and the button
    /// are drawn once, not once per stage.
    ///
    /// **The host beside it is the whole of the fix, and it is not decoration.** When the picker
    /// was its own presentation this set was built fresh every time it opened, so "the boards
    /// ticked" could only ever mean one forum's. Hoisted into a sheet that outlives the stage, it
    /// silently became "the boards ticked at some point during this presentation" — and a reader
    /// who goes boards(A) → Back → Back → row B → Subscribe reaches boards(B) still holding A's
    /// numbers. Discuz! `fid`s are small integers and collide across forums as a matter of
    /// course, so `offer.boards.filter { picked.contains($0.fid) }` would subscribe them to
    /// boards of B they never ticked. Same name, quietly different meaning; see
    /// `carriedTicks(_:from:to:)` for the rule that restores it.
    @State private var picked: Set<Int> = []
    @State private var pickedHost: String?

    /// The ticks and the forum they were made on, together — so that "which boards are ticked"
    /// cannot be read without reading which forum they belong to.
    struct Ticks: Equatable {
        var picked: Set<Int> = []
        var host: String?
    }

    /// What survives a change of stage: the ticks, where the reader is still on the same forum,
    /// and nothing at all where they are not.
    ///
    /// Stepping back to the preview and forward again is one forum and one decision, so the ticks
    /// stay. Every other move — a different forum, the directory, the sheet closing — is a
    /// different decision, and carrying numbers into it is how a reader subscribes to a board
    /// they never saw.
    ///
    /// **Takes the stage rather than a host, so the whole of the wiring is here and testable.**
    /// The rule alone being right is not what was wrong last time: the bug this unit already
    /// shipped green was a correct method called from the wrong place, and a `View` body is the
    /// one place no test reaches. `.onChange` does nothing but hand this its arguments and store
    /// what comes back, so `ticksSurviveTheAttackSequence` can walk the real press-by-press route
    /// that reaches the bug.
    static func ticks(_ held: Ticks, movingTo stage: JoinStage?) -> Ticks {
        let host = stage?.host
        guard let host, host == held.host else { return Ticks(picked: [], host: host) }
        return Ticks(picked: held.picked, host: host)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: ShellSpace.step) {
            reading
            Spacer(minLength: ShellSpace.snug)
            leading
            primary
        }
        .padding(ShellSpace.pad)
    }

    /// The footer's count, where the stage has one.
    @ViewBuilder
    private var reading: some View {
        if case .choosingBoards(let offer, _) = session.stage {
            Text(String(format: L10n.t("board.choose.count"), picked.count, offer.boards.count))
                .font(ShellType.reading)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
        }
    }

    /// **By rule rather than by history** — §2.2. What is behind the reader decides the word:
    /// nothing at the directory, the directory or the field at a preview, and always the preview
    /// at the boards.
    ///
    /// **Named as a value rather than written straight into the button**, because the one bug
    /// this control has already had was a button calling the wrong method — Back from a preview
    /// called `browse()`, which refuses while a sheet is up, so the button did nothing at all and
    /// every test stayed green. A `View` body is the one place a test cannot reach; the rule and
    /// the press are both reachable here, and both are pinned.
    enum Leading: Equatable {
        case close
        case backToBrowsing
        case backToPreview
        case cancel

        /// The word printed on it.
        var key: String {
            switch self {
            case .close: "join.close"
            case .backToBrowsing, .backToPreview: "join.back"
            // Reused rather than duplicated, so the two stages cannot drift in translation.
            case .cancel: "board.choose.cancel"
            }
        }
    }

    /// Which button the reader is looking at. **No `default:`** — a fourth stage has to decide
    /// what is behind it rather than inherit somebody else's answer.
    ///
    /// **A pure function of one value, and that is the whole of what changed here.** The
    /// directory-or-field distinction used to arrive as a second argument fed from a view-local
    /// `@State`, so the rule was pinned and the thing that set it was reachable from no test. The
    /// entrance now travels in the stage, so four stage-shapes give four answers and every one of
    /// them is driven from a test.
    ///
    /// `.previewing(_, .field)` is drawn in the page and has no footer to put a button in; it
    /// still answers, because the rule is about what is behind the reader and not about who is
    /// asking.
    static func leading(for stage: JoinStage?) -> Leading? {
        switch stage {
        case .browsing: .close
        case .previewing(_, .directory): .backToBrowsing
        case .previewing(_, .field): .cancel
        case .choosingBoards: .backToPreview
        case nil: nil
        }
    }

    /// What pressing it does. **No `default:`**, and pinned one case at a time: this switch is
    /// the wiring the shipped bug lived in.
    static func press(_ leading: Leading, on session: ShellSession) {
        switch leading {
        case .close, .cancel: session.dismissStage()
        case .backToBrowsing: session.backToBrowsing()
        case .backToPreview: session.backToPreview()
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let leading = Self.leading(for: session.stage) {
            Button(L10n.t(leading.key)) { Self.press(leading, on: session) }
        }
    }

    @ViewBuilder
    private var primary: some View {
        switch session.stage {
        case .previewing(let preview, _):
            let warned = SourcePreviewView.warns(preview)
            Button(L10n.t("board.choose.subscribe")) { Task { await session.confirm() } }
                .disabled(session.checking)
                // **Withdrawn in the one state the screen has just warned about.** The reader may
                // still press it — the warning is a prediction and not a refusal — but Return
                // must not fire the press they were told would probably fail. They have to aim.
                .keyboardShortcut(warned ? .none : .defaultAction)
                .accessibilityHint(warned ? Text(L10n.t("join.preview.closed.hint")) : Text(""))
        case .choosingBoards(let offer, _):
            Button(L10n.t("board.choose.subscribe")) {
                // **In the index's order, not the order they were tapped.** The rail reads this
                // straight through, and a forum's own ordering is a better rail than a record of
                // which board somebody happened to notice first. Filtering `offer.boards` is what
                // makes that true; iterating `picked` would give tap order, and a `Set` would
                // give neither.
                let picks = offer.boards.filter { picked.contains($0.fid) }
                Task { await session.subscribe(picks) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(picked.isEmpty)
        case .browsing, nil:
            EmptyView()
        }
    }

    // MARK: - Stage: browsing

    /// The catalog, with the sheet's header over it and a field inside it.
    ///
    /// **The field is load-bearing and not an addition.** `visibleServers` and `extraJoinHost` are
    /// both computed off `session.hostname`, so without a field in here the filter and the
    /// type-a-host-that-is-not-listed path are simply gone the moment Browse becomes a sheet.
    /// Bound to the same property, so what is typed here is still in the page's field afterwards.
    private var filterField: some View {
        TextField(L10n.t("join.browse.filter"), text: $session.hostname)
            .font(ShellType.body)
            .textFieldStyle(.plain)
            .disabled(session.checking)
            .onSubmit { Task { await look() } }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
            .accessibilityLabel(L10n.t("join.browse.filter"))
            .padding(.horizontal, ShellSpace.step)
            .padding(.vertical, ShellSpace.snug)
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                    .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: ShellSpace.hair)
            }
    }

    /// A row was pressed here, so the preview it opens has the directory behind it.
    ///
    /// **The entrance goes to the session rather than into a flag here.** It used to set a
    /// `@State` this sheet owned, which meant the one thing deciding where a preview is drawn and
    /// what its Back button says lived in the one place a test cannot reach.
    private func look() async {
        await session.add(from: .directory)
    }

    @ViewBuilder
    private var browsing: some View {
        switch session.catalog {
        case .loading:
            note {
                HStack(spacing: ShellSpace.snug) {
                    ProgressView()
                    Text(L10n.t("account.catalog.loading"))
                        .font(ShellType.body)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                }
            }
        case .failed:
            note { Text(L10n.t("account.catalog.failed")) }
        case .empty:
            note { Text(L10n.t("account.catalog.empty")) }
        case .ready:
            ScrollView {
                // Sections now, with the header drawn only where there is more than one — M1 has
                // exactly one and draws none, so no speculative section name ships. M3 adds rows
                // to a structure that is already here.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if let host = session.extraJoinHost {
                            extraRow(host)
                            hairline
                        }
                        ForEach(session.visibleServers) { server in
                            catalogRow(server)
                            hairline
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func note<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(ShellType.body)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .padding(ShellSpace.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A host the directory does not list. **It opens a preview, like every other row** — which
    /// is why its copy no longer says Add.
    private func extraRow(_ host: String) -> some View {
        let added = session.isAdded(host)
        return Button {
            session.hostname = host
            Task { await look() }
        } label: {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(String(format: L10n.t("join.browse.look"), host))
                    .font(ShellType.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Text(added ? L10n.t("account.catalog.added") : L10n.t("join.browse.look.detail"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.step)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.checking || added)
        .accessibilityLabel(String(format: L10n.t("join.browse.look"), host))
    }

    private func catalogRow(_ server: CatalogServer) -> some View {
        let added = session.isAdded(server.domain)
        return Button {
            Task { await session.pick(server) }
        } label: {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(server.domain)
                    .font(ShellType.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                Text(added ? L10n.t("account.catalog.added") : server.summary)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
                if !added { rowFoot(server) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.step)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.checking || added)
        .accessibilityLabel(server.domain)
        .accessibilityValue(
            added ? L10n.t("account.catalog.added") : "\(server.summary), \(metaLine(server))"
        )
    }

    /// The row's own readings, or — for the one row the reader just pressed — the fact that this
    /// app is asking it. **Which of forty rows they pressed is the thing they cannot otherwise
    /// see**, and `progressHost` already records it.
    @ViewBuilder
    private func rowFoot(_ server: CatalogServer) -> some View {
        if session.checking, session.progressHost == server.domain.lowercased() {
            HStack(spacing: ShellSpace.snug) {
                ProgressView()
                Text(String(format: L10n.t("account.detect.progress"), server.domain))
            }
            .font(ShellType.mark)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
        } else {
            // Three readings, each one a labelled sentence about the server. They used to be a
            // single string joined with middle dots, where one of the numbers was labelled with
            // an initialism and the other was not labelled at all — which is the objection this
            // separation answers, and the reason a dot-joined line is not the tidier version of
            // it. (`JoinSheet.figureLine` *does* dot-join, and may: there both halves say what
            // they are.)
            HStack(spacing: ShellSpace.pad) {
                ForEach(readings(server), id: \.self) { reading in
                    Text(reading)
                }
            }
            .font(ShellType.mark)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .lineLimit(1)
        }
    }

    private func readings(_ server: CatalogServer) -> [String] {
        [
            languageName(server.language),
            String(format: L10n.t("account.catalog.weekly"), Self.compact(server.weekUsers)),
            String(format: L10n.t("account.catalog.people"), Self.compact(server.users)),
        ]
    }

    private func metaLine(_ server: CatalogServer) -> String {
        readings(server).joined(separator: ", ")
    }

    private func languageName(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.t("account.catalog.langUnknown") }
        return locale.localizedString(forLanguageCode: trimmed) ?? trimmed
    }

    /// A count, shortened, **in the shell's language rather than the device's**.
    ///
    /// `.formatted` with no locale follows the system, and this app lets the reader pick a language
    /// the device is not set to — so on a `zh-TW` machine with the shell in English this returned
    /// "9.1萬" and the line read "9.1萬 posts". One sentence in two languages, on all three surfaces
    /// that draw a figure: the directory's rows, the preview, and the source row. They share this
    /// one function, which is why there is one fix and not three.
    ///
    /// `language` is threaded rather than read off a global at the point of use, and resolves the
    /// same way `L10n.t(_:language:)` does — nothing means the shell's current language. A `static
    /// func` has no environment to ask, and the answer must not be allowed to differ from the one
    /// the surrounding string came back in.
    static func compact(_ value: Int, language: DummyLanguage? = nil) -> String {
        value.formatted(.number.notation(.compactName).locale(L10n.locale(language)))
    }
}
