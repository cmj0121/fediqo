import SwiftUI
import FediqoCore

/// What the reader has opened, at the size the app has — and, where the platform has a screen
/// to give, at the size of that.
///
/// The deck was built with no way to make a picture bigger, and said so in its own comment:
/// "there is no lightbox and no gallery — nothing that has to be got out of again". That was
/// the wrong call about the one thing a reader most wants from a picture, which is to see it,
/// and #41 overturned it. What survives of the old rule is the part that was right: there is
/// still nothing here to get lost in. One press opens it, `Escape` leaves it, and what it
/// leaves is the row it was opened from, with the ring where the reader left it.
struct MediaViewing: Equatable {
    var attachments: [Attachment]
    var index: Int
    /// Whether it arrived covered. The cover is the reader's to lift here as in the row, and
    /// lifting it lasts as long as this looking and is written down nowhere.
    var covered: Bool

    var showing: Attachment? {
        attachments.isEmpty ? nil : attachments[index % attachments.count]
    }
}

struct MediaViewer: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    /// The reader's answer about the cover, for as long as this looking lasts.
    @State private var lifted = false

    private var viewing: MediaViewing? { app.viewing }
    private var hidden: Bool { (viewing?.covered ?? false) && !lifted }

    var body: some View {
        if let viewing, let showing = viewing.showing {
            ZStack {
                // The sheet of nothing behind it, which is also the way out: a press anywhere
                // that is not the picture closes it, the way it does behind every other panel
                // in this app.
                Color.black.opacity(0.92)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { app.closeTheMedia() }

                VStack(spacing: Space.gap) {
                    picture(showing)
                    caption(viewing, showing)
                }
                .padding(Space.band)
            }
            .overlay(alignment: .topTrailing) { controls }
            // The keys are the row's keys, unchanged: `m` turns the deck, `p` plays what is
            // on it, `s` lifts what the author covered. They arrive as the same counters the
            // row hears, so one key does one thing whether or not this is open.
            .onChange(of: app.mediaTurns) { _, _ in turn() }
            .onChange(of: app.mediaPlays) { _, _ in play(showing) }
            .onChange(of: app.mediaCovers) { _, _ in withAnimation(Motion.appearing) { lifted.toggle() } }
            .onDisappear { lifted = false }
            .transition(.opacity)
        }
    }

    /// The picture, or the film playing in the same rectangle the still was in. Held to the
    /// room there is and no larger: a picture smaller than the window is not stretched to fill
    /// it, because what the reader asked to see is the picture, not an enlargement of it.
    @ViewBuilder
    private func picture(_ attachment: Attachment) -> some View {
        ZStack {
            if let player = app.playback.player, app.playback.isPlaying(attachment.url) {
                AttachmentPlayer(player: player, audio: attachment.kind == .audio)
            } else {
                AsyncImage(url: hidden ? nil : attachment.displayURL) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    // Covered, or still on its way. Neither is a picture to draw, and both
                    // are the same rectangle so nothing jumps when it arrives.
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                }
                .blur(radius: hidden ? 30 : 0)
            }

            if hidden { cover }
            if !hidden, attachment.isPlayable, !app.playback.isPlaying(attachment.url) {
                Button { play(attachment) } label: {
                    Image(systemName: "play.fill")
                        .fediqoSymbol(Glyph.big)
                        .padding(Space.room)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(t("post.media.play"))
                .accessibilityLabel(Text(t("post.media.play")))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A press on the picture itself turns the deck, which is what a press on it did in
        // the row. It does not close: closing is the sheet behind it, `Escape`, and the mark
        // in the corner.
        .contentShape(Rectangle())
        .onTapGesture { hidden ? lift() : turn() }
    }

    /// Where in the deck this is, and what its author wrote for somebody who cannot see it.
    @ViewBuilder
    private func caption(_ viewing: MediaViewing, _ attachment: Attachment) -> some View {
        VStack(spacing: Space.snug) {
            if viewing.attachments.count > 1 {
                Text(t("post.media.position", viewing.index % viewing.attachments.count + 1,
                       viewing.attachments.count))
                    .fediqoFont(TypeScale.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            if !attachment.alt.isEmpty {
                Text(attachment.alt)
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: Size.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cover: some View {
        Button(action: lift) {
            HStack(spacing: Space.snug) {
                Image(systemName: "eye.slash").fediqoSymbol(Glyph.badge)
                Text(t("post.covered.show")).fediqoFont(TypeScale.caption, weight: .medium)
            }
            .padding(.horizontal, Space.step)
            .padding(.vertical, Space.snug)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    /// The two things this view can be asked, in the corner where a window's own controls are:
    /// take the screen, and give the picture back.
    private var controls: some View {
        HStack(spacing: Space.withinGroup) {
            #if os(macOS)
            IconButton(symbol: app.tookTheScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       labelKey: app.tookTheScreen ? "post.media.leaveFullScreen" : "post.media.fullScreen",
                       tint: .white) {
                app.perform(.fullScreen)
            }
            #endif
            IconButton(symbol: "xmark", labelKey: "common.close", tint: .white) { app.closeTheMedia() }
        }
        .padding(Space.room)
    }

    private func lift() {
        withAnimation(Motion.appearing) { lifted = true }
    }

    private func turn() {
        guard let viewing, viewing.attachments.count > 1 else { return }
        if app.playback.isPlaying(viewing.showing?.url) { app.playback.stop() }
        withAnimation(Motion.appearing) {
            app.viewing?.index = (viewing.index + 1) % viewing.attachments.count
        }
    }

    private func play(_ attachment: Attachment?) {
        guard let url = attachment?.url, attachment?.isPlayable == true else { return }
        app.playback.toggle(url)
    }
}
