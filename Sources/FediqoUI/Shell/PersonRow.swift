import FediqoCore
import SwiftUI

/// Somebody on a list of people (#311): their face, the name they wrote, their handle, and the
/// first line of what they say of themselves.
///
/// **Its own row, and not a post's or a notice's.** Those two share a mark, a name, a source
/// and a time; somebody on a list has a face and a name, no time, and a source the page says
/// once at its head. It is made of the same parts — a post row's face and plate, its lamp and
/// its wash, a name drawn as they wrote it, the pill's own chrome — so it reads as a row of
/// this app, and is one description of a line of its own.
///
///     [face]  Name as they wrote it [lock]              (pill)  […]
///             @handle@host
///             the first line of their own words, cut at its end
///
/// On a narrow page the pills drop to the handle's line and `…` stands beside the third:
///
///     [face]  Name as they wrote it [lock]
///             @handle@host                      (pill)
///             the first line of their own words      […]
///
/// **How the reader stands to them is pills too, after what kind of account it is** (#310,
/// #313): the words their own page says it in, in its order, of what the row was handed — and
/// nothing where it was handed none. Which sign-in is told, and when the source is asked, is
/// the list's (`ShellPeoplePages`). Where a narrow page has no room for them beside the handle
/// they stand under it, and wrap, so no pill is cut.
///
/// **Everything on it but the marks is a stranger's word.** The name and the handle are the
/// ones made fit for a line where they entered (`Person.lineName`, `.lineHandle`); their own
/// words are as many lines as they wrote, and are made one line here. The lock and the pills are
/// this app's, each in a place of its own outside the run their letters and pictures are drawn in.
///
/// **One element to a listener** (`spoken`), pressed to open them; each item of its `…` is a
/// named action on it, as on a notice's line.
struct PersonRow: View {
    let person: Person
    /// How the reader stands to them, as the source last said — or nothing: nobody asked, or
    /// it has not said.
    var stands: PersonStanding?
    var selected = false
    /// A press on the row: the lamp, or the opening — `DummyCommand.tapped` decides which.
    var onPress: (() -> Void)?
    /// Opening them, for a reader who activates a row once.
    var onOpen: (() -> Void)?
    /// The row's `…`, where the list it stands on has something to do to a row. Nothing on a
    /// list that has not.
    var menu: NoticeRow.Menu?
    /// Where a hosted row reports what it laid out and what it says. See `PersonRowProbe`.
    var probe: PersonRowProbe?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellLayout) private var shellLayout

    @ShellMetric(relativeTo: .body) private var faceSide: CGFloat = DummyItemRow.Box.avatar

    // MARK: - What it says

    /// The first line of what they say of themselves, made one line of ours — or nothing where
    /// they wrote none. **Cut here and cleaned here**: what `Person` holds is every line they
    /// wrote, as they wrote it.
    static func firstLine(of person: Person) -> String? {
        person.words.split(whereSeparator: \.isNewline).lazy
            .map { LineText.oneLine(String($0), limit: wordsLength) }.first { !$0.isEmpty }
    }

    /// How much of their first line a row keeps: more than a row shows at any width.
    static let wordsLength = 200

    /// What the source says the account is, where that is not a person: one pill.
    static func pills(of person: Person, language: DummyLanguage? = nil) -> [String] {
        switch person.sort {
        case .person: []
        case .automated: [L10n.t("people.pill.automated", language: language)]
        case .group: [L10n.t("people.pill.group", language: language)]
        }
    }

    /// How the reader stands to them, as pills: their page's own words, in its order.
    static func standing(_ stands: PersonStanding?, language: DummyLanguage? = nil) -> [String] {
        stands.map { PersonActing.pills(of: $0, language: language) } ?? []
    }

    /// What a listener is read: the name, the handle, that they ask before anyone may follow,
    /// each pill, how the reader stands to them, and the first line of their words — whatever
    /// of those there is.
    static func spoken(_ person: Person, stands: PersonStanding? = nil, language: DummyLanguage? = nil) -> String {
        var parts = [person.lineName, person.lineHandle]
        if person.locked { parts.append(PersonSaid.locked(language: language)) }
        parts += pills(of: person, language: language) + standing(stands, language: language)
        if let words = firstLine(of: person) { parts.append(words) }
        return parts.filter { !$0.isEmpty }.joined(separator: L10n.t("people.row.between", language: language))
    }

    /// What the row's `…` is called.
    static func moreLabel(language: DummyLanguage? = nil) -> String {
        ShellMore.label(language: language)
    }

    // MARK: - Drawn

    var body: some View {
        let heard = Self.spoken(person, stands: stands)
        let kinds = Self.pills(of: person)
        let standing = Self.standing(stands)
        let words = Self.firstLine(of: person)
        let narrow = shellLayout == .narrow
        let _ = probe?.spoken = heard
        HStack(alignment: .top, spacing: ShellSpace.step) {
            face
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                HStack(alignment: .center, spacing: ShellSpace.snug) {
                    name
                    Spacer(minLength: 0)
                    if !narrow {
                        pillRun(kinds + standing)
                        dots
                    }
                }
                handleLine(kinds: kinds, standing: standing, narrow: narrow)
                if words != nil || (narrow && menu != nil) {
                    HStack(alignment: .center, spacing: ShellSpace.snug) {
                        if let words {
                            Text(words)
                                .shellFont(.body)
                                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .modifier(PersonProbed(.words, probe: probe))
                        }
                        Spacer(minLength: 0)
                        if narrow { dots }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(.named(PersonRowProbe.space))
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .background(selected ? ShellChrome.floatFill(colorScheme) : .clear)
        .overlay(alignment: .leading) { lamp }
        .animation(.easeInOut(duration: 0.18), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { onPress?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heard)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityAction(.default) { onOpen?() }
        .accessibilityActions {
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

    /// The row's second line: their handle, and on a narrow page the pills. **With a word of
    /// how the reader stands, beside the handle where all of it fits whole, and under it where
    /// it does not** — wrapped there, so no pill is cut.
    ///
    /// **On a wide page the pills stand beside the name and have no such way down**: three or
    /// four are the most a source says of anybody at once — what kind of account, that they
    /// follow the reader, that the reader follows or asked, that they are muted — and with
    /// more the name gives way and is cut at its end, the pills never.
    @ViewBuilder
    private func handleLine(kinds: [String], standing: [String], narrow: Bool) -> some View {
        if narrow, !standing.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                    handle.fixedSize()
                    Spacer(minLength: 0)
                    pillRun(kinds + standing)
                }
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                        handle
                        Spacer(minLength: 0)
                        pillRun(kinds)
                    }
                    PersonStandingPills(pills: standing)
                        .modifier(PersonProbed(.stands, probe: probe))
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                handle
                Spacer(minLength: 0)
                if narrow { pillRun(kinds) }
            }
        }
    }

    /// Their handle, one line, cut in its middle where there is no room for it whole.
    private var handle: some View {
        Text(person.lineHandle)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
            .modifier(PersonProbed(.handle, probe: probe))
    }

    /// Their picture as the source that listed them holds it, or the empty plate — a post
    /// row's two cases, at a post row's size.
    private var face: some View {
        Group {
            if let url = person.avatarURL {
                RemoteImage(
                    url: url, tier: .deck,
                    // The source that listed them, never their own server.
                    host: person.source.host, standing: .avatar, alt: nil, speaks: false,
                    radius: DummyItemRow.Box.plate
                )
            } else {
                ShellVacant(standing: .avatar, radius: DummyItemRow.Box.plate)
            }
        }
        .frame(width: faceSide, height: faceSide)
        .modifier(PersonProbed(.face, probe: probe))
    }

    /// Their name as they wrote it, pictures and all, and after it — in a place of its own —
    /// the lock of an account that asks before anyone may follow.
    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
            EmojiText(person.lineName, emojis: person.emojis, host: person.source.host, role: .name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(1)
                .modifier(PersonProbed(.name, probe: probe))
            if person.locked {
                Image(systemName: "lock")
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .help(PersonSaid.locked())
                    .modifier(PersonProbed(.lock, probe: probe))
            }
        }
    }

    @ViewBuilder
    private func pillRun(_ pills: [String]) -> some View {
        if !pills.isEmpty {
            HStack(spacing: ShellSpace.tight) {
                ForEach(pills, id: \.self) { ShellWellPill($0) }
            }
            .fixedSize()
            .modifier(PersonProbed(.pills, probe: probe))
        }
    }

    @ViewBuilder
    private var dots: some View {
        if let menu {
            ShellMoreButton(label: Self.moreLabel(), asks: menu.asks, more: menu.more)
                .fixedSize()
                .modifier(PersonProbed(.more, probe: probe))
        }
    }
}

