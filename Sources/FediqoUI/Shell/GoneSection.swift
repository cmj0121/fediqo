import FediqoCore
import SwiftUI

/// Posts their source deleted (#179), where this device says what it holds and for how long: the
/// wait after which they go, and a press that lets them all go now.
///
/// **Beside the keep-for window, on the same tab, because it is the same question** — how long
/// a post stays here — asked of the posts a source has since let go. Where the two disagree the
/// shorter one wins, and this says so rather than leaving a reader to wonder why a ninety-day
/// wait let a post go in a month.
///
/// **And the places a read down settled** (#204), where a timeline's source no longer has what lay
/// between two posts: the same wait and the same press let their marks go, and count them apart
/// from the posts, so the press never says it let go of posts it did not.
///
/// A view of its own rather than more of `UsagePane`, so the page keeps one section per fact and
/// this one can be read, and tested, alone.
struct GoneSection: View {
    @Environment(DummyPrefs.self) private var prefs
    @Environment(\.colorScheme) private var colorScheme
    let session: ShellSession

    /// What the last press let go, and nothing before a press — "none went" would be an answer
    /// to a question nobody asked yet.
    @State private var went: WentGone?
    /// The press has counted what it would let go and is asking first, as every other drop on
    /// this page does; `counted` is what the question names.
    @State private var confirming = false
    @State private var counted = WentGone()

    /// The waits offered, in days. Never, the default, is offered beside them.
    static let dayChoices = [1, 7, 30, 90]

    var body: some View {
        @Bindable var prefs = prefs
        Section {
            Picker(L10n.t("prefs.gone.wait"), selection: $prefs.goneDays) {
                Text(L10n.t("prefs.gone.never")).tag(Int?.none)
                ForEach(Self.dayChoices, id: \.self) { days in
                    Text(L10n.count("prefs.gone.days", days)).tag(Int?.some(days))
                }
            }
            if let line = Self.keepWinsLine(days: prefs.goneDays, keepingMonths: prefs.keepMonths) {
                reading(line)
            }
            HStack(spacing: ShellSpace.snug) {
                Button(L10n.t("prefs.gone.now")) {
                    Task {
                        // Nothing to let go is said at once; anything is asked about first.
                        counted = await session.goneHeld()
                        if counted.isNone { went = counted } else { confirming = true }
                    }
                }
                if let went {
                    reading(Self.wentLine(went.posts, places: went.places))
                }
            }
        } header: {
            Text(L10n.t("prefs.gone"))
        } footer: {
            Text(L10n.t("prefs.gone.footer"))
                .shellFont(.mark)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
        .confirmationDialog(
            Text(Self.askLine(counted.posts, places: counted.places)), isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(L10n.t("prefs.gone.confirm"), role: .destructive) {
                Task { went = await session.letAllGoneGo() }
            }
            Button(L10n.t("board.choose.cancel"), role: .cancel) {}
        } message: {
            Text(Self.askDetail(posts: counted.posts, places: counted.places))
        }
    }

    /// What the press asks before it lets `count` posts and `places` settled places go (#204):
    /// each counted apart, and one left unsaid where there are none of it.
    static func askLine(_ count: Int, places: Int = 0, language: DummyLanguage? = nil) -> String {
        if places == 0 { return L10n.count("prefs.gone.ask", count, language: language) }
        if count == 0 { return L10n.count("prefs.gone.ask.places", places, language: language) }
        return String(
            format: L10n.t("prefs.gone.ask.both", language: language),
            L10n.count("prefs.gone.posts", count, language: language),
            L10n.count("prefs.gone.places", places, language: language)
        )
    }

    /// What the question says under it: where places go too, that only their marks do — and where
    /// only places go, nothing of posts going.
    static func askDetail(posts: Int, places: Int, language: DummyLanguage? = nil) -> String {
        let key = places == 0 ? "prefs.gone.ask.detail"
            : posts == 0 ? "prefs.gone.ask.detail.placesonly" : "prefs.gone.ask.detail.places"
        return L10n.t(key, language: language)
    }

    /// What the page says where the keep-for window is the shorter of the two, and nothing where
    /// the wait chosen here is the one that holds.
    static func keepWinsLine(days: Int?, keepingMonths months: Int?, now: Date = Date(),
                             language: DummyLanguage? = nil) -> String? {
        guard let months, GoneWait.cutoff(days: days, keepingMonths: months, from: now).keepWins else {
            return nil
        }
        return L10n.count("prefs.gone.keepwins", months, language: language)
    }

    /// What the press says back: how many posts and places went, or that there were none.
    static func wentLine(_ count: Int, places: Int = 0, language: DummyLanguage? = nil) -> String {
        switch (count, places) {
        case (0, 0): L10n.t("prefs.gone.went.none", language: language)
        case (_, 0): L10n.count("prefs.gone.went", count, language: language)
        case (0, _): L10n.count("prefs.gone.went.places", places, language: language)
        default:
            String(
                format: L10n.t("prefs.gone.went.both", language: language),
                L10n.count("prefs.gone.posts", count, language: language),
                L10n.count("prefs.gone.places", places, language: language)
            )
        }
    }

    private func reading(_ line: String) -> some View {
        Text(line)
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
    }
}

/// Lets go of posts marked gone once this device's wait says so (#179): at launch, whenever the
/// wait or the keep-for window changes, and every hour between — a post marked on Monday with a
/// one-day wait goes on Tuesday whether or not anybody relaunched.
///
/// **A modifier of its own**, so the root view's chain gains one line and no closure of its own.
struct LettingGoneGo: ViewModifier {
    @Environment(DummyPrefs.self) private var prefs
    let session: ShellSession

    private struct Wait: Equatable {
        let days: Int?
        let months: Int?
    }

    func body(content: Content) -> some View {
        content.task(id: Wait(days: prefs.goneDays, months: prefs.keepMonths)) {
            while !Task.isCancelled {
                await session.letGoneGo(waitingDays: prefs.goneDays, keepingMonths: prefs.keepMonths)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}
