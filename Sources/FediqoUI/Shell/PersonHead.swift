import FediqoCore
import SwiftUI

/// The head of somebody's page, as it is handed it: who they are, the marks of the account,
/// whose view the page is, what the source counts of them, and how the reader stands to them.
///
/// **A value, made where the source is asked** (`ShellPersonTabs.head`). A page handed no
/// word of a source — a forum's author — has the head it always had: the host it was read
/// through, in words, and how much of theirs this device holds.
struct PersonHeadSaid: Equatable {
    var name: String
    var handle: String?
    var emojis: [CustomEmoji] = []
    /// The server this device met them on: whose copies the pictures are.
    let host: String
    var face: URL?
    /// The marks of the account after the name, each called by its sentence.
    var marks: [PersonSaid.Line] = []
    /// The source whose view the page is, for the pill beside the handle — and that in a
    /// sentence, for a listener. Nothing on a page handed no word of a source.
    var whose: String?
    var whoseSpoken: String?
    /// The host this device read them through, in words, and how much of theirs it holds: a
    /// page handed no word of a source, and nothing on any other.
    var through: String?
    var held: String?
    /// What the source counts of them, each a press that brings its tab in front.
    var figures: [PersonSaid.Figure] = []
    /// How the reader stands to them, or nothing where nobody stands to them here.
    var standing: PersonActing?
    /// Change, where the page is the reader's own: what stands where Follow would.
    var change: OwnChangeEntry?

    /// What the head is handed, from what the page was: what their row carried until the
    /// source has said who they are, and its word from then on — the name, the handle and the
    /// face the answer carried, so an answer about somebody else shows as somebody else.
    static func made(
        of person: DummyPerson, said: PersonSaid?, tabs: [PersonTab], held: Int, heldAtLeast: Bool = false,
        standing: PersonActing?, language: DummyLanguage? = nil
    ) -> PersonHeadSaid {
        guard let said else {
            return PersonHeadSaid(
                name: person.name, handle: person.handle, emojis: person.emojis, host: person.host, face: person.avatarURL,
                through: String(format: L10n.t("person.through", language: language), person.host),
                held: heldLine(held, atLeast: heldAtLeast, language: language)
            )
        }
        var head = PersonHeadSaid(
            name: person.name, handle: person.handle, emojis: person.emojis, host: person.host, face: person.avatarURL,
            whose: said.source, whoseSpoken: PersonSaid.whoseView(said.source, person: said.person, language: language),
            standing: standing
        )
        guard let subject = said.person else { return head }
        head.name = subject.lineName
        head.handle = subject.lineHandle
        head.emojis = subject.emojis
        head.face = subject.avatarURL
        head.marks = PersonSaid.marks(of: subject, source: said.source, language: language)
        head.figures = PersonSaid.figures(of: subject, tabs: tabs, language: language)
        return head
    }

    /// How much of theirs is here. **A count of what this device holds and never of what they
    /// have written** — the second is a figure only their server could give.
    /// `atLeast`: counted over what this run has read of a store held in part (#360, C31) —
    /// at least so many, never how many.
    static func heldLine(_ count: Int, atLeast: Bool = false, language: DummyLanguage? = nil) -> String {
        L10n.count(atLeast ? "person.held.atLeast" : "person.held", count, language: language)
    }

    /// What a listener is read of who they are, as one element: the name, the handle, whose
    /// view the page is, and each mark of the account in words.
    func spoken(language: DummyLanguage? = nil) -> String {
        ([name, handle, whoseSpoken ?? through].compactMap { $0 } + marks.map(\.words))
            .filter { !$0.isEmpty }.joined(separator: L10n.t("people.row.between", language: language))
    }
}

/// Where a hosted head laid its parts out, in the head's own space.
@MainActor
final class PersonHeadProbe {
    enum Part: Hashable {
        case face, name, handle, whose, figures, stands, acts
    }

    static let space = "PersonHead.parts"
    var frames: [Part: CGRect] = [:]
    /// How wide the head itself was laid out.
    var width: CGFloat = 0
}

extension EnvironmentValues {
    /// Where a hosted head reports what it laid out. Nothing in the app.
    @Entry var personHeadProbe: PersonHeadProbe? = nil
}

