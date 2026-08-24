/// The item `steps` along a list from the one you are on, wrapping at both ends.
///
/// One rule for every rotation in the app: the pages in the rail, the tabs inside a page, and
/// how often the clock ticks. Wrapping is not a nicety here: a reader holding `Tab` should
/// come back round to where they started rather than stop against the end of a list they
/// cannot see.
///
/// `nil` when the list is empty or does not contain `current`, because a rotation with no
/// starting point has no answer — the caller says what to do about that.
func rotated<T: Equatable>(_ items: [T], from current: T, by steps: Int) -> T? {
    guard let index = items.firstIndex(of: current) else { return nil }
    let count = items.count
    return items[((index + steps) % count + count) % count]
}
