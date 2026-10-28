import FediqoCore
import SwiftUI

/// What the notices page says of what its sources hold back (#399): one row at the top of the
/// list, and the page that row opens.
enum NoticesHeldWords {
    /// The row's words: how many notices the sources say they hold back.
    static func row(_ count: Int, language: DummyLanguage? = nil) -> String {
        L10n.count("notices.held.row", count, language: language)
    }

    /// The row as a listener hears it: how many, and what pressing it opens.
    static func spoken(_ count: Int, language: DummyLanguage? = nil) -> String {
        L10n.count("notices.held.row.spoken", count, language: language)
    }

    /// While one source's requests are read, before any is listed.
    static func reading(_ host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("notices.held.reading", language: language), host)
    }

    /// What Again is called to a listener, where reading a source's requests came to nothing.
    static func again(_ host: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("notices.held.again.spoken", language: language), host)
    }

    /// Where a source counts more people than it listed: none listed at all, or fewer.
    static func short(_ host: String, listedNone: Bool, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t(listedNone ? "notices.held.none" : "notices.held.partial", language: language), host)
    }
}

/// **What the sources hold back, as one row at the top of the notices** (#399): how many, which
/// opens them as a page of their own. Drawn only while something is held back, so the notices
/// are never pushed down by what is waiting.
struct NoticesHeldRow: View {
    let count: Int
    let onPress: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellNoticesProbe) private var probe

    static let symbol = "tray"

    var body: some View {
        let spoken = NoticesHeldWords.spoken(count)
        Button(action: onPress) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Image(systemName: Self.symbol)
                    .accessibilityHidden(true)
                Text(NoticesHeldWords.row(count))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    .accessibilityHidden(true)
            }
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
        .modifier(NoticesProbed(.heldRow, says: spoken, probe: probe))
    }
}

/// **The notices the sources hold back, as a page of their own** (#399), in the frame every
/// opened page stands in (`OpenedPage`), with no tabs: under each source's word of how many it
/// holds back, who, how many and the last one's words, each with its acts behind three dots
/// (`NoticeActs.more(_:in:language:)`), asked first through the notices page's one asker. While
/// a source's requests are read that is said; where reading them came to nothing, that is said
/// with Again; and where it counts more people than it listed, that is said under them.
///
/// Leaving it goes back to the notices, where the row says what is held back now.
struct NoticesHeldPage: View {
    let session: ShellSession
    let asks: Binding<ShellMoreAsk?>
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellNoticesProbe) private var probe

    private var acts: ShellNoticeActs { session.noticeList.acts }

    /// The sources the page lists: those opened that still hold something back, in host order.
    static func hosts(in acts: ShellNoticeActs) -> [String] {
        acts.shownHolders.filter { acts.opened.contains($0) }
    }

    var body: some View {
        OpenedPage(
            tabs: SoleTab.tabs, front: .sole, slide: PageSlide(), title: L10n.t("notices.held.title"),
            acts: OpenedPageActs(onBack: { acts.hideHeld() }),
            head: { EmptyView() },
            inFront: { _ in listed }
        )
    }

    private var listed: some View {
        let hosts = Self.hosts(in: acts)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if hosts.isEmpty {
                    words(L10n.t("notices.held.empty"), part: .heldEmpty, ink: ShellChrome.inkFaint(colorScheme))
                }
                ForEach(hosts, id: \.self) { host in
                    source(host)
                }
            }
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func source(_ host: String) -> some View {
        let listed = acts.listed(host: host)
        if let held = acts.shownHeld(host: host) {
            let said = NoticeActs.words(held, host: host)
            Label(said, systemImage: NoticesHeldRow.symbol)
                .labelStyle(.titleAndIcon)
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ShellSpace.pad)
                .padding(.top, ShellSpace.step)
                .padding(.bottom, ShellSpace.snug)
                .accessibilityAddTraits(.isHeader)
                .modifier(NoticesProbed(.held(host), says: said, probe: probe))
            ShellRule()
            if listed.isEmpty, acts.readingRequests.contains(host) {
                words(NoticesHeldWords.reading(host), part: .heldReading(host), ink: ShellChrome.inkFaint(colorScheme))
                ShellRule()
            }
            if let failed = acts.said[host], failed.act == .requests, !acts.readingRequests.contains(host) {
                WordsThenPress(
                    words: Text(NoticeActs.words(failed, host: host))
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.ink(colorScheme))
                        .modifier(NoticesProbed(.heldSaid(host), says: NoticeActs.words(failed, host: host), probe: probe)),
                    press: ShellLinkButton(L10n.t("status.press.again"), symbol: "arrow.clockwise") {
                        Task { await acts.open(host: host, in: session) }
                    }
                    .accessibilityLabel(NoticesHeldWords.again(host))
                    .help(NoticesHeldWords.again(host))
                    .fixedSize()
                    .modifier(NoticesProbed(.heldAgain(host), says: NoticesHeldWords.again(host), probe: probe))
                )
                ShellRule()
            }
            ForEach(listed) { request in
                NoticeRequestRow(request: request, more: { NoticeActs.more(request, in: session) }, asks: asks)
                ShellRule()
            }
            // The source counts more people than it listed — or listed nobody at all: said,
            // so a source never stands over nothing.
            if acts.requests[host] != nil, held.requests > listed.count, !acts.readingRequests.contains(host) {
                words(
                    NoticesHeldWords.short(host, listedNone: listed.isEmpty), part: .heldPartial(host),
                    ink: ShellChrome.inkFaint(colorScheme)
                )
                ShellRule()
            }
        }
    }

    /// One sentence of the page, whole: wrapped where the page is narrow, never cut.
    private func words(_ words: String, part: NoticesProbe.Part, ink: Color) -> some View {
        Text(words)
            .shellFont(.meta)
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(NoticesProbed(part, says: words, probe: probe))
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
    }
}
