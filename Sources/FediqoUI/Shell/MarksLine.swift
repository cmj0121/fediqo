import SwiftUI

/// A post's marks — reply, boost, quote, favourite, bookmark and the rest — **always on one line**,
/// on a Mac and a phone, at every width and every type size (#245).
///
/// Where the line is wider than the width there is, it gives way in this order and never wraps:
/// the gaps between the marks close first, down to `least`; then every mark is narrowed in
/// proportion to its width, and a narrowed mark gives up its touch room, then its count, then
/// the size of its glyph (`DummyMarkButton`). Every mark is still there to press and still named
/// to VoiceOver — it is only drawn smaller.
///
/// **A subview with a negative layout priority is the sentence after the marks** (the refusal): it
/// is not counted when the marks are fitted, and takes whatever is left over, cut short.
///
/// The line is as tall as its tallest mark, which is a press's floor at every width — so the
/// marks line is one line, of one height, on every row alike.
struct MarksLine: Layout {
    /// The gap between two marks, unless a mark asks for its own (`MarkGap`).
    var spacing: CGFloat = ShellSpace.snug
    /// The least a gap closes to before the marks themselves are narrowed.
    var least: CGFloat = ShellSpace.hair

    /// How the marks are fitted into `width`: the gap before each (the first's is never used) and
    /// the width each is offered. Nothing, or no bound, is as wide as the marks like.
    static func fit(_ widths: [CGFloat], gaps: [CGFloat], least: CGFloat, width: CGFloat?)
        -> (gaps: [CGFloat], widths: [CGFloat])
    {
        let inner = Array(gaps.dropFirst())
        let ideal = widths.reduce(0, +) + inner.reduce(0, +)
        guard let bound = width, bound.isFinite, ideal > bound else { return (gaps, widths) }
        let excess = ideal - bound
        let slack = inner.reduce(0) { $0 + max(0, $1 - least) }
        if excess <= slack, slack > 0 {
            let closed = gaps.enumerated().map { index, gap in
                index == 0 ? gap : gap - max(0, gap - least) * excess / slack
            }
            return (closed, widths)
        }
        let closed = gaps.enumerated().map { index, gap in index == 0 ? gap : min(gap, least) }
        let room = max(0, bound - closed.dropFirst().reduce(0, +))
        let total = widths.reduce(0, +)
        let scale = total > 0 ? min(1, room / total) : 1
        return (closed, widths.map { $0 * scale })
    }

    private func split(_ subviews: Subviews) -> (marks: [LayoutSubview], rest: [LayoutSubview]) {
        (subviews.filter { $0.priority >= 0 }, subviews.filter { $0.priority < 0 })
    }

    private func gaps(_ marks: [LayoutSubview]) -> [CGFloat] {
        marks.map { $0[MarkGap.self] ?? spacing }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (marks, rest) = split(subviews)
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let tall = ideals.map(\.height).max() ?? 0
        if let width = proposal.width, width.isFinite { return CGSize(width: width, height: tall) }
        let across = marks.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            + gaps(marks).dropFirst().reduce(0, +)
            + rest.map { spacing + $0.sizeThatFits(.unspecified).width }.reduce(0, +)
        return CGSize(width: across, height: tall)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (marks, rest) = split(subviews)
        let tall = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let fitted = Self.fit(
            marks.map { $0.sizeThatFits(.unspecified).width }, gaps: gaps(marks), least: least, width: bounds.width
        )
        var x = bounds.minX
        for (index, mark) in marks.enumerated() {
            if index > 0 { x += fitted.gaps[index] }
            let offered = ProposedViewSize(width: fitted.widths[index], height: tall)
            let size = mark.sizeThatFits(offered)
            mark.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: offered)
            x += size.width
        }
        for sentence in rest {
            if !marks.isEmpty { x += spacing }
            let offered = ProposedViewSize(width: max(0, bounds.maxX - x), height: tall)
            let size = sentence.sizeThatFits(offered)
            sentence.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: offered)
            x += size.width
        }
    }
}

/// The gap a mark asks for before it, where it starts a group of its own: the marks that keep a
/// post stand a little apart from the marks that pass it on.
struct MarkGap: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}
