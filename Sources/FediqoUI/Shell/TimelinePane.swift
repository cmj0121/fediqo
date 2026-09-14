import SwiftUI

/// The timeline place: named queries as tabs, a rule line, then the stream.
struct TimelinePane: View {
    @Binding var timelineID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(L10n.t("timeline.picker"), selection: $timelineID) {
                ForEach(DummyTimeline.shipped) { timeline in
                    Text(timeline.name).tag(timeline.id)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text(L10n.t("timeline.noRules"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

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
}
