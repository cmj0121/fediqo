import FediqoCore
import Foundation

/// One step away from the stream: a conversation, somebody's page, or on a Mac a page read out of
/// a post's words.
///
/// **Two kinds and one list**, which is the whole of #122. Before this the app held a stack of
/// conversations and, beside it, one person — and because they were two pieces of state the
/// order between them had to be decided once and for all in `DummyLayer`. A person over a
/// conversation is the right answer for the press that opens them, and it made a row on their
/// page a thing that lit and went no further, because a conversation may not open under the
/// layer it is under. Walking is not an order somebody decides in advance; it is the order the
/// reader walked.
enum ShellStep: Hashable, Sendable {
    /// Somebody, opened from their face or their name on a row (#99).
    case person(DummyPerson)
    /// The conversation around one post, by the id of the post it was opened from.
    ///
    /// **The id and not the row.** A row is a value that changes under the reader — a mark
    /// pressed, a cover lifted, a card turned — so a step holding one would draw a post whose
    /// marks stopped answering. The row is looked up afresh each pass, which is the same
    /// arrangement `ShellConversationStanding.loaded` gives its reason for.
    case thread(String)
    /// A page read out of a post's words, drawn in place of the page it was opened from (#169),
    /// by the address the reader pressed.
    ///
    /// **The address pressed, not where the page went.** The page moves as the reader reads it,
    /// and what it is showing is `ShellReader`'s; this step is only the fact that the reader
    /// stepped into a page from here, and what leaving it owes them. It is always the innermost
    /// step: nothing on the page is a row or a face, so nothing walks further from it.
    case link(URL)
    /// What this device holds under one hashtag, opened by pressing it in a post's words (#124).
    /// The tag as the author wrote it where it was pressed; which posts carry it is asked without
    /// regard to case, as the servers this app reads treat a tag.
    case tag(PostTag)
    /// A list of people a source keeps (#311) — whom somebody follows, who follows them — opened
    /// from where the source counts them. A row of it opens that person, and leaving their page
    /// gives the row back: both are the walk's own.
    case people(PeopleList)
    /// The hashtags, or the links, rising on the sources (#320), opened from the head of the
    /// timeline that reads what is rising. A hashtag's row opens that hashtag's page, and
    /// leaving it gives the row back: both are the walk's own.
    case rising(RisingWhich)
    /// What one source found for a search's words (#319): its people and its hashtags, one
    /// page with a tab for each (F10), opened from either press for all of one kind under its
    /// bands, on that kind's tab. A row opens that person's or that hashtag's page, and leaving
    /// it gives the row back: both are the walk's own.
    case found(FoundAt, FoundWhich)
    /// The hashtags the reader follows at one source (#318), opened from its line on their own
    /// page there. A hashtag's row opens that hashtag's page, and leaving it gives the row
    /// back: both are the walk's own.
    case followedTags(FollowedTags)
}

/// Whose the Tab key is with a step in front (F10): the page's own, asked of the walk before
/// the timelines are turned.
enum StepTabKey: Hashable, Sendable {
    /// Somebody's page: its tabs, round their ring (F9).
    case person(DummyPerson)
    /// A hashtag's page (F10): Posts and About where it has both, round their ring — and
    /// taken, turning nothing, where it has its posts alone.
    case tag(PostTag)
    /// What is rising (F10): Hashtags and Links where its sources have both, round their
    /// ring — the tab is the step's own value, turned in place (`ShellWalk.turned(to:)`) — and
    /// taken, turning nothing, where they have one.
    case rising(RisingWhich)
    /// What a search found at a source (F10): People and Hashtags where it gave both, round
    /// their ring — the tab is the step's own value, turned in place — and taken, turning
    /// nothing, where it gave one.
    case found(FoundAt, FoundWhich)
    /// A page with no tabs (F10): the key is taken and does nothing — to change timeline the
    /// reader leaves first — while the page, drawn as `layer`, is what is in front.
    case sole(DummyLayer)
}

extension ShellStep {
    /// The layer this step is drawn as, among what is open (`DummyLayer`): the hashtags a
    /// search found and those followed are drawn as rising's are, and the people it found as a
    /// list of people is — by the tab of what it found that is in front.
    var layer: DummyLayer {
        switch self {
        case .person: .person
        case .tag: .tag
        case .people, .found(_, .people): .people
        case .rising, .found(_, .tags), .followedTags: .rising
        case .thread: .thread
        case .link: .link
        }
    }

