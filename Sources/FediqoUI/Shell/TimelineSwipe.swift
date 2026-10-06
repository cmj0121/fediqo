import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A sideways swipe on a timeline goes to the one beside it (#305).
///
/// ## How the swipe is made, and why
///
/// **A drag recognised over the one list there is, and not timelines laid side by side and
/// paged.** Paging would let the list follow the finger with its neighbour already drawn beside
/// it, which is the better thing to hold — and it costs the three things this was asked to keep:
///
/// - *The press on the status bar that goes to the top.* The system gives it to one scroll view
///   on screen. A pager with a list in each page is several, and then it goes to none.
/// - *A timeline not on screen is not read or kept busy.* A page beside the one in front is a
///   list that is alive: its posts asked for, its rows drawn, its place and its reading mark
///   kept. Here there is one list, and the neighbour does not exist until it is arrived at.
/// - *The post being read and the place each timeline keeps* (#303) are one of each for the
///   list in front. Side by side they would be one for every page.
///
/// **Scrolling up and down is never taken for a swipe**, and that is the recogniser's whole
/// design. It is a pan of the list's own scroll view that **refuses to begin** unless the drag
/// set out sideways (`begins`): a drag that set out up, down or aslant never reaches it, and the
/// scroll view's own pan is the only one there, exactly as before. A gesture that listened to
/// every drag and decided later is one the scroll would have had to wait for.
///
/// While it is recognised the list follows the finger — the list in front alone, moved and not
/// drawn again — and at an end with no neighbour it follows a third as far. Let go past
/// `far`, or flicked, it goes; otherwise it comes back.
enum TimelineSwipe {
    /// Sideways at least this many times as far as up or down: within 27° of level.
    static let level: CGFloat = 2
    /// Let go this far across, the timeline changes.
    static let far: CGFloat = 64
    /// Or flicked this fast, having gone at least `flicked` across.
    static let fast: CGFloat = 500
    static let flicked: CGFloat = 24
    /// How much of the finger's way the list goes where there is no timeline that way.
    static let damped: CGFloat = 1.0 / 3

    /// Whether a drag that has gone `dx` across and `dy` down is a swipe at all: it set out
    /// level. **From anywhere on the page, its leading edge included** — nothing else there
    /// wants that edge.
    static func begins(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) > 0 && abs(dx) >= level * abs(dy)
    }

    /// Which way a drag let go at `dx` across, moving at `velocity`, goes: one timeline on
    /// (`1`), one back (`-1`), or nowhere. `dx` and `velocity` are toward the trailing edge,
    /// so a finger moving toward the leading edge — which pulls the next timeline in — is
    /// negative in both.
    ///
    /// **Flicked hard back the way it came, it goes nowhere**, however far it had gone: the
    /// last thing the hand did was take it back.
    static func outcome(dx: CGFloat, velocity: CGFloat) -> Int {
        let with = (velocity < 0) == (dx < 0)
        if !with, abs(velocity) >= fast { return 0 }
        let goes = abs(dx) >= far || (abs(velocity) >= fast && abs(dx) >= flicked && with)
        guard goes else { return 0 }
        return dx < 0 ? 1 : -1
    }

    /// The place arrived at, `step` from `index` among `count`, or nothing past either end:
    /// the timelines do not go round.
    static func target(from index: Int?, count: Int, step: Int) -> Int? {
        guard let index, step != 0 else { return nil }
        let next = index + step
        return (0 ..< count).contains(next) ? next : nil
    }

    /// Whether a drag let go is still acted on once the list has slid away: only if the
    /// timeline in front is the one the drag began on. Something else may have changed it in
    /// that sixth of a second — a key, the list of timelines — and a step taken then would be
    /// a step from somewhere the hand never was.
    static func completes(startedOn: String?, inFront: String?) -> Bool {
        startedOn != nil && startedOn == inFront
    }

    /// How far the head's dot leans for a page moved `moved` points toward the trailing edge:
    /// the share of its width, toward the next as positive — and nothing where the swipe means
    /// back, or before the page has been measured.
    static func lean(moved: CGFloat, width: CGFloat, beside: Bool) -> CGFloat {
        guard beside, width > 0 else { return 0 }
        return -moved / width
    }

    /// Where the head's dots are sent as a page let go leaves by `step`: all the way to the one
    /// beside — and nowhere where the swipe means back, or with motion reduced, when the dot lit
    /// is simply the other one once the page has changed.
    static func leaves(by step: Int, beside: Bool, still: Bool) -> CGFloat {
        beside && !still ? CGFloat(step.signum()) : 0
    }

    /// How long after a slide begins it is put to rest whatever has or has not been heard of
    /// it, in seconds: several times the slide's own length.
    static let backstop: Double = 1.2

    /// Whether a new drag is heard at all: not while the last one is still sliding the list.
    static func hears(leaving: Bool) -> Bool { !leaving }

    /// How far the list is moved for a finger `dx` across: all the way where there is a
    /// timeline that way, a third where there is not.
    static func follow(dx: CGFloat, hasNext: Bool, hasPrevious: Bool) -> CGFloat {
        let neighbour = dx < 0 ? hasNext : hasPrevious
        return neighbour ? dx : dx * damped
    }

    /// Where a timeline switched to opens (#305): at the post it was left at, and one never
    /// visited — which has none — at its first. Never wherever the last list happened to be.
    static func opensAt(kept: String?, first: String?) -> String? {
        kept ?? first
    }

    /// What a sideways swipe means on the page in front — **one thing a page** (#305).
    enum Means: Equatable, Sendable {
        /// The one beside this one: a timeline's neighbour on the timeline's own page, whatever
        /// it is drawing — its posts, or that it has none, is still reading, or could not be
        /// read — and a tab's neighbour on a page that has tabs.
        case beside
        /// Back: on a page opened over it — a post, a person, a tag. Only the way back; a swipe
        /// the other way goes nowhere.
        case back
    }

    /// What is in front, as far as a swipe cares.
    enum Page: Equatable, Sendable {
        /// The timeline itself, with or without posts to draw.
        case timeline
        /// A post, a person or a tag opened over it.
        case opened
        /// A page read out of a post: somebody's own, and its sideways is its own.
        case link
    }

    /// What a swipe means now, or nothing where it is not heard: only under a finger, never
    /// over a search's results, never with the list of timelines or the editor up, and
    /// **never while anything is drawn over the page** (`covered`): a picture opened, the keys'
    /// guide, the landing. Those are drawn in the same view as the page under them, and a
    /// swipe across one would be heard by the page behind it.
    static func means(
        touch: Bool, page: Page, searching: Bool, listShown: Bool, editing: Bool, covered: Bool = false
    ) -> Means? {
        guard touch, !covered, !listShown, !editing else { return nil }
        switch page {
        case .timeline: return searching ? nil : .beside
        case .opened: return .back
        case .link: return nil
        }
    }

    /// Whether a swipe let go goes back: the way it goes on a timeline to the one before — the
    /// finger toward the trailing edge — by the same distances and the same flick.
    static func goesBack(dx: CGFloat, velocity: CGFloat) -> Bool {
        outcome(dx: dx, velocity: velocity) == -1
    }

    /// What a swipe means on a page with tabs (#305): the tab beside the one in front, or —
    /// with a row's detail opened over the page — back out of it. Under a finger only.
    ///
    /// **With fewer than two tabs and no detail open it means nothing at all**: a page with
    /// nowhere to go is not listened on, so nothing rubber-bands and no press is cancelled.
    static func means(touch: Bool, detail: Bool, tabs: Int, covered: Bool = false) -> Means? {
        guard touch, !covered else { return nil }
        if detail { return .back }
        return tabs > 1 ? .beside : nil
    }

    /// Which ways there is somewhere to go, for what a swipe means: a timeline's neighbours, or
    /// for the way back only back.
    static func ways(_ means: Means, index: Int?, count: Int) -> (next: Bool, previous: Bool) {
        switch means {
        case .beside: (target(from: index, count: count, step: 1) != nil, target(from: index, count: count, step: -1) != nil)
        case .back: (false, true)
        }
    }

    /// What VoiceOver says of the timeline arrived at, or stood on at an end where there was
    /// nowhere further to go: its name, and "2 of 5".
    static func announcement(
        name: String, position: Int?, count: Int, key: String = "timeline.position", language: DummyLanguage? = nil
    ) -> String {
        guard let position, count > 1 else { return name }
        return name + ", " + String(format: L10n.t(key, language: language), position + 1, count)
    }
}

