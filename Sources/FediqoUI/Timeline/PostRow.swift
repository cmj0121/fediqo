import SwiftUI
import FediqoCore

/// One row. It can always say which server handed it over, and whether it is a boost.
struct PostRow: View {
    let post: Post
    /// Whether this is the row the reader is on. The row is told rather than asking: which
    /// post the ring is on belongs to the feed, and a row knows nothing but itself.
    var selected = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let boostedBy = post.boostedBy {
                Label(t("timeline.boostedBy", boostedBy), systemImage: "arrow.2.squarepath")
                    .fediqoFont(10)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 10) {
                RemoteImage(url: post.authorAvatarURL, width: 34, height: 34)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(post.authorName).fediqoFont(13, weight: .semibold).lineLimit(1)
                        Text(post.authorHandle).fediqoFont(11).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(post.createdAt, format: .relative(presentation: .numeric))
                            .fediqoFont(10)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if !post.text.isEmpty {
                        Text(post.text)
                            .fediqoFont(13)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !post.mediaURLs.isEmpty {
                        media
                    }

                    sources
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fediqoCard()
        .fediqoFocusRing(selected)
        .contextMenu {
            if let url = post.webURL {
                Button(t("timeline.open")) { openURL(url) }
            }
        }
    }

    private var media: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(post.mediaURLs, id: \.self) { url in
                    RemoteImage(url: url, width: 132, height: 88)
                }
            }
        }
        .frame(height: 88)
    }

    /// Every row can say which server handed it over — and when two did, it says both.
    private var sources: some View {
        HStack(spacing: 5) {
            Text(t("timeline.via")).fediqoFont(10).foregroundStyle(.tertiary)
            ForEach(post.sources, id: \.self) { host in
                Text(host).fediqoFont(10).fediqoPill()
            }
        }
        .padding(.top, 2)
    }
}

/// An avatar or a thumbnail: the same fetch, placeholder and clip wherever a picture comes
/// off a server rather than out of the bundle.
struct RemoteImage: View {
    @Environment(\.colorScheme) private var colorScheme
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = 7

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(Palette.hairline(colorScheme))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