    /// What Tab turns with this step in front, or nothing where the step has no answer of
    /// its own and the key is the timelines'.
    var tabKey: StepTabKey? {
        switch self {
        case .person(let who): .person(who)
        case .thread: .sole(.thread)
        case .people: .sole(.people)
        case .followedTags: .sole(.rising)
        case .tag(let tag): .tag(tag)
        case .rising(let which): .rising(which)
        case .found(let at, let which): .found(at, which)
        case .link: nil
        }
    }

    /// Whether `other` is another value of the same kind of step — what a tab turned in place
    /// may turn to (`ShellWalk.turned(to:)`): `.rising(.tags)` and `.rising(.links)` are, and
    /// so are the two tabs of what a search found; a hashtag's page and a person's are not.
    func isKind(of other: ShellStep) -> Bool {
        switch self {
        case .person: if case .person = other { true } else { false }
        case .thread: if case .thread = other { true } else { false }
        case .link: if case .link = other { true } else { false }
        case .tag: if case .tag = other { true } else { false }
        case .people: if case .people = other { true } else { false }
        case .rising: if case .rising = other { true } else { false }
        case .found: if case .found = other { true } else { false }
        case .followedTags: if case .followedTags = other { true } else { false }
        }
    }
}

/// How far the reader has walked from the stream, and what each step is owed when it is left.
///
/// **One stack, and the order in it is the order the reader walked.** `DummyLayer` says what is
/// drawn over what — a picture over the guide, the guide over all of this, the lamp under it —
/// and for a person and a conversation it now says only that the two are the same distance out.
/// Which of them is in front is this, and it is a fact about what the reader did rather than a
/// rule somebody wrote down: a face pressed inside a conversation puts a person in front of it,
/// and a row pressed on that page puts a conversation in front of the person.
///
/// **Each step remembers the row the lamp was on when it was taken**, so leaving gives it back.
/// That is one sentence for what used to be two: a conversation gave back the post it was opened
/// from, a person gave back a row kept in a second piece of state beside them, and the two could
/// not be written once while they were different things. The lamp is read after the press has
/// moved it, which is why a conversation still comes back to its own opening post — the press
/// that opened it lit that post first.
struct ShellWalk: Hashable, Sendable {
    /// A step, and the row the lamp was on when the reader took it.
    private struct Taken: Hashable, Sendable {
        let step: ShellStep
        let lamp: String?
    }

    private var taken: [Taken] = []

    /// What the reader is looking at, or nothing where they are on the stream.
    var standing: ShellStep? { taken.last?.step }

    /// The conversation in front, where the thing in front is one. Read by the two rules that
    /// are about a conversation and not about a person: what `r` reloads, and whether `s` has a
    /// page of replies to ask for.
    var openedThread: String? {
        guard case .thread(let id) = standing else { return nil }
        return id
    }

    /// Whoever is in front, where the thing in front is somebody.
    var openedPerson: DummyPerson? {
        guard case .person(let person) = standing else { return nil }
        return person
    }

    /// The hashtag whose page is in front, where one is (#124).
    var openedTag: PostTag? {
        guard case .tag(let tag) = standing else { return nil }
        return tag
    }

    /// The list of people in front, where one is (#311) — a list opened on its own, or the
    /// people a search found, where the page of what it found stands on their tab (F10).
    var openedPeople: PeopleList? {
        switch standing {
        case .people(let list): list
        case .found(let at, .people): at.people
        default: nil
        }
    }

    /// The page read out of a post that is in front, where one is (#169).
    var openedLink: URL? {
        guard case .link(let url) = standing else { return nil }
        return url
    }

    /// The step the page under a link is standing on — the conversation, the person or the
    /// stream a link was pressed on — and so what the timeline place draws beneath it.
    ///
    /// **Beneath rather than instead.** The page a link opens fills the place, but what it was
    /// opened from stays drawn under it, exactly as it was: the list, where it is scrolled to,
    /// which post is lit. Leaving gives that back without building anything again.
    var beneath: ShellStep? {
        taken.last { step in
            if case .link = step.step { return false }
            return true
        }?.step
    }

    /// Every list of the hashtags followed among the steps (#318), in front or under another:
    /// what a walk ended in one go lets go of, as leaving each would.
    var followedTags: [FollowedTags] {
        taken.compactMap { step in
            if case .followedTags(let page) = step.step { return page }
            return nil
        }
    }

