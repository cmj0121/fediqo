import FediqoCore
import SwiftUI

/// One notice, or one line a source gathered from several (#323): who, what happened, the post
/// it is about, its source and when.
///
/// **What happened is the line's mark, and who did it is its name** — the kind's glyph where a
/// post's row draws a face, in the box and the size a post's audience mark is drawn in
/// (`DummyItemRow.visRole`), then the name, the source's pill and the age on one line; then
/// the post's words, quieter than a post's, because the post is what the notice is about and
/// not what the row is.
///
///     [glyph][who                        ]       [source][when][…]
///     the post's words, two lines at most
///
/// **The words for what happened are the glyph's**: what it says to a resting pointer, and
/// what a listener is read. They are drawn only where the glyph cannot say them — in the
/// name's place on a line that names nobody, so no line is a glyph alone, and under the name
/// where the glyph is one that many kinds share (`NoticeWords.symbolSays`).
///
/// On a narrow page `…` stands under the first line instead, beside the post's words: the
/// first has no room to give it without the name going.
///
///     [glyph][who                 ] [source][when]
///     the post's words, two lines at most      […]
///
/// **One element to a listener** (`NoticeWords.spoken`), pressed to open what the notice is
/// about; the person is a named action on it, as on a post's row, and so is each item of its
/// `…` — the menu a long press and the pointer's other button open too.
struct NoticeRow: View {
    /// The row's `…`: what it holds, built when it is opened, and where a chosen item's
    /// question is put — the page's one asker, never the row.
    struct Menu {
        let more: () -> ShellMore
        let asks: Binding<ShellMoreAsk?>
    }

