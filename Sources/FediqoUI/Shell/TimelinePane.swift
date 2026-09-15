import AVKit
import FediqoCore
import SwiftUI

/// The timeline place: named queries, a brief rule, then the stream or a thread.
struct TimelinePane: View {
    @Bindable var session: ShellSession
    @Binding var selectedID: String?
    @Binding var openedID: String?
    /// Where every deck in this pane is turned to, and which rows the reader uncovered. Held by
    /// the app rather than here, because `m` and `s` are pressed where the keys are read.
    @Binding var decks: ShellDecks
    /// What is playing, and the one player in the app. Read here and written nowhere: the rule
    /// about what a press means lives beside the key that means it. See `ShellPlayback`.
    let playback: ShellPlayback
    /// A press on a card's own play mark, which the root answers under the same rule as `a`.
    var onPlayRow: (DummyItem) -> Void
    var jumpToTop: Int
    var onPopThread: () -> Void
    @State private var marks: [String: DummyMarks] = [:]
    /// Bumped once each server's emoji catalogue has landed, so the rows already on screen ask
    /// again. Per host and not one counter for the pane: see `waitForCatalogues`.
    @State private var settledHosts: Set<String> = []
    @State private var toast: String?
    @State private var toastTick = 0
    @Environment(\.colorScheme) private var colorScheme

    private var timeline: DummyTimeline { DummyTimeline(id: session.timelineID ?? "") }

    private var items: [DummyItem] { timeline.items(from: session.notes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, ShellSpace.pad)
                .padding(.top, ShellSpace.step)
                .padding(.bottom, ShellSpace.snug)

            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)

            if let opened = openedItem {
                DummyThreadPane(
                    root: opened,
                    catalogues: session.emoji,
                    catalogueSettled: settledHosts.contains(opened.source.host),
                    selectedID: $selectedID,
                    marks: markBinding,
                    decks: $decks,
                    playback: playback,
                    onPlayRow: onPlayRow,
                    jumpToTop: jumpToTop,
                    onToast: showToast,
                    onBack: onPopThread
                )
            } else if items.isEmpty {
                empty
            } else {
                list
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(ShellType.meta)
                    .padding(.horizontal, ShellSpace.step)
                    .padding(.vertical, ShellSpace.snug)
                    .background(ShellChrome.well(colorScheme), in: Capsule())
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .padding(.bottom, ShellSpace.pad)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .task(id: catalogueHosts) { await waitForCatalogues() }
        .onChange(of: session.timelineID) { _, _ in
            if let selectedID, !items.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            openedID = nil
        }
    }

    private var catalogueHosts: [String] { session.sources.map(\.host).sorted() }

    /// Waits for every joined server's catalogue at once, telling the rows as each one answers.
    ///
    /// **The wait lives here and not on a row.** A catalogue asked for at join is usually still
    /// on the wire when the first rows draw, so somebody has to wait — but `settle(host:)` awaits
    /// a `Task<Void, Never>`, and awaiting one of those ignores the waiting task's own
    /// cancellation. On a row that is a suspended task per row ever scrolled past, held until the
    /// server answers. This view lives as long as the place does, so here it is one per server.
    ///
    /// **Concurrently, and the answer is per host.** Waited in a row, one slow instance withheld
    /// every other instance's emoji: `URLRequest`'s default timeout is sixty seconds of *idle*,
    /// so a server dripping a byte a minute never times out, and a single counter bumped after
    /// the last wait would never have been bumped at all. A host that has settled is also a fact
    /// rather than a signal, so a wait that was superseded can only insert something true — the
    /// spurious bump a counter would have produced on its way out has nowhere to land.
    ///
    /// **And it asks, where nothing else would.** `refresh` had one call site in the whole
    /// product — the join — so a catalogue the reader dropped never came back for the life of
    /// the process: their pictures returned on the next pass through the timeline and that
    /// server's names stayed letters and colons until the app was relaunched. The twenty-four
    /// hour life cannot save it either, because staleness is a question about a catalogue that
    /// is *there*. A timeline is the other place a catalogue is wanted, so it is the other place
    /// that asks for one.
    ///
    /// **Guarded, and the guard that matters is the store's.** `needsFetch` is asked first
    /// because a catalogue already held and still young should not cost an allocation and a
    /// closure on every pass — but it is not what keeps a timeline load from racing the join
    /// into two requests for one host. `refresh` is: it re-reads what is in flight and what is
    /// held from inside the actor, and registers its task before it suspends, so the loser of
    /// that race returns having started nothing. Read as a guard against the race, this line
    /// would be two hops with a network in between, which is the shape the store's own note
    /// says a caller cannot get right.
    ///
    /// What is left is the leak: a superseded child still cannot be cancelled out of `settle`,
    /// so it stays parked against a dripping server. Closing that means a cancellation-aware
    /// `settle`, which is not this file.
    private func waitForCatalogues() async {
        // Captured before the group: the children are `@Sendable` and the store is an actor,
        // which is reachable from one; `session` is not. The client is built per host inside
        // the child rather than passed in, because it is a host and a transport and nothing
        // else — the transport is what has to come from out here.
        let store = session.emoji
        let http = session.http
        await withTaskGroup(of: String.self) { group in
            for host in catalogueHosts {
                group.addTask { await Self.catalogue(host, in: store, over: http); return host }
            }
            // Marked as each one lands rather than after the last, which is the whole of the
            // fix: a server is only ever waited on by the rows that read through it.
            for await host in group { settledHosts.insert(host) }
        }
    }

