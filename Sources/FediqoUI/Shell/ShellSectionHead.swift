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

/// A heading inside a list: the band a run of rows is under — a rule band in the editor, a host
/// over its categories, a forum's category over its boards. Smaller than a section's head and
/// said once: the name, in the quiet ink, on the well.
///
/// Three sites drew this three ways — a rounded plate, no plate at all, a square band — and the
/// reader met the same kind of line as three kinds. **One face, and one difference that is
/// stated**: a band `pinned` to the top of a scrolling list is square and reaches both edges at
/// the page's own margin, because rows pass under it and a rounded plate would show them at its
/// corners; anywhere else it is a rounded plate set in by a row's own inset.
struct ShellBandHead: View {
    let title: String
    let pinned: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, pinned: Bool = false) {
        self.title = title
        self.pinned = pinned
    }

    var body: some View {
        // Pinned over a scrolling list it is square and set in by the page's margin; anywhere
        // else it is a rounded plate.
        let inset = pinned
            ? CGSize(width: ShellSpace.pad, height: ShellSpace.snug)
            : CGSize(width: ShellSpace.snug, height: ShellSpace.tight)
        Text(title)
            .shellFont(.name)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset.width)
            .padding(.vertical, inset.height)
            .background(ShellChrome.well(colorScheme), in: RoundedRectangle(cornerRadius: pinned ? 0 : ShellRadius.field))
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a section is doing, or what it is for while it is doing nothing: the one line under a
/// section's head that changes as the work goes. `.meta` in the quiet ink, whichever it says.
///
/// Carry and Nearby each drew the idle sentence as a `.reading` in the faint ink and the
/// progress sentence as `.meta` in the dim one — so the same slot changed face when the work
/// began, and a sentence was set in the face a figure is read in. It is a sentence both times.
struct ShellStatusLine: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
    }
}

/// A figure or a fact a section reads out — how many posts, that nothing is held — as a line of
/// its own: `.reading` in the faintest ink. Where a line says what the section is *doing*, it
/// is a `ShellStatusLine`.
struct ShellReadingLine: View {
    let text: Text
    @Environment(\.colorScheme) private var colorScheme

    init(_ line: String) {
        text = Text(line)
    }

    /// A line already put together from parts — a count, and a date set in the reader's locale.
    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
    }
}