    let notice: Notice
    var selected = false
    /// Said under the line where its post could not be opened: older than this device keeps.
    var tooOld = false
    /// A press on the row: the lamp, or the opening — `DummyCommand.tapped` decides which.
    var onPress: (() -> Void)?
    /// Opening what the notice is about, for a reader who activates a row once. Nothing where
    /// the line is words and opens nothing.
    var onOpen: (() -> Void)?
    /// A press on the name.
    var onOpenPerson: ((DummyPerson) -> Void)?
    /// Told the label the row set for a listener, each time it sets one.
    var heard: ((String) -> Void)?
    /// Nothing where the row is drawn with nothing to do to it: a fixture, a preview.
    var menu: Menu?
    /// Where a hosted row reports what it laid out and what it says. See `NoticeRowProbe`.
    var probe: NoticeRowProbe?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellLayout) private var shellLayout

    @ShellMetric(relativeTo: .callout) private var glyphSide: CGFloat = DummyItemRow.Box.vis
    @ShellMetric(relativeTo: .body) private var nameRoom: CGFloat = HeadFit.nameRoom
    @ShellMetric(relativeTo: .caption2) private var pillSideways: CGFloat = DummyItemRow.Box.pillSideways
    @ShellMetric(relativeTo: .caption2) private var pillUpright: CGFloat = DummyItemRow.Box.pillUpright

    /// How much of the post's words a row draws: enough to know which post, and no more.
    static let excerptLines = 2

    /// What the source's pill says on a narrow line, most first: its host whole, then its first
    /// letter. The first that fits is drawn — `HeadFit`'s rule for a post's row, **without its
    /// last rung**: every line says its source, so the pill is never given up, and what gives
    /// way on a line with no room is the name.
    enum Pill: CaseIterable {
        case host, initial

        func says(_ host: String) -> String? {
            switch self {
            case .host: host
            case .initial: HeadFit.initial(of: host)
            }
        }
    }

    private var person: DummyPerson? { notice.firstPerson }

    private func spoken(who: String?, what: String, excerpt: String?) -> String {
        let said = NoticeWords.spoken(notice, who: who, what: what, excerpt: excerpt)
        return tooOld ? String(format: L10n.t("notices.spoken.tooOld"), said, Self.tooOldWords()) : said
    }

    /// What is said of a post the store would not take: it is older than the person keeps.
    static func tooOldWords(language: DummyLanguage? = nil) -> String {
        L10n.t("notices.tooOld", language: language)
    }

    var body: some View {
        // Each worked out once a draw: what the row draws is what it says.
        let who = NoticeWords.who(notice), what = NoticeWords.what(notice)
        let excerpt = NoticeWords.excerpt(notice)
        let spoken = spoken(who: who, what: what, excerpt: excerpt)
        let _ = (probe?.spoken = spoken, probe?.glyphSays = what, heard?(spoken))
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            headline(who, what: what)
                .modifier(NoticeProbed(.head, probe: probe))
            beneath(who == nil || NoticeWords.symbolSays(notice) ? nil : what, excerpt)
            if tooOld {
                Text(Self.tooOldWords())
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(NoticeProbed(.tooOld, probe: probe))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(.named(NoticeRowProbe.space))
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .background(selected ? ShellChrome.floatFill(colorScheme) : .clear)
        .overlay(alignment: .leading) { lamp }
        .animation(.easeInOut(duration: 0.18), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { onPress?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityAction(.default) { onOpen?() }
        .accessibilityActions {
            personAction
            if let menu { NoticeMenuActions(more: menu.more, asks: menu.asks) }
        }
        .modifier(NoticeRowMenu(menu: menu))
    }

    /// Where the reader is: a post row's own lamp.
    @ViewBuilder
    private var lamp: some View {
        if selected {
            Rectangle()
                .fill(ShellChrome.phosphor(colorScheme))
                .frame(width: DummyItemRow.Box.lamp)
        }
    }

    /// On a narrow page the line is tried with the host whole, then as its first letter — the
    /// pill is never given up (`Pill`); the name is tried at the room it is sure of, and cut
    /// short where it is long. The age is never cut. A wide page draws the one line.
    @ViewBuilder
    private func headline(_ who: String?, what: String) -> some View {
        if shellLayout == .narrow {
            ViewThatFits(in: .horizontal) {
                ForEach(Pill.allCases, id: \.self) { head(who, what: what, pill: $0, fitted: true) }
            }
        } else {
            head(who, what: what, pill: .host, fitted: false)
        }
    }

    /// A name is one line and the line is centred on it; the words in a name's place may run
    /// to more, and the glyph, the pill and the age stand on the first of them.
    private func head(_ who: String?, what: String, pill: Pill, fitted: Bool) -> some View {
        HStack(alignment: who == nil ? .firstTextBaseline : .center, spacing: ShellSpace.snug) {
            glyph(what)
            // The press is the name's own letters, and the room beside them is the row's.
            pressingPerson(names(who, what: what, fitted: fitted))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: ShellSpace.snug)
            if let said = pill.says(notice.source.host) {
                sourcePill(said)
                    .fixedSize(horizontal: fitted, vertical: false)
                    .modifier(NoticeProbed(.source, probe: probe))
            }
            age
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .modifier(NoticeProbed(.age, probe: probe))
            if shellLayout != .narrow { dots }
        }
    }

    /// The row's `…`, where it has one.
    @ViewBuilder
    private var dots: some View {
        if let menu {
            ShellMoreButton(label: Self.moreLabel(), asks: menu.asks, more: menu.more)
                .fixedSize()
                .modifier(NoticeProbed(.more, probe: probe))
        }
    }

    /// What the row's `…` is called: its menu holds the one item, and is named by it.
    static func moreLabel(language: DummyLanguage? = nil) -> String {
        ShellMore.label(only: L10n.t("notices.dismiss", language: language), language: language)
    }

    /// What happened, as the line's mark: the kind's glyph in a square of one size, so every
    /// name in the list starts at one edge. Its words are what a resting pointer is told; a
    /// listener is read them with the rest of the row.
    private func glyph(_ what: String) -> some View {
        Image(systemName: NoticeWords.symbol(notice))
            .shellFont(DummyItemRow.visRole)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .frame(width: glyphSide, height: glyphSide)
            .help(what)
            .modifier(NoticeProbed(.glyph, probe: probe))
    }

    /// What stands under the first line: what happened where it is drawn there, and the post's
    /// words. On a narrow page the row's `…` stands beside them, and by itself where a line
    /// has neither.
    @ViewBuilder
    private func beneath(_ what: String?, _ excerpt: String?) -> some View {
        if shellLayout == .narrow, menu != nil {
            HStack(alignment: .center, spacing: ShellSpace.snug) {
                VStack(alignment: .leading, spacing: ShellSpace.snug) { words(what, excerpt) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                dots
            }
        } else {
            words(what, excerpt)
        }
    }

    @ViewBuilder
    private func words(_ what: String?, _ excerpt: String?) -> some View {
        if let what {
            Text(what)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NoticeProbed(.whatWords, probe: probe))
        }
        if let excerpt {
            Text(excerpt)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(Self.excerptLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NoticeProbed(.excerpt, probe: probe))
        }
    }

    @ViewBuilder
    private func names(_ who: String?, what: String, fitted: Bool) -> some View {
        if fitted {
            LeastIdeal(cap: nameRoom) { nameLine(who, what: what) }
        } else {
            nameLine(who, what: what)
        }
    }

    /// Who, in the author's line of a post's row. A name is somebody's own writing and may be
    /// partly pictures; "and 2 others" is ours, so only a line of one name is drawn as theirs.
    ///
    /// Where nobody is named, what happened stands here: in the name's size and not its
    /// weight, which is a person's, and whole — it is a sentence, and wraps where a name is cut.
    @ViewBuilder
    private func nameLine(_ who: String?, what: String) -> some View {
        if let who {
            Group {
                if notice.count <= 1, notice.people.count == 1, let one = notice.people.first,
                   !one.lineName.isEmpty {
                    EmojiText(one.lineName, emojis: one.emojis, host: notice.source.host, role: .name)
                } else {
                    Text(who).shellFont(.name)
                }
            }
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .lineLimit(1)
            .modifier(NoticeProbed(.who, probe: probe))
        } else {
            Text(what)
                .shellFont(.name, weight: .regular)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .modifier(NoticeProbed(.whatWords, probe: probe))
        }
    }

    private func sourcePill(_ said: String) -> some View {
        Text(said)
            .shellFont(.mark)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .padding(.horizontal, pillSideways)
            .padding(.vertical, pillUpright)
            .background(Capsule(style: .continuous).fill(ShellChrome.well(colorScheme)))
            .help(notice.source.host)
    }

    /// When, as a timeline's row says it: how long ago, and the exact moment to a resting pointer.
    private var age: some View {
        Text(notice.at, format: .relative(presentation: .numeric, unitsStyle: shellLayout == .narrow ? .narrow : .abbreviated))
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .lineLimit(1)
            .help(DummyItemRow.exact(notice.at))
    }

    @ViewBuilder
    private func pressingPerson(_ content: some View) -> some View {
        if let onOpenPerson, let person {
            Button { onOpenPerson(person) } label: { content }
                .buttonStyle(.plain)
                .help(Self.spokenPerson(person))
        } else {
            content
        }
    }

    /// What opening them is called, in a post's row's own sentence (`DummyItemRow.spokenPerson`)
    /// — with a handle that stands in for a name held to one line, as the name already is.
    static func spokenPerson(_ person: DummyPerson) -> String {
        String(
            format: L10n.t("item.person.open"),
            person.name.isEmpty ? NoticeWords.oneLine(person.handle ?? "") : person.name
        )
    }

    /// The person, as a listener reaches them: the row is one element, so the name inside it is
    /// not one they can land on.
    @ViewBuilder
    private var personAction: some View {
        if let onOpenPerson, let person {
            Button(Self.spokenPerson(person)) { onOpenPerson(person) }
        }
    }
}

/// Where a hosted notice row laid its parts out, in the row's own space, and what it says.
@MainActor
final class NoticeRowProbe {
    enum Part: Hashable {
        case head, glyph, who, source, age, whatWords, excerpt, tooOld, more
    }

    static let space = "NoticeRow.parts"
    var frames: [Part: CGRect] = [:]
    /// What the row told a listener.
    var spoken: String?
    /// What the row's glyph tells a resting pointer.
    var glyphSays: String?
}

/// The row's menu under a long press, and the pointer's other button: the one its `…` opens
/// (`RowMenu`'s rule for a post's row), where the row has one. A modifier of its own, so no
/// row's chain carries the presenter's closure.
struct NoticeRowMenu: ViewModifier {
    let menu: NoticeRow.Menu?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let menu {
            content.contextMenu { ShellMoreItems(asked: menu.asks, build: menu.more) }
        } else {
            content
        }
    }
}

/// Reports where one part of a notice row was laid out to a probe, where one is handed in;
/// draws nothing and changes nothing.
private struct NoticeProbed: ViewModifier {
    let part: NoticeRowProbe.Part
    let probe: NoticeRowProbe?

    init(_ part: NoticeRowProbe.Part, probe: NoticeRowProbe?) {
        self.part = part
        self.probe = probe
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let probe {
            content.background(GeometryReader { room in
                let _ = probe.frames[part] = room.frame(in: .named(NoticeRowProbe.space))
                Color.clear
            })
        } else {
            content
        }
    }
}