    /// One server's share of that: ask if there is anything to ask for, then wait for whatever
    /// is on the wire — the join's fetch or this one.
    ///
    /// Lifted out of the group so a test can run it. The body of a `View` cannot be executed by
    /// anything in this package, so a call site left inside a closure inside `body`'s `.task` is
    /// a call site with no test — and "the timeline asks at all" is exactly the fact that was
    /// missing, not something the store can pin from its own side.
    static func catalogue(_ host: String, in store: EmojiCatalogueStore, over http: any HTTPClient) async {
        if await store.needsFetch(host: host) {
            await store.refresh(host: host) {
                try await MastodonClient(http: http, host: host).customEmojis()
            }
        }
        await store.settle(host: host)
    }

    private var openedItem: DummyItem? {
        guard let openedID else { return nil }
        return items.first { $0.id == openedID }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        DummyItemRow(
                            item: item,
                            catalogues: session.emoji,
                            catalogueSettled: settledHosts.contains(item.source.host),
                            marks: markBinding(item),
                            selected: item.id == selectedID,
                            top: decks.top(of: item.id, of: item.attachments.count),
                            lifted: decks.isLifted(item.id),
                            player: player(of: item),
                            onSelect: { selectedID = item.id },
                            onToggleCover: { _ = decks.toggleCover(item.id) },
                            onPlay: { onPlayRow(item) },
                            onEnded: { playback.stop() },
                            onToast: showToast
                        )
                        .id(item.id)
                        if index < items.count - 1 {
                            Rectangle()
                                .fill(ShellChrome.hairline(colorScheme))
                                .frame(height: ShellSpace.hair)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: jumpToTop) { _, _ in
                guard let first = items.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    /// The player for this row's slot, where this row's card is the thing that is playing. There
    /// is at most one in the app, so at most one row ever gets it back.
    private func player(of item: DummyItem) -> AVPlayer? {
        playback.player(
            for: ShellPlaying.playable(decks.showing(item.attachments, of: item.id)),
            of: item.id,
            on: .row
        )
    }

    private func markBinding(_ item: DummyItem) -> Binding<DummyMarks> {
        Binding(
            get: { marks[item.id] ?? item.marks },
            set: { marks[item.id] = $0 }
        )
    }

    private func showToast(_ text: String) {
        toastTick += 1
        let tick = toastTick
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if toastTick == tick { toast = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            HStack(alignment: .center, spacing: ShellSpace.step) {
                Text(L10n.t("shell.timeline.title"))
                    .font(ShellType.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize()
                HStack(spacing: ShellSpace.tight) {
                    ForEach(session.queries) { query in
                        queryPill(query)
                    }
                }
                if session.timelineID != nil {
                    Text(timeline.rule)
                        .font(ShellType.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func queryPill(_ query: DummyTimeline) -> some View {
        let selected = query.id == session.timelineID
        return Button {
            session.timelineID = query.id
        } label: {
            Text(query.name)
                .font(ShellType.meta.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
                .padding(.horizontal, ShellSpace.snug)
                .padding(.vertical, ShellSpace.tight)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? ShellChrome.selectFill(colorScheme) : ShellChrome.well(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var empty: some View {
        ShellNotice(
            symbol: "list.bullet.rectangle",
            title: L10n.t("\(timeline.emptyKey).title"),
            detail: L10n.t("\(timeline.emptyKey).detail")
        )
    }
}