/// How far the page in front is slid sideways, and how faint (#305).
///
/// **Read by the one modifier that moves the page and by nothing else** (`Slid`), so a drag
/// draws no row again: what is under the modifier is handed to it whole, and is not asked what
/// it is each time the page moves a point.
@MainActor
@Observable
final class PageSlide {
    var x: CGFloat = 0
    var faint = false
    /// How far a finger is dragging the page toward the one beside, as a share of the page's
    /// width: positive toward the next. **Set by the finger, and let go once** — to the one
    /// beside as the page leaves for it, or back to nought as the page comes back — and nought
    /// at every other time: the page arriving has its own place, and leans nowhere. Nought,
    /// too, where a swipe means back and there is no one beside to lean toward.
    var lean: CGFloat = 0
    /// Whether the list the page's name opens is up.
    var listShown = false
    /// How wide the page is, as its recogniser last measured it; nought before it has.
    @ObservationIgnored var width: CGFloat = 0
}

/// Moves what it is put on by a `PageSlide`.
struct Slid: ViewModifier {
    let slide: PageSlide
    /// Whether it moves anything: on an iPhone or iPad, unless said otherwise (`shellSlides`).
    var applies: Bool? = nil

    @Environment(\.shellSlides) private var slides

    @ViewBuilder
    func body(content: Content) -> some View {
        if applies ?? slides {
            content.offset(x: slide.x).opacity(slide.faint ? 0 : 1)
        } else {
            content
        }
    }
}

