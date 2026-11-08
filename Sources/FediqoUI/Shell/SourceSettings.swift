import FediqoCore
import SwiftUI

/// **What is chosen for one joined source, behind a gear on its page** (#400): whether Home
/// arrives as it happens (`LineControl`), which notices it tells of and how
/// (`NoticesToldControl`), whose notices it holds back (`NoticePolicyBlock`) and the server's
/// filters (`ServerFiltersBlock`). The page itself opens on what the server says.
///
/// **Absent, not dim, for what a source lacks**: a part the source has no such thing for is not
/// listed. **Joining the timelines already written is there for every joined source** (#372),
/// greyed with the same icon where none of them can take it now, so every joined source has a
/// gear. **The gear is lit while something there
/// narrows what is shown**: kinds of notice it does not tell, a filter of the server's, or
/// someone's notices held back or let go.
@MainActor
enum SourceSettings {
    enum Part: Equatable, CaseIterable {
        case line, told, policy, filters
    }

    /// The parts the source has, in the order the page lists them.
    static func parts(host: String, in session: ShellSession) -> [Part] {
        Part.allCases.filter { has($0, host: host, in: session) }
    }

    /// Whether the source has any part at all: what draws its gear. Stops at the first.
    static func hasAny(host: String, in session: ShellSession) -> Bool {
        Part.allCases.contains { has($0, host: host, in: session) }
    }

    private static func has(_ part: Part, host: String, in session: ShellSession) -> Bool {
        switch part {
        case .line:
            switch session.lines.offer(host: host, in: session) {
            case .choice?, .signIn?: true
            case .cannot?, nil: false
            }
        case .told:
            switch session.noticesTold.offer(host: host, in: session) {
            case .choice?, .locked?, .signIn?: true
            case .cannot?, nil: false
            }
        case .policy:
            NoticePolicyBlock.shows(NoticePolicyWords.stands(host, in: session))
        case .filters:
            session.serverFilters.offer(host: host, in: session) != nil
        }
    }

    /// Whether something chosen there narrows what is shown: what lights the gear.
    static func narrows(host: String, in session: ShellSession) -> Bool {
        let told = session.noticesTold.choice(host: host)
        if told.on, !told.off.isEmpty { return true }
        if case .read(let filters)? = session.serverFilters.reading[host.lowercased()], !filters.isEmpty { return true }
        if let policy = session.noticeList.acts.shownPolicy(host: host),
           policy.ways.values.contains(where: { $0 != .accept }) { return true }
        return false
    }

    /// What the parts and the gear's light depend on, asked of the source once as its page opens:
    /// whose notices it holds back, and its filters where it lists them here.
    static func read(host: String, in session: ShellSession) async {
        await session.noticeList.acts.look(host: host, in: session)
        if case .list? = session.serverFilters.offer(host: host, in: session) {
            await session.serverFilters.read(host: host, in: session)
        }
    }

    /// The page's "join timelines" (#372): live where some timeline already written can take the
    /// source, greyed with the same icon, saying no timeline can, where none can — one may later,
    /// as home comes with a sign-in and lists as they are chosen.
    static func joinMark(host: String, in session: ShellSession, language: DummyLanguage? = nil) -> ShellMark {
        let name = L10n.t("source.settings.join", language: language)
        let look: MarkLook = session.joinsTimelines(host: host) ? .live : .dim(.noTimeline)
        return ShellMark(TimelineJoinEntry.symbol, name, look: look, word: name)
    }

    /// What a listener hears of the gear beside its name: whether something there narrows.
    static func spoken(narrows: Bool, language: DummyLanguage? = nil) -> String {
        L10n.t(narrows ? "source.settings.narrows" : "source.settings.plain", language: language)
    }
}

/// The gear on a joined source's page: opens what is chosen for it, lit while something there
/// narrows. Drawn only where the source has something to choose. What its light depends on is
/// read once as the source's page opens (`SourceSettings.read`), and not again as the gear comes
/// and goes.
struct SourceSettingsGear: View {
    let host: String
    let session: ShellSession
    let onOpen: () -> Void

    static let symbol = ShellGearLabel.symbol

    /// Whether the gear is drawn: for every joined source, whose page always holds the entry to
    /// join the timelines (#372), and where the source has a part.
    static func shows(host: String, in session: ShellSession) -> Bool {
        session.isAdded(host) || SourceSettings.hasAny(host: host, in: session)
    }

    var body: some View {
        if Self.shows(host: host, in: session) {
            let narrows = SourceSettings.narrows(host: host, in: session)
            ShellIconButton(Self.symbol, name: "source.settings", tone: narrows ? .lit : .quiet, action: onOpen)
                .accessibilityValue(SourceSettings.spoken(narrows: narrows))
        }
    }
}

/// What is chosen for one joined source, as the page its gear opens: the way back, and each part
/// the source has.
struct SourceSettingsPage: View {
    let host: String
    let session: ShellSession
    let onBack: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    /// Where a listener lands as the page opens: its title.
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        let parts = SourceSettings.parts(host: host, in: session)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ShellBackButton("source.settings.back", action: onBack)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.vertical, ShellSpace.snug)
                Text(String(format: L10n.t("source.settings.title"), host))
                    .shellFont(.name)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.bottom, ShellSpace.step)
                ForEach(parts, id: \.self) { part in
                    switch part {
                    case .line: LineControl(host: host, session: session)
                    case .told: NoticesToldControl(host: host, session: session)
                    case .policy: NoticePolicyBlock(host: host, session: session)
                    case .filters: ServerFiltersBlock(host: host, session: session)
                    }
                }
                TimelineJoinEntry(host: host, session: session)
            }
        }
        .onAppear { titleFocused = true }
    }
}

/// The source page's row that opens the timelines already written it can join (#372) — the
/// join's last step, for a source already held. Greyed with the same icon where none can take it.
struct TimelineJoinEntry: View {
    let host: String
    let session: ShellSession

    static let symbol = "rectangle.stack.badge.plus"

    /// What a press on it does, said to a listener.
    static func hint(language: DummyLanguage? = nil) -> String {
        L10n.t("source.settings.join.hint", language: language)
    }

    var body: some View {
        let mark = SourceSettings.joinMark(host: host, in: session)
        ShellMarkButton(mark) { session.openTimelineJoin(host: host) }
            .accessibilityHint(Text(Self.hint()))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
    }
}
