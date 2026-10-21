import Foundation
import Testing
@testable import FediqoCore

/// #333: what Fediqo believes a Mastodon says of a post sent later, held against the real one
/// this checkout brings up (`make servers`, Mastodon 4.6.6) — the table in
/// `MastodonLaterCaptures`. Each check goes through this app's own `MastodonWrite` and beside it
/// asks the server plainly for what the belief rests on. That a waiting post goes out at its time
/// is the worker's, and `MastodonWorkerSaysTests` asks it.
///
/// **Passed over where the servers are not up.** **This makes waiting posts, and lets go of every
/// one it made however the check ends**; a waiting post's letting go is not held to the thirty
/// takings back in half an hour a post's is. The one post a past time publishes is taken back.
@Suite("What a Mastodon says of a post sent later", .enabled(if: LocalServers.requested), .serialized)
struct MastodonLaterSaysTests {
    private static let host = LocalServers.mastodon
    private static let source = Source(host: host, kind: .mastodon)

    private struct Answer {
        let status: Int
        let body: Data
        var object: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    private static func door(_ token: String) throws -> MastodonAuthorized {
        let tokens = MemoryMastodonTokens()
        let held = MastodonToken(host: host, accessToken: token, clientID: "x", clientSecret: "x")
        try tokens.save(held)
        return MastodonAuthorized(token: held, sender: try LocalHTTP.client(), store: tokens)
    }

