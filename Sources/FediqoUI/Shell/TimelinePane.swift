import SwiftUI

/// The timeline place: named queries, a brief rule, then the stream or a thread.
struct TimelinePane: View {
    @Binding var timelineID: String
    @Binding var selectedID: String?
    @Binding var openedID: String?
    @State private var marks: [String: DummyMarks] = [:]
    @State private var toast: String?
    @State private var toastTick = 0
    @Environment(\.colorScheme) private var colorScheme

    private var timeline: DummyTimeline { DummyTimeline(id: timelineID) }

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
                    marks: markBinding,
                    onToast: showToast,
                    onBack: { openedID = nil }
                )
            } else if timeline.items.isEmpty {
                empty
            } else {
                list
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ShellChrome.selectFill(colorScheme), in: Capsule())
                    .foregroundStyle(ShellChrome.selectInk(colorScheme))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .onChange(of: timelineID) { _, _ in
            if let selectedID, !timeline.items.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            openedID = nil
        }
    }

    private var openedItem: DummyItem? {
        guard let openedID else { return nil }
        return DummyItem.stored.first { $0.id == openedID }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(timeline.items) { item in
                        DummyItemRow(
                            item: item,
                            marks: markBinding(item),
                            selected: item.id == selectedID,
                            onSelect: { selectedID = item.id },
                            onToast: showToast
                        )
                        .id(item.id)
                        Rectangle()
                            .fill(ShellChrome.hairline(colorScheme))
                            .frame(height: 1)
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
        }
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
        HStack(alignment: .center, spacing: 8) {
            Text(L10n.t("shell.timeline.title"))
                .font(.headline)
                .fixedSize()
            HStack(spacing: 6) {
                ForEach(DummyTimeline.shipped) { query in
                    queryPill(query)
                }
                addQuery
            }
            Text(timeline.rule)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func queryPill(_ query: DummyTimeline) -> some View {
        let selected = query.id == timelineID
        return Button {
            timelineID = query.id
        } label: {
            Text(query.name)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? ShellChrome.selectInk(colorScheme) : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? ShellChrome.selectFill(colorScheme) : ShellChrome.well(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var addQuery: some View {
        Button {
            showToast(L10n.t("timeline.add.toast"))
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 24)
                .background(
                    Capsule(style: .continuous)
                        .fill(ShellChrome.well(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("timeline.add"))
        .help(L10n.t("timeline.add"))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image("Mascot", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 200)
            Text(L10n.t("timeline.empty"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
