import FediqoCore
import SwiftUI

/// The head of a hashtag's page (F10): the tag as it was written where it was pressed, the
/// press that follows it where exactly one source offers that, how many posts this device
/// holds under it, and a mark for each source that said the reader follows it there.
///
///     #swift                                        [ Follow ]
///     (bubble 41)  [✓ mastodon.social]
///
/// **It draws what it is handed and asks nothing.** The figure is a press that opens Posts
/// where the page has a strip of tabs, and a glyph and a number on no well where it has
/// none (`PageFigure`). **A source that did not say it is followed has no mark** — there is
/// no mark for "not followed" — and a mark is its glyph with the host as its word, never a
/// colour alone.
struct TagHead: View {
    let said: TagPageSaid
    /// The figure pressed: its tab, brought in front.
    var onTab: (TagTab) -> Void = { _ in }
    /// The head's Follow, pressed.
    var onFollow: (TagFollowLine) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            // The press beside the tag where both fit whole, and under it where they do not.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
                    name.fixedSize()
                    Spacer(minLength: 0)
                    follow
                }
                VStack(alignment: .leading, spacing: ShellSpace.snug) {
                    name
                    follow
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: ShellSpace.step) { counted(whole: true) }
                VStack(alignment: .leading, spacing: ShellSpace.tight) { counted(whole: true) }
                VStack(alignment: .leading, spacing: ShellSpace.tight) { counted(whole: false) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
    }

    private var name: some View {
        Text(verbatim: said.tag.text)
            .shellFont(.name)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .lineLimit(1)
            .accessibilityLabel(String(format: L10n.t("post.tag.spoken"), said.tag.name))
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var follow: some View {
        if let line = said.follow, let word = line.pressWords() {
            let spoken = line.pressSpoken() ?? word
            ShellLinkButton(word) { onFollow(line) }
                .accessibilityLabel(spoken)
                .help(spoken)
                .fixedSize()
        }
    }

    /// The figure, and after it the marks. `whole` is whether each is held to one line.
    @ViewBuilder
    private func counted(whole: Bool) -> some View {
        PageFigureView(figure: said.figure) { onTab(.posts) }.fixedSize(horizontal: whole, vertical: true)
        ForEach(said.followed) { mark in
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                Image(systemName: TagPageSaid.Followed.symbol).accessibilityHidden(true)
                Text(mark.host)
            }
            .shellFont(.mark)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: whole, vertical: true)
            .help(mark.spoken)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mark.spoken)
        }
    }
}
