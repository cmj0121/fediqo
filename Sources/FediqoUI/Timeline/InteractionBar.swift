import SwiftUI
import FediqoCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What can be done with a post, and what has already been done with it by everybody else.
///
/// Three groups, left to right, and the order is the argument: **what others did**, which
/// carries counts and is about the post; **what I did**, which carries no counts and is a
/// switch; and **where this goes**, which leaves the row. Five controls in one undifferentiated
/// run was readable; eight would not have been.
///
/// A count is drawn only where there is one. Nothing here shows a zero it invented: zero means
/// nobody replied, and a post stored before migration 005 has no idea how many did. The same
/// rule governs the switches — a mark nobody has told us about is drawn unfilled and does not
/// claim to mean "not favourited".
struct InteractionBar: View {
    let post: Post
    var open: (() -> Void)?

    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showingMore = false

    private var marks: PostMarks { app.marks(of: post) }

    var body: some View {
        HStack(spacing: 14) {
            theirs
            divider
            mine
            divider
            leaving
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    /// What everybody else did, with the numbers the servers gave us.
    private var theirs: some View {
        HStack(spacing: 14) {
            // Replying makes a new post rather than marking this one, and this app has no
            // composer that can send one yet — so it still leaves, and says so by doing
            // nothing else. When #8 lands it stops leaving and nothing else here changes.
            counted("arrowshape.turn.up.left", count: post.counts.replies,
                    labelKey: "post.reply", on: false, tint: .secondary) { hand() }
            counted("arrow.2.squarepath", count: post.counts.reblogs,
                    labelKey: "post.reblog", on: marks.reblogged == true, tint: .green) {
                Task { await app.act(.reblog, on: post) }
            }
            counted(marks.favourited == true ? "star.fill" : "star", count: post.counts.favourites,
                    labelKey: "post.favourite", on: marks.favourited == true, tint: .yellow) {
                Task { await app.act(.favourite, on: post) }
            }
        }
    }

    /// What I did. No counts here, and there never will be: how many other people bookmarked
    /// something is not a thing any server tells anybody, and what this device keeps is
    /// nobody's business but this device's.
    private var mine: some View {
        HStack(spacing: 14) {
            switching(marks.bookmarked == true ? "bookmark.fill" : "bookmark",
                      labelKey: "post.bookmark", on: marks.bookmarked == true, tint: .blue) {
                Task { await app.act(.bookmark, on: post) }
            }
            switching(app.isKept(post) ? "archivebox.fill" : "archivebox",
                      labelKey: "post.kept", on: app.isKept(post), tint: .accentColor) {
                Task { await app.keep(post) }
            }
        }
    }

    /// Where this goes: the conversation here, the post on its own server, and everything else.
    private var leaving: some View {
        HStack(spacing: 14) {
            if let open {
                // The conversation, which is what opening a post here shows: the post and
                // everything around it. Not an arrow — nothing is being sent anywhere.
                switching("bubble.left.and.bubble.right", labelKey: "post.open",
                          on: false, tint: .secondary, action: open)
            }
            if post.webURL != nil {
                // An arrow leaving the app, because that is exactly what this does.
                switching("arrow.up.right.square", labelKey: "timeline.open",
                          on: false, tint: .secondary) { hand() }
            }
            switching("ellipsis.circle", labelKey: "post.more", on: showingMore, tint: .secondary) {
                showingMore = true
            }
            .popover(isPresented: $showingMore, arrowEdge: .bottom) {
                MoreActions(post: post) { showingMore = false }
                    .environment(app)
            }
        }
    }

    /// A hairline between the groups. It is what makes them groups rather than a longer run of
    /// the same thing, and it is the cheapest possible way to say so.
    private var divider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 14)
    }

