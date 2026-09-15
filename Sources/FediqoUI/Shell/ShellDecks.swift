/// Which card each row's deck is turned to, and which rows the reader has uncovered.
///
/// **It belongs to the app rather than to the row.** A row is rebuilt every time the list is,
/// and a refresh replaces the list wholesale — so a reader who turned to the third picture and
/// then got a refresh would be looking at the first one again, having done nothing. Keyed by the
/// post's own id rather than by its position, because a refresh moves rows and the third picture
/// belongs to the post, not to the third line on the screen.
///
/// Nothing here is written down anywhere. A lifted cover lasts as long as this run of the app,
/// which is decision 3's second half: the reader's answer is about this moment and not a standing
/// permission granted to a server.
struct ShellDecks: Equatable, Sendable {
    /// How many rows' worth of turning and uncovering is kept.
    ///
    /// **A rate is not a bound.** These only grow where a reader pressed a key, which is slow —
    /// and a collection that only grows slowly is still one that only grows, which is the leak
    /// every other collection in this shell is bounded against. `ShellPictures` bounds two maps
    /// of exactly this shape and this is the same clause.
    ///
    /// It is more than a reader will reach in a run, so what the bound actually does is put a
    /// ceiling on the pathological case rather than change the ordinary one.
    static let remembered = 256

    private var turned: [String: Int] = [:]
    private var lifted: Set<String> = []

    /// Which one is on top. Folded by the count every time it is read, not only when it is
    /// written: a refresh can bring back the same post carrying fewer things than it did, and a
    /// position remembered from the longer version would point past the end of the shorter one.
    func top(of id: String, of count: Int) -> Int {
        AttachmentDeck.folded(turned[id] ?? 0, of: count)
    }

    /// Turns one row's deck, and says whether there was anything to turn.
    ///
    /// **A deck of one does not turn**, and neither does a row that brought nothing: the press
    /// moves nothing and reports that it moved nothing.
    mutating func turn(_ id: String, of count: Int) -> Bool {
        guard count > 1 else { return false }
        turned[id] = AttachmentDeck.folded(top(of: id, of: count) + 1, of: count)
        // The entry dropped is an arbitrary one rather than the oldest, for the reason the
        // picture cache drops an arbitrary refusal: giving this its own ordering would be a
        // second piece of bookkeeping for a map nobody can see. Losing the wrong one costs a
        // reader one deck back at its first card; it cannot loop, because the entry just written
        // is never the one removed.
        while turned.count > Self.remembered, let spare = turned.keys.first(where: { $0 != id }) {
            turned.removeValue(forKey: spare)
        }
        return true
    }

    func isLifted(_ id: String) -> Bool { lifted.contains(id) }

    /// Takes one row's cover off, or puts it back.
    ///
    /// **A pure toggle, with no second thing it also does.** The on-screen control changes its
    /// label and stays where it is, so both directions are reachable without a keyboard; a key
    /// that only went one way would be lift-only for every reader using a pointer or a screen
    /// reader.
    ///
    /// **A lift is remembered against the post's id, so an author who adds a warning to a post
    /// the reader has already uncovered does not get one on the refreshed row.** The bound below
    /// puts a ceiling on how long that lasts rather than closing it; closing it properly means
    /// remembering what was uncovered rather than only that something was, which is a decision
    /// about what a lift is an answer to.
    mutating func toggleCover(_ id: String) -> Bool {
        if lifted.remove(id) != nil { return true }
        lifted.insert(id)
        while lifted.count > Self.remembered, let spare = lifted.first(where: { $0 != id }) {
            lifted.remove(spare)
        }
        return true
    }
}
