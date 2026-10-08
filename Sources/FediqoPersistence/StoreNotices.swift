import FediqoCore
import Foundation
import GRDB

// What each signed-in source says happened to the person (`NoticeReach`, #323), in two tables of
// their own beside the items: written as a part of their own, so a page of notices read rewrites
// no post. **Other people's names and words, private mentions among them**: nothing here is ever
// put in a log, and a line let go is zeroed in the file as it goes (`secure_delete`, #292).

/// One source's reach as the `notice_reach` table holds it.
private struct ReachRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notice_reach"

    var host: String
    var gathered: Bool
    var before: String?
    var reached: Date?
    var full: Bool

    init(_ reach: NoticeReach) {
        host = reach.host
        gathered = reach.gathered
        before = reach.before
        reached = reach.reached
        full = reach.full
    }
}

/// Somebody a line names, as `notice.people` writes them: a JSON array of these, newest first.
private struct PersonRow: Codable {
    struct Emoji: Codable {
        var shortcode: String
        var url: URL
        var staticURL: URL?
    }

    var handle: String
    var name: String
    var avatarURL: URL?
    var emojis: [Emoji]?

    init(_ person: NoticePerson) {
        handle = person.handle
        name = person.name
        avatarURL = person.avatarURL
        emojis = person.emojis.isEmpty ? nil : person.emojis.map {
            Emoji(shortcode: $0.shortcode, url: $0.url, staticURL: $0.staticURL)
        }
    }

    var person: NoticePerson {
        NoticePerson(
            handle: handle, name: name, avatarURL: avatarURL,
            emojis: (emojis ?? []).map { CustomEmoji(shortcode: $0.shortcode, url: $0.url, staticURL: $0.staticURL) }
        )
    }
}

/// One line as the `notice` table holds it, named as its source names it: which read brought it
/// (`handle`) and the notice's id or the group's key (`name`).
private struct NoticeRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notice"

    var host: String
    var handle: String
    var name: String
    var place: Int
    var kind: String
    var at: Date
    var newestID: String
    var oldestID: String
    var count: Int
    var people: String
    var post: String?

    enum CodingKeys: String, CodingKey {
        case host, handle, name, place, kind, at, count, people, post
        case newestID = "newest_id"
        case oldestID = "oldest_id"
    }

    init(_ notice: Notice, host: String, place: Int) {
        self.host = host
        switch notice.handle {
        case .one(let id): (handle, name) = ("one", id)
        case .gathered(let key): (handle, name) = ("gathered", key)
        }
        self.place = place
        kind = notice.kind.type
        at = notice.at
        newestID = notice.newestID
        oldestID = notice.oldestID
        count = notice.count
        let written = (try? JSONEncoder().encode(notice.people.map(PersonRow.init))) ?? Data("[]".utf8)
        people = String(decoding: written, as: UTF8.self)
        post = CarriedPost.text(notice.post)
    }

    /// **Read leniently but for its name.** People that will not read are nobody named, and a
    /// post that will not read is a line without what it was about — a notice all the same.
    /// A line named by a read this build does not know cannot be dismissed by name, and is not
    /// read: the next read of its source says it again.
    func notice(from source: Source) -> Notice? {
        let named: Notice.Handle
        switch handle {
        case "one": named = .one(id: name)
        case "gathered": named = .gathered(key: name)
        default: return nil
        }
        let rows = (try? JSONDecoder().decode([PersonRow].self, from: Data(people.utf8))) ?? []
        return Notice(
            source: source, handle: named, kind: Notice.Kind(type: kind), people: rows.map(\.person),
            count: count, post: CarriedPost.note(post, from: source), at: at, newestID: newestID, oldestID: oldestID
        )
    }
}

extension StoreFile {
    /// Every reach held, in host order, each with its lines newest first as its source handed
    /// them over. **Only of a source among `sources`**: a notice names its source as a post
    /// does, and one of a host no longer here is nothing a page could draw or dismiss.
    public func loadNotices(of sources: [Source]) throws -> [NoticeReach] {
        let byHost = Dictionary(sources.map { ($0.host, $0) }, uniquingKeysWith: { first, _ in first })
        return try db.read { db in
            let lines = Dictionary(grouping: try NoticeRecord.order(Column("place")).fetchAll(db), by: \.host)
            return try ReachRecord.order(Column("host")).fetchAll(db).compactMap { reach in
                guard let source = byHost[reach.host] else { return nil }
                return NoticeReach(
                    host: reach.host, notices: (lines[reach.host] ?? []).compactMap { $0.notice(from: source) },
                    before: reach.before, reached: reach.reached, gathered: reach.gathered, full: reach.full
                )
            }
        }
    }

    /// Writes `reaches` in the place of every notice held, both tables in one transaction, and
    /// touches no other table. A line dismissed, let go with its sign-in, or struck of the post
    /// it carried is not left in the file — the connection zeroes what it frees
    /// (`secure_delete`, #292).
    public func save(notices reaches: [NoticeReach]) async throws {
        try await db.write { db in try Self.write(notices: reaches, in: db) }
    }

    /// `save(notices:)` inside a transaction of the caller's: what a read back writes with the
    /// items it lays in, so no crash leaves the last sign-in's notices beside the new store.
    static func write(notices reaches: [NoticeReach], in db: Database) throws {
        try NoticeRecord.deleteAll(db)
        try ReachRecord.deleteAll(db)
        for reach in reaches {
            try ReachRecord(reach).insert(db, onConflict: .replace)
            for (place, notice) in reach.notices.enumerated() {
                // A line named twice is written once, the later in its place: one line must
                // not be what stops every notice being saved.
                try NoticeRecord(notice, host: reach.host, place: place).insert(db, onConflict: .replace)
            }
        }
    }

    /// Lets every notice go: what a read back does to the store a package carried before that
    /// store becomes this device's. Notices were said to one sign-in on one device; a take-away
    /// writes none, and one that came all the same would be shown to whoever reads it back.
    func dropNotices() throws {
        try db.write { db in
            _ = try NoticeRecord.deleteAll(db)
            _ = try ReachRecord.deleteAll(db)
        }
    }
}
