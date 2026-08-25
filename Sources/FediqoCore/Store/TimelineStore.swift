import Foundation
import GRDB

/// The reader's own timelines, in and out of the store.
///
/// Definitions live here rather than in `Preferences` because they are rows and behave like
/// rows: they point at a base source and at an account, they are ordered, and their rules
/// hang off them. `servers.selected_at` and `servers.position` — the other choices a reader
/// makes — are already kept the same way.
extension LocalStore {
    /// Every timeline the reader has, left to right, each with its rules.
    ///
    /// Two statements rather than a join: a timeline with no rules is the common one, and a
    /// join would hand back a row per rule to be folded again on this side.
    public func timelines() async throws -> [Timeline] {
        try await read { db in
            let rules = try Row.fetchAll(db, sql: """
                SELECT timeline_id, kind, value, negate FROM timeline_filters ORDER BY rowid
                """).reduce(into: [String: [TimelineFilter]]()) { filters, row in
                guard let kind = TimelineFilter.Kind(rawValue: row["kind"]) else { return }
                filters[row["timeline_id"], default: []].append(
                    TimelineFilter(kind: kind, value: row["value"], negate: (row["negate"] as Int) == 1))
            }
            return try Row.fetchAll(db, sql: """
                SELECT id, name, summary, feed, author_id, template, position
                FROM timelines ORDER BY position, id
                """).compactMap { row in
                // A row naming a base source this build does not know is a row from a later
                // version of the app, opened by an older one. It is left where it is and left
                // out of the answer: dropping it would delete somebody's timeline for the
                // crime of being newer than the code reading it.
                guard let source = BaseSource(rawValue: row["feed"]) else { return nil }
                let id: String = row["id"]
                return Timeline(id: id, name: row["name"], summary: row["summary"],
                                source: source, account: row["author_id"],
                                template: row["template"], position: row["position"],
                                filters: rules[id] ?? [])
            }
        }
    }

    /// One timeline written down, rules and all — new or changed, the same statement either
    /// way. The rules are rewritten rather than merged: a rule the reader took off is a rule
    /// that has to be gone, and there is no such thing as a half-applied set of them.
    public func save(_ timeline: Timeline, now: Date = Date()) async throws {
        let ms = Self.milliseconds(now)
        let filters = timeline.filters
        try await write { db in
            try db.execute(sql: """
                INSERT INTO timelines (id, name, summary, feed, author_id, template, position, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    name = excluded.name, summary = excluded.summary, feed = excluded.feed,
                    author_id = excluded.author_id, position = excluded.position,
                    updated_at = excluded.created_at
                """, arguments: [timeline.id, timeline.name, timeline.summary,
                                 timeline.source.rawValue, timeline.account, timeline.template,
                                 timeline.position, ms])
            try db.execute(sql: "DELETE FROM timeline_filters WHERE timeline_id = ?", arguments: [timeline.id])
            for filter in filters {
                try db.execute(sql: """
                    INSERT INTO timeline_filters (timeline_id, kind, value, negate, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (timeline_id, kind, value) DO UPDATE SET
                        negate = excluded.negate, updated_at = excluded.created_at
                    """, arguments: [timeline.id, filter.kind.rawValue, filter.value,
                                     filter.negate ? 1 : 0, ms])
            }
        }
    }

    /// A timeline the reader deleted. Its rules go with it — `ON DELETE CASCADE` — and not one
    /// post moves: a timeline was never where posts were kept.
    public func deleteTimeline(_ id: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM timelines WHERE id = ?", arguments: [id])
        }
    }

    /// The order the reader put them in, written down in one transaction so that a list half
    /// reordered never reaches the screen.
    public func reorderTimelines(_ ids: [String], now: Date = Date()) async throws {
        let ms = Self.milliseconds(now)
        try await write { db in
            for (position, id) in ids.enumerated() {
                try db.execute(sql: """
                    UPDATE timelines SET position = ?, updated_at = ?
                    WHERE id = ? AND position IS NOT ?
                    """, arguments: [position, ms, id, position])
            }
        }
    }

    /// The words an older build wrote into the rows it seeded, cleared — once per install.
    ///
    /// A seeded row is one whose `id` is its template's name: everything the reader makes gets
    /// an id of its own, so the two cannot be confused. Every one of them is cleared, without
    /// asking whether the words in it look like the app's, because **nothing about the row can
    /// answer that.** `updated_at` was the obvious candidate and it is wrong: reordering the
    /// row stamps it too, so "written to" covers a reader who dragged a tab as much as one who
    /// renamed it. Comparing the stored words against the app's own is the other candidate and
    /// it is also wrong: the app's words change between versions, so a sentence this release
    /// rewrote would stop being recognised and freeze in the older wording.
    ///
    /// So it clears, and the caller runs it once and remembers that it has. What it costs is
    /// the one case where somebody renamed a shipped timeline in a build that seeded words:
    /// their name goes and the tab is said in the app's words again. That is a build of this
    /// feature before it was released, and the alternative is every reader whose language is
    /// not English reading English tabs for ever.
    public func clearSeededWording(now: Date = Date()) async throws {
        let ms = Self.milliseconds(now)
        try await write { db in
            try db.execute(sql: """
                UPDATE timelines SET name = '', summary = '', updated_at = ?
                WHERE id = template AND (name <> '' OR summary <> '')
                """, arguments: [ms])
        }
    }

    /// The timelines a fresh install starts with, written once and never again.
    ///
    /// It writes nothing where anything is already there, and that is the whole of what makes
    /// the shipped three ordinary rows: once they exist they are the reader's, and deleting
    /// one is deleting it — not asking for it back on the next launch.
    @discardableResult
    public func seedTimelines(_ seeds: [Timeline], now: Date = Date()) async throws -> Bool {
        let existing = try await read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM timelines") ?? 0 }
        guard existing == 0 else { return false }
        for seed in seeds { try await save(seed, now: now) }
        return true
    }
}
