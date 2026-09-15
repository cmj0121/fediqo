import CoreGraphics

/// One spacing scale for the shell. Every gap in a pane is one of these.
///
/// Three panes used to carry a private metrics table each, and the gaps between them
/// drifted — 16, 12, 10, 8, 6, 4 all appeared, and none of them agreed about what a
/// step was. These are the steps.
enum ShellSpace {
    /// A rule, a border, a lamp's own width before it is doubled.
    static let hair: CGFloat = 1

    /// Inside a control: glyph to its count, cap to its edge.
    static let tight: CGFloat = 4

    /// Between things that belong together: an avatar and the name beside it.
    static let snug: CGFloat = 8

    /// Between the parts of one row.
    static let step: CGFloat = 12

    /// A pane's own margin, and the gap between its blocks.
    static let pad: CGFloat = 16

    /// Around something that has to stand alone.
    static let room: CGFloat = 24
}
