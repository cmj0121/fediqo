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
    /// `r` — reload what is in front: the open thread, or else the selected timeline (#29).
    case reload
    case compose
    case showShortcuts
    /// `/` — search what this device holds (#32). `?` is still the keys list; see `typed`.
    case search
    case dismiss
    /// ⌘R — play the launch overlay again, from rest, without quitting the process.
    ///
    /// **Not the letter `r`**, which reloads (#29). A ⌘ chord is otherwise the platform's — this
    /// is the one dummy exception.
    case replayLanding
    /// `e` — open the editor on the timeline in front (#27). All and Trends are not edited:
    /// the press says so. Adding is the `[+]` pill, pressed, not a Tab stop.
    case editTimeline

    /// The character a press stands for, where a platform reports Shift-/ as `/` with Shift held.
    ///
    /// **Only on the key that is `/` on an ANSI keyboard is Shift-/ a `?`** — the keys list. On a
    /// layout where `/` itself needs Shift (German and Nordic Shift-7, AZERTY Shift-:), the same
    /// report is the reader typing `/`, and reading it as `?` would leave search unreachable.
    public static func typed(_ character: Character, shift: Bool, onSlashKey: Bool) -> Character {
        shift && character == "/" && onSlashKey ? "?" : character
    }

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
        switch character {
        case "?": return .showShortcuts
        case "/": return .search
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
        case "e": return .editTimeline
        case "r": return .reload
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

    /// Whether `e` may open the timeline editor now: only over the timeline itself, with at most
    /// a post selected on it. Under a search, a thread, the viewer or the keys list, the timeline
    /// is not what the reader is looking at. **No `default:`**, for the reason `.back` gives.
    public static func canEditTimeline(whenOpen open: Set<DummyLayer>) -> Bool {
        switch outermost(of: open) {
        case .selection, nil: true
        case .viewer, .shortcuts, .person, .thread, .search: false
        }
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

    /// The two layers that are one walk: somebody's page, and a conversation (#122).
    ///
    /// They are drawn at the same distance from the stream and only ever one at a time, because
    /// `ShellWalk` holds them in one stack and only its innermost step is open. Their order
    /// relative to each other in `allCases` is therefore never asked — which of them is in front
    /// is what the reader walked, not what this list says.
    public static let walk: Set<DummyLayer> = [.person, .thread]

    /// Whether the reader may walk one step further out from where they are now.
    ///
    /// **The order is still read once**, out of `DummyLayer.allCases` and through `canOpen`. The
    /// walk's own two layers are set aside first and the question is asked about `.person`, which
    /// is the front of the pair: a step may be taken exactly when nothing outside the walk stands
    /// in front of it. So a conversation still does not open under the viewer or the guide, and
    /// it now does open from somebody's page — which is #122, and which no second list of layers
    /// had to be written to say.
    public static func canWalk(whenOpen open: Set<DummyLayer>) -> Bool {
        canOpen(.person, whenOpen: open.subtracting(walk))
    }

    /// What a press of a finger on a row means: the lamp, or the conversation (#33).
    ///
    /// Pure, and separate from the acting, for the reason `focused(in:selected:)` is: inside a
    /// view neither case can be asserted. Both lists that draw a row read this one function, so
    /// the stream and an open thread cannot come to answer a press differently.
    public static func tapped(_ id: String, selected: String?) -> DummyRowTap {
        selected == id ? .open : .select
    }

    /// Which post a list centres on when it is drawn afresh.
    ///
    /// A list is not drawn while a thread covers it, and it centres on a selection *change*, so
    /// coming back with the selection unchanged moved nothing. The exception is a thread just
    /// opened, whose selection is its own post: that one reads from the top as it always has.
    public static func centredOnAppear(selected: String?, opening root: String? = nil) -> String? {
        guard let selected, selected != root else { return nil }
        return selected
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
    /// Somebody's page, opened by pressing their face or their name on a row (#99).
    ///
    /// **It and `.thread` are one walk, and neither is in front of the other** (#122). The two
    /// used to be ordered here, a person over a conversation, which is the right answer for the
    /// press that opens them — a face is on every row a thread draws, so a person has to open
    /// from inside a conversation — and the wrong one for the press that leaves the page again:
    /// a row there lit and went no further, because a conversation may not open under the layer
    /// it is under. Which of the two is in front is now `ShellWalk`, and it is what the reader
    /// walked rather than what a list decided in advance.
    ///
    /// Only the innermost step of that walk is ever open, so these two are never both in a set
    /// of open layers and the order between them is never asked. What is still asked, and still
    /// read out of this one list, is what stands in front of *both* — see
    /// `DummyCommand.canWalk(whenOpen:)`.
    case person
    /// The conversation opened over whatever it was opened from: the stream, a search's results,
    /// another conversation, or somebody's page. One walk with `.person` — see there.
    case thread
    /// A search's results in place of the stream (#32). Under a thread, because a result can be
    /// opened; over the selection, because leaving it gives back the one made before it opened.
    case search
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

/// What a press of a finger on a row means (#33).
///
/// **The keyboard says this in two keys and a finger has one press.** `j` lights a row and
/// `Return` opens it, which is two presses of two different keys; a finger only ever presses the
/// row itself, so the second press on the row it is already on is the one that opens it. It is
/// the same shape `focused(in:selected:)` already gives a press that lands with nothing selected
/// — the first press puts the reader somewhere, the second one acts — and it is here, beside
/// that rule, because both are the answer to "what does this press do given what is lit".
public enum DummyRowTap: Hashable, Sendable, CaseIterable {
    /// The lamp moves to this row, which is what `j` and `k` do.
    case select
    /// The row is already lit, so this press is `Return`: the conversation opens.
    case open
}

/// How a key's own job is done with no keyboard to do it on (#33).
///
/// **One case per line of the written-down keys, and not optional.** A key added to
/// `DummyShortcut.all` has to say how a finger reaches it. `.keysOnly` is the answer where there
/// is honestly nothing and `.partly` where there is some of it, and `TouchTests` refuses both for
/// the Timeline group, because a way in for most of a key is not what #33 accepts. A field that
/// could be left off would be a promise the next key is free to break silently.
///
/// **It says how, not what.** Nothing dispatches on this: it is the written-down answer to "and
/// without a keyboard?", kept next to the key so the two are read in one place. What it cannot do
/// is prove the control is drawn — a line claiming `.press` over a surface with no mark on it is
/// a lie this type cannot catch, and the test that it *is* drawn is the one every `View` body in
/// this package is missing for the same reason.
public enum DummyTouch: String, Hashable, Sendable, CaseIterable {
    /// A control drawn on the surface and pressed once: a pill, a mark on a card, a mark in a
    /// header, the button a cover is.
    case press
    /// A press on the thing the lamp is already on. See `DummyRowTap`.
    case pressAgain
    /// The secondary press — a long press on a phone, a right or control click on a Mac. The one
    /// gesture with two names this app already argues for in `WayOut` and in `ProseLinks`.
    case hold
    /// The finger on the list itself.
    case scroll
    /// Some of what this key does is reachable and some of it is not.
    ///
    /// The answer for a key that is several jobs at once, where writing either `.press` or
    /// `.keysOnly` would be a claim about the other half. `TouchTests` refuses it for the
    /// Timeline group exactly as it refuses `.keysOnly`: "partly" is not what #33 accepts there.
    case partly
    /// No touch path at all: this key is reachable only from a keyboard.
    case keysOnly
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
    /// How this line is done with no keyboard (#33). Named on every line, so a key added later
    /// cannot be added without an answer. See `DummyTouch`.
    public let touch: DummyTouch

    public var id: String { name }
    public var detail: String { L10n.t("shortcut.\(name)") }

    static func lines(in group: DummyShortcutGroup) -> [DummyShortcut] {
        all.filter { $0.group == group }
    }

    public static let all: [DummyShortcut] = [
        // The named pills along the top of the timeline, pressed.
        DummyShortcut(group: .timeline, keys: ["Tab", "⇧Tab"], name: "tabs",
                      commands: [.nextTab, .previousTab], touch: .press),
        // A press on a row lights it, which is where `j` and `k` leave the lamp.
        DummyShortcut(group: .timeline, keys: ["j", "k", "↓", "↑"], name: "posts",
                      commands: [.nextPost, .previousPost], touch: .press),
        // **The list under a finger, and no mark of our own.** `g` is a shortcut for a scroll,
        // and a phone already has the scroll; a "top" button would be chrome on every row of
        // every timeline for something the reader's thumb does. What `g` does besides — light
        // the first post — is `.press` on that post, which is the line above.
        DummyShortcut(group: .timeline, keys: ["g"], name: "top", commands: [.goTop], touch: .scroll),
        DummyShortcut(group: .timeline, keys: ["Return", "Space"], name: "expand",
                      commands: [.expandPost], touch: .pressAgain),
        // The card itself, pressed. The mark on it is `a`'s and takes its own press.
        DummyShortcut(group: .timeline, keys: ["v"], name: "view",
                      commands: [.viewAttachment], touch: .press),
        DummyShortcut(group: .timeline, keys: ["a"], name: "play",
                      commands: [.playAttachment], touch: .press),
        // The counter in the card's corner, which is drawn exactly where there is more than one
        // card to turn to.
        DummyShortcut(group: .timeline, keys: ["m"], name: "turn",
                      commands: [.nextAttachment], touch: .press),
        // The cover is a button over its whole face — `DummyItemRow.cover`.
        DummyShortcut(group: .timeline, keys: ["s"], name: "reveal", commands: [.reveal], touch: .press),
        // Back in the thread's own header, and the close mark on the viewer.
        DummyShortcut(group: .timeline, keys: ["q"], name: "back", commands: [.back], touch: .press),
        // A tab held, or double-clicked — `TimelinePane.queryPill`.
        DummyShortcut(group: .timeline, keys: ["e"], name: "edit",
                      commands: [.editTimeline], touch: .hold),
        DummyShortcut(group: .timeline, keys: ["/"], name: "search", commands: [.search], touch: .press),
        DummyShortcut(group: .timeline, keys: ["r"], name: "reload", commands: [.reload], touch: .press),
        // The rail on a Mac, the tab bar on a phone.
        DummyShortcut(group: .app, keys: ["⌃Tab", "⌃⇧Tab"], name: "pages",
                      commands: [.nextPage, .previousPage], touch: .press),
        DummyShortcut(group: .app, keys: ["c"], name: "compose", commands: [.compose], touch: .press),
        // **This list is the one thing in this app a finger cannot ask for**, which is the honest
        // answer and not a resting place: a reader with no keyboard has no way to the written-down
        // keys, and needs none, because #33 is the promise that they never have to read them.
        DummyShortcut(group: .app, keys: ["?"], name: "list",
                      commands: [.showShortcuts], touch: .keysOnly),
        // Everything this closes has its own control — the ground behind a pop-up, Back, the
        // close mark. What it does that none of them do is stop a running reload and put the lamp
        // out, and neither of those has a touch path: hence `.partly` rather than `.press`, which
        // would be this list claiming a way in that is not drawn anywhere.
        DummyShortcut(group: .app, keys: ["Escape"], name: "dismiss", commands: [.dismiss], touch: .partly),
        DummyShortcut(group: .app, keys: ["⌘R"], name: "landing",
                      commands: [.replayLanding], touch: .keysOnly),
    ]
}