    private static func ask(_ path: String, as token: String, _ method: String = "GET", form: [(String, String)]? = nil) async throws -> Answer {
        guard let url = URL(string: "https://\(host)\(path)") else { throw LocalHTTPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form { request.setForm(form) }
        let (body, response) = try await LocalHTTP.client().send(request)
        return Answer(status: response.statusCode, body: body)
    }

    private static func writer() throws -> (write: MastodonWrite, store: ItemStore, writer: String) {
        let seeded = try LocalServers.seeded()
        let store = ItemStore(sources: [source], notes: [])
        return (MastodonWrite(door: try door(seeded.writer), store: store), store, seeded.writer)
    }

    /// Runs `body` with a list it adds the ids of the waiting posts it makes to, and lets each go
    /// after, whatever became of it.
    private static func waiting(as token: String, _ body: (inout [String]) async throws -> Void) async throws {
        var made: [String] = []
        let thrown: (any Error)?
        do {
            try await body(&made)
            thrown = nil
        } catch {
            thrown = error
        }
        for id in made { _ = try? await ask("/api/v1/scheduled_statuses/\(id)", as: token, "DELETE") }
        if let thrown { throw thrown }
    }

    @Test("A post given a time an hour ahead waits, as the source keeps it — words, cover, covered, language, who may read it, its file and description, its poll, what it answers — and nothing of it is held here; it is moved by its time alone, refused too near in the source's words, and let go")
    func aPostWaits() async throws {
        try await LocalServers.requireHealthy()
        let (write, store, writer) = try Self.writer()
        let seeded = try LocalServers.seeded()
        try await Self.waiting(as: writer) { made in
            let file = try await write.upload(
                bytes: try #require(Data(base64Encoded: MastodonPartsCaptures.pixel)), name: "a.png", type: "image/png",
                description: "alt one"
            )
            let at = MastodonLater.earliest().addingTimeInterval(3600)
            let post = try await write.postLater(
                "later with media", visibility: .unlisted, at: at, key: UUID(), spoiler: "cw", language: "de",
                sensitive: true, mediaIDs: [file]
            )
            made.append(post.id)
            #expect(post.at == at && post.text == "later with media" && post.spoiler == "cw" && post.sensitive)
            #expect(post.language == "de" && post.audience == .unlisted && post.media.map(\.description) == ["alt one"])

            let poll = NewPoll(choices: ["A", "B"], multiple: true, runs: 3600)
            let polled = try await write.postLater("later with poll", visibility: .followers, at: at, poll: poll)
            made.append(polled.id)
            #expect(polled.poll == poll && polled.audience == .followers)
            let answering = seeded.seeded.plain
            let answer = try await write.postLater("later answer", visibility: .everyone, at: at, answering: answering)
            made.append(answer.id)
            #expect(answer.answering == answering, "every digit of the id")

            let listed = try await write.waiting()
            #expect(Set(made).isSubset(of: listed.posts.map(\.id)) && listed.posts.first { $0.id == post.id } == post)
            #expect(await store.all().isEmpty, "nothing waiting is held here")

            // Moved by its time alone: words beside it are passed over.
            let later = at.addingTimeInterval(1800)
            let moved = try await write.move(post, to: later)
            #expect(moved.at == later && moved.text == post.text)
            let words = try await Self.ask("/api/v1/scheduled_statuses/\(post.id)", as: writer, "PUT", form: [
                ("scheduled_at", MastodonLater.written(later.addingTimeInterval(60))), ("status", "other words"),
            ])
            #expect(words.status == 200 && (words.object["params"] as? [String: Any])?["text"] as? String == "later with media")
            await #expect(throws: MastodonLaterError.self) { _ = try await write.move(post, to: Date()) }
            let near = try await Self.ask("/api/v1/scheduled_statuses/\(post.id)", as: writer, "PUT", form: [
                ("scheduled_at", MastodonLater.written(Date().addingTimeInterval(120))),
            ])
            #expect(near.status == 422 && near.text == MastodonLaterCaptures.tooSoon)

            try await write.withdraw(post)
            try await write.withdraw(post)
            #expect(try await Self.ask("/api/v1/scheduled_statuses/\(post.id)", as: writer).status == 404)
            #expect(await store.all().isEmpty)
        }
    }

    @Test("What waits is read on by the id cursor to its end, newest made first, none twice")
    func readOn() async throws {
        try await LocalServers.requireHealthy()
        let (write, _, writer) = try Self.writer()
        try await Self.waiting(as: writer) { made in
            let at = MastodonLater.earliest().addingTimeInterval(7200)
            for n in 0..<3 {
                made.append(try await write.postLater("read on \(n)", visibility: .unlisted, at: at).id)
            }
            var seen: [String] = []
            var next: String?
            repeat {
                let stretch = try await write.waiting(after: next, limit: 2)
                #expect(stretch.posts.count <= 2)
                seen += stretch.posts.map(\.id)
                next = stretch.next
            } while next != nil
            #expect(Set(seen).count == seen.count, "none twice")
            #expect(seen.filter(made.contains) == made.reversed(), "newest made first, to the end")
        }
    }

    @Test("A time already passed is published at once, not refused; four minutes ahead is refused in the source's words; the same post again under its key makes no second; a day holding 25 takes no 26th, nor a move onto it; a sign-in that only reads may list and not move")
    func refusals() async throws {
        try await LocalServers.requireHealthy()
        let (write, _, writer) = try Self.writer()
        let reading = try #require(try LocalServers.seeded().notices?.reading.token)
        try await Self.waiting(as: writer) { made in
            let past = try await Self.ask("/api/v1/statuses", as: writer, "POST", form: [
                ("status", "past \(UUID().uuidString.prefix(6))"), ("visibility", "unlisted"),
                ("scheduled_at", MastodonLater.written(Date().addingTimeInterval(-600))),
            ])
            #expect(past.status == 200 && past.object["content"] is String && past.object["scheduled_at"] == nil, "published at once")
            if let id = past.object["id"] as? String { _ = try? await Self.ask("/api/v1/statuses/\(id)", as: writer, "DELETE") }

            let near = try await Self.ask("/api/v1/statuses", as: writer, "POST", form: [
                ("status", "near"), ("scheduled_at", MastodonLater.written(Date().addingTimeInterval(240))),
            ])
            #expect(near.status == 422 && near.text == MastodonLaterCaptures.tooSoon)
            await #expect(throws: MastodonLaterError.self) {
                _ = try await write.postLater("near", visibility: .everyone, at: Date().addingTimeInterval(240))
            }

            let key = UUID()
            let at = MastodonLater.earliest().addingTimeInterval(3600)
            let once = try await write.postLater("keyed", visibility: .unlisted, at: at, key: key)
            made.append(once.id)
            await #expect(throws: MastodonLaterError.mayHaveBeenMade) {
                _ = try await write.postLater("keyed", visibility: .unlisted, at: at, key: key)
            }
            #expect(try await write.waiting().posts.filter { $0.text == "keyed" }.map(\.id) == [once.id], "no second")

            // A day far enough ahead to hold nothing else: its 25, then a 26th.
            let calendar = Calendar(identifier: .gregorian)
            var utc = calendar
            utc.timeZone = TimeZone(identifier: "UTC")!
            let day = utc.startOfDay(for: Date().addingTimeInterval(9 * 86_400)).addingTimeInterval(12 * 3600)
            for n in 0..<MastodonLater.perDay {
                made.append(try await write.postLater("day \(n)", visibility: .unlisted, at: day.addingTimeInterval(Double(n) * 60)).id)
            }
            // The source's own words, in the language it answers this machine in; asked in English,
            // the ones captured.
            await #expect(throws: MastodonUnprocessable.self) {
                _ = try await write.postLater("day 26", visibility: .unlisted, at: day.addingTimeInterval(1800))
            }
            let full = try await Self.ask("/api/v1/statuses", as: writer, "POST", form: [
                ("status", "day 26"), ("scheduled_at", MastodonLater.written(day.addingTimeInterval(1800))),
            ])
            #expect(full.status == 422 && full.text == MastodonLaterCaptures.dayFull)
            let mover = try await write.postLater("mover", visibility: .unlisted, at: day.addingTimeInterval(86_400))
            made.append(mover.id)
            await #expect(throws: MastodonUnprocessable.self) {
                _ = try await write.move(mover, to: day.addingTimeInterval(3600))
            }

