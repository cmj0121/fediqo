import FediqoCore
import SwiftUI

/// Where the reader is in adding a source: looking for one, looking *at* one, or picking what of
/// it to read.
///
/// **Three stages, one sheet, one piece of state.** Three sheets driven by three optionals is
/// what this replaces, and on iOS two `.sheet` modifiers that can both be active means the second
/// is silently ignored. The stage is the presenter and the sheet switches on it inside its own
/// body — see `JoinSheet` for why that is `.sheet(isPresented:)` and not `.sheet(item:)`.
///
/// **`.choosingBoards` carries the preview it came from** — decision 12. It is what lets the
/// boards stage draw a Back button at all, and Back without a second request is the reader-visible
/// gain of merging the three sheets. A stage that is a pure function of its own value is also the
/// thing that makes the sheet testable.
enum JoinStage: Identifiable, Equatable {
    /// A list of servers to look at. Nothing has been typed and nothing detected.
    case browsing
    /// One server, and what it says about itself. **Nothing added.**
    case previewing(SourcePreview)
    /// D28's pause: the forum's boards, and the preview to step back to.
    case choosingBoards(JoinOffer, from: SourcePreview)

    var id: String {
        switch self {
        case .browsing: "browsing"
        case .previewing(let preview): "previewing:\(preview.host)"
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
        case .previewing(let preview): preview.host
        case .choosingBoards(let offer, _): offer.host
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

    /// Whether this presentation began at the directory, which is the only thing that decides
    /// whether the preview's leading button says Back or Cancel — §2.2's rule by shape rather
    /// than by history. View-local because it is about this presentation and nothing else, and
    /// `@State` survives a stage change within one.
    @State private var cameFromBrowsing = false
    @AccessibilityFocusState private var headerFocused: Bool

    private enum Metrics {
        static let fieldRadius: CGFloat = 6
        /// A server's own banner, at the one size a sheet this wide can afford.
        static let hero: CGFloat = 120
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
            case .previewing(let preview):
                titled(preview.host, L10n.t("join.preview.detail"))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Self.spoken(preview))
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
        case .previewing(let preview):
            previewing(preview)
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
    static func leading(for stage: JoinStage?, cameFromBrowsing: Bool) -> Leading? {
        switch stage {
        case .browsing: .close
        case .previewing: cameFromBrowsing ? .backToBrowsing : .cancel
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
        if let leading = Self.leading(for: session.stage, cameFromBrowsing: cameFromBrowsing) {
            Button(L10n.t(leading.key)) { Self.press(leading, on: session) }
        }
    }

    @ViewBuilder
    private var primary: some View {
        switch session.stage {
        case .previewing(let preview):
            let warned = Self.warns(preview)
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
    private func look() async {
        cameFromBrowsing = true
        await session.add()
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
            Task {
                cameFromBrowsing = true
                await session.pick(server)
            }
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

    // MARK: - Stage: previewing

    /// What the reader is about to take on.
    ///
    /// **Built silent-first.** The spine — who this is, what the server claims, what pressing
    /// will do — is drawable from `host` and `kind` alone, so a Discuz! with nothing to publish
    /// gets a finished screen with less evidence rather than a rich screen with holes in it.
    /// Blocks collapse; nothing greys out; a hairline is drawn only *between* blocks that exist,
    /// so the emptiest preview has no internal hairline and cannot read as a form with its rows
    /// deleted.
    @ViewBuilder
    private func previewing(_ preview: SourcePreview) -> some View {
        ScrollView {
            switch preview.profile {
            case .stated(let profile):
                stated(preview, profile)
            case .silent:
                spine(preview) {
                    Text(String(format: L10n.t("join.preview.silent"), preview.host))
                        .font(ShellType.body)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unread(_, _, let error):
                spine(preview) {
                    VStack(alignment: .leading, spacing: ShellSpace.snug) {
                        Text(String(format: L10n.t("join.preview.unread"), preview.host))
                            .font(ShellType.body)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.unreadMessage(error))
                            .font(ShellType.mark)
                            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            // **The contract says this cannot arrive here, and the house bans `default:`**, so it
            // is drawn rather than asserted on: the spine with no evidence is still a finished
            // screen, and it costs one string to make a contract change upstream unable to
            // produce a blank sheet.
            case .unasked:
                spine(preview) {
                    Text(String(format: L10n.t("join.preview.unasked"), preview.host))
                        .font(ShellType.body)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Identity, whatever evidence there is, and what the press will do — one block, no internal
    /// hairlines, because there is not enough here to separate.
    private func spine<Evidence: View>(
        _ preview: SourcePreview,
        @ViewBuilder _ evidence: () -> Evidence
    ) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.pad) {
            identityLine(preview.kind)
            evidence()
            outcome(preview)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
    }

    /// The rich case, which is the variation and not the design.
    private func stated(_ preview: SourcePreview, _ profile: SourceProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: ShellSpace.pad) {
                if let thumbnail = profile.thumbnail { hero(thumbnail, host: preview.host) }
                VStack(alignment: .leading, spacing: ShellSpace.snug) {
                    identityLine(preview.kind)
                    if let title = profile.title {
                        Text(title)
                            .font(ShellType.name)
                            .foregroundStyle(ShellChrome.ink(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let summary = profile.summary {
                        Text(summary)
                            .font(ShellType.body)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                figures(profile)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ShellSpace.pad)

            if !profile.rules.isEmpty {
                hairline
                rules(profile.rules)
            }
            hairline
            VStack(alignment: .leading, spacing: ShellSpace.pad) {
                outcome(preview)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ShellSpace.pad)
        }
    }

    /// The server's own picture of itself.
    ///
    /// **The hairline overlay is a light-mode requirement, not trim.** `ShellChrome.page` in light
    /// is very nearly white, and a banner with a pale edge bleeds into the page without it.
    private func hero(_ url: URL, host: String) -> some View {
        RemoteImage(
            url: url,
            tier: .deck,
            host: host,
            alt: String(format: L10n.t("join.preview.thumbnail"), host),
            radius: ShellSpace.tight
        )
        .aspectRatio(16 / 9, contentMode: .fill)
        .frame(maxWidth: .infinity, maxHeight: Metrics.hero)
        .clipShape(RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous)
                .strokeBorder(ShellChrome.hairline(colorScheme), lineWidth: ShellSpace.hair)
        }
    }

    private func identityLine(_ kind: ProtocolKind) -> some View {
        Text(kind.displayName)
            + Text(verbatim: " · ")
            + Text(DummyItem.shapeWord(DummyItem.shape(of: kind)))
    }

    /// What the server stated about its size and its door, and **only** what it stated.
    ///
    /// Concatenated `Text` rather than an `HStack`, which is `BoardPickerSheet.stated(_:)`'s
    /// technique and the house's answer to this exact problem: the numbers follow the shell's
    /// language, and the line wraps instead of clipping at a 460pt sheet in Chinese.
    @ViewBuilder
    private func figures(_ profile: SourceProfile) -> some View {
        let stated = Self.figureLine(profile)
        if stated != nil || profile.registration != nil {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                if let stated {
                    stated
                        .font(ShellType.reading)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // **Kept apart from the outcome line on purpose.** Whether a stranger may sign up
                // is a fact about the server's character; whether *this reader* may read it is a
                // fact about their press. Drawn adjacently, a reader reads "sign-ups are closed"
                // as "I cannot read this", which is false for most servers.
                if let registration = profile.registration {
                    Text(L10n.t(Self.registrationKey(registration)))
                        .font(ShellType.meta)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func figureLine(_ profile: SourceProfile) -> Text? {
        dotted(figurePieces(profile))
    }

    /// Readings joined by `" · "`, as **concatenated `Text` and never as a formatted `String`** —
    /// `BoardPickerSheet.stated(_:)`'s technique and the house's answer to this exact problem: the
    /// line wraps instead of clipping at a 460pt sheet in Chinese.
    ///
    /// Shared with the source page's rows, which draw the same figures about the same server. Two
    /// copies of a five-line loop is not the cost; two places that can come to disagree about what
    /// separates two readings is.
    static func dotted(_ pieces: [String]) -> Text? {
        var line: Text?
        for piece in pieces {
            line = line.map { $0 + Text(verbatim: " · ") + Text(piece) } ?? Text(piece)
        }
        return line
    }

    /// The figures a server stated, each already a sentence, in the order they are read.
    ///
    /// **Split out from `figureLine` because the source page needs the same facts twice over.** It
    /// draws them as a concatenated `Text`, like this sheet, *and* has to put them into one spoken
    /// label for a row collapsed to a single accessibility element — and a `Text` cannot be read
    /// back out. Two spellings of "what this server stated about its size" is two things to drift,
    /// which is the whole argument `shapeWord` already won for the shape.
    ///
    /// Nothing where the server stated nothing: a fact it did not state is drawn as nothing and
    /// never as a zero, which is this house's second rule.
    /// `language` is threaded to **both** halves of every piece — the sentence and the number in
    /// it — so the two cannot come back in different languages. That is the failure this parameter
    /// exists for: `L10n.t` was already resolving the shell's language while `compact` quietly
    /// resolved the device's.
    static func figurePieces(_ profile: SourceProfile, language: DummyLanguage? = nil) -> [String] {
        var pieces: [String] = []
        if let active = profile.activeMonth {
            pieces.append(String(
                format: L10n.t("join.preview.activeMonth", language: language),
                compact(active, language: language)
            ))
        }
        if let people = profile.people {
            pieces.append(String(
                format: L10n.t("account.catalog.people", language: language),
                compact(people, language: language)
            ))
        }
        if let posts = profile.posts {
            pieces.append(String(
                format: L10n.t("join.preview.posts", language: language),
                compact(posts, language: language)
            ))
        }
        return pieces
    }

    /// **No `default:`.** A registration state swept into somebody else's sentence is a reader
    /// told the wrong thing about whether they can join a server.
    static func registrationKey(_ registration: SourceProfile.Registration) -> String {
        switch registration {
        case .open: "join.preview.reg.open"
        case .byApproval: "join.preview.reg.approval"
        case .closed: "join.preview.reg.closed"
        }
    }

    /// **The numbers are information, not styling.** Every server's own about page numbers its
    /// rules, and a reader comparing "rule 3" with what a moderator quoted at them needs it.
    /// Monospaced so a column of 1–9 does not wobble.
    private func rules(_ rules: [String]) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Text(L10n.t("join.preview.rules"))
                .font(ShellType.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                    Text(verbatim: "\(index + 1)")
                        .font(ShellType.reading)
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .accessibilityHidden(true)
                    Text(rule)
                        .font(ShellType.body)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                // The number is on screen for a sighted reader and would simply be gone
                // otherwise — `BoardPickerSheet.spoken(_:)`'s doctrine applied to a list.
                .accessibilityLabel(String(
                    format: L10n.t("join.preview.rules.spoken"),
                    index + 1, rules.count, rule
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ShellSpace.pad)
        .accessibilityLabel(L10n.t("join.preview.rules"))
    }

    /// What pressing Subscribe will do — or, where the server has said a signed-out reader may
    /// not read it, what it will most likely do instead.
    @ViewBuilder
    private func outcome(_ preview: SourcePreview) -> some View {
        if let caution = Self.caution(preview) {
            // **It replaces the outcome line rather than sitting beside it, because it *is* the
            // outcome.** Full `ink` at medium weight and one literal glyph: the only full-ink
            // body text and the only glyph in the preview, so it reads as the significant line
            // without borrowing `alarm`, which is spent on refusals that have actually happened.
            //
            // **One glyph for both cautions, and the sentence carries the difference.** A second
            // symbol would be a second statement, and this house spends glyphs one at a time —
            // what the reader needs told apart is the cause and the remedy, which are words.
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Image(systemName: "lock")
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .accessibilityHidden(true)
                Text(L10n.t(caution.key))
                    .font(ShellType.meta.weight(.medium))
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(L10n.t(Self.outcomeKey(preview.kind)))
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the reader is likely to meet if they press, where the look already found out.
    ///
    /// **Two of them, because they are two different facts and the reader can act on them
    /// differently.** One is the server's own policy and the other is a doorman in front of it;
    /// folding them would assert "reading this needs an account" about a forum that may read
    /// perfectly well to a signed-out human, which is a claim this app would have invented.
    enum Caution: Equatable {
        /// **The server said so about itself.** A signed-out reader may not read it.
        case needsAccount
        /// **Something in front of the server said so, and the server said nothing.** A filter
        /// decided this app was a robot. Usually a sign-in clears it.
        case turnedAway

        var key: String {
            switch self {
            case .needsAccount: "join.preview.closed"
            case .turnedAway: "join.preview.turnedAway"
            }
        }
    }

    /// **A prediction, never a refusal**, in either shape. `nil` on `readsWithoutAccount` is
    /// "this protocol has no such idea" and is not a warning; only a stated `false` is.
    ///
    /// **No `default:`** on the answer: which case carries the caution is a decision, and a new
    /// one swept in here is a screen that warns about the wrong thing or stays silent about the
    /// right one.
    static func caution(_ preview: SourcePreview) -> Caution? {
        switch preview.profile {
        case .stated(let profile):
            profile.readsWithoutAccount == false ? .needsAccount : nil
        // A refusal is the one read failure that predicts the press, and the only one a reader
        // can do something about. The rest say nothing about whether this server can be joined.
        case .unread(_, _, let error):
            if case .refused = error { .turnedAway } else { nil }
        case .silent, .unasked:
            nil
        }
    }

    /// Whether the press has been warned about at all — what withdraws the Return key and adds
    /// the spoken hint, which both cautions earn equally.
    static func warns(_ preview: SourcePreview) -> Bool {
        caution(preview) != nil
    }

    /// **No `default:`**, so units 6–8 break the build at the place that has to decide what a
    /// press on their protocol actually does.
    static func outcomeKey(_ kind: ProtocolKind) -> String {
        switch kind {
        case .discuz: "join.preview.next.boards"
        case .discourse: "join.preview.next.forum"
        case .mastodon, .pleroma, .akkoma, .misskey, .pixelfed, .lemmy, .peertube, .friendica,
             .gotosocial, .unknown:
            "join.preview.next.microblog"
        }
    }

    /// Why a profile could not be read, as a sentence. `ShellSession.unreadMessage(_:)`'s shape,
    /// one layer up and about a document rather than a board.
    ///
    /// **No `default:`.** A reason swept into somebody else's sentence tells the reader the wrong
    /// thing about a server they can very probably still have.
    static func unreadMessage(_ error: ProfileError) -> String {
        switch error {
        case .unreachable: L10n.t("join.preview.unread.network")
        case .refused(let status): String(format: L10n.t("join.preview.unread.refused"), status)
        case .unreadable: L10n.t("join.preview.unread.unreadable")
        }
    }
}