    private func counted(_ symbol: String, count: Int?, labelKey: String, on: Bool,
                         tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                if let count { Text(verbatim: "\(count)").fediqoFont(11) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? tint : Color.secondary)
        .help(t(labelKey))
        .accessibilityLabel(Text(t(labelKey)))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func switching(_ symbol: String, labelKey: String, on: Bool, tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? tint : Color.secondary)
        .help(t(labelKey))
        .accessibilityLabel(Text(t(labelKey)))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func hand() {
        guard let url = post.webURL else { return }
        openURL(url)
    }
}

/// Everything else that can be done with a post, behind one control and two headings.
///
/// A popover and not a menu, because a menu cannot have tabs on either platform — and the tabs
/// are the point. What is under **Danger** is not a longer list of the same kind of thing: it
/// is muting somebody and reporting them, and putting those one slip away from Copy link is
/// how a reader ends up doing one of them by accident.
struct MoreActions: View {
    let post: Post
    var dismiss: () -> Void = {}

    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var page = Page.general
    @State private var comment = ""

    enum Page: String, CaseIterable, Identifiable {
        case general, danger
        var id: String { rawValue }
        var titleKey: String { "post.more.\(rawValue)" }
    }

    private var author: String { post.authorHandle }
    private var host: String { post.sources.first ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $page) {
                ForEach(Page.allCases) { page in
                    Text(t(page.titleKey)).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch page {
            case .general: general
            case .danger: danger
            }

            acting
        }
        .padding(12)
        .frame(width: 300)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("link", t("post.copyLink"), tint: .primary) {
                copy(post.webURL)
                dismiss()
            }
            .disabled(post.webURL == nil)
            row("arrow.up.right.square", t("timeline.open"), tint: .primary) {
                if let url = post.webURL { openURL(url) }
                dismiss()
            }
            .disabled(post.webURL == nil)
        }
    }

    /// Each target twice: once for a rule this device keeps to itself, once for one a server
    /// carries out. They are written as two rows rather than one control with a scope, because
    /// this app promises it can always say which of the two hid something — and it can only
    /// keep that promise if the reader was asked which of the two they meant.
    private var danger: some View {
        VStack(alignment: .leading, spacing: 2) {
            muting(.author, author, labelKey: "post.muteAuthor", value: post.authorId)
            muting(.host, host, labelKey: "post.muteHost", value: host)
            Divider().padding(.vertical, 4)
            if app.reported.contains(post.mergeKey) {
                label("checkmark.circle", t("post.reported"), tint: .secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    row("flag", t("post.report"), tint: .red) {
                        Task { await app.report(post, comment: comment); dismiss() }
                    }
                    TextField(t("post.report.why"), text: $comment, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .fediqoFont(11)
                }
            }
        }
    }

    private func muting(_ kind: Mute.Kind, _ name: String, labelKey: String,
                        value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(kind == .author ? "person.slash" : "network.slash",
                  t(labelKey, name), tint: .orange)
            HStack(spacing: 6) {
                place(t("post.mute.here"), done: app.isMuted(kind, value, onServer: false)) {
                    Task { await app.mute(kind, value, onServer: false, for: post) }
                }
                place(t("post.mute.onServer"), done: app.isMuted(kind, value, onServer: true)) {
                    Task { await app.mute(kind, value, onServer: true, for: post) }
                }
                .disabled(app.actingChoices.isEmpty)
            }
            .padding(.leading, 22)
        }
        .padding(.vertical, 2)
    }

    private func place(_ name: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: done ? "checkmark" : "circle")
                    .font(.system(size: 9, weight: .semibold))
                Text(name).fediqoFont(11)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary.opacity(done ? 1 : 0.4)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Who is about to act, said out loud whenever there is more than one answer. Which of the
    /// reader's servers acts decides which of them learns the post exists, so it is never a
    /// thing this app settles quietly on their behalf.
    @ViewBuilder
    private var acting: some View {
        let choices = app.actingChoices
        if choices.count > 1 {
            Divider()
            Picker(t("post.actingAs"), selection: Binding(
                get: { app.preferences.actingServer ?? choices[0].endpoint },
                set: { app.preferences.actingServer = $0 }
            )) {
                ForEach(choices, id: \.endpoint) { choice in
                    Text(choice.account.handle).tag(choice.endpoint)
                }
            }
            .fediqoFont(11)
        }
    }

    private func row(_ symbol: String, _ name: String, tint: Color,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(symbol, name, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func label(_ symbol: String, _ name: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 14)
            Text(name).fediqoFont(12)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func copy(_ url: URL?) {
        guard let url else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.string = url.absoluteString
        #endif
    }
}
