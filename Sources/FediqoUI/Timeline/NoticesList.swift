import SwiftUI
import FediqoCore

/// What reached you — one half of the inbox page (#122).
///
/// It was a sheet put up from a bell in the timeline's own header — so the one reading that
/// arrives *while nobody is looking* was the only one with no page of its own, and closing
/// whatever was underneath closed it too.
///
/// **It is a page and not a timeline.** `BaseSource.notice` offers no template on purpose: an
/// inbox is not a stretch of time somebody can page through, and a notice missing from one is not
/// evidence of anything. What it takes from the other pages is the furniture — a header that says
/// what the page is, the ring, `j`, `k` and `g` — and what it keeps of its own is everything
/// underneath: a live connection, catching up on what happened while nobody was here, and *seen*.
struct NoticesList: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    private var model: NoticeModel? { app.notices }

    var body: some View {
        VStack(spacing: 0) {
            body(for: model?.notices ?? [])
            Hairline()
            foot
        }
        // Marked seen on arriving, which is what arriving means here. Not on every redraw: the
        // task runs when the page appears and the count it writes is the newest it has.
        .task { await model?.markSeen() }
        // The ring lets go with the page. A ring standing on a notice nobody is looking at is
        // the key doing nothing, as far as the reader is concerned.
        .onDisappear { app.noticePlace.clear() }
    }


    /// When this device last managed to ask, and why a notice can be late.
    ///
    /// **At the foot rather than hidden behind a button.** A reader coming here came for what
    /// happened; the rule is what they read once and never again. It stays on the screen because
    /// the day it matters is the day something is late, and that is not a day to go looking for
    /// an explanation.
    private var foot: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(alignment: .firstTextBaseline, spacing: Space.step) {
                Text(heard)
                    .fediqoFont(TypeScale.minor)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.tight)
                Button(t("notices.ask")) { Task { await app.askForNotices() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fediqoFont(TypeScale.minor)
                    .disabled(model?.asking ?? true)
            }
            Text(t("notices.why"))
                .fediqoFont(TypeScale.minor)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.pad)
        .padding(.vertical, Space.mid)
        .background(Palette.raised(colorScheme))
    }

    /// What a notice opens.
    ///
    /// The post it is about, where it has one. **Where it has none it opens the person**, which
    /// is not a fallback: somebody following you is an event about them, and their page is the
    /// whole of what there is to look at (#123).
    private func open(_ notice: Notice) {
        if let post = notice.post {
            app.expand(post)
        } else {
            app.openPerson(notice.actorHandle, on: notice.serverURL)
        }
    }

    private var heard: String {
        guard let when = model?.lastHeard else { return t("notices.never") }
        return t("notices.asked", when.formatted(.relative(presentation: .numeric)))
    }

    @ViewBuilder
    private func body(for notices: [Notice]) -> some View {
        if notices.isEmpty {
            VStack(spacing: Space.mid) {
                Image(systemName: "bell")
                    .fediqoSymbol(Glyph.big, weight: .light)
                    .foregroundStyle(.tertiary)
                Text(t("timeline.notifications.empty"))
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Size.prose)
            }
            .padding(Space.room)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { rows in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(notices) { notice in
                            NoticeRow(notice: notice)
                                .fediqoFocusRing(notice.id == app.noticePlace.selection)
                                .contentShape(Rectangle())
                                // One press says which one they mean and opens it, because a
                                // line telling somebody they were replied to that goes nowhere
                                // is the inbox being a dead end (#123).
                                .onTapGesture {
                                    app.noticePlace.select(notice)
                                    open(notice)
                                }
                                .id(notice.id)
                        }
                    }
                    .padding(Space.gap)
                }
                // The ring asking to be scrolled to, which is the same arrangement the timeline
                // has: the key moves the ring and the ring says where it went.
                .onChange(of: app.noticePlace.selection) { _, key in
                    guard let key else { return }
                    withAnimation(Motion.appearing) { rows.scrollTo(key, anchor: .center) }
                }
                .onChange(of: app.noticePlace.topRequests) { _, _ in
                    withAnimation(Motion.appearing) { rows.scrollTo(notices.first?.id, anchor: .top) }
                }
            }
        }
    }
}
