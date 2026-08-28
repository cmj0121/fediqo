import SwiftUI

/// A row that wraps.
///
/// SwiftUI has no such stack. The pills on a server's card are a list whose length is the
/// server's to decide — six languages, a version and a word about registrations do not fit on
/// one line of a phone — and an `HStack` would rather squeeze every one of them to nothing
/// than admit it ran out of room.
struct FlowRow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, within: width)
        let stacked: CGFloat = rows.reduce(CGFloat(0)) { $0 + $1.height }
        let gaps = CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: stacked + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, within: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
        var width: CGFloat = 0
    }

    /// Which subview goes on which line, measured at the size each one asks for. A single
    /// subview wider than the row still gets its own line rather than none.
    private func arrange(_ subviews: Subviews, within width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
            current.width = x - spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
