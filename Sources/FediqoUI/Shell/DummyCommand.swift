import SwiftUI

/// A dummy key press. Only the keys that actually work are named here, so the guide cannot lie.
public enum DummyCommand: String, Hashable, Sendable, CaseIterable {
    case nextTab
    case previousTab
    case nextPage
    case previousPage
    case nextPost
    case previousPost
    case goTop
    case expandPost
    case viewAttachment
    case playAttachment
    case nextAttachment
    /// The key `s` — **one key, two jobs, and one rule that says which.**
    ///
    /// It was `liftCover`, and it still lifts covers: every press that did something before this
    /// unit does exactly the same thing after it. What changed is what happens on the presses that
    /// did *nothing*.
    ///
    /// **Why `s` and not a free letter.** The reader named it — "and you can load the more by `s`"
    /// — and they named it for a reason that turns out to be a fact about the code. Neither
    /// `Discuz.swift` nor `Discourse.swift` ever sets `sensitive` or `spoiler`; both default to
    /// `nil` on a `Note`, so `DummyItem.covered` is false for **every forum row this app can
    /// draw**, and `s` was already a key that did nothing at all on a forum. The reader pressed
    /// the idle key and expected it to mean something. That is not a collision to be worked
    /// around — it is a key with a vacancy exactly where the new job is.
    ///
    /// **The rule is `DummyCommand.reveal(hasCover:repliesWanted:)` and it is written once.** Each
    /// site reading it back out of its own `if`s is the shape this branch has now written down
    /// three times — the layer order re-expressed in `.back`, host folding at each consumer's
    /// door, and a `default:` over `DummyLayer?` found alive six commits after the plan said it
    /// was gone.
    ///
    /// **The cover wins where there is one**, and the precedence matters in both directions. A
    /// covered post that also had replies would otherwise fetch them behind a blur the reader has
    /// not lifted — which is `s` doing something invisible, the same fault as `s` doing nothing,
    /// wearing the other coat. And it degrades honestly: lift the cover, press `s` again, and now
    /// there is no cover to lift, so the second press asks for the replies.
    case reveal
    case back
    case compose
    case showShortcuts
    case dismiss
    /// ⌘R — play the launch overlay again, from rest, without quitting the process.
    ///
    /// **Not the letter `r`.** That letter is later reblog, and taking it here would make
    /// the two jobs a collision the day the later one arrives. A ⌘ chord is otherwise the
    /// platform's — this is the one dummy exception.
    case replayLanding

    /// What a press means. Letters are the draft's while composing, except Escape.
    /// A focused text field owns every key, including Escape.
    public static func from(
        _ character: Character,
        shift: Bool = false,
        control: Bool = false,
        command: Bool = false,
        typing: Bool = false,
        fieldFocused: Bool = false
    ) -> DummyCommand? {
        if command {
            // ⌘R only. ⌘Q, ⌘C, ⌘W stay the platform's. Control+⌘ is a different chord.
            guard !control, character == "r" || character == "R" else { return nil }
            return .replayLanding
        }
        if fieldFocused { return nil }
        if character == KeyEquivalent.escape.character {
            return .dismiss
        }
        if character == KeyEquivalent.tab.character {
            if typing { return nil }
            if control { return shift ? .previousPage : .nextPage }
            return shift ? .previousTab : .nextTab
        }
        guard !typing else { return nil }
        if shift, character == "?" || character == "/" { return .showShortcuts }
        switch character {
        case "?": return .showShortcuts
        case "c": return .compose
        case "j", KeyEquivalent.downArrow.character: return .nextPost
        case "k", KeyEquivalent.upArrow.character: return .previousPost
        case "g": return .goTop
        case "v": return .viewAttachment
        case "a": return .playAttachment
        case "m": return .nextAttachment
        case "s": return .reveal
        case KeyEquivalent.return.character, " ": return .expandPost
        case "q": return .back
        default: return nil
        }
    }

    /// Keys the platform may still want. Letters are ours whether or not they moved anything.
    public static let sharedWithControls: Set<Character> = [
        KeyEquivalent.upArrow.character,
        KeyEquivalent.downArrow.character,
        KeyEquivalent.return.character,
        KeyEquivalent.escape.character,
        KeyEquivalent.tab.character,
        " ",
    ]

    public static func consumes(_ character: Character, did: Bool) -> Bool {
        sharedWithControls.contains(character) ? did : true
    }

