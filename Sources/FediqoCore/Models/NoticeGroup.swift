import Foundation

/// Several people doing the same thing to the same post, as one row (#124).
///
/// **The rule the timeline already keeps, asked of the inbox**: one thing that happened is one
/// row, and the row says how many. A post carried by three servers is one row that says three
/// (#3); six favourites on one post should be one row that says six, rather than six lines that
/// bury everything else that happened.
///
/// **Grouped here and not in the store.** Every event a server sent is kept exactly as it
/// arrived — nothing is merged away, nothing needs a migration, and the count of what has not
/// been looked at goes on meaning what it always meant, because it counts events. Grouping is
/// how they are *drawn*, and a drawing that is worked out from what arrived cannot come to
/// disagree with it.
public struct NoticeGroup: Sendable, Hashable, Identifiable {
    /// Every event in it, newest first. Never empty.
    public let notices: [Notice]

    public init(_ notices: [Notice]) {
        self.notices = notices
    }

    /// The newest of them, which is what the row is drawn from and where it sits in the list.
    public var newest: Notice { notices[0] }

    /// What names this row. The pair it was grouped on where it is a group, and the event's own
    /// id where it is alone — so a row that stops being a group does not change its name and
    /// take the ring somewhere else with it.
    public var id: String { Notice.grouping(of: newest) ?? newest.id }

    public var count: Int { notices.count }

    /// Whether any of them has not been looked at. **Any and not all**: a row with one new thing
    /// in it is a row with something new in it, and a reader who has read five of six has not
    /// read the sixth.
    public var isUnseen: Bool { notices.contains(where: \.isUnseen) }

    /// Everyone who did it, newest first, each named once. Somebody who favourited and then
    /// unfavourited and favourited again is one person, not three.
    public var actors: [String] {
        notices.reduce(into: [String]()) { names, notice in
            let name = notice.actorName.isEmpty ? notice.actorHandle : notice.actorName
            if !names.contains(name) { names.append(name) }
        }
    }
}

extension Notice {
    /// What two events have to share to be one row: **the same kind of thing, about the same
    /// post.** Nothing looser.
    ///
    /// Six favourites on one post are one row. A favourite and a boost on the same post are two,
    /// because they are two different things somebody did. Six favourites on six posts are six.
    ///
    /// Nothing at all where the event is about no post — a follow is about a person, and being
    /// followed is not something that happens to you repeatedly by different people in a way
    /// worth adding up.
    static func grouping(of notice: Notice) -> String? {
        guard let key = notice.postKey else { return nil }
        return "\(notice.kind.rawValue)|\(key)"
    }

    /// A list of events as the rows it should be drawn as, in the order the newest of each puts
    /// them — which is the order the list was already in, because a group sits where its newest
    /// event sat.
    public static func grouped(_ notices: [Notice]) -> [NoticeGroup] {
        var rows: [NoticeGroup] = []
        var at: [String: Int] = [:]
        for notice in notices {
            guard let key = grouping(of: notice) else {
                rows.append(NoticeGroup([notice]))
                continue
            }
            if let index = at[key] {
                rows[index] = NoticeGroup(rows[index].notices + [notice])
            } else {
                at[key] = rows.count
                rows.append(NoticeGroup([notice]))
            }
        }
        return rows
    }
}
