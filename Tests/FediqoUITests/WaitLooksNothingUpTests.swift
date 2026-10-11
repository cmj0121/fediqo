import Foundation
import Observation
import os
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A post held without the id its source gave it is looked up there by its address — which has
/// that source go and fetch it from the server it was written on. That is for an act of the
/// reader's: opening the thread, asking again, `r`. The wait this device keeps never asks for it.
@MainActor
@Suite("The wait looks no post up at another server")
struct WaitLooksNothingUpTests {
    private static let host = "one.example"
    private static let search = "/api/v2/search"
    private static let post = "/api/v1/statuses/9"
    private static let thread = "/api/v1/statuses/9/context"

    private static func status(_ id: String, answering parent: String? = nil, words: String? = nil) -> String {
        let reply = parent.map { #""in_reply_to_id":"\#($0)","# } ?? ""
        return """
        {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)",\(reply)
         "created_at":"2024-01-01T00:00:00.000Z","content":"<p>\(words ?? "answer \(id)")</p>",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    private static func context(_ ids: [String]) -> String {
        #"{"ancestors":[],"descendants":["# + ids.map { status($0, answering: "9") }.joined(separator: ",") + "]}"
    }

    private static let found = #"{"statuses":["# + status("9") + "]}"

    /// The post, held as a row kept before ids were: by its address alone unless `statusID` is given.
    private static func held(statusID: String? = nil, words: String = "the post") -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/9", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@\(host)", body: words,
            postedAt: Date(timeIntervalSince1970: 0), categories: [.public], statusID: statusID
        )
    }

    /// Signed in to the one source, holding `note`, with a record of its own.
    private func shell(_ door: Door, holding note: Note) async throws -> (ShellSession, DummyItem) {
        let tokens = MemoryMastodonTokens()
        try tokens.save(MastodonToken(host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s"))
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon))
        await store.ingest([note])
        let http = FixtureHTTP()
        let session = ShellSession(
            http: http, store: store, mastodon: MastodonSessions(tokens: tokens, sender: door),
            posts: ForumPosts(http: http)
        )
        let work = SourceWork()
        session.work = work
        session.mastodon.work = work
        await session.reloadFromStore()
        return (session, DummyItem(note))
    }

    private static func bodies(_ session: ShellSession, _ item: DummyItem) -> [String] {
        session.conversations.conversation(around: item).descendants.map(\.item.body)
    }

    /// How many times the record says the thread's source was asked for a conversation.
    private static func recorded(_ session: ShellSession) -> Int {
        session.work.record.filter { $0.purpose == .conversation && $0.source == host }.count
    }

    /// One pass of the wait: slept once, asked, and the loop let go at the next sleep.
    private func oneWait(_ session: ShellSession) async {
        var waits = 0
        await session.reload.keepAsking(every: .seconds(60), in: session) { _ in
            waits += 1
            if waits > 1 { throw CancellationError() }
        }
    }

    // MARK: - The wait

    @Test("A thread whose post could not be looked up as it opened is not looked up by the wait, and stays as it was")
    func theWaitAsksNobodyForAnId() async throws {
        // The look-up does not answer, so the thread opens saying it could not be had — the one
        // standing the wait asks again by itself.
        let door = Door([:])
        let (session, item) = try await shell(door, holding: Self.held())
        await session.reload.opened(item, in: session)
        #expect(await door.lookUps == 1, "opening it looks the post up")
        let standing = session.conversations.standing(of: item.id)
        #expect(standing == .absent(.unreachable))
        let further = session.conversations.further(of: item.id)
        let recorded = Self.recorded(session)

        // By now the source would answer: only nobody may ask it.
        await door.answer(Self.search, with: Self.found)
        await door.answer(Self.thread, with: Self.context(["10"]))
        // Not even on its way for a moment: nothing about the thread is so much as written over.
        let touched = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = session.conversations.standing(of: item.id)
            _ = session.conversations.further(of: item.id)
        } onChange: {
            touched.withLock { $0 = true }
        }
        await oneWait(session)
        #expect(touched.withLock { $0 } == false, "the wait began a read of a post it cannot name")
        #expect(await door.lookUps == 1, "the wait looked it up")
        #expect(await door.paths.contains(Self.thread) == false)
        #expect(Self.recorded(session) == recorded, "the record holds an ask of the wait's")
        #expect(session.conversations.standing(of: item.id) == standing)
        #expect(session.conversations.further(of: item.id) == further)
        #expect(Self.bodies(session, item).isEmpty)
        #expect(session.reload.failures[.renew] == nil)
    }

    @Test("A thread opened by looking its post up is renewed on the wait by the id that found, and not looked up again")
    func theWaitRenewsByWhatOpeningFound() async throws {
        let door = Door([Self.search: Self.found, Self.thread: Self.context(["10"])])
        let (session, item) = try await shell(door, holding: Self.held())
        await session.reload.opened(item, in: session)
        #expect(await door.lookUps == 1)
        #expect(Self.bodies(session, item) == ["answer 10"])
        #expect(session.notes.first { $0.key.rowID == item.id }?.statusID == nil, "nothing new is written down")
        let recorded = Self.recorded(session)

        await door.answer(Self.thread, with: Self.context(["10", "11"]))
        await oneWait(session)
        #expect(await door.lookUps == 1, "the wait looked it up")
        #expect(Self.bodies(session, item) == ["answer 10", "answer 11"])
        #expect(Self.recorded(session) == recorded + 1, "one ask: the thread, by its id")
        #expect(session.conversations.further(of: item.id) == .end)
    }

    @Test("A lone post opened by looking it up is renewed on the wait too")
    func aLonePostIsRenewedByWhatOpeningFound() async throws {
        let door = Door([Self.search: Self.found, Self.thread: Self.context([])])
        let (session, item) = try await shell(door, holding: Self.held())
        await session.reload.opened(item, in: session)
        #expect(session.conversations.standing(of: item.id) == ShellConversationStanding.none)

        await door.answer(Self.thread, with: Self.context(["10"]))
        await oneWait(session)
        #expect(await door.lookUps == 1, "the wait looked it up")
        #expect(Self.bodies(session, item) == ["answer 10"])
    }

    @Test("A post held with its id is renewed on the wait as it always was")
    func theWaitRenewsWhatItCanName() async throws {
        let door = Door([Self.thread: Self.context(["10"])])
        let (session, item) = try await shell(door, holding: Self.held(statusID: "9"))
        await session.reload.opened(item, in: session)
        await door.answer(Self.thread, with: Self.context(["10", "11"]))
        await oneWait(session)
        #expect(Self.bodies(session, item) == ["answer 10", "answer 11"])
        #expect(await door.lookUps == 0)
    }

    @Test("A thread let go of while open, its post not named, is left as it was by the wait: nothing asked, nothing said")
    func aThreadLetGoOfIsLeftAsItWas() async throws {
        let door = Door([Self.search: Self.found, Self.thread: Self.context(["10"])])
        let (session, item) = try await shell(door, holding: Self.held())
        await session.reload.opened(item, in: session)
        session.conversations.forget(host: Self.host)
        let asked = await door.threadAsks

        await oneWait(session)
        #expect(session.conversations.standing(of: item.id) == .unasked)
        #expect(session.conversations.further(of: item.id) == nil)
        #expect(await door.lookUps == 1, "the wait looked it up")
        #expect(await door.threadAsks == asked, "the wait read the thread by an id let go of")
    }

    @Test("Every thread let go of at once lets go of what was looked up too")
    func clearingLetsGoOfWhatWasLookedUp() async throws {
        let door = Door([Self.search: Self.found, Self.thread: Self.context(["10"])])
        let (session, item) = try await shell(door, holding: Self.held())
        await session.reload.opened(item, in: session)
        session.conversations.clear()
        let asked = await door.threadAsks

        await oneWait(session)
        #expect(session.conversations.standing(of: item.id) == .unasked)
        #expect(await door.threadAsks == asked, "the wait read the thread by an id let go of")
    }

    @Test("Asked again by the reader and no longer found, a post is not read on the wait by the id found before")
    func whatIsNoLongerFoundIsNotKept() async throws {
        let door = Door([Self.search: Self.found, Self.thread: Self.context(["10"])])
        let (session, item) = try await shell(door, holding: Self.held())
        await session.reload.opened(item, in: session)
        await door.answer(Self.search, with: #"{"statuses":[]}"#)
        await session.conversations.again(item, in: session)
        #expect(session.conversations.further(of: item.id) == .failed(.unfindable))
        let asked = await door.threadAsks

        await oneWait(session)
        #expect(await door.threadAsks == asked, "the wait read the thread by an id gone stale")
        #expect(session.conversations.further(of: item.id) == .failed(.unfindable))
        #expect(Self.bodies(session, item) == ["answer 10"])
    }

    // MARK: - The reader's own acts

    @Test("Opening a thread, asking for it again and r each look the post up, as they did")
    func theReaderStillLooksItUp() async throws {
        let door = Door([
            Self.search: Self.found, Self.post: Self.status("9", words: "edited"),
            Self.thread: Self.context(["10"]),
        ])
        let (session, item) = try await shell(door, holding: Self.held())
        await session.reload.opened(item, in: session)
        #expect(await door.lookUps == 1, "opening")
        await session.conversations.again(item, in: session)
        #expect(await door.lookUps == 2, "the ask-again press")
        #expect(Self.bodies(session, item) == ["answer 10"])
        await session.reload.thread(item, in: session)
        #expect(await door.lookUps == 3, "r")
        #expect(session.notes.first { $0.key.rowID == item.id }?.statusID == "9", "r keeps what it found, as it did")
    }

    @Test("A quote post kept before quotes were read is still looked up as its thread opens")
    func aQuoteReadAtOpenStillLooksItUp() async throws {
        let door = Door([
            Self.search: Self.found, Self.post: Self.status("9", words: "read again"),
            Self.thread: Self.context([]),
        ])
        let note = Self.held(words: "RE: https://two.example/@bob/5 what they said")
        let (session, item) = try await shell(door, holding: note)
        await session.reload.opened(item, in: session)
        #expect(await door.lookUps == 2, "once for the thread, once for the post read again")
        #expect(await door.paths.contains(Self.post))
        let kept = await session.store.all().first { $0.key.rowID == item.id }
        #expect(kept?.body == "read again")
    }

    @Test("A thread whose look-up the source refuses for want of a scope says it was refused")
    func aScopeRefusalIsARefusal() async throws {
        let door = Door(
            [Self.search: #"{"error":"This action is outside the authorized scopes"}"#], status: [Self.search: 403]
        )
        let (session, item) = try await shell(door, holding: Self.held())
        await session.reload.opened(item, in: session)
        #expect(session.conversations.standing(of: item.id) == .absent(.refused))
    }

    // MARK: - Where it is said

    @Test("Only the reader's three ways into a thread say a post may be looked up; the wait says it may not")
    func whoMayLookUp() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let sources = root.appending(path: "Sources")
        var may: [String] = []
        var mayNot: [String] = []
        var unsaid: [String] = []
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() where !line.contains("///") {
                let site = "\(file.lastPathComponent):\(number + 1)"
                if line.contains("lookingItUp: true") { may.append(site) }
                if line.contains("lookingItUp: false") { mayNot.append(site) }
                // The look-up itself is called with the caller's word for it, never a word of its own.
                if line.contains(".id(of:"), !line.contains("lookingItUp: lookingItUp"), !line.contains("lookingItUp: true") {
                    unsaid.append(site)
                }
            }
        }
        #expect(may.count == 3, "\(may)")
        #expect(may.filter { $0.hasPrefix("ShellConversations.swift:") }.count == 2, "\(may)")
        #expect(may.filter { $0.hasPrefix("ShellReload.swift:") }.count == 1, "\(may)")
        #expect(mayNot.count == 1, "\(mayNot)")
        #expect(unsaid.isEmpty, "\(unsaid)")

        let conversations = try String(
            contentsOf: sources.appending(path: "FediqoUI/Shell/ShellConversations.swift"), encoding: .utf8
        )
        let renew = try #require(
            conversations.components(separatedBy: "func renew(_ item: DummyItem, in session: ShellSession) async {")
                .dropFirst().first?.components(separatedBy: "\n    }\n").first
        )
        #expect(renew.contains("lookingItUp: false"), "the wait's read does not say it may not look up")
        #expect(!renew.contains("lookingItUp: true"), "the wait's read says it may look up")
        for start in ["func open(_ item: DummyItem, in session: ShellSession) async {", "func again(_ item: DummyItem, in session: ShellSession) async {"] {
            let body = try #require(
                conversations.components(separatedBy: start).dropFirst().first?.components(separatedBy: "\n    }\n").first
            )
            #expect(body.contains("lookingItUp: true"), "\(start)")
        }
    }
}

/// A signed-in door answering by path from a table a test can change, remembering what was asked.
private actor Door: HTTPSender {
    private var bodies: [String: String]
    private let status: [String: Int]
    private(set) var asked: [URL] = []

    init(_ bodies: [String: String], status: [String: Int] = [:]) {
        self.bodies = bodies
        self.status = status
    }

    func answer(_ path: String, with body: String) {
        bodies[path] = body
    }

    var paths: [String] { asked.map(\.path) }

    /// How many times the thread around the post was asked for.
    var threadAsks: Int { asked.filter { $0.path == "/api/v1/statuses/9/context" }.count }

    /// How many asks had the source look a post up, wherever it was written.
    var lookUps: Int {
        asked.filter {
            let query = URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return query.contains(URLQueryItem(name: "resolve", value: "true"))
        }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        asked.append(url)
        guard let body = bodies[url.path] else { throw FixtureHTTPError.unreachable }
        let code = status[url.path] ?? 200
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}