/// The sideways swipe on a page: **one thing, for every page that has an order to it and one
/// of them in front** — the timelines, a page's tabs, and the way back from what is opened
/// over either. On an iPhone or iPad; nothing on a Mac.
struct PageSwipes: ViewModifier {
    let slide: PageSlide
    let enabled: Bool
    /// What a swipe means here now, by name: when it changes, a slide half made is put back.
    let key: String
    let hasNext: Bool
    let hasPrevious: Bool
    let inFront: () -> String?
    let step: (Int) -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(iOS)
        content.background(PageSwipeCatcher(
            enabled: enabled, key: key, hasNext: hasNext, hasPrevious: hasPrevious,
            reduceMotion: reduceMotion, slide: slide, inFront: inFront, step: step
        ))
        #else
        content
        #endif
    }
}

/// A page with tabs, swiped sideways to the tab beside the one in front (#305); and with a
/// row's detail opened over it, swiped back out of that. Stops at the first and last tab: it
/// never goes on into another place of the app.
///
/// **It listens, and moves nothing itself.** What follows the finger is what the page puts
/// `Slid` on with the same `slide` — what is under its row of tabs, and never the row: the
/// tabs stay where they are and show the change.
struct SwipesTabs<Tab: Hashable>: ViewModifier {
    let slide: PageSlide
    let tabs: [Tab]
    let selected: Tab
    /// Whether a detail is opened over the page, and the way back out of it.
    var detail = false
    var back: () -> Void = {}
    let select: (Tab) -> Void

    @Environment(\.shellTouch) private var touch
    @Environment(\.shellCovered) private var covered

    func body(content: Content) -> some View {
        let means = TimelineSwipe.means(touch: touch, detail: detail, tabs: tabs.count, covered: covered)
        let index = tabs.firstIndex(of: selected)
        let ways = means.map { TimelineSwipe.ways($0, index: index, count: tabs.count) }
        content
            .modifier(PageSwipes(
                slide: slide, enabled: means != nil, key: means == .back ? "back" : "beside",
                hasNext: ways?.next ?? false, hasPrevious: ways?.previous ?? false,
                inFront: { means == .back ? "detail" : index.map(String.init) },
                step: { step in
                    if means == .back {
                        guard step == -1 else { return false }
                        back()
                        return true
                    }
                    guard let to = TimelineSwipe.target(from: index, count: tabs.count, step: step) else { return false }
                    select(tabs[to])
                    return true
                }
            ))
            .modifier(TabsHeld(holds: touch))
    }
}

/// Keeps a tabbed page slid sideways inside itself, on an iPhone or iPad.
private struct TabsHeld: ViewModifier {
    let holds: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content.clipShape(SlideBounds(holds: holds))
        #else
        content
        #endif
    }
}

/// What under a finger moves sideways itself, and so is not swiped across (#305): a control
/// that is dragged — a slider, a switch, a stepper, a segmented control, a picker's wheel — a
/// field being typed in, whose caret is dragged, and anything that scrolls sideways, such as a
/// row of tabs too long for the page. A swipe that sets out on one of these is that thing's.
enum SwipeObstacle {
    /// Whether a scroll view holding this much, in this much room, scrolls sideways.
    static func scrollsSideways(content: CGSize, bounds: CGSize) -> Bool {
        content.width > bounds.width + 1
    }

