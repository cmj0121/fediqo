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

    enum CodingKeys: String, CodingKey {
        case id, host, body, audience, answers, root, standing, writer
        case pressedAt = "pressed_at"
        case writerID = "writer_id"
        case askedAt = "asked_at"
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
    }

    /// **A standing this build does not know is read as asked** — the careful word: it may have
    /// landed, and is never sent again by itself. A reach it does not know is the narrowest, for
    /// the same care. A row with no name of its own cannot be sent under one, and is not read.
    var unsent: Unsent? {
        guard let id = UUID(uuidString: id) else { return nil }
        return Unsent(
            id: id, host: host, text: body, audience: Audience(rawValue: audience) ?? .mentioned,
            answers: answers.flatMap(NoteKey.init(rowID:)), root: root.flatMap(NoteKey.init(rowID:)),
            pressedAt: pressedAt, standing: Unsent.Standing(rawValue: standing) ?? .asked,
            writerID: writerID, writer: writer, askedAt: askedAt
        )
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