            let reader = MastodonWrite(door: try Self.door(reading), store: ItemStore(sources: [Self.source], notes: []))
            #expect(try await reader.waiting().posts.contains { $0.id == mover.id })
            await #expect(throws: MastodonScopeError.outside) { _ = try await reader.move(mover, to: day.addingTimeInterval(90_000)) }
        }
    }

    @Test("A waiting post changed is a new one made first and the old let go after: the new waits with the change, the old is gone, the old's file is the new one's from the moment it is made and stays when the old is let go, and nothing is held here")
    func aChange() async throws {
        try await LocalServers.requireHealthy()
        let (write, store, writer) = try Self.writer()
        try await Self.waiting(as: writer) { made in
            let at = MastodonLater.earliest().addingTimeInterval(3600)
            let file = try await write.upload(
                bytes: try #require(Data(base64Encoded: MastodonPartsCaptures.pixel)), name: "a.png", type: "image/png",
                description: "kept"
            )
            let old = try await write.postLater("before the change", visibility: .unlisted, at: at, mediaIDs: [file])
            made.append(old.id)
            let changed = try await write.change(
                old, to: "after the change", visibility: .everyone, at: at.addingTimeInterval(600), mediaIDs: [file]
            )
            let new = try #require(changed.new)
            made.append(new.id)
            #expect(!changed.oldStays && new.id != old.id && new.text == "after the change" && new.audience == .everyone)
            #expect(try await Self.ask("/api/v1/scheduled_statuses/\(old.id)", as: writer).status == 404)
            #expect(new.media.map(\.id) == [file] && new.media.map(\.description) == ["kept"])
            let listed = try await write.waiting().posts.first { $0.id == new.id }
            #expect(listed?.media.map(\.id) == [file], "the file stays with the new one once the old is let go")

            // Made beside the old, the file is the new one's from that moment: the old waits without it.
            let other = try await write.postLater("a second", visibility: .unlisted, at: at, mediaIDs: [file])
            made.append(other.id)
            let moved = try await write.waiting().posts.first { $0.id == new.id }
            #expect(moved?.media.isEmpty == true && other.media.map(\.id) == [file])
            #expect(await store.all().isEmpty)
        }
    }
}