    /// Step through a ring. Used by Tab and ⌃Tab so the two rotates cannot drift apart.
    public static func advanced<T: Equatable>(_ items: [T], from current: T, by step: Int) -> T {
        guard let index = items.firstIndex(of: current), !items.isEmpty else { return current }
        let count = items.count
        let offset = ((step % count) + count) % count
        return items[(index + offset) % count]
    }

    /// Where a press that acts on the focused post lands, when there may not be one.
    ///
    /// Pure, and separate from the acting, because the rule is the part with cases in it: an
    /// empty list, nothing focused yet, a selection left pointing at a post the last refresh took
    /// away. Inside a view none of those can be asserted; here all of them can.
    public static func focused(in items: [DummyItem], selected: String?) -> DummyFocus {
        guard let first = items.first else { return .nothing }
        guard let selected, let item = items.first(where: { $0.id == selected }) else {
            // Nothing focused, so the press focuses the first row the way `j` does and stops
            // there. A key whose first press does nothing and says nothing is a key a reader
            // concludes is broken; the second press, now that there is a row to press it on,
            // does the thing.
            return .first(first.id)
        }
        return .post(item)
    }

    /// Which of what is open a dismissing press closes: the outermost, and only that one.
    ///
    /// The order is `DummyLayer.allCases` and nothing else, which is the point of this existing
    /// at all — the alternative is a run of `if`s in a view, where the order is whatever somebody
    /// last wrote and cannot be asserted from anywhere.
    public static func outermost(of open: Set<DummyLayer>) -> DummyLayer? {
        DummyLayer.allCases.first(where: open.contains)
    }

    /// Whether a layer may be entered now.
    ///
    /// The dual of `outermost`, and deliberately the **same function** rather than a second list:
    /// a layer may open only if it would then be the outermost one.
    ///
    /// A key that would open something underneath what the reader is already looking at is not
    /// handled and yields. **It does not close the layer above to make room for itself** — that
    /// is the compound behaviour ruled out for `s` inside the viewer, ruled out here for the same
    /// reason. Keys do not navigate implicitly.
    ///
    /// There is exactly one expression of the layer order in this codebase, and both directions
    /// read it. A second expression is a bug that has not happened yet.
    public static func canOpen(_ layer: DummyLayer, whenOpen open: Set<DummyLayer>) -> Bool {
        outermost(of: open.union([layer])) == layer
    }

    /// **What one press of `s` means on the post it landed on. The one place this is decided.**
    ///
    /// Pure, and separate from the acting, for the reason `focused(in:selected:)` is: the part
    /// with the cases in it is the part that can be got wrong, and inside a view none of them can
    /// be asserted. `FediqoRootView.revealFocused` switches on this, `DummyThreadPane` draws its
    /// mark where this says `.replies`, and `PressTests` presses it — three readers, one rule, no
    /// site free to re-express it.
    ///
    /// Written as a switch over the pair rather than as two `if`s, so the precedence is a thing
    /// you can see rather than a thing you have to trace, and so a fourth combination cannot be
    /// added without a case for it. **No `default:`.**
    ///
    /// - Parameter hasCover: `DummyItem.covered` — the author flagged this post or wrote a line
    ///   over it. Not whether the reader has lifted it: `s` toggles, so a lifted cover is still a
    ///   cover and still what this key is for.
    /// - Parameter repliesWanted: whether asking for the rest of this topic could do anything —
    ///   `ForumRepliesStanding.wantsPressing`, on a thread the reader has actually opened. The
    ///   caller answers it, because it needs the cache and the open pane and this needs neither.
    public static func reveal(hasCover: Bool, repliesWanted: Bool) -> DummyReveal {
        switch (hasCover, repliesWanted) {
        // **The cover wins, and it wins even where there are replies to fetch.** Pulling a page
        // in behind a blur the reader has not lifted is `s` doing something they cannot see,
        // which is the same fault as `s` doing nothing — and a reader who lifts the cover and
        // presses `s` again gets the replies, because by then this is no longer the case.
        case (true, _): return .cover
        case (false, true): return .replies
        // Nothing to uncover and nothing to load. Honest, and the same answer `v`, `a` and `m`
        // give on a row with nothing to view, play or turn.
        case (false, false): return .nothing
        }
    }

    /// Step through a list without wrapping. Nil current picks the first (down) or last (up).
    public static func stepped<T: Equatable>(_ items: [T], from current: T?, by step: Int) -> T? {
        guard !items.isEmpty else { return nil }
        guard let current, let index = items.firstIndex(of: current) else {
            return step >= 0 ? items.first : items.last
        }
        let next = index + step
        guard items.indices.contains(next) else { return current }
        return items[next]
    }
}

