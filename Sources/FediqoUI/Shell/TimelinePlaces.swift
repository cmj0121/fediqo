/// Where the reader was standing on each timeline, for as long as this run lasts (#100).
///
/// **"Place" here is a post, and not a `ShellPlace`.** A shell place is a page the rail reaches;
/// this is the post the lamp was on inside one of them. The two words sit beside each other
/// because the reader uses one for both — the place they were — and nothing in this type ever
/// mentions the other.
///
/// **One lamp for the whole shell was the defect.** `FediqoRootView` holds a single selected id,
/// which is right while there is one list: a thread opened and escaped comes back to the post it
/// opened from (#23), and a reload lands newer rows above the selected one and leaves it centred
/// (#29). It is wrong the moment the reader changes which list they are reading. Standing on a
/// post in All, pressing Trends, and pressing All again put them back at the top, because the
/// lamp went out on the way past a timeline that did not hold that post.
///
/// Each query keeps its own, so one cannot overwrite another and a timeline opened for the first
/// time this run has nothing to inherit.
///
/// **This run only.** Nothing here is written down, and coming back to where reading stopped
/// after a quit is #63 — a different question with a store schema in it.
struct TimelinePlaces: Hashable, Sendable {
    private var held: [TimelineQuery: String] = [:]

    /// Writes down where the reader was standing on the timeline they are leaving.
    ///
    /// Standing nowhere is a place too, and is kept as one: a reader who left All with no post
    /// lit comes back to All with no post lit, rather than to whatever was lit before that.
    mutating func leave(_ query: TimelineQuery, standingOn item: String?) {
        held[query] = item
    }

    /// The post to stand on when this timeline is opened, among the posts it now holds.
    ///
    /// Nothing for a timeline this run has not opened, which is what keeps it from borrowing
    /// another's, and nothing where the post it remembers has since left the list — a timeline
    /// that lit a row no longer in it would be the app saying a post is there when it is not.
    func arriving(at query: TimelineQuery, among items: [String]) -> String? {
        guard let held = held[query], items.contains(held) else { return nil }
        return held
    }

    /// Both halves of a tab press, and what the lamp should be on afterwards.
    ///
    /// Written as one call because the two halves are one act and have to happen in this order:
    /// a switch back onto the timeline just left would otherwise read its own place before it
    /// was written. `items` are the posts the *arrived-at* timeline holds.
    mutating func switched(
        from left: TimelineQuery?,
        to arrived: TimelineQuery?,
        standingOn item: String?,
        among items: [String]
    ) -> String? {
        if let left { leave(left, standingOn: item) }
        guard let arrived else { return nil }
        return arriving(at: arrived, among: items)
    }
}
