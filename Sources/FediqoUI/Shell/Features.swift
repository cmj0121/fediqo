import FediqoCore
import SwiftUI

/// What somebody features on their profile, as About of their page is handed it (#315, #318):
/// the hashtags, each a row, and — only where the source said somebody is featured — the one
/// line to the people.
///
/// **A value, made where the source is asked** (`ShellFeatures`): it names no kind of source.
/// **An empty answer draws nothing**: a host may answer the same for "none" and for "not kept".
struct FeaturedSaid: Equatable {
    /// The host of the source that says.
    let source: String
    /// Whether the page is the reader's own: its sentences say "you".
    var own = false
    var tags: [FeaturedTag] = []
    /// The list of the people they feature, where the source said there is somebody in it.
    var people: PeopleList?
    /// Whether a row's `…` holds Take off your profile: on the reader's own page alone.
    var takesOff = false
    /// How the sign-in stands where it lacks the account part Take off wants: the item is dim
    /// with this lock, and its press asks where it may. Nothing where it holds it.
    var accountLock: PartWords.Place?
    /// The sentences of a taking off that did not arrive, said under the hashtags.
    var missed: [String] = []

    /// Whether the hashtags have a block: some to draw. Being asked, and an ask that came to
    /// nothing, are the page's toast to say (DESIGN-reload).
    var tagsDrawn: Bool { !tags.isEmpty }

    static let peopleID = "about.featured.people"
    static let tagsID = "about.featured.tags"

    /// What the lamp calls the row of `tag`.
    static func lamp(of tag: PostTag) -> String { "about.featured.tag:" + HeldUnderTag.folded(tag) }

    /// The rows `j` and `k` walk in the hashtags' block: one a hashtag.
    var tagRows: [String] { tags.map { Self.lamp(of: $0.tag) } }

    func tagsTitle(language: DummyLanguage? = nil) -> String {
        L10n.t(own ? "person.featured.tags.own" : "person.featured.tags", language: language)
    }

    func peopleWords(language: DummyLanguage? = nil) -> String {
        L10n.t(own ? "person.featured.people.own" : "person.featured.people", language: language)
    }

    /// What the source says of one of them: how many of their posts carry it, and the day of
    /// the last — or that none does yet. Nothing where it said neither.
    func said(of featured: FeaturedTag, language: DummyLanguage? = nil) -> String? {
        let suffix = own ? ".own" : ""
        guard let count = featured.count else { return nil }
        guard count > 0 else { return L10n.t("person.featured.tag.never" + suffix, language: language) }
        guard let last = featured.last else { return nil }
        var style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).day().month(.abbreviated)
        style.locale = L10n.locale(language)
        return String(
            format: L10n.t("person.featured.tag.said" + suffix, language: language),
            L10n.grouped(count, language: language), last.formatted(style)
        )
    }

    /// One row as a listener hears it: the hashtag, and what the source says of it.
    func spoken(_ featured: FeaturedTag, language: DummyLanguage? = nil) -> String {
        [featured.tag.text, said(of: featured, language: language)].compactMap { $0 }
            .joined(separator: L10n.t("people.row.between", language: language))
    }

    /// The `…` of the row of `featured` (#318), on the reader's own page alone: Take off your
    /// profile, plain and at once — its press is `act` — or dim with the account part's lock,
    /// the part's sentence at the head, its press `act` too where the part may be asked for.
    @MainActor
    func more(of featured: FeaturedTag, act: @escaping () -> Void, language: DummyLanguage? = nil) -> ShellMore? {
        guard takesOff else { return nil }
        let name = L10n.t("tag.feature.unfeature", language: language)
        guard let lock = accountLock else {
            return ShellMore(items: [.plain(PersonActing.featuredSymbol, name, act: act)])
        }
        return ShellMore.ending(
            in: .plain(ShellMark(SourceRow.permissionSymbol, name, look: .dim(.askAgain)), ask: lock.asks ? act : nil, act: {}),
            dimFor: String(format: L10n.t(lock.key, language: language), source)
        )
    }

    /// What the row's `…` is called: what it takes off, and where.
    func moreLabel(of featured: FeaturedTag, language: DummyLanguage? = nil) -> String {
        ShellMore.label(
            only: String(format: L10n.t("tag.feature.unfeature.spoken", language: language), featured.tag.text, source),
            language: language
        )
    }

    /// What Return does with the lamp on the row `id`, where that row is one of these.
    func press(on id: String) -> FeaturedPress? {
        if id == Self.peopleID, let people { return .people(people) }
        return tags.first { Self.lamp(of: $0.tag) == id }.map { .tag($0.tag) }
    }
}

/// A press on what somebody features: a hashtag's page, or the list of the people.
enum FeaturedPress: Equatable {
    case tag(PostTag)
    case people(PeopleList)
    /// Take off your profile, from the `…` of a row of the reader's own (#318).
    case takeOff(PostTag)
}