/// What a dismissing press can close, outermost first.
///
/// **The order of the cases is the layer order**, which is why they are `CaseIterable` and why
/// `DummyCommand.outermost` is the only reader of that order. A viewer left open under a popped
/// thread is the failure this is arranged to make unreachable: the viewer is drawn over the whole
/// app, so it is what a press to leave has to leave.
///
/// The selection is a layer in this sense too. It is not something drawn over anything, but it is
/// the last thing `Escape` has to give back, and leaving it out of the list would put the rule in
/// two places again.
public enum DummyLayer: Hashable, Sendable, CaseIterable {
    /// What `v` opened, over the whole app.
    case viewer
    /// The written-down keys.
    case shortcuts
    /// The conversation opened over the stream.
    case thread
    /// The lamp on a row.
    case selection
}

/// The two jobs the key `s` has, and the third answer of neither.
///
/// `CaseIterable` for the reason `DummyLayer` is: a harness that enumerates is a harness that
/// cannot describe a smaller world than the code, which is this branch's first convention.
public enum DummyReveal: Hashable, Sendable, CaseIterable {
    /// Take the author's cover off this post, or put it back. What `s` has always meant.
    case cover
    /// Ask the forum for the rest of this topic — D31, from the keyboard.
    case replies
    /// Neither. The press moves nothing and says so.
    case nothing
}

/// What a press on the focused post has to work with. See `DummyCommand.focused(in:selected:)`.
public enum DummyFocus: Equatable, Sendable {
    /// No list to press on at all.
    case nothing
    /// Nobody is on a row yet, so this press only puts them on one.
    case first(String)
    /// The post to act on.
    case post(DummyItem)
}

/// The tabs of the written-down keys. Timeline is this page's stream; App is every tab.
public enum DummyShortcutGroup: String, CaseIterable, Identifiable, Sendable {
    case timeline
    case app

    public var id: String { rawValue }
    var titleKey: String { "shortcut.group.\(rawValue)" }

    /// Tab under the guide rotates these, wrapping, the same ring `DummyCommand.advanced`
    /// uses for All/Trends. A second list here would be the order written down twice.
    static func rotated(from current: DummyShortcutGroup, by step: Int) -> DummyShortcutGroup {
        DummyCommand.advanced(allCases, from: current, by: step)
    }
}

/// One line of the written-down list. Caps are not translated: a keyboard is labelled as it is.
public struct DummyShortcut: Identifiable, Hashable, Sendable {
    public let group: DummyShortcutGroup
    public let keys: [String]
    public let name: String
    public let commands: [DummyCommand]

    public var id: String { name }
    public var detail: String { L10n.t("shortcut.\(name)") }

    static func lines(in group: DummyShortcutGroup) -> [DummyShortcut] {
        all.filter { $0.group == group }
    }

    public static let all: [DummyShortcut] = [
        DummyShortcut(group: .timeline, keys: ["Tab", "⇧Tab"], name: "tabs",
                      commands: [.nextTab, .previousTab]),
        DummyShortcut(group: .timeline, keys: ["j", "k", "↓", "↑"], name: "posts",
                      commands: [.nextPost, .previousPost]),
        DummyShortcut(group: .timeline, keys: ["g"], name: "top", commands: [.goTop]),
        DummyShortcut(group: .timeline, keys: ["Return", "Space"], name: "expand",
                      commands: [.expandPost]),
        DummyShortcut(group: .timeline, keys: ["v"], name: "view", commands: [.viewAttachment]),
        DummyShortcut(group: .timeline, keys: ["a"], name: "play", commands: [.playAttachment]),
        DummyShortcut(group: .timeline, keys: ["m"], name: "turn", commands: [.nextAttachment]),
        DummyShortcut(group: .timeline, keys: ["s"], name: "reveal", commands: [.reveal]),
        DummyShortcut(group: .timeline, keys: ["q"], name: "back", commands: [.back]),
        DummyShortcut(group: .app, keys: ["⌃Tab", "⌃⇧Tab"], name: "pages",
                      commands: [.nextPage, .previousPage]),
        DummyShortcut(group: .app, keys: ["c"], name: "compose", commands: [.compose]),
        DummyShortcut(group: .app, keys: ["?"], name: "list", commands: [.showShortcuts]),
        DummyShortcut(group: .app, keys: ["Escape"], name: "dismiss", commands: [.dismiss]),
        DummyShortcut(group: .app, keys: ["⌘R"], name: "landing", commands: [.replayLanding]),
    ]
}
