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
/// switch; and **where this goes**, which leaves the row.
///
/// The grouping is spacing and nothing else. A rule between each pair drew three boxes where
/// what was wanted was three breaths — the eye reads the gap on its own, and the lines were
/// three more marks competing with the seven that mean something.
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
    /// The numbers, from the app rather than off the post: a write's answer says what they are
    /// with the press counted in, and the row in the list and the opened post are two copies of
    /// one post that have to agree.
    private var counts: Counts { app.counts(of: post) }

    var body: some View {
        HStack(spacing: Space.betweenGroups) {
            theirs
            mine
            leaving
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.top, Space.tight)
    }

    /// What everybody else did, with the numbers the servers gave us.
    private var theirs: some View {
        HStack(spacing: Space.withinGroup) {
            // Replying makes a new post rather than marking this one, and this app has no
            // composer that can send one yet — so it still leaves, and says so by doing
            // nothing else. When #8 lands it stops leaving and nothing else here changes.
            counted("arrowshape.turn.up.left", count: counts.replies,
                    labelKey: "post.reply", on: false, tint: .secondary) { hand() }
            counted("arrow.2.squarepath", count: counts.reblogs,
                    labelKey: "post.reblog", on: marks.reblogged == true, tint: .green) {
                Task { await app.act(.reblog, on: post) }
            }
            counted(marks.favourited == true ? "star.fill" : "star", count: counts.favourites,
                    labelKey: "post.favourite", on: marks.favourited == true, tint: .yellow) {
                Task { await app.act(.favourite, on: post) }
            }
        }
    }

    /// What I did. No counts here, and there never will be: how many other people bookmarked
    /// something is not a thing any server tells anybody, and what this device keeps is
    /// nobody's business but this device's.
    private var mine: some View {
        HStack(spacing: Space.withinGroup) {
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

    /// Where this goes: the conversation here, and everything else.
    ///
    /// Opening the post on its own server used to sit here too, and does not any more. It is
    /// the way out of the app, which makes it the rarest thing on the row and the one a reader
    /// scanning a long list never wants — and it is one row down in `⋯` under **General**,
    /// beside Copy link, which is the other thing you do with an address.
    private var leaving: some View {
        HStack(spacing: Space.withinGroup) {
            if let open {
                // The conversation, which is what opening a post here shows: the post and
                // everything around it. Not an arrow — nothing is being sent anywhere.
                switching("bubble.left.and.bubble.right", labelKey: "post.open",
                          on: false, tint: .secondary, action: open)
            }
            // Bare, not circled. The ring made it the heaviest mark in a row of outlines, so
            // the least of the controls read as the most important one — and the chips above
            // the timeline have always spelled "more of this" as three plain dots, which is
            // now the one spelling this app has.
            switching("ellipsis", labelKey: "post.more", on: showingMore, tint: .secondary) {
                showingMore = true
            }
            .popover(isPresented: $showingMore, arrowEdge: .bottom) {
                MoreActions(post: post) { showingMore = false }
                    .environment(app)
            }
        }
    }

    private func counted(_ symbol: String, count: Int?, labelKey: String, on: Bool,
                         tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.tight) {
                Image(systemName: symbol).fediqoSymbol(Glyph.action, weight: .medium)
                if let count { Text(verbatim: "\(count)").fediqoFont(TypeScale.small) }
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
            Image(systemName: symbol).fediqoSymbol(Glyph.action, weight: .medium).contentShape(Rectangle())
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
        VStack(alignment: .leading, spacing: Space.gap) {
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
        .padding(Space.gap)
        .frame(width: Size.popover)
    }

    /// The two ordinary things: take the address, or go to it. Glyphs in a row, the way the
    /// interaction bar spells everything it can do — the words are in `help()` and in what a
    /// screen reader is told, because neither of these can go wrong and neither needs reading
    /// twice. What is under **Danger** keeps its words for exactly the opposite reason.
    private var general: some View {
        HStack(spacing: Space.withinGroup) {
            IconButton(symbol: "link", labelKey: "post.copyLink") {
                copy(post.webURL)
                dismiss()
            }
            .disabled(post.webURL == nil)
            IconButton(symbol: "arrow.up.right.square", labelKey: "timeline.open") {
                if let url = post.webURL { openURL(url) }
                dismiss()
            }
            .disabled(post.webURL == nil)
            Spacer(minLength: 0)
        }
    }

    /// Each target twice: once for a rule this device keeps to itself, once for one a server
    /// carries out. They are written as two rows rather than one control with a scope, because
    /// this app promises it can always say which of the two hid something — and it can only
    /// keep that promise if the reader was asked which of the two they meant.
    private var danger: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            muting(.author, author, labelKey: "post.muteAuthor", value: post.authorId)
            muting(.host, host, labelKey: "post.muteHost", value: host)
            Divider().padding(.vertical, Space.tight)
            if app.reported.contains(post.mergeKey) {
                label("checkmark.circle", t("post.reported"), tint: .secondary)
            } else {
                VStack(alignment: .leading, spacing: Space.snug) {
                    row("flag", t("post.report"), tint: .red) {
                        Task { await app.report(post, comment: comment); dismiss() }
                    }
                    TextField(t("post.report.why"), text: $comment, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .fediqoFont(TypeScale.minor)
                }
            }
        }
    }

    private func muting(_ kind: Mute.Kind, _ name: String, labelKey: String,
                        value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            label(kind == .author ? "person.slash" : "network.slash",
                  t(labelKey, name), tint: .orange)
            HStack(spacing: Space.snug) {
                place(t("post.mute.here"), done: app.isMuted(kind, value, onServer: false)) {
                    Task { await app.mute(kind, value, onServer: false, for: post) }
                }
                place(t("post.mute.onServer"), done: app.isMuted(kind, value, onServer: true)) {
                    Task { await app.mute(kind, value, onServer: true, for: post) }
                }
                .disabled(app.actingChoices.isEmpty)
            }
            .padding(.leading, Glyph.column + Space.step)
        }
        .padding(.vertical, Space.hair)
    }

    private func place(_ name: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.tight) {
                Image(systemName: done ? "checkmark" : "circle")
                    .fediqoSymbol(Glyph.badge)
                Text(name).fediqoFont(TypeScale.minor)
            }
            .padding(.horizontal, Space.step)
            .padding(.vertical, Space.tight)
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
            .fediqoFont(TypeScale.minor)
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
        HStack(spacing: Space.step) {
            Image(systemName: symbol).fediqoSymbol(Glyph.inline, weight: .medium).frame(width: Glyph.column)
            Text(name).fediqoFont(TypeScale.small)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.vertical, Space.tight)
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
