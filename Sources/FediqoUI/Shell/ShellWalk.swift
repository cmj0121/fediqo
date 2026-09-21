import Foundation

/// One step away from the stream: a conversation, or somebody's page.
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

    var isEmpty: Bool { taken.isEmpty }

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
}
