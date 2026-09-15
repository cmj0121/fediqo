import SwiftUI

/// The timeline place: named queries, a brief rule, then the stream or a thread.
struct TimelinePane: View {
    @Bindable var session: ShellSession
    @Binding var selectedID: String?
    @Binding var openedID: String?
    var jumpToTop: Int
    var onPopThread: () -> Void
    @State private var marks: [String: DummyMarks] = [:]
    @State private var toast: String?
    @State private var toastTick = 0
    @Environment(\.colorScheme) private var colorScheme

    private var timeline: DummyTimeline { DummyTimeline(id: session.timelineID ?? "") }

    private var items: [DummyItem] { timeline.items(from: session.notes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: 1)

            if let opened = openedItem {
                DummyThreadPane(
                    root: opened,
                    selectedID: $selectedID,
                    marks: markBinding,
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
        .onChange(of: session.timelineID) { _, _ in
            if let selectedID, !items.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            openedID = nil
        }
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
                            marks: markBinding(item),
                            selected: item.id == selectedID,
                            onSelect: { selectedID = item.id },
                            onToast: showToast
                        )
                        .id(item.id)
                        if showsHairline(after: index) {
                            Rectangle()
                                .fill(ShellChrome.hairline(colorScheme))
                                .frame(height: 1)
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

    /// Hide the rule against a floating row so the plate is not cut by a hairline.
    private func showsHairline(after index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        if items[index].id == selectedID { return false }
        let next = items.index(after: index)
        if items.indices.contains(next), items[next].id == selectedID { return false }
        return true
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(L10n.t("shell.timeline.title"))
                    .font(ShellType.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize()
                HStack(spacing: 6) {
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
            if !session.sources.isEmpty {
                SourceMarkRow(sources: session.sources.map { .unsigned($0.host) })
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
        ContentUnavailableView(
            L10n.t(timeline.emptyKey),
            systemImage: "list.bullet.rectangle"
        )
    }
}
