import FediqoCore
import SwiftUI

/// What the About tab of somebody's page says, as it is handed it: whose view the page is,
/// what their source says of the account and in their own words, how the reader stands to
/// them, the line about the server they live on, and — on the reader's own page — what is
/// theirs there.
///
/// **A value, made where the source is asked** (`ShellPersonTabs.about`), so the tab draws
/// what it is given and the keys walk the very blocks it draws (`blocks`).
///
/// **While their own server's word is drawn, About alone is that server's**: its sentences,
/// words and fields, with nothing in them to press, and its figures as one line of words. The
/// head, every other tab and every act stay the added source's.
struct PersonAboutSaid: Equatable {
    /// One block of the tab, top to bottom: what the lamp stops on.
    enum Block: String, CaseIterable {
        case view, sentences, picture, words, fields, featuredTags, featuredPeople, figures, none, stands, boosts, notices, home,
             requests, muted, blocked, servers, waiting, you
    }

    /// The host of the source that says, and whose copies the pictures are.
    let source: String
    /// Whose view this is, in a sentence: the source's, or their own server's and when.
    var view: String
    /// Whose words are drawn: as the source said them, or as their own server did.
    var person: Person?
    /// Whether what is drawn is their own server's word: letters alone, nothing fetched.
    var fromHome = false
    /// The account's sentences, each beside its glyph.
    var sentences: [PersonSaid.Line] = []
    /// Their own server's figures, as one line of words: nothing of the added source's, whose
    /// figures stand in the head.
    var figures: String?
    /// What stands where the source said who they are and nothing more.
    var none: String?
    /// How the reader stands to them, or nothing where nobody stands to them here.
    var standing: PersonActing?
    /// The line about the server they live on, where there is one to ask.
    var home: PersonHomeLine?
    /// The way to the hashtags the reader follows, on their own page.
    var followed: FollowedTagsEntry?
    /// The way to the people who ask to follow the reader, on their own page (#313).
    var requests: RequestsEntry?
    /// The ways to whom the reader mutes and blocks, and the servers they block, on their own
    /// page (#314): one each, or the one lock where the sign-in does not see them.
    var keeping: [KeepingEntry] = []
    /// The way to the posts waiting to be sent at this source, on the reader's own page (#333).
    var waiting: WaitingEntry?
    /// What they feature on their profile (#315, #318), or nothing where it is not asked.
    var featured: FeaturedSaid?

    /// What About is handed, from what the page was: the source's word, their own server's
    /// where it is drawn, and how the reader stands.
    ///
    /// `hidden` is whether the page has no tab for their lists because the account hides
    /// them: said here in words, since no tab says it. `homeInLine` is whether the line about
    /// their own server stands over the tabs instead — where the source has not heard of them.
    static func made(
        of said: PersonSaid, home: PersonHomeSaid?, homeLine: PersonHomeLine?, standing: PersonActing?,
        followed: FollowedTagsEntry?, hidden: Bool, requests: RequestsEntry? = nil, language: DummyLanguage? = nil
    ) -> PersonAboutSaid {
        var about = PersonAboutSaid(
            source: said.source,
            view: home?.whoseView(language: language) ?? PersonSaid.whoseView(said.source, person: said.person, language: language),
            person: home?.person ?? said.person, fromHome: home != nil, standing: standing,
            home: said.reading == .unheardOf ? nil : homeLine, followed: followed, requests: requests
        )
        guard let person = about.person else { return about }
        about.sentences = PersonSaid.marks(of: person, source: home?.home ?? said.source, language: language)
        if home != nil {
            let counted = PersonSaid.counts(of: person.tally, language: language)
            about.figures = counted.isEmpty ? nil : counted.joined(separator: L10n.t("people.row.between", language: language))
        } else {
            if hidden {
                let words = String(format: L10n.t("person.lists.hidden", language: language), person.lineHandle)
                about.sentences.append(PersonSaid.Line(symbol: "eye.slash.circle", words: words))
            }
            if person.headerURL == nil, person.words.isEmpty, person.fields.isEmpty {
                about.none = String(format: L10n.t("person.about.none", language: language), said.source)
            }
        }
        return about
    }

