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
    /// level. **From anywhere on the list, its leading edge included** — nothing else on this
    /// page wants that edge; the swipe back is an opened page's (`backHeard`).
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

    /// Whether a swipe is heard: only where there is nothing but a finger, with the list itself
    /// in front — nothing opened over it, no search, and neither the list of timelines nor the
    /// editor up.
    static func enabled(touch: Bool, opened: Bool, searching: Bool, listShown: Bool, editing: Bool) -> Bool {
        touch && !opened && !searching && !listShown && !editing
    }

    /// Whether a drag let go is still acted on once the list has slid away: only if the
    /// timeline in front is the one the drag began on. Something else may have changed it in
    /// that sixth of a second — a key, the list of timelines — and a step taken then would be
    /// a step from somewhere the hand never was.
    static func completes(startedOn: String?, inFront: String?) -> Bool {
        startedOn != nil && startedOn == inFront
    }

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

    /// Whether a swipe in from the leading edge goes back (#305): under a finger, on a page
    /// opened over the list — a post, a person, a tag — and nowhere else. It does what that
    /// page's Back does, and changes no timeline.
    static func backHeard(touch: Bool, opened: Bool) -> Bool {
        touch && opened
    }

    /// What VoiceOver says of the timeline arrived at, or stood on at an end where there was
    /// nowhere further to go: its name, and "2 of 5".
    static func announcement(name: String, position: Int?, count: Int, language: DummyLanguage? = nil) -> String {
        guard let position, count > 1 else { return name }
        return name + ", " + String(format: L10n.t("timeline.position", language: language), position + 1, count)
    }
}

#if os(iOS)
/// The recogniser, put on the list's own scroll view. See `TimelineSwipe` for why it is this.
///
/// Drawn nowhere: it stands inside what the list scrolls, finds the scroll view it is in, and
/// adds its pan there. **The list is moved by its layer and not by anything SwiftUI reads**, so
/// a drag draws no row again.
///
/// ## What it is to every other recogniser, said rather than left to the order they are asked in
///
/// - **The scroll view's own pan waits for this one to fail** (`shouldBeRequiredToFailBy`).
///   Two pans on one view are exclusive, and whichever is asked first would otherwise win
///   every drag. This one fails at once on a drag that did not set out level — both judge the
///   same first few points — so scrolling waits for nothing a hand could feel, and nothing
///   here ever turns the scroll view's pan off.
/// - **It is simultaneous with nothing** (`shouldRecognizeSimultaneouslyWith` is no). So once
///   it has begun, the press a row or a mark was waiting to finish is cancelled — a swipe that
///   ends over a button presses nothing — and so is the long press that would raise a row's
///   menu; and once a long press has been recognised, this, still only possible, fails.
///   `cancelsTouchesInView` says the same to anything listening to touches themselves.
struct TimelineSwipeCatcher: UIViewRepresentable {
    var enabled: Bool
    var hasNext: Bool
    var hasPrevious: Bool
    var reduceMotion: Bool
    /// The timeline in front, asked as a drag begins and again as it is acted on.
    var inFront: () -> String?
    /// One timeline on or back. Says whether there was one to go to.
    var step: (Int) -> Bool

    func makeUIView(context: Context) -> Finder {
        let view = Finder()
        view.isUserInteractionEnabled = false
        view.catcher = context.coordinator
        return view
    }

