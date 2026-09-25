import SwiftUI

/// A sheet's presses, Cancel first and the act after it, at the trailing edge — **in one row
/// wherever the row fits, and one above another only where it does not**: three choices at the
/// largest type on a phone.
///
/// **Measured against the width there is, not a guess at it.** The question's card used
/// `ViewThatFits` inside a card capped at its reading measure, so a row wider than the measure
/// less its margins — Take away's Cancel, Without pictures, With pictures — stacked on a Mac
/// with the whole window beside it. This lays the presses out from their own ideal widths: asked
/// for its ideal it answers the row, so a fitted sheet grows to hold it, and given a width it
/// stacks only where the row is wider than that width.
struct ShellPressRow: Layout {
    var spacing: CGFloat = ShellSpace.snug

    /// Where each press goes, from its ideal size: the space the presses take and each one's
    /// origin from the top leading corner, trailing aligned. `width` is what there is; nothing,
    /// or no bound, is as wide as the row likes.
    static func arrangement(_ sizes: [CGSize], spacing: CGFloat, width: CGFloat?) -> (size: CGSize, origins: [CGPoint]) {
        let bound = width.flatMap { $0.isFinite ? $0 : nil }
        let row = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        if bound.map({ row <= $0 + 0.5 }) ?? true {
            let across = max(bound ?? row, row)
            let tall = sizes.map(\.height).max() ?? 0
            var x = across - row
            var origins: [CGPoint] = []
            for size in sizes {
                origins.append(CGPoint(x: x, y: (tall - size.height) / 2))
                x += size.width + spacing
            }
            return (CGSize(width: across, height: tall), origins)
        }
        let across = bound ?? row
        var y: CGFloat = 0
        var origins: [CGPoint] = []
        for size in sizes {
            origins.append(CGPoint(x: across - min(size.width, across), y: y))
            y += size.height + spacing
        }
        return (CGSize(width: across, height: max(0, y - spacing)), origins)
    }

    /// Whether the presses sit in one row at `width`.
    static func inOneRow(_ sizes: [CGSize], spacing: CGFloat = ShellSpace.snug, width: CGFloat?) -> Bool {
        let origins = arrangement(sizes, spacing: spacing, width: width).origins
        let middles = zip(origins, sizes).map { $0.y + $1.height / 2 }
        return middles.allSatisfy { abs($0 - (middles.first ?? 0)) < 0.5 }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.arrangement(subviews.map { $0.sizeThatFits(.unspecified) }, spacing: spacing, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let origins = Self.arrangement(sizes, spacing: spacing, width: bounds.width).origins
        for (index, subview) in subviews.enumerated() {
            let width = min(sizes[index].width, bounds.width)
            subview.place(
                at: CGPoint(x: bounds.minX + origins[index].x, y: bounds.minY + origins[index].y),
                proposal: ProposedViewSize(width: width, height: sizes[index].height)
            )
        }
    }
}