/// A few words on the well: the chrome a row's source pill is drawn in, for a word that is this
/// app's — what kind of account, which source a page is of.
struct ShellWellPill: View {
    let words: String
    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .caption2) private var sideways: CGFloat = DummyItemRow.Box.pillSideways
    @ShellMetric(relativeTo: .caption2) private var upright: CGFloat = DummyItemRow.Box.pillUpright

    init(_ words: String) {
        self.words = words
    }

    var body: some View {
        Text(words)
            .shellFont(.mark)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .padding(.horizontal, sideways)
            .padding(.vertical, upright)
            .background(Capsule(style: .continuous).fill(ShellChrome.well(colorScheme)))
    }
}

/// Where a hosted person's row laid its parts out, in the row's own space, and what it says.
@MainActor
final class PersonRowProbe {
    enum Part: Hashable {
        case face, name, lock, handle, words, pills, more
        /// How the reader stands to them, where it stands under the handle.
        case stands
    }

    static let space = "PersonRow.parts"
    var frames: [Part: CGRect] = [:]
    /// What the row told a listener.
    var spoken: String?
}

/// Reports where one part of a person's row was laid out to a probe, where one is handed in;
/// draws nothing and changes nothing.
private struct PersonProbed: ViewModifier {
    let part: PersonRowProbe.Part
    let probe: PersonRowProbe?

    init(_ part: PersonRowProbe.Part, probe: PersonRowProbe?) {
        self.part = part
        self.probe = probe
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let probe {
            content.background(GeometryReader { room in
                let _ = probe.frames[part] = room.frame(in: .named(PersonRowProbe.space))
                Color.clear
            })
        } else {
            content
        }
    }
}