    #if os(iOS)
    /// Whether `view` is one of them, by what it is.
    @MainActor
    static func isOne(_ view: UIView) -> Bool {
        if let scroll = view as? UIScrollView {
            // A field being typed in is a scroll view too; any other is one only if it scrolls sideways.
            return view is UITextView || scrollsSideways(content: scroll.contentSize, bounds: scroll.bounds.size)
        }
        return view is UISlider || view is UISwitch || view is UIStepper || view is UISegmentedControl
            || view is UIPickerView || view is UIDatePicker || view is UITextField
    }

    /// Whether `view` or anything it stands in, up to and including `top`, is one.
    @MainActor
    static func stands(_ view: UIView, upTo top: UIView?) -> Bool {
        var here: UIView? = view
        while let now = here {
            if isOne(now) { return true }
            if now === top { break }
            here = now.superview
        }
        return false
    }
    #endif
}

/// Where a swipe does not begin: on the head of a page — the timeline's name and marks, a row
/// of tabs. **The head stays where it is and shows the change; what is under it is what moves**,
/// and a finger that came down on something that will not move is not dragging the page.
enum SwipeZone {
    static func refuses(_ start: CGPoint, zones: [CGRect]) -> Bool {
        zones.contains { $0.contains(start) }
    }
}

#if os(iOS)
/// Marks what it stands behind as a head: see `SwipeZone`.
struct NoSwipeZone: UIViewRepresentable {
    final class Zone: UIView {}

    func makeUIView(context: Context) -> Zone {
        let view = Zone()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Zone, context: Context) {}
}
#endif

extension View {
    /// A head: a sideways swipe does not begin on it. Nothing on a Mac.
    @ViewBuilder
    func headOfPage() -> some View {
        #if os(iOS)
        background(NoSwipeZone())
        #else
        self
        #endif
    }
}

#if os(iOS)
/// The recogniser for a sideways swipe on the timelines' page. See `TimelineSwipe` for why it
/// is this, and `TimelineSwipe.means` for what a swipe means where.
///
/// **One, for the whole page under the timeline's head, whatever is drawn there.** It was put
/// inside the list's own scroll view, and a timeline with no posts draws no list: there was
/// nothing to carry it, and no swipe out of an empty timeline. Now it stands behind the page,
/// listens on the view of the screen the page is in, and hears only a drag that set out inside
/// the page. The same one is the way back from an opened post, person or tag — which the swipe
/// in from the very edge of the screen was, and which nobody found.
///
/// ## What it is to every other recogniser, said rather than left to the order they are asked in
///
/// - **Every scroll view's own pan in the page waits for this one to fail**
///   (`shouldBeRequiredToFailBy`). This one fails at once on a drag that did not set out level
///   — both judge the same first few points — so scrolling waits for nothing a hand could
///   feel, and nothing here ever turns a scroll view's pan off.
/// - **It is simultaneous with nothing.** Once it has begun, the press a row or a mark was
///   waiting to finish is cancelled, and so is the long press that would raise a row's menu;
///   once a long press has been recognised, this, still only possible, fails.
///   `cancelsTouchesInView` says the same to anything listening to touches themselves.
struct PageSwipeCatcher: UIViewRepresentable {
    var enabled: Bool
    var key: String
    var hasNext: Bool
    var hasPrevious: Bool
    var reduceMotion: Bool
    let slide: PageSlide
    /// What is in front, asked as a drag begins and again as it is acted on.
    var inFront: () -> String?
    /// One on or back. Says whether there was somewhere to go.
    var step: (Int) -> Bool

    func makeUIView(context: Context) -> Finder {
        let view = Finder()
        view.isUserInteractionEnabled = false
        view.catcher = context.coordinator
        context.coordinator.page = view
        return view
    }