    /// Whether there is anything to say of how the reader stands to them.
    var standsDrawn: Bool {
        guard let standing else { return false }
        return standing.shown != nil || standing.lock != nil
    }

    /// One of the two things taken from somebody followed (#313), where About has a row of it:
    /// under how the reader stands, and only where the reader follows them.
    func taken(_ which: PersonActing.Narrow.Which) -> PersonActing.Narrow? {
        standing?.narrows().first { $0.which == which }
    }

    /// The blocks drawn, top to bottom.
    var blocks: [Block] {
        Block.allCases.filter { block in
            switch block {
            case .view: true
            case .sentences: !sentences.isEmpty
            case .picture: person?.headerURL != nil
            case .words: person?.words.isEmpty == false
            case .fields: person?.fields.isEmpty == false
            case .featuredTags: featured?.tagsDrawn == true
            case .featuredPeople: featured?.people != nil
            case .figures: figures != nil
            case .none: none != nil
            case .stands: standsDrawn
            case .boosts: taken(.boosts) != nil
            case .notices: taken(.notices) != nil
            case .home: home != nil
            case .requests: requests != nil
            case .muted: keeping.contains { $0.which == .muted }
            case .blocked: keeping.contains { $0.which == .blocked }
            case .servers: keeping.contains { $0.which == .servers }
            case .waiting: waiting != nil
            case .you: followed != nil
            }
        }
    }

    /// What the lamp stands on where it stands on `block`. The way to the hashtags followed
    /// keeps its own name, so Return on it opens what a press on it opens.
    func lamp(on block: Block) -> String {
        switch block {
        case .you: followed?.id ?? Self.name(block)
        case .featuredPeople: FeaturedSaid.peopleID
        case .featuredTags: FeaturedSaid.tagsID
        default: Self.name(block)
        }
    }

    static func name(_ block: Block) -> String { "about." + block.rawValue }

    /// Every row `j` and `k` walk on About, top to bottom as it is drawn: one a block, and
    /// one a hashtag they feature.
    var walked: [String] {
        blocks.flatMap { block in
            switch block {
            case .featuredTags: featured?.tagRows ?? []
            case .featuredPeople: [FeaturedSaid.peopleID]
            default: [lamp(on: block)]
            }
        }
    }

    /// What Return does with the lamp on a block of About.
    enum Press: Equatable {
        case home(PersonHomeLine.Press)
        /// The question that asks the sign-in for following.
        case askFollows
        /// One of what is taken from them, turned the other way.
        case act(PersonAct)
        /// What they feature (#315, #318): answered by whoever takes that step.
        case featured(FeaturedPress)
    }

    /// The press of the block the lamp is on, where that block is one: the line about their
    /// own server, and the lock of a sign-in that may be asked for following. The way to the
    /// hashtags followed is answered by whoever takes that step.
    func press(on id: String) -> Press? {
        if let press = featured?.press(on: id) { return .featured(press) }
        if id == Self.name(.home), let press = home?.press { return .home(press) }
        if id == Self.name(.stands), standing?.lock?.asks == true { return .askFollows }
        for which in PersonActing.Narrow.Which.allCases where id == Self.name(which == .boosts ? .boosts : .notices) {
            guard standing?.narrowsTakePress == true, let row = taken(which) else { return nil }
            return .act(row.act)
        }
        return nil
    }
}