    func updateUIView(_ view: Finder, context: Context) {
        let catcher = context.coordinator
        catcher.now = self
        if catcher.pan.isEnabled, !enabled { catcher.rest() }
        catcher.pan.isEnabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleUIView(_ view: Finder, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Finds the scroll view this stands in, once it is in one.
    final class Finder: UIView {
        weak var catcher: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var above = superview
            while let view = above, !(view is UIScrollView) { above = view.superview }
            catcher?.attach(to: above as? UIScrollView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var now: TimelineSwipeCatcher
        let pan = UIPanGestureRecognizer()
        private weak var list: UIScrollView?
        /// The timeline the drag in hand began on.
        private var startedOn: String?
        /// The list is sliding away or in: no new drag is heard till it is at rest.
        private var leaving = false

        init(_ catcher: TimelineSwipeCatcher) {
            now = catcher
            super.init()
            pan.addTarget(self, action: #selector(panned))
            pan.delegate = self
            pan.cancelsTouchesInView = true
            pan.isEnabled = catcher.enabled
        }

        func attach(to scroll: UIScrollView?) {
            guard scroll !== list else { return }
            detach()
            list = scroll
            scroll?.addGestureRecognizer(pan)
        }

        /// The pan taken off, and with it everything it asked of the scroll view's own: the
        /// waiting is asked through the delegate for each touch, and is not a thing left set.
        func detach() {
            rest()
            list?.removeGestureRecognizer(pan)
            list = nil
        }

        /// The list where it belongs, whatever a drag or a slide had made of it.
        func rest() {
            list?.layer.removeAllAnimations()
            list?.transform = .identity
            list?.alpha = 1
            leaving = false
            startedOn = nil
        }

        /// Toward the trailing edge is positive, whichever way the language reads.
        private func across(_ x: CGFloat) -> CGFloat {
            list?.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -x : x
        }

        /// **Refused unless the drag set out level**, and while the last one is still sliding.
        func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
            guard let list, recogniser === pan else { return true }
            guard TimelineSwipe.hears(leaving: leaving) else { return false }
            let moved = pan.translation(in: list)
            return TimelineSwipe.begins(dx: moved.x, dy: moved.y)
        }

        /// The scroll view's own pan waits for this one to fail. Only that pan: nothing else
        /// is made to wait.
        func gestureRecognizer(_ recogniser: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            recogniser === pan && other === list?.panGestureRecognizer
        }

        func gestureRecognizer(_ recogniser: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }

        @objc private func panned() {
            guard let list else { return }
            let dx = across(pan.translation(in: list).x)
            switch pan.state {
            case .began:
                startedOn = now.inFront()
            case .changed:
                guard !now.reduceMotion else { return }
                let moved = TimelineSwipe.follow(dx: dx, hasNext: now.hasNext, hasPrevious: now.hasPrevious)
                list.transform = CGAffineTransform(translationX: across(moved), y: 0)
            case .ended:
                let step = TimelineSwipe.outcome(dx: dx, velocity: across(pan.velocity(in: list).x))
                let goes = step != 0 && (step > 0 ? now.hasNext : now.hasPrevious)
                goes ? leave(list, by: step) : settle(list)
            case .cancelled, .failed:
                settle(list)
            default:
                break
            }
        }

        private func settle(_ list: UIScrollView) {
            startedOn = nil
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                list.transform = .identity
            }
        }

        /// The list in front goes off the way it was pushed, the timeline is changed, and the
        /// one arrived at comes in from the other side — one list throughout. With motion
        /// reduced, it fades out and the other in. **The step is taken only if the timeline in
        /// front is still the one the drag began on** (`TimelineSwipe.completes`).
        private func leave(_ list: UIScrollView, by step: Int) {
            let width = list.bounds.width
            let off = across(step > 0 ? -width : width)
            let reduce = now.reduceMotion
            let began = startedOn
            startedOn = nil
            leaving = true
            UIView.animate(withDuration: 0.16, delay: 0, options: .curveEaseIn) {
                if reduce { list.alpha = 0 } else { list.transform = CGAffineTransform(translationX: off, y: 0) }
            } completion: { _ in
                guard self.leaving else { return }
                let stepped = TimelineSwipe.completes(startedOn: began, inFront: self.now.inFront()) && self.now.step(step)
                if stepped, !reduce { list.transform = CGAffineTransform(translationX: -off, y: 0) }
                UIView.animate(withDuration: 0.2, delay: 0.02, options: .curveEaseOut) {
                    list.transform = .identity
                    list.alpha = 1
                } completion: { _ in
                    self.leaving = false
                }
            }
        }
    }
}

/// The swipe in from the leading edge that goes back, on a page opened over the list (#305).
///
/// The pages a post, a person and a tag open on are this app's own and not a navigation stack's,
/// so the system gives them no swipe back: this is it. A screen-edge pan — the leading edge, the
/// trailing one where the language reads the other way — that **does exactly what the page's
/// Back does**, and nothing to any timeline.
///
/// **A scroll view's pan under it waits for it to fail** (`shouldBeRequiredToFailBy`), as the
/// list's waits for the swipe between timelines: an edge pan fails at once on a touch that did
/// not come down at the edge, so nothing is felt to wait.
///
/// It listens on the nearest view above it that holds the page, so a sheet over the page —
/// which is not inside that view — is not listened through.
struct BackEdgeCatcher: UIViewRepresentable {
    var enabled: Bool
    var back: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let catcher = context.coordinator
        catcher.back = back
        catcher.edge.isEnabled = enabled
        // A tick later: the page this stands behind is put in the window after it is.
        DispatchQueue.main.async { catcher.attach(from: view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(back) }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.edge.view?.removeGestureRecognizer(coordinator.edge)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var back: () -> Void
        let edge = UIScreenEdgePanGestureRecognizer()

        init(_ back: @escaping () -> Void) {
            self.back = back
            super.init()
            edge.addTarget(self, action: #selector(swiped))
            edge.delegate = self
            edge.cancelsTouchesInView = true
        }

        /// The nearest view above `view` that holds a scroll view — the page — or, with none,
        /// the view it is in.
        func attach(from view: UIView) {
            func holdsScroll(_ view: UIView) -> Bool {
                view is UIScrollView || view.subviews.contains(where: holdsScroll)
            }
            var above = view.superview
            while let candidate = above, !holdsScroll(candidate), candidate.superview != nil { above = candidate.superview }
            guard let host = above, edge.view !== host else { return }
            edge.view?.removeGestureRecognizer(edge)
            edge.edges = host.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
            host.addGestureRecognizer(edge)
        }

        func gestureRecognizer(_ recogniser: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            recogniser === edge && other is UIPanGestureRecognizer && other.view is UIScrollView
        }

        func gestureRecognizer(_ recogniser: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }

        @objc private func swiped() {
            if edge.state == .ended { back() }
        }
    }
}
#endif