    func updateUIView(_ view: Finder, context: Context) {
        let catcher = context.coordinator
        let was = catcher.now
        catcher.now = self
        if was.key != key || was.enabled != enabled { catcher.rest() }
        catcher.pan.isEnabled = enabled
        catcher.attach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleUIView(_ view: Finder, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Stands behind the page: its frame is the page's.
    final class Finder: UIView {
        weak var catcher: Coordinator?

        override func layoutSubviews() {
            super.layoutSubviews()
            catcher?.now.slide.width = bounds.width
        }

        /// In a window, it listens; out of one — the page gone to another place, or let go —
        /// it stops listening and what it had slid is put back.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { catcher?.detach() } else { catcher?.attach() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var now: PageSwipeCatcher
        let pan = UIPanGestureRecognizer()
        weak var page: Finder?
        private weak var host: UIView?
        private var startedOn: String?
        private var leaving = false
        /// Counted up at every slide begun and every rest: what a slide's backstop checks, so
        /// one left over from an earlier slide does nothing.
        private var slides = 0

        init(_ catcher: PageSwipeCatcher) {
            now = catcher
            super.init()
            pan.addTarget(self, action: #selector(panned))
            pan.delegate = self
            pan.cancelsTouchesInView = true
            pan.isEnabled = catcher.enabled
        }

        /// Listens on the view of the screen the page is in: the nearest above it that is a
        /// view controller's own. A sheet over the page is another's, and is not listened through.
        func attach() {
            guard let page, page.window != nil else { return }
            var above = page.superview
            while let view = above, !(view.next is UIViewController), view.superview != nil { above = view.superview }
            guard let found = above, found !== host else { return }
            host?.removeGestureRecognizer(pan)
            host = found
            found.addGestureRecognizer(pan)
        }

        func detach() {
            rest()
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        /// The page where it belongs, whatever a drag or a slide had made of it.
        func rest() {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                now.slide.x = 0
                now.slide.faint = false
                now.slide.lean = 0
            }
            leaving = false
            startedOn = nil
            slides += 1
        }

        private var mirrored: Bool { page?.effectiveUserInterfaceLayoutDirection == .rightToLeft }

        /// Toward the trailing edge is positive, whichever way the language reads.
        private func across(_ x: CGFloat) -> CGFloat { mirrored ? -x : x }

        /// **Refused unless the drag set out level, inside the page**, and while the last one
        /// is still sliding.
        func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
            guard recogniser === pan, let page, now.enabled else { return false }
            guard TimelineSwipe.hears(leaving: leaving) else { return false }
            let moved = pan.translation(in: page)
            let here = pan.location(in: page)
            let began = CGPoint(x: here.x - moved.x, y: here.y - moved.y)
            guard page.bounds.contains(began) else { return false }
            guard TimelineSwipe.begins(dx: moved.x, dy: moved.y) else { return false }
            guard !SwipeZone.refuses(began, zones: heads(in: page)) else { return false }
            return !obstacle(at: began, in: page)
        }

        /// Where the page's heads and rows of tabs are, in the page's own space: a swipe that
        /// sets out on one is not begun (`SwipeZone`).
        private func heads(in page: UIView) -> [CGRect] {
            var found: [CGRect] = []
            func look(_ view: UIView) {
                if view is NoSwipeZone.Zone, view.window != nil { found.append(view.convert(view.bounds, to: page)) }
                view.subviews.forEach(look)
            }
            if let host { look(host) }
            return found
        }

        /// Whether what the finger came down on moves sideways itself (`SwipeObstacle`): asked
        /// of what is there, from it up to the view listened on.
        private func obstacle(at point: CGPoint, in page: UIView) -> Bool {
            guard let host, let hit = host.hitTest(page.convert(point, to: host), with: nil) else { return false }
            return SwipeObstacle.stands(hit, upTo: host)
        }

        /// A scroll view's own pan, of one inside the page, waits for this one to fail.
        func gestureRecognizer(_ recogniser: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard recogniser === pan, let page, let scroll = other.view as? UIScrollView,
                  other === scroll.panGestureRecognizer
            else { return false }
            return page.convert(page.bounds, to: nil).intersects(scroll.convert(scroll.bounds, to: nil))
        }

        func gestureRecognizer(_ recogniser: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }

        @objc private func panned() {
            guard let page else { return }
            let dx = across(pan.translation(in: page).x)
            switch pan.state {
            case .began:
                startedOn = now.inFront()
            case .changed:
                guard !now.reduceMotion else { return }
                let moved = TimelineSwipe.follow(dx: dx, hasNext: now.hasNext, hasPrevious: now.hasPrevious)
                now.slide.x = across(moved)
                now.slide.lean = TimelineSwipe.lean(moved: moved, width: page.bounds.width, beside: now.key == "beside")
            case .ended:
                let step = TimelineSwipe.outcome(dx: dx, velocity: across(pan.velocity(in: page).x))
                let goes = step != 0 && (step > 0 ? now.hasNext : now.hasPrevious)
                goes ? leave(width: page.bounds.width, by: step) : settle()
            case .cancelled, .failed:
                settle()
            default:
                break
            }
        }

        /// Back where it was, the head's dots with it: one animation for both.
        private func settle() {
            startedOn = nil
            withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                now.slide.x = 0
                now.slide.lean = 0
            }
        }

        /// The page goes off the way it was pushed, what is in front is changed, and what is
        /// arrived at comes in from the other side. With motion reduced, it fades out and the
        /// other in. **The step is taken only if what is in front is still what the drag began
        /// on** (`TimelineSwipe.completes`).
        private func leave(width: CGFloat, by step: Int) {
            let off = across(step > 0 ? -width : width)
            let reduce = now.reduceMotion
            let began = startedOn
            let slide = now.slide
            startedOn = nil
            leaving = true
            slides += 1
            let mine = slides
            // **The backstop.** What follows hangs on two animations saying they are done, and
            // one that is never told so — the page taken off screen half-way — would leave the
            // page slid away and no swipe heard again. Well after both should have ended, a
            // slide that is still this one is put to rest.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(TimelineSwipe.backstop))
                if self.leaving, self.slides == mine { self.rest() }
            }
            // **The head's dots go the rest of the way as the page leaves, in the one animation
            // with it.** They were held where the finger left them until the page had gone and
            // then sent on by an animation of their own: a stop and a second start.
            withAnimation(.easeIn(duration: 0.16)) {
                if reduce { slide.faint = true } else { slide.x = off }
                slide.lean = TimelineSwipe.leaves(by: step, beside: self.now.key == "beside", still: reduce)
            } completion: {
                guard self.leaving else { return }
                // The place changes and the lean goes in one drawing, unanimated: the row is
                // already drawn as the one arrived at, and nothing is seen to change.
                slide.lean = 0
                let stepped = TimelineSwipe.completes(startedOn: began, inFront: self.now.inFront()) && self.now.step(step)
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { slide.x = stepped && !reduce ? -off : 0 }
                withAnimation(.easeOut(duration: 0.2)) {
                    slide.x = 0
                    slide.faint = false
                } completion: {
                    self.leaving = false
                }
            }
        }
    }
}

