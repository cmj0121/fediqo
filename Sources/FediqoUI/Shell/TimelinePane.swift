import SwiftUI

/// The timeline place: named queries, a brief rule, then the stream.
struct TimelinePane: View {
    @Binding var timelineID: String
    @State private var marks: [String: DummyMarks] = [:]
    @State private var toast: String?
    @State private var toastTick = 0

    private var timeline: DummyTimeline { DummyTimeline(id: timelineID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            if timeline.items.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(timeline.items) { item in
                            DummyItemRow(
                                item: item,
                                marks: markBinding(item),
                                onToast: showToast
                            )
                            Divider()
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.14 : 0.06))
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
                        .fill(Color.primary.opacity(0.06))
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