/// The About tab of somebody's page, drawn: each block of what it was handed, top to bottom,
/// the one the lamp is on drawn on the lamp's wash.
///
/// **It draws what it is given and asks nothing**: which blocks there are is the value's, and
/// which kind of source this is is never looked at here.
struct PersonAbout<Lead: View>: View {
    let said: PersonAboutSaid
    /// The block the lamp is on.
    var lit: String?
    var jumpToTop: Int = 0
    var onHome: (PersonHomeLine.Press) -> Void = { _ in }
    var onFollowed: ((FollowedTagsEntry) -> Void)?
    /// The press on the lock of a sign-in that was not asked for following.
    var onAskFollows: () -> Void = {}
    /// A switch of what is taken from them, pressed.
    var onAct: (PersonAct) -> Void = { _ in }
    /// The way to the people who ask to follow the reader, pressed.
    var onRequests: (RequestsEntry) -> Void = { _ in }
    /// A way to whom the reader mutes or blocks, or the servers they block, pressed (#314).
    var onKeeping: (KeepingEntry) -> Void = { _ in }
    /// A hashtag they feature, or the way to the people they feature (#315, #318).
    var onFeatured: (FeaturedPress) -> Void = { _ in }
    /// What stands over the blocks and scrolls away with them: the page's head, at a text
    /// size where it would fill the page.
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
    /// What the line to what waits opens through; nothing where the tab is drawn alone.
    @Environment(ShellSession.self) private var session: ShellSession?
    @ShellMetric(relativeTo: .body) private var bandHeight: CGFloat = 96
    @ShellMetric(relativeTo: .caption2) private var sealColumn: CGFloat = 16
    @ShellMetric(relativeTo: .caption2) private var glyphColumn: CGFloat = 20