/// Takes the scroll view this stands in out of the running for the system's press on the top of
/// the screen (#308).
///
/// **That press goes to the top of one scroll view, and only where there is one that wants it.**
/// Every scroll view wants it unless told otherwise, a row of names that scrolls sideways as
/// much as the list under it — and with two that want it, it goes to neither. So everything on
/// a timeline's page that scrolls and is not the list says it does not.
struct NotToTop: UIViewRepresentable {
    func makeUIView(context: Context) -> Finder {
        let view = Finder()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Finder, context: Context) {
        view.setNeedsLayout()
    }

    /// **Never a scroll view that scrolls up and down** (`ScrollAxis.notUpAndDown`). Asked each
    /// time this is laid out, since what a scroll view holds is not known when it is made, and
    /// answered both ways: one that has come to scroll up and down is given the press back.
    final class Finder: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            var above = superview
            while let view = above, !(view is UIScrollView) { above = view.superview }
            guard let scroll = above as? UIScrollView, scroll.contentSize.height > 0 else { return }
            scroll.scrollsToTop = !ScrollAxis.notUpAndDown(content: scroll.contentSize, bounds: scroll.bounds.size)
        }
    }
}

/// How many scroll views on screen want the press on the top of the screen, of how many there
/// are: what a staged picture writes down, since nothing can make that press for it.
@MainActor
enum ScrollsToTopCount {
    static func now() -> (wanting: Int, all: Int) {
        var wanting = 0, all = 0
        func look(_ view: UIView) {
            if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.window != nil {
                all += 1
                if scroll.scrollsToTop { wanting += 1 }
            }
            view.subviews.forEach(look)
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach(look)
        }
        return (wanting, all)
    }
}
#endif

extension View {
    /// Says of the scroll view this is inside that the press on the top of the screen is not
    /// for it. Put on what it scrolls. Nothing on a Mac.
    @ViewBuilder
    func notToTop() -> some View {
        #if os(iOS)
        background(NotToTop())
        #else
        self
        #endif
    }
}

/// Which way a scroll view scrolls, by what it holds.
enum ScrollAxis {
    /// Whether it does not scroll up and down: what it holds is no taller than it is. A row of
    /// names is so whether or not there are names enough to scroll sideways — two names that
    /// fit are still a scroll view the system counts — and a list longer than its page never is.
    static func notUpAndDown(content: CGSize, bounds: CGSize) -> Bool {
        content.height > 0 && content.height <= bounds.height + 1
    }
}
