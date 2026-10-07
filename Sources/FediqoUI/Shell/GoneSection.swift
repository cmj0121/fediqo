import FediqoCore
import SwiftUI

/// Posts their source deleted (#179), where this device says how long it holds them: the wait
/// after which they go, or never.
///
/// **Beside the keep-for window, on the same tab, because it is the same question** — how long
/// a post stays here — asked of the posts a source has since let go. Where the two disagree the
/// shorter one wins, and this says so rather than leaving a reader to wonder why a ninety-day
/// wait let a post go in a month.
///
/// **And the places a read down settled** (#204), where a timeline's source no longer has what lay
/// between two posts: the same wait lets their marks go.
///
/// **Nothing here lets them go at a press.** They go by the wait alone (`LettingGoneGo`), so the
/// section is a choice and what follows from it, and holds nothing that takes away.
///
/// A view of its own rather than more of `UsagePane`, so the page keeps one section per fact and
/// this one can be read, and tested, alone.
struct GoneSection: View {
    @Environment(DummyPrefs.self) private var prefs
    let session: ShellSession

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
                ShellReadingLine(line)
            }
        } header: {
            ShellSectionHead(title: "prefs.gone", line: "usage.gone.line", help: "prefs.gone.footer")
        }
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
