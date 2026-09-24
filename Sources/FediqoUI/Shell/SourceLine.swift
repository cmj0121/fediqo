import SwiftUI

/// One line of what this run asks of the sources (#236): the source, what for, and when — the
/// one row both the work in flight and the record draw, rather than a copy each.
///
///     [purpose]  source                         when  ›
///                what for
///
/// A `ShellListRow`, so it is entered as every row is — a press lights it and a second opens it,
/// Return opens the lit one, VoiceOver opens it in one — and VoiceOver hears the source, what
/// for and when as one element, in that order. What its detail is, is the list's to say.
struct SourceLineRow<ID: Hashable>: View {
    let id: ID
    let source: String
    let purpose: SourceWork.Purpose
    /// What for, as the list words it: a work line names the board or the count too.
    let what: String
    /// When: how long it has run, or the clock time it left.
    let when: String
    @Binding var selection: ID?
    let onOpen: () -> Void
    let onStep: (Int) -> Void

    var body: some View {
        ShellListRow(
            id: id, title: source, brief: what, figure: when,
            selection: $selection, onOpen: onOpen, onStep: onStep
        ) {
            Image(systemName: purpose.symbol)
        }
    }
}

extension SourceWork.Purpose {
    /// The glyph a row of work, or of the record, leads with.
    var symbol: String {
        switch self {
        case .timeline: "text.line.first.and.arrowtriangle.forward"
        case .conversation: "bubble.left.and.bubble.right"
        case .forumPost, .forumReplies: "text.bubble"
        case .lists: "list.bullet"
        case .joining: "plus.circle"
        case .boards: "square.grid.2x2"
        case .directory: "list.bullet.rectangle"
        case .serverCheck: "checkmark.seal"
        case .picture: "photo"
        case .emoji: "face.smiling"
        case .signInCheck, .signIn: "person.badge.key"
        case .signOut: "rectangle.portrait.and.arrow.right"
        case .write: "square.and.pencil"
        case .search: "magnifyingglass"
        case .page: "doc.richtext"
        case .video: "play.rectangle"
        case .signInPage: "arrow.up.forward.square"
        case .personCheck: "person.badge.shield.checkmark"
        case .pagePart: "puzzlepiece"
        }
    }
}
