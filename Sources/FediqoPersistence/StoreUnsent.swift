import FediqoCore
import Foundation
import GRDB

// The texts the person pressed to send (`Unsent`), in a table of their own beside the items:
// written as a part of their own, so holding one rewrites no post.

/// One `Unsent` as the `unsent` table holds it. The posts it answers and was written under are
/// named as a row is (`NoteKey.rowID`), the host with the name.
private struct UnsentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "unsent"

    var id: String
    var host: String
    var body: String
    var audience: String
    var answers: String?
    var root: String?
    var pressedAt: Date
    var standing: String
    var writerID: String?
    var writer: String?
    var askedAt: Date?
    var spoiler: String?
    var language: String?
    var sensitive: Bool?
    /// JSON of the files, or NULL where there are none. A cell that will not read is no media.
    var media: String?
    /// JSON of the poll, or NULL where there is none. A cell that will not read is no poll.
    var poll: String?
    /// The post a change is of (#332), as its row's name and its source's id for it, joined by a
    /// unit separator; NULL for a post or an answer. A cell that will not read is a text that
    /// is not read at all: sent as a post, a change would be a second post.
    var changes: String?
    /// When its source is to send it (#333); NULL for a post sent at once.
    var at: Date?

    enum CodingKeys: String, CodingKey {
        case id, host, body, audience, answers, root, standing, writer
        case pressedAt = "pressed_at"
        case writerID = "writer_id"
        case askedAt = "asked_at"
        case spoiler, language, sensitive, media, poll, changes
        case at = "send_at"
    }

    init(_ text: Unsent) {
        id = text.id.uuidString
        host = text.host
        body = text.text
        audience = text.audience.rawValue
        answers = text.answers?.rowID
        root = text.root?.rowID
        pressedAt = text.pressedAt
        standing = text.standing.rawValue
        writerID = text.writerID
        writer = text.writer
        askedAt = text.askedAt
        spoiler = text.spoiler
        language = text.language
        sensitive = text.sensitive
        media = UnsentMediaRow.text(text.media)
        poll = text.poll.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        changes = text.changes.map { $0.item.rowID + Self.separator + $0.statusID }
        at = text.at
    }

    private static let separator = "\u{1f}"

    /// What `changes` names, or nothing where it is NULL; `.none` inside where it will not read.
    private var changed: Unsent.Changes?? {
        guard let changes else { return .some(nil) }
        let parts = changes.components(separatedBy: Self.separator)
        guard parts.count == 2, let item = NoteKey(rowID: parts[0]), !parts[1].isEmpty else { return nil }
        return .some(Unsent.Changes(item: item, statusID: parts[1]))
    }

    /// **A standing this build does not know is read as asked** — the careful word: it may have
    /// landed, and is never sent again by itself. A reach it does not know is the narrowest, for
    /// the same care. A row with no name of its own cannot be sent under one, and is not read.
    var unsent: Unsent? {
        guard let id = UUID(uuidString: id), let changed else { return nil }
        return Unsent(
            id: id, host: host, text: body, audience: Audience(rawValue: audience) ?? .mentioned,
            answers: answers.flatMap(NoteKey.init(rowID:)), root: root.flatMap(NoteKey.init(rowID:)),
            pressedAt: pressedAt, standing: Unsent.Standing(rawValue: standing) ?? .asked,
            writerID: writerID, writer: writer, askedAt: askedAt,
            spoiler: spoiler, language: language, sensitive: sensitive, media: UnsentMediaRow.list(media),
            poll: poll.flatMap { try? JSONDecoder().decode(NewPoll.self, from: Data($0.utf8)) },
            changes: changed, at: at
        )
    }
}

/// The files of one unsent text, as the `media` cell holds them. Bytes are base64. A row whose
/// bytes will not read is left out; a cell that is not the array is no media, and the text is
/// still read.
private enum UnsentMediaRow {
    struct Row: Codable {
        var id: String
        var bytes: String
        var mime: String
        var name: String
        var description: String
        var remoteID: String?
    }

    static func text(_ media: [UnsentMedia]) -> String? {
        guard !media.isEmpty else { return nil }
        let rows = media.map {
            Row(
                id: $0.id.uuidString, bytes: $0.bytes.base64EncodedString(), mime: $0.mime,
                name: $0.name, description: $0.description, remoteID: $0.remoteID
            )
        }
        guard let data = try? JSONEncoder().encode(rows) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func list(_ text: String?) -> [UnsentMedia] {
        guard let text, let data = text.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: data)
        else { return [] }
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row.id), let bytes = Data(base64Encoded: row.bytes) else { return nil }
            return UnsentMedia(
                id: id, bytes: bytes, mime: row.mime, name: row.name, description: row.description,
                remoteID: row.remoteID
            )
        }
    }
}

extension StoreFile {
    /// Every text held, in the order pressed.
    public func loadUnsent() throws -> [Unsent] {
        try db.read { db in
            try UnsentRecord.order(Column("pressed_at"), Column.rowID).fetchAll(db).compactMap(\.unsent)
        }
    }

    /// Writes `texts` in the place of every text held, in one transaction, and touches no other
    /// table: a handful of rows, whatever the store holds. A text sent or discarded is not left
    /// in the file — the connection zeroes what it frees (`secure_delete`, #292).
    public func save(unsent texts: [Unsent]) async throws {
        try await db.write { db in
            try UnsentRecord.deleteAll(db)
            for text in texts {
                try UnsentRecord(text).insert(db)
            }
        }
    }

    /// Lets every text go: what a read back does to the store a package carried before that
    /// store becomes this device's. A text is sent from the device it was written on, and one
    /// that rode in a package would be sent from two.
    func dropUnsent() throws {
        try db.write { db in _ = try UnsentRecord.deleteAll(db) }
    }
}
