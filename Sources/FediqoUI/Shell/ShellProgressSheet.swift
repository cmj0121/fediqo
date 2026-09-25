import FediqoCore
import SwiftUI

/// What a move's progress sheet says (#253, #247): built by the flow from its step, pure, and
/// drawn by `ShellProgressSheet` whichever flow it is — a move nearby on either device, a take
/// away, a read back.
struct ShellProgress: Equatable {
    /// The glyph at the head.
    let symbol: String
    /// Which way and with whom: "Moving to a tablet", "Holding from a laptop", "Reading back".
    let title: String
    /// The stage, in one line.
    let stage: String
    /// How far, where that is known; a spinner where it is not.
    let fraction: Double?
    /// Bytes and the estimate: "1.2 GB of 3.4 GB · about 2 minutes left".
    let amount: String?
    /// The code both screens show, on a move nearby.
    let code: String?
    /// Whether Cancel may still stop it: not once a read back has begun.
    let canCancel: Bool
    /// What Cancel does, as a key: told to VoiceOver and the pointer.
    let cancelHelp: String

    /// VoiceOver's value for the bar: the stage, and the percent where there is one.
    static func spoken(stage: String, fraction: Double?, language: DummyLanguage? = nil) -> String {
        guard let fraction else { return stage }
        let percent = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        return stage + ", " + String(format: L10n.t("progress.percent", language: language), percent)
    }
}

/// A move under way, on its own sheet so it is seen whatever tab is up: the glyph and which way
/// at the head with Cancel at its end, the stage in one line, the bar — determinate where the
/// flow knows how far — the bytes and the estimate, and the code. Where it can no longer be
/// stopped Cancel is dimmed and one line says so, the rest behind (?).
///
/// **Only Cancel ends it.** The sheet cannot be swiped or escaped away
/// (`interactiveDismissDisabled`), and a flow judges any clearing of it as nothing
/// (`ShellNearby.sheetPutAway`), so the system taking it down never stops a move.
struct ShellProgressSheet: View {
    let progress: ShellProgress
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .title3) private var side: CGFloat = 36
    @ShellMetric(relativeTo: .body) private var measure: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.pad) {
            head
            bar
            facts
            if !progress.canCancel { cannot }
        }
        .padding(ShellSpace.room)
        .frame(minWidth: min(measure, 320), maxWidth: measure, alignment: .leading)
        .background(ShellChrome.page(colorScheme))
        .interactiveDismissDisabled()
        .presentationSizing(.fitted)
        .presentationDetents([.medium, .large])
    }

    private var head: some View {
        HStack(alignment: .center, spacing: ShellSpace.step) {
            Image(systemName: progress.symbol)
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                .frame(width: side, height: side)
                .background(Circle().fill(ShellChrome.well(colorScheme)))
                .accessibilityHidden(true)
            Text(progress.title)
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: ShellSpace.snug)
            ShellIconButton("xmark.circle", name: "progress.stop", help: progress.cancelHelp, action: onCancel)
                .disabled(!progress.canCancel)
        }
    }

    @ViewBuilder
    private var bar: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(progress.stage)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            gauge
                .accessibilityLabel(L10n.t("progress.spoken"))
                .accessibilityValue(ShellProgress.spoken(stage: progress.stage, fraction: progress.fraction))
        }
    }

    @ViewBuilder
    private var gauge: some View {
        if let fraction = progress.fraction {
            ProgressView(value: fraction)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var facts: some View {
        if let amount = progress.amount {
            Text(amount)
                .shellFont(.meta)
                .monospacedDigit()
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let code = progress.code {
            Text(code)
                .shellFont(.meta)
                .monospacedDigit()
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
        }
    }

    private var cannot: some View {
        Text(L10n.t("progress.cannot"))
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .shellHelp("progress.cannot.help", about: progress.title)
    }
}
