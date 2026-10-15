import SwiftUI

/// The About tab of a hashtag's page (F10): where the hashtag is followed — one row for each
/// source that has a line, with the press to follow there or the `…` that unfollows, or how its
/// sign-in stands and the press that asks — and which sources the page's posts were asked of.
///
/// **Each a block the lamp stops on.** It draws what it is handed (`TagAboutSaid`) and asks
/// nothing: the asking and the presses are `ShellTagFollow`'s, and a row is the one a
/// hashtag's page always drew (`TagFollowRow`).
struct TagAbout<Lead: View>: View {
    let said: TagAboutSaid
    /// The block the lamp is on.
    var lit: String?
    var jumpToTop: Int = 0
    /// A row's press at its source: follow, or ask again whether it is followed.
    var onPress: (TagFollowLine) -> Void = { _ in }
    /// The item of a row's `…` that unfollows.
    var onUnfollow: (TagFollowLine) -> Void = { _ in }
    /// A lock's press: the question that asks that source's sign-in for who the reader follows.
    var onAsk: (String) -> Void = { _ in }
    /// What stands over the blocks and scrolls away with them: the page's head, at a text
    /// size where it would fill the page.
    @ViewBuilder var lead: Lead

    @Environment(\.colorScheme) private var colorScheme

    private static var top: String { "tag.about.top" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top).accessibilityHidden(true)
                    lead
                    ForEach(said.follows) { line in
                        TagFollowRow(line: line, onPress: { onPress(line) }, onUnfollow: { onUnfollow(line) }, onAsk: { onAsk(line.host) })
                            .modifier(TagAboutBlock(id: TagAboutSaid.lamp(on: line), lit: lit))
                    }
                    if let reach = said.reach {
                        Text(reach)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, ShellSpace.pad)
                            .padding(.vertical, ShellSpace.snug)
                            .modifier(TagAboutBlock(id: TagAboutSaid.reachID, lit: lit))
                    }
                }
                .padding(.vertical, ShellSpace.tight)
            }
            .scrollIndicators(.never)
            .clearsFloatingCorner()
            .onChange(of: lit) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: jumpToTop) { _, _ in
                withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(Self.top, anchor: .top) }
            }
        }
    }
}

/// Which blocks a hosted About drew, and how large: by what the lamp calls each.
@MainActor
final class TagAboutProbe {
    var sizes: [String: CGSize] = [:]
    /// The press each source's row drew beside its line, by host: its words.
    var presses: [String: String] = [:]
    /// The `…` each source's row drew, by host: what it is called.
    var menus: [String: String] = [:]
}

extension EnvironmentValues {
    /// Where a hosted About reports what it drew. Nothing in the app.
    @Entry var tagAboutProbe: TagAboutProbe? = nil
}

/// One block of About: as wide as the page, lit as the lamp lights it (`AboutBlockLit`), and
/// called what the lamp calls it.
private struct TagAboutBlock: ViewModifier {
    let id: String
    let lit: String?

    @Environment(\.tagAboutProbe) private var probe

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(AboutBlockLit(lit: id == lit))
            .background(GeometryReader { room in
                let _ = probe?.sizes[id] = room.size
                Color.clear
            })
            .id(id)
    }
}
