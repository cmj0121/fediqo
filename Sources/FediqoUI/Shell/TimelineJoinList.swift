import FediqoCore
import SwiftUI

/// The timelines already written that a source can join (#372): one band per timeline, a tick per
/// division of the source it would take — the list picker's rows, so the three choices this sheet
/// asks look like the one kind of choice they are.
///
/// **A division already on is drawn ticked and cannot be pressed**: it flows into that timeline
/// now, and unticking it is not this sheet's to do. A timeline that takes the source whole, or
/// with what is already on, has one row for that.
struct TimelineJoinList: View {
    @Binding var choice: TimelineJoinChoice?

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .callout) private var tickSize: CGFloat = 20

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let choice {
                    ForEach(choice.offers) { offer in
                        Section {
                            rows(offer, in: choice)
                        } header: {
                            ShellBandHead(offer.name, pinned: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rows(_ offer: TimelineJoinOffer, in choice: TimelineJoinChoice) -> some View {
        if offer.joinsAsIs {
            row(Self.asIsName(offer, host: choice.host), in: offer, on: choice.joinsAsIs(offer), locked: false) {
                self.choice = choice.tickingAsIs(offer)
            }
            ShellRule()
        }
        ForEach(offer.divisions, id: \.category) { division in
            row(
                choice.labels[division.category] ?? "", in: offer, on: choice.isTicked(division.category, on: offer),
                locked: division.locked
            ) {
                self.choice = choice.ticking(division.category, on: offer)
            }
            ShellRule()
        }
    }

    /// The row that joins a timeline as it is: the whole source where it has no divisions to
    /// pick, and with what is already on where it has.
    static func asIsName(_ offer: TimelineJoinOffer, host: String, language: DummyLanguage? = nil) -> String {
        offer.divisions.isEmpty
            ? String(format: L10n.t("timeline.join.whole", language: language), host)
            : L10n.t("timeline.join.asIs", language: language)
    }

    /// What a row says out loud: what it adds, and to which timeline — the band heading it is
    /// under is not read with it.
    static func spoken(_ name: String, in offer: TimelineJoinOffer, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("timeline.join.spoken", language: language), name, offer.name)
    }

    private func row(
        _ name: String, in offer: TimelineJoinOffer, on: Bool, locked: Bool, press: @escaping () -> Void
    ) -> some View {
        Button(action: press) {
            HStack(alignment: .center, spacing: ShellSpace.step) {
                PickTick(on: on, size: tickSize)
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    Text(name)
                        .shellFont(.name)
                        .foregroundStyle(nameInk(on: on, locked: locked))
                        .modifier(PickName())
                    if locked {
                        Text(L10n.t("timeline.join.locked"))
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on && !locked ? ShellChrome.selectFill(colorScheme) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityLabel(Text(Self.spoken(name, in: offer)))
        .accessibilityValue(Text(locked ? L10n.t("timeline.join.locked") : ""))
        .accessibilityHint(Text(locked ? "" : L10n.t(on ? "timeline.join.hint.off" : "timeline.join.hint.on")))
    }

    private func nameInk(on: Bool, locked: Bool) -> Color {
        if locked { return ShellChrome.inkDim(colorScheme) }
        return on ? ShellChrome.selectInk(colorScheme) : ShellChrome.ink(colorScheme)
    }
}
