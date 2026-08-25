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

    @State private var statistics: Statistics?
    @State private var accounting: APIAccounting?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    groups(of: app.statisticsTab)
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(22)
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
        }
    }

    private func load() async {
        accounting = APILedger.shared.accounting()
        guard let store = app.store else { return }
        do {
            statistics = try await store.statistics()
        } catch {
            failed = true
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
                .fediqoFont(11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if statistics.bySource.isEmpty {
                Text(t("stats.disk.empty")).fediqoFont(12).foregroundStyle(.secondary)
            } else {
                ForEach(statistics.bySource) { source in
                    HStack(spacing: 8) {
                        Text(source.host).fediqoFont(12).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(source.share, format: .percent.precision(.fractionLength(0)))
                            .fediqoFont(12)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let bytes = source.estimatedBytes {
                            Text(bytes, format: .byteCount(style: .file))
                                .fediqoFont(12)
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
                Text(t("stats.requests.none")).fediqoFont(12).foregroundStyle(.secondary)
            } else {
                if !chosen.isEmpty {
                    usageTable(t("stats.requests.mine"), rows: chosen)
                }
                if !strangers.isEmpty {
                    if !chosen.isEmpty { Divider().opacity(0.4) }
                    usageTable(t("stats.requests.others"), rows: strangers)
                    Text(t("stats.requests.others.note"))
                        .fediqoFont(11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            windowNote(accounting.windowMinutes)
            note("stats.requests.note")
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// One heading and its rows: who was asked, how often, how fast, and how much of it came
    /// back. A rate nobody has is a dash — never a hundred percent of nothing.
    private func usageTable(_ heading: String, rows: [UsageRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .fediqoFont(11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    Text(t("stats.requests.source")).gridColumnAlignment(.leading)
                    Text(t("stats.requests.calls")).gridColumnAlignment(.trailing)
                    Text(t("stats.requests.perMinute")).gridColumnAlignment(.trailing)
                    Text(t("stats.requests.answered")).gridColumnAlignment(.trailing)
                }
                .fediqoFont(10)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

                ForEach(rows) { row in
                    GridRow {
                        Text(row.host).fediqoFont(12).lineLimit(1).truncationMode(.middle)
                        Text(row.usage.callsSinceStart, format: .number)
                        Text(row.usage.callsPerMinute, format: .number.precision(.fractionLength(1)))
                        if let rate = row.usage.successRate {
                            Text(rate, format: .percent.precision(.fractionLength(0)))
                        } else {
                            Text(verbatim: dash)
                        }
                    }
                    .fediqoFont(12)
                    .monospacedDigit()
                }
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
            Text(t("stats.noStore")).fediqoFont(12).foregroundStyle(.secondary)
        } else if failed {
            Label(t("stats.failed"), systemImage: "exclamationmark.triangle")
                .fediqoFont(12)
                .foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func metric(_ titleKey: String, @ViewBuilder value: () -> some View) -> some View {
        LabeledContent {
            value().fediqoFont(13).monospacedDigit()
        } label: {
            Text(t(titleKey)).fediqoFont(13)
        }
    }

    private func note(_ key: String) -> some View {
        Text(t(key))
            .fediqoFont(11)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// How far back the per-minute figure looks. The one windowed number on the screen, so
    /// it is the one that has to say its window out loud.
    private func windowNote(_ minutes: Int) -> some View {
        Text(t("stats.requests.window", minutes))
            .fediqoFont(11)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The same card and heading Settings uses, so the two screens read as one app.
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).fediqoFont(11, weight: .semibold).foregroundStyle(.secondary).textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fediqoCard()
        }
    }
}