/// The head of somebody's page, drawn: their face and name with the marks of the account, the
/// handle and whose view this is, the source's figures as glyph and number — each a press
/// that brings its tab in front — and how the reader stands to them as glyphs, with Follow
/// and the page's `…`.
///
///     [face]  Alice Example [lock] [gear]                    [ Follow ]  […]
///             @alice@example.org   (mastodon.social)
///             (bubble 1,204) (pp 2,811) (p··p 310)        [p✓] [p+] [spk/]
///
/// On a narrow page the figures wrap whole, and the marks, Follow and `…` share the line
/// under them.
///
/// **Nothing is carried by colour.** The figure whose tab is in front has its glyph filled
/// and its number semibold on the lamp's wash — a tab pill's own three; one that opens
/// nothing is words on no well; and a way the reader does not stand has no glyph at all.
/// **Every glyph says what it is to a pointer and a listener**: alone it says nothing.
struct PersonHead: View {
    let head: PersonHeadSaid
    /// The tab in front: whose figure is drawn as the one the page is on.
    var front: PersonTab?
    /// A figure pressed: its tab, brought in front.
    var onTab: (PersonTab) -> Void = { _ in }
    /// The head's Follow, or an item of the `…`.
    var onAct: (PersonAct) -> Void = { _ in }
    /// The press on the lock of a sign-in that was not asked for following.
    var onAskFollows: () -> Void = {}
    /// Change pressed, on the reader's own page: the sheet, or the question for the account part.
    var onChange: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellLayout) private var shellLayout
    @Environment(\.personHeadProbe) private var probe
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Whether the face stands over the words and not beside them: at an accessibility text
    /// size, where it has grown with the letters and beside it a name would have no room.
    private var stacked: Bool { typeSize.isAccessibilitySize }

    /// The face at the head of the page. Larger than a row's, because here it is the subject
    /// rather than a fitting beside the words — and scaled with the letters, for the reason
    /// every other fitting in this shell is.
    @ShellMetric(relativeTo: .body) private var faceSide: CGFloat = 56

    /// The glyph that stands where the source could not be asked how the reader stands.
    static let failedSymbol = "exclamationmark.arrow.circlepath"

    var body: some View {
        Group {
            if head.whose == nil {
                plain
            } else if shellLayout == .narrow || stacked {
                narrow
            } else {
                wide
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { room in
            let _ = probe?.width = room.size.width
            Color.clear
        })
        .coordinateSpace(.named(PersonHeadProbe.space))
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .shellMoreHeld()
    }

    // MARK: - The three arrangements

    /// The page of somebody whose source is not asked who people are, as it always was: the
    /// host they were read through, and at the far end how much of theirs is here.
    @ViewBuilder
    private var plain: some View {
        if stacked {
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                face
                plainWho.accessibilityElement(children: .combine)
                plainHeld
            }
        } else {
            HStack(alignment: .center, spacing: ShellSpace.step) {
                HStack(alignment: .center, spacing: ShellSpace.step) {
                    face
                    plainWho
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                plainHeld
            }
        }
    }

    private var plainWho: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            nameLine
            handleLine
            if let through = head.through {
                Text(through)
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var plainHeld: some View {
        if let held = head.held {
            Text(held)
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .lineLimit(1)
        }
    }

    private var wide: some View {
        HStack(alignment: .top, spacing: ShellSpace.step) {
            face
            VStack(alignment: .leading, spacing: ShellSpace.snug) {
                HStack(alignment: .center, spacing: ShellSpace.step) {
                    who
                    Spacer(minLength: 0)
                    acts
                }
                if !head.figures.isEmpty || stands != nil {
                    // Beside the figures where both fit whole, and under them where not.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: ShellSpace.step) {
                            figures
                            Spacer(minLength: 0)
                            standsRun
                        }
                        VStack(alignment: .leading, spacing: ShellSpace.snug) {
                            figures
                            standsRun
                        }
                    }
                }
                words
            }
        }
    }

    private var narrow: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            if stacked {
                face
                who
            } else {
                HStack(alignment: .top, spacing: ShellSpace.step) {
                    face
                    who
                }
            }
            figures
            if stands != nil || acting.map(PersonHeadActs.draws) == true || head.change != nil {
                // On one line where both fit whole, and one under the other where they do not.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: ShellSpace.step) {
                        standsRun
                        Spacer(minLength: 0)
                        acts
                    }
                    VStack(alignment: .leading, spacing: ShellSpace.snug) {
                        standsRun
                        acts
                    }
                }
            }
            words
        }
    }

    // MARK: - Who they are

    /// Their name with the marks of the account, the handle and whose view the page is: one
    /// element to a listener.
    private var who: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            nameLine
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: ShellSpace.snug) {
                    handleLine.fixedSize()
                    whose
                }
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    handleLine
                    whose
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(head.spoken())
        .accessibilityAddTraits(.isHeader)
    }

    /// Their own writing, pictures and all — the same view a row draws a name with, so a name
    /// written in emoji reads the same in both places — and after it the marks of the account.
    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
            EmojiText(head.name, emojis: head.emojis, host: head.host, role: .name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
            ForEach(head.marks) { mark in
                Image(systemName: mark.symbol)
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .help(mark.words)
                    .accessibilityLabel(mark.words)
            }
        }
        .modifier(HeadProbed(.name, probe: probe))
    }

    /// The handle whole, cut in its middle only where a line cannot hold it.
    @ViewBuilder
    private var handleLine: some View {
        if let handle = head.handle {
            Text(handle)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .modifier(HeadProbed(.handle, probe: probe))
        }
    }

    /// Whose view the page is: the source's host, on the well.
    @ViewBuilder
    private var whose: some View {
        if let source = head.whose {
            ShellWellPill(source)
                .help(head.whoseSpoken ?? source)
                .modifier(HeadProbed(.whose, probe: probe))
        }
    }

    /// Their picture, and the plate where the post carried none — the row's own two cases, at
    /// the size this page draws them.
    private var face: some View {
        Group {
            if let url = head.face {
                RemoteImage(
                    url: url,
                    tier: .deck,
                    // The server this device met them on, never their own instance: decision 14,
                    // and the same reading `DummyItemRow.avatar` makes about the same address.
                    host: head.host,
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
        .modifier(HeadProbed(.face, probe: probe))
    }

    // MARK: - The figures

    /// Each figure whole, wrapped to the next line where they do not fit on one — and where
    /// one figure alone is wider than the page, at the largest text, its digits go on to a
    /// second line: never cut, and never shortened.
    @ViewBuilder
    private var figures: some View {
        if !head.figures.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ShellSpace.tight) { ForEach(head.figures) { figure($0).fixedSize() } }
                VStack(alignment: .leading, spacing: ShellSpace.tight) { ForEach(head.figures) { figure($0).fixedSize() } }
                VStack(alignment: .leading, spacing: ShellSpace.tight) { ForEach(head.figures) { figure($0) } }
            }
            .modifier(HeadProbed(.figures, probe: probe))
        }
    }

    private func figure(_ counted: PersonSaid.Figure) -> some View {
        PageFigureView(figure: counted.drawn(front: front)) { onTab(counted.tab) }
    }

    // MARK: - How the reader stands

    private var acting: PersonActing? { head.standing }

    /// What stands where the marks do, or nothing: the source has not said yet, or nobody
    /// stands to them here.
    private var stands: PersonActing? {
        guard let acting, acting.standsInHead else { return nil }
        return acting
    }

    /// How the reader stands to them: each way a mark and a short word beside it, in full
    /// ink — the words a row of a list says it in — and all of them one element to a
    /// listener; where the source could not be asked, the press that asks again; and where
    /// the sign-in holds less than following needs, the mark of a sign-in asked for more and
    /// a word — the whole sentence to a pointer and a listener, and the press that asks
    /// where it may be asked.
    ///
    /// **Each stands whole, on one line where they all fit and one under another where they
    /// do not**: a narrow page, the largest text. None is cut, and none loses its word —
    /// where one alone is wider than the page, its word goes on to a second line.
    @ViewBuilder
    private var standsRun: some View {
        if let stood = stands {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: ShellSpace.step) { standsParts(stood, whole: true) }
                VStack(alignment: .leading, spacing: ShellSpace.tight) { standsParts(stood, whole: true) }
                VStack(alignment: .leading, spacing: ShellSpace.tight) { standsParts(stood, whole: false) }
            }
            .modifier(HeadProbed(.stands, probe: probe))
        }
    }

    /// One way the reader stands: its glyph, and its word beside it.
    private func stance(_ mark: PersonActing.Mark, whole: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
            Image(systemName: mark.symbol).accessibilityHidden(true)
            Text(mark.words)
        }
        .shellFont(.mark)
        .foregroundStyle(ShellChrome.ink(colorScheme))
        .fixedSize(horizontal: whole, vertical: true)
    }

    /// The marks and the presses that stand with them. `whole` is whether each is laid out
    /// on one line of its own length; where it is not, each has the page's width and wraps.
    @ViewBuilder
    private func standsParts(_ stood: PersonActing, whole: Bool) -> some View {
        let marks = stood.marks()
        if !marks.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ShellSpace.step) { ForEach(marks) { stance($0, whole: true) } }
                VStack(alignment: .leading, spacing: ShellSpace.tight) { ForEach(marks) { stance($0, whole: whole) } }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PersonActing.spoken(marks))
        }
        standsPresses(stood, whole: whole)
    }

    /// What stands with the marks and is a press: the sign-in asked for more.
    @ViewBuilder
    private func standsPresses(_ stood: PersonActing, whole: Bool) -> some View {
        if let words = stood.lockWords() { lock(words, asks: stood.lock?.asks == true, whole: whole) }
    }

    @ViewBuilder
    private func lock(_ words: String, asks: Bool, whole: Bool) -> some View {
        let label = Label(L10n.t("account.source.permission.word"), systemImage: SourceRow.permissionSymbol)
            .shellFont(.mark)
            .foregroundStyle(ShellChrome.markDim(colorScheme))
        if asks {
            Button(action: onAskFollows) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(ShellMark.said(words, L10n.t("mark.dim.askAgain")))
                .accessibilityLabel(words)
                .fixedSize(horizontal: whole, vertical: true)
        } else {
            label
                .help(words)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
                .fixedSize(horizontal: whole, vertical: true)
        }
    }

    /// The head's press and the page's `…`, as they were built (`PersonHeadActs`).
    @ViewBuilder
    private var acts: some View {
        if let change = head.change {
            OwnChangeAct(entry: change, onChange: onChange)
                .modifier(HeadProbed(.acts, probe: probe))
        } else if let acting, PersonHeadActs.draws(acting) {
            PersonHeadActs(acting: acting, onAct: onAct, onAsk: onAskFollows)
                .modifier(HeadProbed(.acts, probe: probe))
        }
    }

    /// In full ink under the figures, what no glyph may say: that they block the reader, and
    /// a press that did not arrive.
    @ViewBuilder
    private var words: some View {
        if let acting {
            ForEach(acting.headWords(), id: \.self) { sentence in
                Text(sentence)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Change, on the reader's own page: a press that opens the sheet — or, where the sign-in does
/// not hold the account part, its lock: dim, with the mark of a sign-in asked for more, and the
/// press that asks where it may be asked. No `…` beside it: nothing on it is dangerous.
private struct OwnChangeAct: View {
    let entry: OwnChangeEntry
    let onChange: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let words = entry.lockWords() {
            locked(words, asks: entry.lock?.asks == true)
        } else {
            ShellLinkButton(L10n.t("profile.change"), action: onChange)
                .help(L10n.t("profile.change.help"))
                .accessibilityLabel(entry.spoken())
                .fixedSize()
        }
    }

    @ViewBuilder
    private func locked(_ words: String, asks: Bool) -> some View {
        let label = Label(L10n.t("profile.change"), systemImage: SourceRow.permissionSymbol)
            .shellFont(.meta, weight: .medium)
            .foregroundStyle(ShellChrome.markDim(colorScheme))
        if asks {
            Button(action: onChange) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(ShellMark.said(words, L10n.t("mark.dim.askAgain")))
                .accessibilityLabel(words)
                .accessibilityHint(L10n.t("mark.dim.askAgain"))
                .fixedSize()
        } else {
            label
                .help(words)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
                .fixedSize()
        }
    }
}

/// Reports where one part of the head was laid out to a probe, where one is handed in; draws
/// nothing and changes nothing.
private struct HeadProbed: ViewModifier {
    let part: PersonHeadProbe.Part
    let probe: PersonHeadProbe?

    init(_ part: PersonHeadProbe.Part, probe: PersonHeadProbe?) {
        self.part = part
        self.probe = probe
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let probe {
            content.background(GeometryReader { room in
                let _ = probe.frames[part] = room.frame(in: .named(PersonHeadProbe.space))
                Color.clear
            })
        } else {
            content
        }
    }
}
