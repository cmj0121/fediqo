import SwiftUI

/// A sheet's presses, Cancel first and the act after it, at the trailing edge — **always in one
/// row.** A question is answered on one line of presses, whatever the width and whatever the type:
/// where the row is wider than the width there is, each press gives up its share of the
/// difference, and its label — one line, set by `onePressLine()` — shrinks to fit rather than
/// breaking onto a second line or dropping below the others.
///
/// **Measured against the width there is, not a guess at it.** Asked for its ideal it answers the
/// whole row, so a fitted sheet grows to hold it; only a width narrower than that is shared out.
struct ShellPressRow: Layout {
    var spacing: CGFloat = ShellSpace.snug

    /// Where each press goes and how wide it is: one row, trailing aligned. `width` is what there
    /// is; nothing, or no bound, is as wide as the row likes. Past the bound each press is
    /// narrowed in proportion to its ideal width, so the row always ends inside it.
    static func arrangement(_ sizes: [CGSize], spacing: CGFloat, width: CGFloat?) -> (size: CGSize, origins: [CGPoint], widths: [CGFloat]) {
        let bound = width.flatMap { $0.isFinite ? $0 : nil }
        let gaps = spacing * CGFloat(max(0, sizes.count - 1))
        let ideal = sizes.map(\.width).reduce(0, +)
        let room = bound.map { max(0, $0 - gaps) } ?? ideal
        let scale = ideal > room && ideal > 0 ? room / ideal : 1
        let widths = sizes.map { $0.width * scale }
        let row = widths.reduce(0, +) + gaps
        let across = max(bound ?? row, row)
        let tall = sizes.map(\.height).max() ?? 0
        var x = across - row
        var origins: [CGPoint] = []
        for (size, wide) in zip(sizes, widths) {
            origins.append(CGPoint(x: x, y: (tall - size.height) / 2))
            x += wide + spacing
        }
        return (CGSize(width: across, height: tall), origins, widths)
    }

    /// Whether the presses sit in one row at `width` — always, and kept as a check.
    static func inOneRow(_ sizes: [CGSize], spacing: CGFloat = ShellSpace.snug, width: CGFloat?) -> Bool {
        let placed = arrangement(sizes, spacing: spacing, width: width)
        let middles = zip(placed.origins, sizes).map { $0.y + $1.height / 2 }
        let inside = width.map { bound in zip(placed.origins, placed.widths).allSatisfy { $0.x >= -0.5 && $0.x + $1 <= bound + 0.5 } } ?? true
        return inside && middles.allSatisfy { abs($0 - (middles.first ?? 0)) < 0.5 }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.arrangement(subviews.map { $0.sizeThatFits(.unspecified) }, spacing: spacing, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let placed = Self.arrangement(sizes, spacing: spacing, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + placed.origins[index].x, y: bounds.minY + placed.origins[index].y),
                proposal: ProposedViewSize(width: placed.widths[index], height: sizes[index].height)
            )
        }
    }
}

extension View {
    /// A press's label on one line, shrinking before it would break or be cut: what lets
    /// `ShellPressRow` keep every question's answers in one row.
    func onePressLine() -> some View {
        lineLimit(1).minimumScaleFactor(0.5)
    }
}
