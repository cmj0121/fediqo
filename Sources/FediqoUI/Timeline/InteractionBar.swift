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
                    labelKey: "post.reblog", on: marks.reblogged == true, tint: .green,
                    sending: app.isActing(.reblog, on: post)) {
                Task { await app.act(.reblog, on: post) }
            }
            counted(marks.favourited == true ? "star.fill" : "star", count: counts.favourites,
                    labelKey: "post.favourite", on: marks.favourited == true, tint: .yellow,
                    sending: app.isActing(.favourite, on: post)) {
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
                      labelKey: "post.bookmark", on: marks.bookmarked == true, tint: .blue,
                      sending: app.isActing(.bookmark, on: post)) {
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

    /// A control with a number beside it, and one without. Both are `MarkButton`; these name
    /// the two shapes so the bar above reads as what it is rather than as a parameter list.
    private func counted(_ symbol: String, count: Int?, labelKey: String, on: Bool,
                         tint: Color, sending: Bool = false,
                         action: @escaping () -> Void) -> some View {
        MarkButton(symbol: symbol, counting: true, count: count, labelKey: labelKey, on: on,
                   tint: tint, sending: sending, action: action)
    }

    private func switching(_ symbol: String, labelKey: String, on: Bool, tint: Color,
                           sending: Bool = false, action: @escaping () -> Void) -> some View {
        MarkButton(symbol: symbol, counting: false, count: nil, labelKey: labelKey, on: on,
                   tint: tint, sending: sending, action: action)
    }

    private func hand() {
        guard let url = post.webURL else { return }
        openURL(url)
    }
}

/// One control in the interaction bar: a mark, and the number beside it where there is one.
///
/// A view of its own rather than a function, because it has a fact of its own to keep — how
/// long the write has been out. Everything else here is read off the app.
///
/// **Three fixed things and one moving one.** The glyph sits in a box of one width and the
/// count in a column of one width, so every control is the same size on every row and the bar
/// holds its columns down a list. What moves is the mark itself, once, when it is pressed.
private struct MarkButton: View {
    let symbol: String
    /// Whether this control has a count at all — not whether it has one *now*.
    ///
    /// The two are different and the difference is the column. A favourite whose number nobody
    /// has told us still keeps the space, so the mark beside it lands where every other row's
    /// does; a bookmark has no number and never will — how many other people bookmarked
    /// something is not a thing any server tells anybody — so it keeps no space for one.
    let counting: Bool
    /// The number, where there is one to draw.
    var count: Int?
    let labelKey: String
    let on: Bool
    let tint: Color
    /// Whether a write for this mark is still out to a server.
    var sending = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The reader's text size, because the column a count sits in is measured in digits and a
    /// digit is whatever size they asked for.
    @Environment(\.fediqoTextScale) private var scale
    /// Whether the wait has gone on long enough to be worth showing. See `settling`.
    @State private var waiting = false

    /// How long a write is given to land before the control says it is working.
    ///
    /// A server on the same machine answers in a few milliseconds, and a pulse that starts and
    /// stops inside that is not a signal — it is a blink, and a row of them reads as the bar
    /// twitching. So a mark that lands quickly never says anything at all, and the ones that do
    /// say it are the slow servers the signal was always for.
    private static let settling = Duration.milliseconds(320)

    /// How a mark moves, or nothing at all where the reader has asked for nothing to move.
    /// The same pair `ActionNotice` and `FeedScreen` keep.
    private var motion: Animation? { reduceMotion ? nil : Motion.appearing }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.tight) {
                glyph
                if counting {
                    // The column is here whether or not there is a number in it, and it is the
                    // same width either way. A post nobody has given counts for still draws no
                    // zero — it draws nothing — but it holds the place, so the mark beside it
                    // lands where every other row's does.
                    Text(verbatim: count.map { "\($0)" } ?? "")
                        .fediqoFont(TypeScale.small)
                        // Proportional digits are different widths: 1 is narrow and 8 is not,
                        // so a count going from 3 to 4 moved the whole bar a hair to the right.
                        // These are all one width, which also gives `numericText` somewhere to
                        // roll in.
                        .monospacedDigit()
                        // A count is a quantity, and `numericText` moves the digits that
                        // changed rather than crossfading one number into another.
                        .contentTransition(.numericText(value: Double(count ?? 0)))
                        .animation(motion, value: count)
                        .frame(minWidth: Size.actionCount * scale, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? tint : Color.secondary)
        .animation(motion, value: on)
        .help(t(labelKey))
        .accessibilityLabel(Text(t(labelKey)))
        .accessibilityAddTraits(on ? .isSelected : [])
        .task(id: sending) { await settle() }
    }

    /// The mark, in a box of one width — so a wide symbol and a narrow one start their control
    /// in the same place, and so a symbol swapped for another cannot move what is beside it.
    ///
    /// **One movement, not two.** The press bounces the mark; the shape changes inside that
    /// bounce and is not given a transition of its own. Both together were two scales on one
    /// glyph in the same instant, which read as a stutter rather than as one thing happening —
    /// and the shape change needs no announcing when the whole mark has just jumped.
    ///
    /// Under Reduce Motion it is the plain image. That is the test of whether the movement was
    /// decoration: the state is still said by the shape and the colour, and standing still
    /// costs the reader nothing.
    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: symbol)
            .fediqoSymbol(Glyph.action, weight: .medium)
            .frame(width: Size.actionGlyph)
        if reduceMotion {
            image
        } else {
            image
                // `bounce` fires on the press, because `on` moves there and not when the server
                // answers — the mark is the reader's the moment they make it, and putting it
                // back is what a refusal is for.
                .symbolEffect(.bounce, value: on)
                .symbolEffect(.pulse, isActive: waiting)
        }
    }

    /// Waits out `settling` before letting the mark say it is working, and stops the moment the
    /// write lands. `task(id:)` cancels this when `sending` changes, which is what makes a
    /// quick write silent rather than a blink.
    private func settle() async {
        guard sending else { return waiting = false }
        try? await Task.sleep(for: Self.settling)
        guard !Task.isCancelled else { return }
        waiting = true
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
