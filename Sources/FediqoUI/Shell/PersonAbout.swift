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
        case view, sentences, picture, words, fields, figures, none, stands, boosts, notices, home, you
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

    /// What About is handed, from what the page was: the source's word, their own server's
    /// where it is drawn, and how the reader stands.
    ///
    /// `hidden` is whether the page has no tab for their lists because the account hides
    /// them: said here in words, since no tab says it. `homeInLine` is whether the line about
    /// their own server stands over the tabs instead — where the source has not heard of them.
    static func made(
        of said: PersonSaid, home: PersonHomeSaid?, homeLine: PersonHomeLine?, standing: PersonActing?,
        followed: FollowedTagsEntry?, hidden: Bool, language: DummyLanguage? = nil
    ) -> PersonAboutSaid {
        var about = PersonAboutSaid(
            source: said.source,
            view: home?.whoseView(language: language) ?? PersonSaid.whoseView(said.source, person: said.person, language: language),
            person: home?.person ?? said.person, fromHome: home != nil, standing: standing,
            home: said.reading == .unheardOf ? nil : homeLine, followed: followed
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
        return standing.shown != nil || standing.stillAsked || standing.offersAgain || standing.lock != nil
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
            case .figures: figures != nil
            case .none: none != nil
            case .stands: standsDrawn
            case .boosts: taken(.boosts) != nil
            case .notices: taken(.notices) != nil
            case .home: home != nil
            case .you: followed != nil
            }
        }
    }

    /// What the lamp stands on where it stands on `block`. The way to the hashtags followed
    /// keeps its own name, so Return on it opens what a press on it opens.
    func lamp(on block: Block) -> String {
        block == .you ? followed?.id ?? Self.name(block) : Self.name(block)
    }

    static func name(_ block: Block) -> String { "about." + block.rawValue }

    /// Every row `j` and `k` walk on About, top to bottom as it is drawn.
    var walked: [String] { blocks.map(lamp(on:)) }

    /// What Return does with the lamp on a block of About.
    enum Press: Equatable {
        case home(PersonHomeLine.Press)
        /// The question that asks the sign-in for following.
        case askFollows
        /// One of what is taken from them, turned the other way.
        case act(PersonAct)
    }

    /// The press of the block the lamp is on, where that block is one: the line about their
    /// own server, and the lock of a sign-in that may be asked for following. The way to the
    /// hashtags followed is answered by whoever takes that step.
    func press(on id: String) -> Press? {
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
    /// "Try again", where the source could not be asked how the reader stands to them.
    var onStandingAgain: () -> Void = {}
    /// A switch of what is taken from them, pressed.
    var onAct: (PersonAct) -> Void = { _ in }
    /// What stands over the blocks and scrolls away with them: the page's head, at a text
    /// size where it would fill the page.
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme
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
                            .background(said.lamp(on: block) == lit ? ShellChrome.floatFill(colorScheme) : .clear)
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
        case .figures: quiet(said.figures ?? "")
        case .none: quiet(said.none ?? "")
        case .stands: stands
        case .boosts: narrowRow(.boosts)
        case .notices: narrowRow(.notices)
        case .home: home
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
    /// head draws alone; that it is neither, is being asked, or could not be; and how the
    /// sign-in stands where it holds less than following needs — the whole sentence, a press
    /// where it asks.
    @ViewBuilder
    private var stands: some View {
        if let standing = said.standing {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                ForEach(standing.marks()) { marked($0.symbol, $0.words, ink: ShellChrome.ink(colorScheme)) }
                if let neither = standing.neitherWords() { quiet(neither) }
                if let asking = standing.askingWords() { quiet(asking) }
                if let failed = standing.failedWords() {
                    marked(PersonHead.failedSymbol, failed, ink: ShellChrome.ink(colorScheme))
                    ShellLinkButton(L10n.t("person.retry"), action: onStandingAgain).fixedSize()
                }
                if let words = standing.lockWords() { locked(words, asks: standing.lock?.asks == true) }
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
    private func locked(_ words: String, asks: Bool) -> some View {
        let label = marked(SourceRow.permissionSymbol, words, ink: ShellChrome.markDim(colorScheme))
        if asks {
            Button(action: onAskFollows) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(L10n.t("mark.dim.askAgain"))
        } else {
            label
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

    @ViewBuilder
    private var you: some View {
        if let followed = said.followed, let onFollowed {
            FollowedTagsEntryLine(entry: followed, lit: false, onPress: onFollowed)
                .shellFont(.reading)
        }
    }
}