    private static var top: String { "about.top" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    lead
                    ForEach(said.blocks, id: \.self) { block in
                        drawn(block)
                            .padding(.horizontal, ShellSpace.pad)
                            .padding(.vertical, ShellSpace.snug)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(AboutBlockLit(lit: said.lamp(on: block) == lit))
                            .id(said.lamp(on: block))
                    }
                }
                .padding(.vertical, ShellSpace.tight)
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            .onChange(of: lit) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jumpToTop) { _, _ in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(Self.top, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private func drawn(_ block: PersonAboutSaid.Block) -> some View {
        switch block {
        case .view: quiet(said.view)
        case .sentences: sentences
        case .picture: picture
        case .words: words
        case .fields: fields
        case .featuredTags: featuredTags
        case .featuredPeople: featuredPeople
        case .figures: quiet(said.figures ?? "")
        case .none: quiet(said.none ?? "")
        case .stands: stands
        case .boosts: narrowRow(.boosts)
        case .notices: narrowRow(.notices)
        case .home: home
        case .requests: requests
        case .muted: keeping(.muted)
        case .blocked: keeping(.blocked)
        case .servers: keeping(.servers)
        case .waiting: waitingLine
        case .you: you
        }
    }

    private func quiet(_ sentence: String) -> some View {
        Text(sentence)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A glyph in a column of its own and the words it stands for beside it: one thing to a
    /// listener, who is read the words.
    private func marked(_ symbol: String, _ words: String, ink: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Image(systemName: symbol)
                // A whole number of points: beside a column that is not, words that wrap are
                // laid out a fraction wider than the room they were given.
                .frame(width: glyphColumn.rounded(.up), alignment: .leading)
                .accessibilityHidden(true)
            Text(words).fixedSize(horizontal: false, vertical: true)
        }
        .shellFont(.meta)
        .foregroundStyle(ink)
        .accessibilityElement(children: .combine)
    }

    private var sentences: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ForEach(said.sentences) { marked($0.symbol, $0.words, ink: ShellChrome.inkDim(colorScheme)) }
        }
    }

    /// The picture at the head of their profile: a low band, the source's own copy.
    @ViewBuilder
    private var picture: some View {
        if let header = said.person?.headerURL {
            RemoteImage(
                url: header, tier: .deck, host: said.source, standing: .picture, alt: nil, speaks: false,
                radius: DummyItemRow.Box.plate
            )
            .frame(maxWidth: .infinity)
            .frame(height: bandHeight)
            .clipped()
            .accessibilityHidden(true)
        }
    }

    /// Their own words. **Letters alone where they are their own server's**: an address or a
    /// hashtag in them is then no press.
    @ViewBuilder
    private var words: some View {
        if let person = said.person {
            EmojiText.words(person.words, emojis: person.emojis, host: said.source, covered: said.fromHome)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The fields they filled in: a label, and what stands under it.
    ///
    /// **The source's "checked" is a mark of ours, in a place of its own**: before the label,
    /// in the shell's own ink, outside the run their letters and pictures are drawn in — so
    /// nothing they wrote, a custom emoji least of all, can stand where it stands.
    @ViewBuilder
    private var fields: some View {
        if let person = said.person {
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                ForEach(Array(person.fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                        Group {
                            if field.verifiedAt != nil {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                                    .help(PersonSaid.checked(said.source))
                                    .accessibilityLabel(PersonSaid.checked(said.source))
                            } else {
                                Color.clear.accessibilityHidden(true)
                            }
                        }
                        .shellFont(.mark)
                        .frame(width: sealColumn, alignment: .leading)
                        VStack(alignment: .leading, spacing: ShellSpace.hair) {
                            EmojiText(field.name, emojis: person.emojis, host: said.source, role: .meta)
                                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                                .lineLimit(1)
                            EmojiText(field.value, emojis: person.emojis, host: said.source, role: .meta)
                                .foregroundStyle(ShellChrome.ink(colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// How the reader stands to them, in words: a line for each way, beside the glyph the
    /// head draws alone; that it is neither; and how the
    /// sign-in stands where it holds less than following needs — the whole sentence, a press
    /// where it asks.
    @ViewBuilder
    private var stands: some View {
        if let standing = said.standing {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                ForEach(standing.marks()) { marked($0.symbol, $0.words, ink: ShellChrome.ink(colorScheme)) }
                if let neither = standing.neitherWords() { quiet(neither) }
                if let words = standing.lockWords() { locked(words, asks: standing.lock?.asks == true, press: onAskFollows) }
            }
        }
    }

    /// One thing taken from them, as a row: its glyph, what it is and how it stands in words,
    /// the whole row a press that turns it — shown at the press, and sent after. While a
    /// press is on its way the row is words, and takes none.
    @ViewBuilder
    private func narrowRow(_ which: PersonActing.Narrow.Which) -> some View {
        if let standing = said.standing, let row = said.taken(which) {
            let label = marked(row.symbol, row.words(), ink: ShellChrome.ink(colorScheme))
            if standing.narrowsTakePress {
                Button { onAct(row.act) } label: { label.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(ShellIconButton.hover(name: row.words(), help: standing.narrowHint()))
                    .accessibilityLabel(row.name())
                    .accessibilityValue(row.state())
                    .accessibilityHint(standing.narrowHint())
            } else {
                label
            }
        }
    }

    @ViewBuilder
    private func locked(_ words: String, asks: Bool, press: @escaping () -> Void) -> some View {
        let label = marked(SourceRow.permissionSymbol, words, ink: ShellChrome.markDim(colorScheme))
        if asks {
            Button(action: press) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(L10n.t("mark.dim.askAgain"))
        } else {
            label
        }
    }

    /// The hashtags they feature: a head, and each a row the lamp stops on — the hashtag, and
    /// what the source says of it — whose press opens the hashtag's page. Being asked, and an
    /// ask that came to nothing, are the page's toast to say (DESIGN-reload).
    @ViewBuilder
    private var featuredTags: some View {
        if let featured = said.featured {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                Text(featured.tagsTitle())
                    .shellFont(.meta, weight: .semibold)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                ForEach(featured.tags, id: \.self) { tag in featuredRow(tag, of: featured) }
                ForEach(featured.missed, id: \.self) { missed in
                    Text(missed)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One hashtag they feature: its press opens the hashtag's page, and on the reader's own
    /// page its `…` holds Take off your profile.
    private func featuredRow(_ tag: FeaturedTag, of featured: FeaturedSaid) -> some View {
        HStack(alignment: .center, spacing: ShellSpace.step) {
            Button { onFeatured(.tag(tag.tag)) } label: {
                VStack(alignment: .leading, spacing: ShellSpace.hair) {
                    Text(tag.tag.text).shellFont(.body).foregroundStyle(ShellChrome.ink(colorScheme))
                    if let words = featured.said(of: tag) {
                        Text(words).shellFont(.meta).foregroundStyle(ShellChrome.inkDim(colorScheme))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(featured.spoken(tag))
            .accessibilityAddTraits(.isButton)
            if let more = featured.more(of: tag, act: { onFeatured(.takeOff(tag.tag)) }) {
                ShellMoreButton(label: featured.moreLabel(of: tag)) { more }
                    .fixedSize()
            }
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.hair)
        .modifier(AboutBlockLit(lit: FeaturedSaid.lamp(of: tag.tag) == lit))
        .padding(.horizontal, -ShellSpace.pad)
        .id(FeaturedSaid.lamp(of: tag.tag))
    }


    /// The way to the people they feature: words, and the mark that says it leads on.
    @ViewBuilder
    private var featuredPeople: some View {
        if let featured = said.featured, let list = featured.people {
            Button { onFeatured(.people(list)) } label: {
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                    Text(featured.peopleWords()).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.right").shellFont(.mark).accessibilityHidden(true)
                }
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(featured.peopleWords())
        }
    }

    @ViewBuilder
    private var home: some View {
        if let line = said.home {
            // The line's own margins are the block's here.
            PersonHomeLineView(line: line, onPress: onHome)
                .padding(.horizontal, -ShellSpace.pad)
                .padding(.vertical, -ShellSpace.snug)
        }
    }

    /// The way to the people who ask to follow the reader: words and the mark that says it
    /// leads on; or, where the sign-in does not see who follows them, its own sentence dim
    /// with the lock, a press where it may be asked.
    @ViewBuilder
    private var requests: some View {
        if let entry = said.requests {
            if let place = entry.locked {
                locked(entry.words(), asks: place.asks, press: { onRequests(entry) })
            } else {
                Button { onRequests(entry) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                        Text(entry.words()).fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.right").shellFont(.mark).accessibilityHidden(true)
                    }
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.words())
            }
        }
    }

    /// The way to the posts waiting to be sent at this source (#333, X0 §2): no count — that would
    /// be an ask at every open of the page — and the list is read when it is opened. Dim with the
    /// lock's words where the sign-in lacks the writing part, its press asking.
    @ViewBuilder
    private var waitingLine: some View {
        if let entry = said.waiting {
            if entry.locked != nil {
                locked(entry.words(), asks: true, press: { session.map { _ = $0.askFor([.acting], host: entry.host) } })
            } else {
                Button { session.map { $0.later.show(host: entry.host, in: $0) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                        Image(systemName: "clock").accessibilityHidden(true)
                        Text(entry.words()).fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.right").shellFont(.mark).accessibilityHidden(true)
                    }
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.words())
            }
        }
    }

    /// A way to one of the reader's lists of whom they keep away (#314): words and the mark that
    /// says it leads on — or the sign-in's lock, dim, a press where it may be asked.
    @ViewBuilder
    private func keeping(_ which: KeepingEntry.Which) -> some View {
        if let entry = said.keeping.first(where: { $0.which == which }) {
            if let place = entry.locked {
                locked(entry.words(), asks: place.asks, press: { onKeeping(entry) })
            } else {
                Button { onKeeping(entry) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                        Image(systemName: entry.symbol).accessibilityHidden(true)
                        Text(entry.words()).fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.right").shellFont(.mark).accessibilityHidden(true)
                    }
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.words())
            }
        }
    }

    @ViewBuilder
    private var you: some View {
        if let followed = said.followed, let onFollowed {
            FollowedTagsEntryLine(entry: followed, lit: false, onPress: onFollowed)
                .shellFont(.reading)
        }
    }
}