    var isEmpty: Bool { taken.isEmpty }

    /// What Tab turns with the step in front (`ShellStep.tabKey`): nothing on the stream.
    var tabKey: StepTabKey? { standing?.tabKey }

    /// Whether the page of the person `id` names is one of the steps taken, in front or under
    /// another. **By who they are, as their page is kept, and not by the value a row carried**:
    /// somebody met twice — from a post, then from a row of a list — may be two unequal
    /// values, a name or a picture apart, and is one page.
    func holdsPerson(_ id: String) -> Bool {
        taken.contains { taken in
            if case .person(let who) = taken.step { return who.id == id }
            return false
        }
    }

    /// Whether the page of `tag` is one of the steps taken, in front or under another — by
    /// the hashtag as its page is kept, whatever case it was written in where it was pressed.
    func holdsTag(_ tag: PostTag) -> Bool {
        taken.contains { taken in
            if case .tag(let held) = taken.step { return HeldUnderTag.same(held, tag) }
            return false
        }
    }

    /// How far out the reader has walked. Nothing dispatches on it; it is what a test counts to
    /// say that walking in and back out left nothing behind.
    var depth: Int { taken.count }

    /// One step further out, from the row the lamp is on.
    ///
    /// **A step onto what the reader is already standing on is not a step.** Pressing the open
    /// conversation's own post again, or the face of the person whose page this is, would
    /// otherwise put a second copy of the same step on the stack and make leaving take two
    /// presses to do one thing.
    mutating func walk(to step: ShellStep, from lamp: String?) -> Bool {
        if taken.last?.step == step { return false }
        taken.append(Taken(step: step, lamp: lamp))
        return true
    }

    /// A tab that is the step's own value, brought in front (F10): the step in front is
    /// replaced where it stands. Whether anything changed.
    ///
    /// **A tab is not a step.** The row the lamp goes back to stays the one the page was
    /// opened from, and the walk is no deeper: leaving never passes through the other tab.
    ///
    /// **Only for a tab of the page in front** — the same kind of step, another of its own
    /// values (`.rising(.tags)` to `.rising(.links)`); it is not a way to another page, and
    /// **a step of another kind is refused** (`ShellStep.isKind(of:)`). Nothing is turned on
    /// the stream, to the step already in front, or to the step beneath: that would stand the
    /// reader twice on one step, which `walk(to:)` refuses.
    @discardableResult
    mutating func turned(to step: ShellStep) -> Bool {
        guard let last = taken.last, last.step != step, last.step.isKind(of: step) else { return false }
        if taken.count > 1, taken[taken.count - 2].step == step { return false }
        taken[taken.count - 1] = Taken(step: step, lamp: last.lamp)
        return true
    }

    /// One step back: what was left, and the row it was taken from, which the lamp goes back to.
    ///
    /// Nothing else is unwound with it. The steps under it are exactly as the reader left them,
    /// which is what "leaving unwinds in the order the reader walked in" asks for.
    mutating func back() -> (step: ShellStep, lamp: String?)? {
        guard let last = taken.popLast() else { return nil }
        return (last.step, last.lamp)
    }

    /// Back to the stream in one go, with no lamp handed back.
    ///
    /// **Not a run of `back()`s.** This is the list underneath being replaced — a timeline
    /// switched, a search closed — so the rows every step was standing on are gone and there is
    /// nothing to give the lamp back to. Whoever changed the list says where the lamp lands.
    mutating func clear() { taken.removeAll() }

    /// The timeline under the walk switched with a tag's page in front — or under a page read out
    /// of a post, which goes: the tag's page stays, alone, because it answers to the timeline in
    /// front and is asked again of the new one (#197). The tag kept, or nothing and the walk
    /// untouched, for whoever switched to `clear()` it.
    ///
    /// **The row it gives back is parked, as a search's is** (#145). The row the walk was taken
    /// from on the stream is the timeline left's place, and leaving the page now gives back the
    /// place of the timeline arrived at: `place` is handed the one and answers the other.
    mutating func timelineSwitched(_ place: (String?) -> String?) -> PostTag? {
        guard case .tag(let tag) = beneath else { return nil }
        taken = [Taken(step: .tag(tag), lamp: place(taken.first?.lamp))]
        return tag
    }
}
