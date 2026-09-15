import SwiftUI

/// The type scale. Six roles, and every piece of copy in the shell picks one of them.
///
/// Built on the semantic styles rather than point sizes, so the type-size preference in
/// Preferences still moves the whole scale. What is chosen here is which role a line
/// plays and what weight it carries — not how many points it happens to be.
enum ShellType {
    /// A pane's own title. One per page.
    static let pane = Font.title3.weight(.semibold)

    /// The line you read to know what this is: an author, a host, a group header.
    static let name = Font.callout.weight(.semibold)

    /// The words themselves.
    static let body = Font.body

    /// Present, read second: handles, summaries, the rule a timeline is under.
    static let meta = Font.caption

    /// The smallest engraving: a decorator above a row, a hint under a field.
    static let mark = Font.caption2

    /// A reading off the instrument — a count, an age, a figure. Monospaced so a
    /// column of them does not wobble as the numbers change.
    static let reading = Font.system(.caption, design: .monospaced)

    /// A key, written as the cap it is printed on.
    static let keycap = Font.system(.body, design: .monospaced)
}
