import SwiftUI
import FediqoCore

/// The reader's timelines, left to right, and the way to make another.
///
/// A row of chips rather than a segmented control, and the difference is not decoration: a
/// segmented control assumes a list that is short and fixed, and this one is neither — the
/// reader makes them, copies them and deletes them. So the row scrolls when there are more
/// than fit, and everything that is not "go to that one" lives in the menu at the end of it.
///
/// Two controls sit at the end of it and they are different kinds of thing: the plus makes
/// one, which is the first thing anybody does here and so is not hidden; the menu is what can
/// be done to the one you are on. Going to another is the chips' own job and is in neither.
struct TimelineChips: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    /// Which timeline the editor is open on, or `.new` for one that does not exist yet.
    @Binding var editing: TimelineEditor.Subject?

    var body: some View {
        HStack(spacing: Space.snug) {
            ScrollViewReader { row in
                ScrollView(.horizontal) {
                    HStack(spacing: Space.snug) {
                        ForEach(app.timelines) { timeline in
                            chip(timeline)
                        }
                    }
                    .padding(.vertical, Space.hair)
                }
                // The chosen one is brought into view whenever it changes, because it changes
                // from outside this row as well: `Tab` rotates through the timelines, and a
                // reader who cannot see where they have landed has been moved somewhere they
                // have no way of knowing about.
                .onChange(of: app.currentTimeline, initial: true) { _, id in
                    withAnimation(Motion.appearing) { row.scrollTo(id, anchor: .center) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            add
            menu
        }
    }

    /// Making one is the first thing anybody does here, and the first thing should not be
    /// behind a menu: an ellipsis reads as "more of what you already have", never as "make
    /// another". So the plus stands on its own, and the menu keeps everything else.
    private var add: some View {
        Button { editing = .new } label: {
            Image(systemName: "plus")
        }
        .modifier(HeaderMenuChrome(labelKey: "timeline.new", warning: false))
        .buttonStyle(.plain)
    }

    private func chip(_ timeline: Timeline) -> some View {
        let selected = timeline.id == app.currentTimeline
        // A timeline with nowhere to read from is drawn as what it is: a tab that is not
        // available yet, rather than one that opens onto a blank page. Home before anybody has
        // signed in is the whole of the case today — and it comes back the moment they do.
        let readable = app.isReadable(timeline)
        return Button {
            app.currentTimeline = timeline.id
        } label: {
            Text(timeline.displayName)
                .fediqoFont(TypeScale.small, weight: selected ? .semibold : .regular)
                .lineLimit(1)
                .padding(.horizontal, Space.mid)
                .padding(.vertical, Space.snug)
                .background(
                    Capsule().fill(selected ? Palette.accent.opacity(colorScheme == .dark ? 0.22 : 0.18)
                                            : Color.primary.opacity(0.06))
                )
                .foregroundStyle(chipColour(selected: selected, readable: readable))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!readable)
        .id(timeline.id)
        // The same four things the menu at the end offers, at the chip they are about — so a
        // reader who has one in front of them does not have to go and name it somewhere else.
        .contextMenu {
            Button(t("timeline.edit")) { editing = .existing(timeline) }
            Button(t("timeline.duplicate")) { _ = app.duplicate(timeline) }
            Divider()
            Button(t("timeline.delete"), role: .destructive) { app.delete(timeline.id) }
        }
        // Why it cannot be opened, where that is the case — a greyed tab that will not say
        // what is missing is a tab the reader can only guess at.
        .help(readable ? (timeline.displaySummary.isEmpty ? timeline.displayName : timeline.displaySummary)
                       : t("timeline.needsAccount"))
    }

    private func chipColour(selected: Bool, readable: Bool) -> Color {
        guard readable else { return .primary.opacity(0.3) }
        return selected ? Palette.accent : .primary.opacity(0.75)
    }

    /// What can be done to the timeline in front of you, and nothing else.
    ///
    /// Going to another one is not in here. The chips are how you do that — they are the tabs
    /// of this page, and a menu listing them again would be a second way to do the one thing
    /// the row is already for, sitting in the place where the things you cannot see live.
    private var menu: some View {
        Menu {
            if let current = app.timeline(app.currentTimeline) {
                Button(t("timeline.edit")) { editing = .existing(current) }
                Button(t("timeline.duplicate")) { _ = app.duplicate(current) }
                Divider()
                Button(t("timeline.delete"), role: .destructive) { app.delete(current.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .modifier(HeaderMenuChrome(labelKey: "timeline.more", warning: false))
    }
}

/// The Timeline page with no timelines on it — which a reader reaches by deleting the last
/// one, and which is therefore a place rather than an error.
///
/// It offers the way back rather than refusing to let them get here: the three that ship are
/// ordinary rows, so deleting them all is allowed, and what makes that safe is that any of
/// them can be made again from the template it came from.
struct NoTimelinesView: View {
    @Environment(AppState.self) private var app
    @State private var making: TimelineEditor.Subject?

    var body: some View {
        VStack(spacing: Space.mid) {
            Image(systemName: "rectangle.stack").fediqoSymbol(Glyph.big, weight: .light)
                .foregroundStyle(.tertiary)
            Text(t("timeline.none")).fediqoFont(TypeScale.small).foregroundStyle(.secondary)
            Button(t("timeline.new")) { making = .new }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .fediqoFont(TypeScale.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $making) { subject in
            TimelineEditor(subject: subject) { making = nil }
                .fediqoChrome(app)
        }
    }
}
