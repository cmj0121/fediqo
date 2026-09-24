import SwiftUI

/// The heading of a group of data (#243) — **rule 5 of #242: the description heads its data.**
///
///     Title
///     a short line  (?)
///
/// A group says what it is and one short line about it, and the long explanation is behind the
/// (?) after that line — here, on its heading, beside the rows it speaks of. Nothing about a
/// group is said under a page's title or at a group's foot; a page's title names the page.
///
/// The title is a header to VoiceOver, so a reader walking by headings lands on each group. The
/// short line is read after it; the (?) is spoken as itself, "More about <title>", with the long
/// explanation as its hint.
///
/// Headings wrap rather than cut: a heading is read once per group, not scanned forty times like
/// a row, and cutting the one line that says what a group is would cut the thing it is for.
struct ShellSectionHead: View {
    let title: String
    let line: String?
    let help: String?

    @Environment(\.colorScheme) private var colorScheme

    /// A heading already worded: the title, its short line, and the whole explanation behind (?).
    init(_ title: String, line: String? = nil, help: String? = nil) {
        self.title = title
        self.line = line
        self.help = help
    }

    /// A heading by its keys.
    init(title key: String, line lineKey: String? = nil, help helpKey: String? = nil) {
        self.init(L10n.t(key), line: lineKey.map { L10n.t($0) }, help: helpKey.map { L10n.t($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.hair) {
            titled
            said
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
    }

    /// The title, with the (?) beside it where there is no short line for it to follow.
    @ViewBuilder
    private var titled: some View {
        let text = Text(title)
            .shellFont(.name)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        if line == nil, let help {
            text.shellHelp(verbatim: help, about: title)
        } else {
            text
        }
    }

    /// The short line, and its (?) after it.
    @ViewBuilder
    private var said: some View {
        if let line {
            let text = Text(line)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if let help {
                text.shellHelp(verbatim: help, about: title)
            } else {
                text
            }
        }
    }
}
