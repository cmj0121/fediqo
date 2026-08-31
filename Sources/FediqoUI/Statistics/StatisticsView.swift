import SwiftUI
import FediqoCore

/// What Fediqo is keeping for you, and what it has taken from other people's servers to get
/// it. Two tabs over four groups, and each group says what kind of number it is showing: the
/// store is counted exactly, the split between sources is an estimate, and the requests are
/// counted from a moment the screen names rather than from the beginning of time.
///
/// How the numbers are counted goes under Network rather than beside Storage, because two of
/// the three things it explains are requests and the third is named in the same breath. A note
/// follows what it is about.
///
/// The screen reads the store and the running app. It asks nobody anything.
struct StatisticsView: View {
    @Environment(AppState.self) private var app

    /// Whether the servers nobody chose are showing. Folded to begin with, and every time:
    /// they are not what a reader came to this page to find out, and a page that opens with
    /// them spread across it buries the four rows that are the answer.
    ///
    /// It lives in the screen rather than in `AppState`, unlike which page and which tab —
    /// those are where the reader is, and this is only what they last looked under.
    @State private var showingOthers = false

    @State private var statistics: Statistics?
    @State private var accounting: APIAccounting?
    @State private var failed = false
    /// What this store made out of more than one arrival. Loaded with the rest, because the
    /// tabs are three views of one reading rather than three readings.
    @State private var collapses: [Collapse] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.room) {
                    groups(of: app.statisticsTab)
                }
                .frame(maxWidth: Size.pageColumn, alignment: .leading)
                .padding(Space.band)
            }
            .frame(maxWidth: .infinity)
        }
        // The counting happens off this actor; all the screen does here is wait for it, and
        // it has already drawn something to wait behind.
        .task { await load() }
    }

    private var header: some View {
        @Bindable var app = app
        return PageHeader(titleKey: app.railItem.titleKey,
                          subtitleKey: "\(app.statisticsTab.rawValue).subtitle") {
            SegmentedChoice(StatisticsTab.allCases, keyPrefix: "tab", selection: $app.statisticsTab)
        }
    }

    /// Both tabs are read from the same two loads, so switching between them shows the other
    /// half of what is already here rather than counting anything again.
    @ViewBuilder
    private func groups(of tab: StatisticsTab) -> some View {
        switch tab {
        case .storage:
            section(t("stats.stored")) { stored }
            section(t("stats.disk")) { disk }
        case .network:
            section(t("stats.requests")) { requests }
            section(t("stats.counting")) { counting }
        case .merges:
            section(t("stats.merges")) { merged }
        }
    }

    private func load() async {
        accounting = APILedger.shared.accounting()
        guard let store = app.store else { return }
        do {
            statistics = try await store.statistics()
            collapses = try await store.collapses()
        } catch {
            failed = true
        }
    }

    // MARK: - What was made out of more than one

    /// Every post this store made out of more than one arrival, and on what grounds.
    ///
    /// #5's last promise, and the only one of its five that is about being wrong: the other four
    /// are rules the app follows silently, and this is the one that says a reader must be able
    /// to check them. So it is a list of decisions rather than of posts — what the row says, the
    /// servers it was made from, and which of the two reasons it had.
    ///
    /// The two reasons are drawn apart because they are not the same kind of thing. An address
    /// two servers agreed on is an inference, and it is shown so it can be disbelieved; a post
    /// this app published is a record of what it did, and there is nothing to check.
    @ViewBuilder
    private var merged: some View {
        if collapses.isEmpty {
            Text(t("stats.merges.none"))
                .fediqoFont(TypeScale.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: Space.gap) {
                ForEach(collapses, id: \.mergeKey) { collapse in
                    VStack(alignment: .leading, spacing: Space.tight) {
                        Text(collapse.says)
                            .fediqoFont(TypeScale.small)
                            .lineLimit(2)
                        HStack(spacing: Space.tight) {
                            ForEach(collapse.sources, id: \.self) { source in
                                Text(source).fediqoFont(TypeScale.caption).fediqoPill()
                            }
                        }
                        .foregroundStyle(.secondary)
                        switch collapse.reason {
                        case .published:
                            Label(t("stats.merges.published"), systemImage: "square.and.pencil")
                                .fediqoFont(TypeScale.caption)
                                .foregroundStyle(Palette.accent)
                        case .sameAddress(let address):
                            // The address itself, because it is the reasoning: if two posts were
                            // ever wrongly made one, this is the line that says why.
                            Text(t("stats.merges.sameAddress", address))
                                .fediqoFont(TypeScale.caption)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.mid)
                    .fediqoCard(radius: Radius.inner, raised: false)
                }
            }
        }
    }

    // MARK: - What is stored

    @ViewBuilder
    private var stored: some View {
        if let statistics {
            metric("stats.stored.posts") {
                Text(statistics.posts, format: .number)
            }
            Divider().opacity(0.4)
            metric("stats.stored.oldest") {
                if let oldest = statistics.oldestPostedAt {
                    Text(oldest, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                } else {
                    Text(verbatim: dash)
                }
            }
        } else {
            storeStatus
        }
    }

    // MARK: - Disk

    @ViewBuilder
    private var disk: some View {
        if let statistics {
            metric("stats.disk.total") {
                if let bytes = statistics.diskBytes {
                    Text(bytes, format: .byteCount(style: .file))
                } else {
                    Text(verbatim: dash)
                }
            }
            Divider().opacity(0.4)

            Text(t("stats.disk.bySource"))
                .fediqoFont(TypeScale.minor, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if statistics.bySource.isEmpty {
                Text(t("stats.disk.empty")).fediqoFont(TypeScale.small).foregroundStyle(.secondary)
            } else {
                ForEach(statistics.bySource) { source in
                    HStack(spacing: Space.step) {
                        Text(source.host).fediqoFont(TypeScale.small).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.step)
                        Text(source.share, format: .percent.precision(.fractionLength(0)))
                            .fediqoFont(TypeScale.small)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let bytes = source.estimatedBytes {
                            Text(bytes, format: .byteCount(style: .file))
                                .fediqoFont(TypeScale.small)
                                .monospacedDigit()
                        }
                    }
                }
            }

            note("stats.disk.estimate")
        } else {
            storeStatus
        }
    }

    // MARK: - Requests

    @ViewBuilder
    private var requests: some View {
        if let accounting {
            let chosen = app.servers.map {
                UsageRow(id: $0.endpoint, host: $0.host, usage: accounting.bySource[$0.endpoint] ?? Self.nothingAsked)
            }
            let mine = Set(app.servers.map(\.endpoint))
            // Everything else we spoke to: the suggested-server directory, and every hostname
            // somebody typed into the picker and did not keep. They are real requests to real
            // machines, so they are shown — under their own heading, because they are not
            // sources anybody chose.
            let strangers = accounting.bySource
                .filter { !mine.contains($0.key) }
                .map { UsageRow(id: $0.key, host: Self.host(of: $0.key), usage: $0.value) }
                .sorted { $0.usage.callsSinceStart > $1.usage.callsSinceStart }

            if chosen.isEmpty && strangers.isEmpty {
                Text(t("stats.requests.none")).fediqoFont(TypeScale.small).foregroundStyle(.secondary)
            } else {
                if !chosen.isEmpty {
                    usageTable(t("stats.requests.mine"), rows: chosen)
                }
                if !strangers.isEmpty {
                    if !chosen.isEmpty { Divider().opacity(0.4) }
                    others(strangers)
                }
            }

            windowNote(accounting.windowMinutes)
            note("stats.requests.note")
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// The servers nobody chose, folded away and kept.
    ///
    /// They are real requests to real machines — the directory this app asked for suggestions,
    /// and every hostname somebody typed into the picker and did not keep — so taking them off
    /// the screen would be the app being quiet about what it did. But they are not what a
    /// reader opened this page to find out, and there can be a great many of them. So they are
    /// here, and shut.
    ///
    /// The count stays in front of the fold, because a fold that does not say what it is
    /// holding reads as nothing being there — which would be the same as having hidden them.
    private func others(_ rows: [UsageRow]) -> some View {
        DisclosureGroup(isExpanded: $showingOthers) {
            VStack(alignment: .leading, spacing: Space.snug) {
                usageGrid(rows)
                Text(t("stats.requests.others.note"))
                    .fediqoFont(TypeScale.minor)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: Space.step) {
                tableHeading(t("stats.requests.others"))
                Text(rows.count, format: .number)
                    .fediqoFont(TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fediqoPill()
            }
            // The whole row opens it, rather than the triangle alone.
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.appearing) { showingOthers.toggle() } }
        }
        .accessibilityValue(Text(rows.count, format: .number))
    }

    /// One heading and its rows: who was asked, how often, how fast, and how much of it came
    /// back. A rate nobody has is a dash — never a hundred percent of nothing.
    private func usageTable(_ heading: String, rows: [UsageRow]) -> some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            tableHeading(heading)
            usageGrid(rows)
        }
    }

    /// Written apart from the table because one of the two tables draws its own: a heading
    /// that opens is still the same heading, and it has to look like one.
    private func tableHeading(_ heading: String) -> some View {
        Text(heading)
            .fediqoFont(TypeScale.minor, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func usageGrid(_ rows: [UsageRow]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Space.gap, verticalSpacing: Space.snug) {
            GridRow {
                Text(t("stats.requests.source")).gridColumnAlignment(.leading)
                Text(t("stats.requests.calls")).gridColumnAlignment(.trailing)
                Text(t("stats.requests.perMinute")).gridColumnAlignment(.trailing)
                Text(t("stats.requests.answered")).gridColumnAlignment(.trailing)
            }
            .fediqoFont(TypeScale.caption)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)

            ForEach(rows) { row in
                GridRow {
                    Text(row.host).fediqoFont(TypeScale.small).lineLimit(1).truncationMode(.middle)
                    Text(row.usage.callsSinceStart, format: .number)
                    Text(row.usage.callsPerMinute, format: .number.precision(.fractionLength(1)))
                    if let rate = row.usage.successRate {
                        Text(rate, format: .percent.precision(.fractionLength(0)))
                    } else {
                        Text(verbatim: dash)
                    }
                }
                .fediqoFont(TypeScale.small)
                .monospacedDigit()
            }
        }
    }

    // MARK: - When counting started

    @ViewBuilder
    private var counting: some View {
        metric("stats.counting.since") {
            if let accounting {
                Text(accounting.startedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
            } else {
                Text(verbatim: dash)
            }
        }
        note("stats.counting.note")
    }

    // MARK: - Chrome

    /// An em dash, for a number that does not exist. Not zero: nobody asked is a different
    /// fact from asked and got nothing, and the two must not read the same.
    private let dash = "—"

    /// A server on the list that no request has been sent to yet — chosen, but not yet
    /// spoken to. It still gets a row, because its absence would read as "not a source".
    private static let nothingAsked = APIUsage(callsSinceStart: 0, failuresSinceStart: 0, callsPerMinute: 0)

    /// The bare hostname of an address, or the address itself when it does not read as one.
    private static func host(of endpoint: String) -> String {
        URL(string: endpoint)?.host() ?? endpoint
    }

    /// One line of the requests table. A struct rather than a pair because `ForEach` needs
    /// something to key on, and the address is the only thing that cannot repeat.
    private struct UsageRow: Identifiable {
        let id: String
        let host: String
        let usage: APIUsage
    }

    /// Why there are no numbers yet: nothing to read them from, something went wrong
    /// reading, or they are still coming.
    @ViewBuilder
    private var storeStatus: some View {
        if app.store == nil {
            Text(t("stats.noStore")).fediqoFont(TypeScale.small).foregroundStyle(.secondary)
        } else if failed {
            Label(t("stats.failed"), systemImage: "exclamationmark.triangle")
                .fediqoFont(TypeScale.small)
                .foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func metric(_ titleKey: String, @ViewBuilder value: () -> some View) -> some View {
        LabeledContent {
            value().fediqoFont(TypeScale.body).monospacedDigit()
        } label: {
            Text(t(titleKey)).fediqoFont(TypeScale.body)
        }
    }

    private func note(_ key: String) -> some View {
        Text(t(key))
            .fediqoFont(TypeScale.minor)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// How far back the per-minute figure looks. The one windowed number on the screen, so
    /// it is the one that has to say its window out loud.
    private func windowNote(_ minutes: Int) -> some View {
        Text(t("stats.requests.window", minutes))
            .fediqoFont(TypeScale.minor)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The same card and heading Settings uses, so the two screens read as one app.
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.mid) {
            Text(title).fediqoFont(TypeScale.minor, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
            VStack(alignment: .leading, spacing: Space.mid) { content() }
                .padding(Space.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fediqoCard()
        }
    }
}