/// One source's feature row on a hashtag's About (#318): at which source, whether the reader
/// features the hashtag on their profile there, and the press for the other — Take off is in
/// the row's `…`, as unfollowing is — or, where the sign-in lacks the account part, how it
/// stands, dim with the lock.
struct TagFeatureLine: Equatable, Identifiable {
    enum Standing: Equatable {
        /// Whether it is featured is being found out.
        case asking
        /// As the source last said: featured, or not.
        case said(Bool)
        /// A press is out: featuring, or taking off.
        case doing(Bool)
        /// Whether it is featured could not be found out: nothing is offered but asking again.
        case unknown
        /// The sign-in does not hold the account part: how it stands, in its own line.
        case locked(PartWords.Place)
    }

    enum Offer: Equatable {
        case feature, unfeature
        /// Asks the source again whether it is featured.
        case again
        /// Raises the question that asks the sign-in for the account part.
        case ask
    }

    let host: String
    let tag: PostTag
    var standing: Standing
    /// What a press that did not arrive wanted: to feature, or to take off.
    var missed: Bool?
    /// What the source said where it would not, made fit for a line.
    var refused: String?

    var id: String { "tag.about.feature:" + host }

    var offers: Offer? {
        switch standing {
        case .said(let featured): featured ? .unfeature : .feature
        case .unknown: .again
        case .locked(let place): place.asks ? .ask : nil
        case .asking, .doing: nil
        }
    }

    /// The row's own press, and Return's with the lamp on it: **never Take off**, which is in
    /// the row's `…`.
    var press: Offer? { offers == .unfeature ? nil : offers }

    var isLocked: Bool {
        if case .locked = standing { return true }
        return false
    }

    func words(language: DummyLanguage? = nil) -> String {
        let stands: String
        switch standing {
        case .asking: stands = L10n.t("tag.feature.asking", language: language)
        case .said(let featured): stands = L10n.t(featured ? "tag.feature.featured" : "tag.feature.notFeatured", language: language)
        case .doing(let to): stands = L10n.t(to ? "tag.feature.featuring" : "tag.feature.unfeaturing", language: language)
        case .unknown: stands = L10n.t("tag.feature.unknown", language: language)
        case .locked(let place): stands = String(format: L10n.t(place.key, language: language), host)
        }
        return String(format: L10n.t("tag.follow.at", language: language), host, stands)
    }

    func pressWords(language: DummyLanguage? = nil) -> String? {
        switch press {
        case .feature: L10n.t("tag.feature.feature", language: language)
        case .again: L10n.t("tag.retry", language: language)
        case .unfeature, .ask, nil: nil
        }
    }

    func pressSpoken(language: DummyLanguage? = nil) -> String? {
        switch press {
        case .feature: String(format: L10n.t("tag.feature.feature.spoken", language: language), tag.text, host)
        case .again: String(format: L10n.t("tag.again.spoken", language: language), tag.text, host)
        case .unfeature, .ask, nil: nil
        }
    }

    /// The row's `…`: Take off your profile, plain and at once. Nothing where it is not featured.
    @MainActor
    func more(act: @escaping () -> Void) -> ShellMore? {
        guard offers == .unfeature else { return nil }
        return ShellMore(items: [.plain(PersonActing.featuredSymbol, L10n.t("tag.feature.unfeature"), act: act)])
    }

    func moreLabel(language: DummyLanguage? = nil) -> String {
        ShellMore.label(
            only: String(format: L10n.t("tag.feature.unfeature.spoken", language: language), tag.text, host), language: language
        )
    }

    func missedWords(language: DummyLanguage? = nil) -> String? {
        missed.map {
            String(format: L10n.t($0 ? "tag.feature.failed.feature" : "tag.feature.failed.unfeature", language: language), tag.text, host)
        }
    }

    func refusedWords(language: DummyLanguage? = nil) -> String? {
        guard missed != nil, let refused, !refused.isEmpty else { return nil }
        return String(format: L10n.t("profile.refused.said", language: language), host, refused)
    }
}

/// A feature row drawn: its words and its press, or the `…` that takes it off, or the lock.
/// It draws what it is handed and asks nothing: the asking and the press are `ShellFeatures`'s.
struct TagFeatureRow: View {
    let line: TagFeatureLine
    var onPress: () -> Void
    var onUnfeature: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if line.isLocked {
                locked
            } else {
                WordsThenPress(words: words, press: press)
                    .shellMoreHeld()
            }
            ForEach([line.missedWords(), line.refusedWords()].compactMap { $0 }, id: \.self) { said in
                Text(said)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.bottom, ShellSpace.snug)
            }
        }
    }

    private var words: some View {
        Text(line.words())
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .accessibilityAddTraits(line.offers == nil ? .updatesFrequently : [])
    }

    @ViewBuilder
    private var press: some View {
        if let word = line.pressWords() {
            let spoken = line.pressSpoken() ?? word
            ShellLinkButton(word, action: onPress)
                .accessibilityLabel(spoken)
                .help(spoken)
                .fixedSize()
        } else if line.offers == .unfeature {
            ShellMoreButton(label: line.moreLabel(), more: menu)
                .fixedSize()
        }
    }

    private func menu() -> ShellMore {
        line.more(act: onUnfeature) ?? ShellMore(items: [])
    }

    @ViewBuilder
    private var locked: some View {
        let label = Label(line.words(), systemImage: SourceRow.permissionSymbol)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.markDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
        if line.offers == .ask {
            Button(action: onPress) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(L10n.t("mark.dim.askAgain"))
        } else {
            label
        }
    }
}
