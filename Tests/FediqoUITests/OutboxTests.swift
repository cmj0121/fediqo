import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoPersistence
@testable import FediqoUI

/// A source that answers each post in turn as the test scripted it, remembering every request,
/// and holds the ones the test says to hold until it lets them through.
private actor PostServer: HTTPSender {
    enum Answer: Sendable {
        /// Taken: the status comes back, saying what was sent.
        case yes
        case http(Int)
        case error(URLError.Code)
    }

    private let script: [Answer]
    private var gates: [Int: Gate]
    /// Held for every post to a source other than the first one asked; nothing where none is.
    private let elsewhere: Gate?

    /// What the account check answers: 200, or the 401 that ends the sign-in.
    private var account: Int
    private(set) var posts: [URLRequest] = []
    /// What each read of somebody's own posts answers, in turn: a list of statuses, or
    /// nothing for a 500. Past the end, an empty list.
    private var own: [String?]
    private(set) var looks = 0
    /// Held for every read of somebody's own posts; nothing where none is.
    private let looking: Gate?
    /// Who each sign-in is, by its token: an id and a name.
    private static let people = ["tok-1": ("1", "me"), "tok-2": ("2", "other"), "tok-3": ("1", "me")]

    func endSignIn() { account = 401 }

    /// `script` and `gates` are by turn, among the posts to `host`; every other source says yes.
    private let host: String

    init(
        _ script: [Answer] = [], holding gates: [Int: Gate] = [:], account: Int = 200,
        host: String = "social.example", elsewhere: Gate? = nil, own: [String?] = [], looking: Gate? = nil
    ) {
        self.own = own
        self.looking = looking
        self.script = script
        self.gates = gates
        self.host = host
        self.elsewhere = elsewhere
        self.account = account
    }

    var keys: [String?] { posts.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } }
    var texts: [String] { posts.map { Self.form($0)["status"] ?? "" } }
    var tokens: [String?] { posts.map { $0.value(forHTTPHeaderField: "Authorization") } }

    static func form(_ request: URLRequest) -> [String: String] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding : ""
        }
        return fields
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func answered(_ body: String, _ status: Int) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        if url.path.hasSuffix("/statuses"), request.httpMethod != "POST" {
            looks += 1
            await looking?.wait()
            guard let list = own.isEmpty ? "[]" : own.removeFirst() else { return answered("{}", 500) }
            return answered(list, 200)
        }
        guard url.path == "/api/v1/statuses" else {
            let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
            let (id, name) = Self.people[token] ?? ("0", "nobody")
            return answered(#"{"id":"\#(id)","acct":"\#(name)"}"#, account)
        }
        let here = url.host == host
        let turn = posts.count(where: { $0.url?.host == host })
        let named = posts.count
        posts.append(request)
        if here { await gates[turn]?.wait() } else { await elsewhere?.wait() }
        switch here && turn < script.count ? script[turn] : .yes {
        case .http(let status):
            return answered("{}", status)
        case .error(let code):
            throw URLError(code)
        case .yes:
            let form = Self.form(request)
            let host = url.host ?? ""
            let reply = form["in_reply_to_id"].map { #","in_reply_to_id":"\#($0)""# } ?? ""
            return answered("""
            {"id":"9\(named)","uri":"https://\(host)/users/me/statuses/9\(named)",
             "created_at":"2024-06-01T00:00:0\(named).000Z","content":"<p>\(form["status"] ?? "")</p>",
             "visibility":"\(form["visibility"] ?? "public")"\(reply),
             "account":{"username":"me","acct":"me","display_name":"Me"}}
            """, 200)
        }
    }
}

/// Post and answer are shown first: the press takes the text and the sheet is gone; the text is
/// on disk before its source is asked; what came of it is said on the page; and nothing the
/// person wrote is lost or sent twice by itself.
///
/// What a test can reach: the session and the outbox between every two awaits, the source held
/// mid-request, the file read while it is, a second run over what the first left, the strip
/// hosted at 600 and 320 points. What it cannot: the sheet sliding away, a process really
/// killed, and VoiceOver walking the strip.
@Suite("A post and an answer are shown first and sent after")
@MainActor
struct OutboxTests {
    init() {
        L10n.language = .english
    }

    private static let host = "social.example"
    private static let other = "b.example"
    private static let writing = MastodonOAuth.scopes(writing: true)

    private static func token(_ host: String, _ access: String = "tok-1", knownAs id: String? = nil) -> MastodonToken {
        MastodonToken(
            host: host, accessToken: access, clientID: "cid", clientSecret: "csecret", scopes: writing,
            accountID: id, handle: id.map { _ in "@me@\(host)" }
        )
    }

    /// A status as its source lists it among its writer's own, published `after` seconds from now.
    private static func status(
        _ words: String, by name: String = "me", after seconds: TimeInterval = 1, answering: String? = nil, id: String = "77"
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reply = answering.map { #","in_reply_to_id":"\#($0)""# } ?? ""
        return """
        {"id":"\(id)","uri":"https://\(host)/users/\(name)/statuses/\(id)",
         "created_at":"\(formatter.string(from: Date().addingTimeInterval(seconds)))","content":"<p>\(words)</p>",
         "visibility":"public"\(reply),"account":{"username":"\(name)","acct":"\(name)","display_name":"\(name)"}}
        """
    }

    private static func root(on host: String = host) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/9", source: Source(host: host, kind: .mastodon),
            author: "Ada", handle: "@ada@\(host)", body: "the post",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.home],
            audience: .everyone, statusID: "9"
        )
    }

    /// The index a run writes, and the saver that writes it.
    private struct Disk {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)

        /// What a second connection reads of the texts, while the first is open.
        func texts() throws -> [Unsent] { try StoreFile(at: dir).loadUnsent() }

        func holds(_ phrase: String) throws -> Bool {
            try FileManager.default.subpathsOfDirectory(atPath: dir.path).contains { name in
                (try? Data(contentsOf: dir.appendingPathComponent(name)))?.range(of: Data(phrase.utf8)) != nil
            }
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    /// How many times each kind of save was asked for.
    @MainActor
    private final class Saves {
        var whole = 0
        var texts = 0
    }

    /// A run: signed in to `hosts` with writing, holding `notes`, saving to `disk` where one is given.
    private func run(
        _ server: PostServer, hosts: [String] = [host], holding notes: [Note] = [], disk: Disk? = nil,
        saves: Saves? = nil, named: Bool = true, keptAs id: String? = nil
    ) async throws -> (ShellSession, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        for host in hosts { try tokens.save(Self.token(host, knownAs: id)) }
        var store = ItemStore()
        var saver: StoreSaver?
        if let disk {
            let opened = StoreFile.open(at: disk.dir)
            store = ItemStore(sources: opened.sources, notes: opened.notes, said: opened.said, unsent: opened.unsent)
            saver = StoreSaver(store: store, file: try #require(opened.file))
        }
        for host in hosts { await store.add(Source(host: host, kind: .mastodon)) }
        await store.ingest(notes)
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        session.said.announce = { _ in }
        if let saver {
            session.persist = { saves?.whole += 1; return (try? await saver.save()) != nil }
            session.persistUnsent = { saves?.texts += 1; return (try? await saver.saveUnsent()) ?? false }
            await session.write()
        }
        session.mastodon.refresh()
        // Each source says who is signed in, as a launch and a sign-in ask it.
        if named { for host in hosts { await session.mastodon.learnWho(host: host) } }
        await session.reloadFromStore()
        await session.adoptUnsent()
        session.prepareCompose()
        return (session, tokens)
    }

    private func post(_ words: String, to host: String = host, in session: ShellSession) -> Bool {
        session.composeHost = host
        session.composeDraft = words
        return session.send()
    }

    private func line(_ sending: ShellOutbox.Sending, in session: ShellSession) -> String {
        OutboxWords.line(
            sending, hold: session.outbox.hold(sending, in: session), whom: session.outbox.whom(sending, in: session)
        )
    }

    private func presses(_ sending: ShellOutbox.Sending, in session: ShellSession) -> [OutboxWords.Press] {
        OutboxWords.presses(sending, hold: session.outbox.hold(sending, in: session))
    }

    // MARK: - The press

    @Test("The press returns with the text taken and the draft empty while the source has not answered: nothing is drawn as a post, a line says it is being sent, and no sheet or question is up")
    func thePressWaitsForNothing() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer(holding: [0: gate])
        let (session, _) = try await run(server)
        var heard: [String] = []
        session.said.announce = { heard.append($0) }

        // Not `async`: there is nothing for a sheet to wait on.
        let took: Bool = post("  hello there \n", in: session)

        #expect(took)
        #expect(session.composeDraft.isEmpty, "the composer opened again shows no text: it left for the outbox")
        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.unsent.text == "hello there" && entry.unsent.audience == .everyone && entry.unsent.host == Self.host)
        #expect(entry.isOut)
        #expect(await server.posts.isEmpty, "the press returned before anything was asked")
        #expect(heard == ["Sending your post to social.example…"])
        #expect(!session.raisesOverPages)

        #expect(await spun { await server.posts.count == 1 })
        #expect(session.outbox.sendings.first?.standing == .onItsWay)
        #expect(session.notes.isEmpty, "no row is made up for a post its source has not named (#282)")
        #expect(presses(try #require(session.outbox.sendings.first), in: session).isEmpty, "nothing to press while it is out")

        await gate.open()
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        #expect(session.notes.map(\.body) == ["hello there"], "the post appears by itself")
        #expect(heard.count == 1, "a landing says nothing: the post is there")
    }

    @Test("The text is in the file, marked as asked, before its request leaves — written as a part of its own, with no post written for it — and the yes takes it out of the file and writes the post behind it")
    func onDiskBeforeTheRequest() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer(holding: [0: gate])
        let saves = Saves()
        let (session, _) = try await run(server, disk: disk, saves: saves)
        let whole = saves.whole

        #expect(post("persimmon-lantern words", in: session))
        #expect(await spun { await server.posts.count == 1 })

        // The request is held at the source: this is the moment a crash would be.
        let held = try disk.texts()
        #expect(held.map(\.text) == ["persimmon-lantern words"])
        #expect(held.first?.standing == .asked, "a run that finds it knows it may have landed")
        #expect(held.first?.id == session.outbox.sendings.first?.id)
        #expect(await server.keys == [held.first?.id.uuidString], "and the request went under its name")
        #expect(saves.whole == whole, "no post was written again for it")
        #expect(saves.texts >= 1)

        await gate.open()
        await session.outbox.settled()
        await session.saved()
        #expect(try disk.texts().isEmpty, "the row goes with the entry")
        #expect(try !disk.holds("persimmon-lantern words</p>"), "nothing of the request is kept")
        #expect(StoreFile.open(at: disk.dir).notes.map(\.body) == ["persimmon-lantern words"], "and the post is written behind its landing")
        #expect(saves.whole == whole + 1)
    }

    // MARK: - What the source says

    @Test("A refusal, another answer and a source not reached each leave the text whole, on the page and in the file, saying why, with the presses that send it again, open it or discard it",
          arguments: [
              (PostServer.Answer.http(403), WriteWhy.refused, Unsent.Standing.refused),
              (.http(422), .declined, .declined),
              (.error(.notConnectedToInternet), .unreachable, .unreachable),
          ])
    private func itDidNotArrive(_ answer: PostServer.Answer, _ why: WriteWhy, _ written: Unsent.Standing) async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([answer])
        let (session, _) = try await run(server, disk: disk)
        var heard: [String] = []
        session.said.announce = { heard.append($0) }
        let words = "every «character» — 100% + more"

        #expect(post(words, in: session))
        await session.outbox.settled()

        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.standing == .failed(why))
        #expect(entry.unsent.text == words)
        #expect(session.composeDraft.isEmpty)
        #expect(try disk.texts().map(\.text) == [words])
        #expect(try disk.texts().first?.standing == written, "never written down as maybe landed")
        #expect(heard.count == 2 && heard.last == line(entry, in: session), "said aloud once")
        #expect(line(entry, in: session).contains(Self.host))
        #expect(session.notes.isEmpty)
        #expect(await server.posts.count == 1, "never sent again by itself")
        // A 403 leaves nobody who may write there, and then there is no sending again from here.
        #expect(presses(entry, in: session) == (why == .refused ? [.copy, .discard] : [.again, .edit, .discard]))
        #expect(line(entry, in: session) == String(
            format: L10n.t(why == .refused ? "outbox.refused.post" : why == .declined ? "outbox.declined.post" : "outbox.failed.post"),
            Self.host
        ))
    }

    @Test("No answer in time is not a failure: the text may have been posted, the file still says it was asked, nothing sends it again by itself — and Send again goes under the same key, and lands")
    func theDeadline() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.error(.timedOut)])
        let (session, _) = try await run(server, disk: disk)

        #expect(post("did this go", in: session))
        await session.outbox.settled()

        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.standing == .unconfirmed)
        #expect(line(entry, in: session) == "social.example did not confirm your post. It may have been posted: reload your Home, or open your posts on social.example, to see.")
        #expect(entry.unsent.writerID == "1" && entry.unsent.writer == "@me@social.example")
        #expect(try disk.texts().first?.standing == .asked)
        #expect(presses(entry, in: session) == [.again, .edit, .discard])
        await session.reload.timeline(.all, in: session)
        await session.outbox.settled()
        #expect(await server.posts.count == 1, "never sent again by itself")

        #expect(session.outbox.again(entry.id, in: session))
        #expect(session.outbox.sendings.first?.standing == .looking, "looked for before it is sent again")
        #expect(line(try #require(session.outbox.sendings.first), in: session) == "Looking for your post on social.example before sending it again…")
        await session.outbox.settled()
        #expect(await server.looks == 1)
        #expect(session.resendingUnsent == nil, "not found, and its source still keeps the key: nothing to ask")
        #expect(await server.keys == [entry.id.uuidString, entry.id.uuidString], "a source that honours the key posts once")
        #expect(session.outbox.sendings.isEmpty)
        #expect(session.notes.map(\.body) == ["did this go"])
        #expect(try disk.texts().isEmpty)
    }

    @Test("A text that may have been posted goes on saying so when Send again fails, whatever the failure — a try that failed says nothing of the one before it — in this run and in the next",
          arguments: [PostServer.Answer.http(500), .http(403), .error(.notConnectedToInternet)])
    private func onceMaybeAlwaysMaybe(_ later: PostServer.Answer) async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.error(.timedOut), later])
        let (session, _) = try await run(server, disk: disk)
        #expect(post("it landed the first time", in: session))
        await session.outbox.settled()
        let id = try #require(session.outbox.sendings.first?.id)

        // A 403 leaves nobody who may write there; the other two leave Send again to press.
        #expect(session.outbox.again(id, in: session))
        await session.outbox.settled()

        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.standing == .unconfirmed, "not said to be unsent: nobody knows that")
        #expect(entry.unsent.text == "it landed the first time")
        #expect(try disk.texts().first?.standing == .asked)
        #expect(await server.keys == [id.uuidString, id.uuidString])
        if case .http(403) = later {} else {
            #expect(line(entry, in: session).contains("may have been posted"))
        }

        // The next run, and a try there that is not reached either.
        let next = PostServer([.error(.notConnectedToInternet)])
        let (after, _) = try await run(next, disk: disk)
        #expect(after.outbox.sendings.map(\.standing) == [.unconfirmed])
        #expect(after.outbox.again(id, in: after))
        await after.outbox.settled()
        #expect(after.outbox.sendings.map(\.standing) == [.unconfirmed])
        #expect(try disk.texts().first?.standing == .asked)
    }

    @Test("A source that took it and answered something unreadable may have posted it")
    func anUnreadableYes() async throws {
        let server = PostServer([.http(200)])
        let (session, _) = try await run(server)
        #expect(post("taken, probably", in: session))
        await session.outbox.settled()
        #expect(session.outbox.sendings.first?.standing == .unconfirmed)
    }

    @Test("A 401 the source stands by ends the sign-in and keeps the text: it waits, saying a sign-in is needed, and is not offered to send")
    func theSignInEnded() async throws {
        let server = PostServer([.http(401)])
        let (session, _) = try await run(server)
        await server.endSignIn()
        #expect(post("kept through it", in: session))
        await session.outbox.settled()

        let entry = try #require(session.outbox.sendings.first)
        #expect(!session.isSignedIn(host: Self.host))
        #expect(entry.unsent.text == "kept through it")
        #expect(session.outbox.hold(entry, in: session) == .signedOut)
        #expect(presses(entry, in: session) == [.copy, .discard])
        #expect(!session.outbox.again(entry.id, in: session))
        await session.outbox.settled()
        #expect(await server.posts.count == 1)
    }

    // MARK: - A relaunch

    @Test("A run that finds a text whose source was asked draws it as maybe posted, and one that was never asked as not sent — and sends neither; Send again sends the first under the key it had")
    func aRelaunch() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        // The first run: one on the wire and one behind it, and then it is gone without a word.
        let first = PostServer(holding: [0: gate])
        let (before, _) = try await run(first, disk: disk)
        #expect(post("was on the wire", in: before))
        #expect(post("was waiting its turn", in: before))
        #expect(await spun { await first.posts.count == 1 })
        #expect(await spun { (try? disk.texts().count) == 2 })
        #expect(try disk.texts().map(\.standing) == [.asked, .fresh])
        let asked = try #require(before.outbox.sendings.first?.id)

        let server = PostServer()
        let (session, _) = try await run(server, disk: disk)
        await session.outbox.settled()

        #expect(session.outbox.sendings.map(\.unsent.text) == ["was on the wire", "was waiting its turn"])
        #expect(session.outbox.sendings.map(\.standing) == [.unconfirmed, .failed(.unreachable)])
        #expect(await server.posts.isEmpty, "neither is sent by the launch")
        #expect(line(session.outbox.sendings[0], in: session).contains("may have been posted"))
        #expect(line(session.outbox.sendings[1], in: session) == "Your post was not sent to social.example. Every word of it is kept here.")

        #expect(session.outbox.again(asked, in: session))
        await session.outbox.settled()
        #expect(await server.keys == [asked.uuidString], "as the same account in a later run: allowed, under the same key")
        #expect(await server.looks == 1)
        #expect(await server.posts.count == 1, "and the other still waits for the person")
        #expect(try disk.texts().map(\.text) == ["was waiting its turn"])
        await gate.open()
    }

    // MARK: - More than one

    @Test("Two texts to one source go one at a time in the order written, the second on disk while it waits; one that fails does not hold the next back; and two sources are asked at once")
    func twoAtOnce() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let gate = Gate(), elsewhere = Gate()
        let watchdog = hangGuard(gate), second = hangGuard(elsewhere)
        defer { watchdog.cancel(); second.cancel() }
        // By turn: the first to the source is held and then fails; the other source's is held too.
        let server = PostServer([.http(422)], holding: [0: gate], elsewhere: elsewhere)
        let (session, _) = try await run(server, hosts: [Self.host, Self.other], disk: disk)

        #expect(post("first", in: session))
        #expect(post("second", in: session))
        #expect(post("elsewhere", to: Self.other, in: session))
        #expect(session.composeDraft.isEmpty)
        #expect(await spun { await server.posts.count == 2 })

        #expect(Set(await server.posts.map { $0.url?.host }) == [Self.host, Self.other], "one on the wire a source")
        #expect(session.outbox.sendings.map(\.standing) == [.onItsWay, .waiting, .onItsWay])
        #expect(await spun { (try? disk.texts().count) == 3 })
        #expect(try disk.texts().map(\.text) == ["first", "second", "elsewhere"], "the one that waits is written too")

        await gate.open()
        #expect(await spun { await server.posts.count == 3 })
        await elsewhere.open()
        await session.outbox.settled()
        #expect(await server.texts.filter { $0 != "elsewhere" } == ["first", "second"], "in the order written")
        #expect(session.outbox.sendings.map(\.unsent.text) == ["first"], "the failure stays, and did not hold the next back")
        #expect(session.outbox.sendings.first?.standing == .failed(.declined))
        #expect(Set(session.notes.map(\.body)) == ["second", "elsewhere"])
    }

    // MARK: - The door it was written for

    @Test("A text is sent only as who wrote it: with somebody else signed in at its source it waits, naming both, with nothing to press but Copy and Discard — and the writer signed in again, under whatever sign-in, sends it under the key it had")
    func onlyAsWhoWroteIt() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer(holding: [0: gate])
        let (session, tokens) = try await run(server)

        #expect(post("first", in: session))
        #expect(post("written as me", in: session))
        #expect(await spun { await server.posts.count == 1 })
        // Somebody else signs in at the same source while the second waits its turn.
        try tokens.save(Self.token(Self.host, "tok-2"))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        await gate.open()
        await session.outbox.settled()

        #expect(await server.posts.count == 1, "nothing went out as somebody else")
        let entry = try #require(session.outbox.sendings.first { $0.unsent.text == "written as me" })
        #expect(entry.standing == .failed(.unreachable))
        #expect(session.outbox.hold(entry, in: session) == .otherAccount(here: "@other@social.example"))
        #expect(line(entry, in: session) == "Your post was written as @me@social.example, and social.example is signed in as @other@social.example. Sign in as @me@social.example to send it.")
        #expect(presses(entry, in: session) == [.copy, .discard])
        #expect(!session.outbox.again(entry.id, in: session))
        #expect(!session.outbox.sendAnyway(entry.id, in: session))
        #expect(session.outbox.edit(entry.id, in: session))
        session.outbox.write(entry.id, text: "said another way")
        #expect(!session.send(unsent: entry.id), "nor changed, nor from its sheet")
        session.editingUnsent = nil
        await session.outbox.settled()
        #expect(await server.posts.count == 1)

        // The writer signs in again: another sign-in, the same account.
        try tokens.save(Self.token(Self.host, "tok-3"))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.outbox.hold(entry, in: session) == nil)
        session.outbox.write(entry.id, text: "written as me")
        #expect(session.outbox.again(entry.id, in: session))
        await session.outbox.settled()
        #expect(await server.tokens.last == "Bearer tok-3")
        #expect(await server.keys.last == entry.id.uuidString)
        #expect(await server.texts.last == "written as me")
    }

    @Test("A sign-in that arrived under the session — a read back's — is nobody its source has named: a text waits, and is not sent, until the source says who it is; and then only if it is the writer")
    func aReadBackBroughtAnotherSignIn() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.error(.notConnectedToInternet)])
        let (session, tokens) = try await run(server, disk: disk)
        #expect(post("written before the read back", in: session))
        await session.outbox.settled()
        let entry = try #require(session.outbox.sendings.first)
        #expect(try disk.texts().first?.writerID == "1", "who wrote it is written down with it")
        #expect(try disk.texts().first?.writer == "@me@social.example")

        // What a read back does: the Keychain holds another sign-in, and who is signed in is read again.
        try tokens.save(Self.token(Self.host, "tok-2"))
        session.mastodon.refresh()

        #expect(session.outbox.hold(entry, in: session) == .otherAccount(here: nil), "what was learnt of the old sign-in is not laid on the new")
        #expect(line(entry, in: session) == "Your post was written as @me@social.example. social.example has not yet said who is signed in now, so it waits. It can be sent once social.example answers.")
        #expect(presses(entry, in: session) == [.copy, .discard])
        #expect(!session.outbox.again(entry.id, in: session))
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.outbox.hold(entry, in: session) == .otherAccount(here: "@other@social.example"))
        #expect(!session.outbox.again(entry.id, in: session))
        await session.outbox.settled()
        #expect(await server.posts.count == 1)

        // And in a later run with that other sign-in: still not sent.
        let next = PostServer()
        let (after, later) = try await run(next, disk: disk)
        try later.save(Self.token(Self.host, "tok-2"))
        after.mastodon.refresh()
        await after.mastodon.learnWho(host: Self.host)
        let held = try #require(after.outbox.sendings.first)
        #expect(after.outbox.hold(held, in: after) == .otherAccount(here: "@other@social.example"))
        #expect(!after.outbox.again(held.id, in: after))
        await after.outbox.settled()
        #expect(await next.posts.isEmpty)
    }

    @Test("Offline: a text pressed with no source answering is named from the sign-in itself, and after a quit and a relaunch, online, Send again sends it as the same account under the key it had")
    func pressedOfflineSentLater() async throws {
        let disk = Disk()
        defer { disk.remove() }
        // The sign-in says whose it is, as the last run that reached its source wrote it down.
        let dark = PostServer([.error(.notConnectedToInternet)])
        let (offline, _) = try await run(dark, disk: disk, named: false, keptAs: "1")
        #expect(post("written on a plane", in: offline))
        await offline.outbox.settled()
        let entry = try #require(offline.outbox.sendings.first)
        #expect(entry.unsent.writerID == "1" && entry.unsent.writer == "@me@social.example", "named at the press, with no network")
        #expect(entry.standing == .failed(.unreachable))
        #expect(try disk.texts().first?.writerID == "1")

        // Quit; a later run, still dark at first, and nothing has asked the source who is signed in.
        let server = PostServer()
        let (later, _) = try await run(server, disk: disk, named: false, keptAs: "1")
        let held = try #require(later.outbox.sendings.first)
        #expect(later.outbox.hold(held, in: later) == nil, "not a dead end: the sign-in itself says it is the writer's")
        #expect(presses(held, in: later) == [.again, .edit, .discard])
        #expect(later.outbox.again(held.id, in: later))
        await later.outbox.settled()
        #expect(await server.keys == [entry.id.uuidString])
        #expect(await server.tokens == ["Bearer tok-1"])
        #expect(later.outbox.sendings.isEmpty)
        #expect(try disk.texts().isEmpty)
    }

    @Test("What a source says of who is signed in is written down with the sign-in, where it is still the one held")
    func whoIsKeptWithTheSignIn() async throws {
        let (session, tokens) = try await run(PostServer())
        let kept = try #require(try tokens.token(host: Self.host))
        #expect(kept.accountID == "1" && kept.handle == "@me@social.example")
        #expect(kept.accessToken == "tok-1" && kept.scopes == Self.writing, "and nothing else of it moved")
        #expect(session.mastodon.reader(host: Self.host)?.id == "1")
    }

    @Test("A text nobody could put a name to at the press goes under the sign-in it was pressed with, is named as soon as its source says who that is, and in a later run without a name is not sent at all")
    func noNameAtThePress() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.error(.notConnectedToInternet), .error(.timedOut)])
        let (session, _) = try await run(server, disk: disk, named: false)
        #expect(post("pressed before anybody said who", in: session))
        await session.outbox.settled()
        let entry = try #require(session.outbox.sendings.first)
        #expect(await server.posts.count == 1, "the sign-in it was pressed under sends it")
        #expect(entry.unsent.writerID == nil && session.outbox.hold(entry, in: session) == nil)
        #expect(try disk.texts().first?.writerID == nil)

        // A later run, and nothing says whose it was.
        let (after, _) = try await run(PostServer(), disk: disk)
        let held = try #require(after.outbox.sendings.first)
        #expect(after.outbox.hold(held, in: after) == .otherAccount(here: "@me@social.example"))
        #expect(line(held, in: after) == "Nobody can say who was signed in to social.example when your post was written, so it is not sent from here.")
        #expect(presses(held, in: after) == [.copy, .discard])

        // In the run it was pressed in, once the source has said who is signed in, it is named.
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.outbox.again(entry.id, in: session))
        await session.outbox.settled()
        #expect(session.outbox.sendings.first?.unsent.writerID == "1")
        #expect(try disk.texts().first?.writer == "@me@social.example")
    }

    @Test("Signing out leaves a text that waits, saying a sign-in is needed; removing its source lets it go, off the disk, after a question that says how many")
    func signedOutAndRemoved() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.error(.notConnectedToInternet), .error(.notConnectedToInternet)])
        let (session, _) = try await run(server, disk: disk)
        #expect(post("waits through a sign-out", in: session))
        #expect(post("and so does this", in: session))
        await session.outbox.settled()

        await session.signOut(host: Self.host)
        #expect(session.outbox.sendings.count == 2, "unsent texts stay at a sign-out")
        let entry = try #require(session.outbox.sendings.first)
        #expect(session.outbox.hold(entry, in: session) == .signedOut)
        #expect(line(entry, in: session) == "Your post waits here. Sign in to social.example with writing to send it.")
        #expect(presses(entry, in: session) == [.copy, .discard])
        #expect(!session.outbox.again(entry.id, in: session))
        var copied: [String] = []
        session.outbox.copy = { copied.append($0) }
        SaidStrip.pressed(OutboxPressed(press: .copy, id: entry.id), in: session)
        #expect(copied == ["waits through a sign-out"])
        #expect(try disk.texts().count == 2)

        let question = session.removeQuestion(host: Self.host, postsStay: false)
        #expect((question.line + (question.help ?? "")).contains("The 2 texts waiting to be sent to it are deleted."))
        #expect(!ShellQuestion.remove(host: Self.host, boards: 0).line.contains("waiting to be sent"))

        await session.remove(host: Self.host)
        #expect(session.outbox.sendings.isEmpty)
        #expect(try disk.texts().isEmpty)
        #expect(try !disk.holds("waits through a sign-out"))
        #expect(await server.posts.count == 2, "nothing was sent on the way out")
    }

    // MARK: - An answer

    @Test("An answer is taken at the press — its draft, its reach and the sheet go — said as being sent to whom it answers, and laid into the conversation when it lands")
    func anAnswerIsTaken() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer(holding: [0: gate])
        let (session, _) = try await run(server, holding: [Self.root()])
        let post = DummyItem(try #require(session.notes.first))
        #expect(session.openAnswer(to: post, in: post))
        let target = try #require(session.answering)
        session.answerDrafts[target.id] = "@ada yes"
        session.answerReach[target.id] = .followers

        #expect(session.send(answer: target))

        #expect(session.answering == nil, "the sheet is gone at the press")
        #expect(session.answerDrafts[target.id] == nil && session.answerReach[target.id] == nil)
        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.unsent.answers == Self.root().key && entry.unsent.root == Self.root().key)
        #expect(entry.unsent.audience == .followers)
        #expect(line(entry, in: session) == "Sending your answer to Ada on social.example…")
        #expect(session.conversations.conversation(around: post).descendants.isEmpty, "no row before the source names it")

        await gate.open()
        await session.outbox.settled()
        #expect(PostServer.form(try #require(await server.posts.first))["in_reply_to_id"] == "9")
        #expect(session.conversations.conversation(around: post).descendants.map(\.item.body) == ["@ada yes"])
        #expect(session.outbox.sendings.isEmpty)
    }

    @Test("An answer whose post was marked gone while it waited is not sent: it says why, and offers its words to copy or to discard")
    func theAnsweredPostWent() async throws {
        let server = PostServer([.error(.notConnectedToInternet)])
        let (session, _) = try await run(server, holding: [Self.root()])
        let post = DummyItem(try #require(session.notes.first))
        #expect(session.openAnswer(to: post, in: post))
        let target = try #require(session.answering)
        session.answerDrafts[target.id] = "@ada too late"
        #expect(session.send(answer: target))
        await session.outbox.settled()
        let entry = try #require(session.outbox.sendings.first)
        #expect(presses(entry, in: session) == [.again, .edit, .discard])

        await session.markGone(Self.root().key, at: Date(timeIntervalSince1970: 1_700_000_100))

        #expect(session.outbox.hold(entry, in: session) == .answeredGone)
        #expect(line(entry, in: session) == "The post your answer was to is no longer here, so it cannot be sent to social.example.")
        #expect(presses(entry, in: session) == [.copy, .discard])
        #expect(!session.outbox.again(entry.id, in: session))
        #expect(!session.send(unsent: entry.id))
        await session.outbox.settled()
        #expect(await server.posts.count == 1)
        #expect(session.outbox.sendings.first?.unsent.text == "@ada too late")
    }

    @Test("An answer that waited behind another, and whose post was marked gone before its turn, is not sent")
    func goneBeforeItsTurn() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer(holding: [0: gate])
        let (session, _) = try await run(server, holding: [Self.root()])
        let post = DummyItem(try #require(session.notes.first))
        #expect(self.post("ahead of it", in: session))
        #expect(session.openAnswer(to: post, in: post))
        let target = try #require(session.answering)
        session.answerDrafts[target.id] = "@ada behind"
        #expect(session.send(answer: target))
        #expect(await spun { await server.posts.count == 1 })

        await session.markGone(Self.root().key, at: Date(timeIntervalSince1970: 1_700_000_100))
        await gate.open()
        await session.outbox.settled()

        #expect(await server.texts == ["ahead of it"])
        #expect(session.outbox.sendings.map(\.unsent.text) == ["@ada behind"])
        #expect(session.outbox.sendings.first?.standing == .failed(.unreachable))
    }

    // MARK: - Opened again, and discarded

    @Test("Leaving the sheet on a text changes nothing of it, and keeps what was typed for the next time; a text known not to have gone is sent changed at once, as a different post under a new name")
    func openedAgain() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.error(.notConnectedToInternet)])
        let (session, _) = try await run(server, disk: disk)
        #expect(post("did not go", in: session))
        await session.outbox.settled()
        let id = try #require(session.outbox.sendings.first?.id)
        let before = try #require(session.outbox.sendings.first)
        session.composeDraft = "another draft entirely"

        #expect(session.outbox.edit(id, in: session))
        #expect(session.editingUnsent == UnsentAsk(id: id) && session.raisesOverPages)
        #expect(session.outbox.draft(id) == "did not go")
        session.outbox.write(id, text: "did not go, said better ")
        session.editingUnsent = nil
        await session.outbox.settled()

        #expect(session.outbox.sendings == [before], "Cancel changes nothing")
        #expect(try disk.texts().map(\.id) == [id])
        #expect(try disk.texts().first?.text == "did not go")
        #expect(session.outbox.draft(id) == "did not go, said better ", "and nothing typed is lost")
        #expect(session.composeDraft == "another draft entirely", "no draft is touched")
        #expect(await server.posts.count == 1)

        #expect(session.outbox.edit(id, in: session))
        #expect(session.send(unsent: id))
        #expect(session.editingUnsent == nil && session.resendingUnsent == nil, "known not to have gone: nothing to ask")
        await session.outbox.settled()
        let keys = await server.keys
        #expect(keys.count == 2 && keys[1] != id.uuidString, "a changed text is a different post")
        #expect(await server.texts.last == "did not go, said better")
        #expect(session.outbox.sendings.isEmpty)
        #expect(try disk.texts().isEmpty)
    }

    @Test("A text that may have been posted is not changed into a new one without the person being told: its sheet's Send asks first, Cancel there changes nothing, and the yes sends the new text under a new name")
    func changedAfterMaybePosted() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.error(.timedOut)])
        let (session, _) = try await run(server, disk: disk)
        #expect(post("may have gone", in: session))
        await session.outbox.settled()
        let before = try #require(session.outbox.sendings.first)
        let id = before.id

        #expect(session.outbox.edit(id, in: session))
        session.outbox.write(id, text: "may have gone, said better")
        #expect(session.send(unsent: id))
        #expect(session.editingUnsent == nil)
        #expect(session.resendingUnsent == UnsentAsk(id: id), "asked first")
        await session.outbox.settled()
        #expect(await server.posts.count == 1)
        #expect(session.outbox.sendings == [before])
        let question = ShellQuestion.resend(before, changed: session.outbox.changed(id) != nil)
        #expect(question.line == "The first may have been posted to social.example already. This is sent as a new one, and the first stays.")
        #expect(question.choices.map(\.label) == ["Send anyway"] && question.cancel != nil)

        // Cancel: as it was, on the page and in the file.
        session.resendingUnsent = nil
        await session.outbox.settled()
        #expect(session.outbox.sendings == [before])
        #expect(try disk.texts().map(\.id) == [id])
        #expect(try disk.texts().first?.standing == .asked)

        #expect(session.outbox.sendAnyway(id, in: session))
        await session.outbox.settled()
        let keys = await server.keys
        #expect(keys.count == 2 && keys[1] != id.uuidString)
        #expect(await server.texts.last == "may have gone, said better")
        #expect(await server.looks == 0, "a new text is nobody's post yet: nothing to look for")
        #expect(session.outbox.sendings.isEmpty)
        #expect(try disk.texts().isEmpty)
    }

    @Test("A text too long for its source, or one that is out, is not sent from its sheet")
    func notSentFromTheSheet() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer([.error(.notConnectedToInternet)], holding: [1: gate])
        let (session, _) = try await run(server)
        #expect(post("short", in: session))
        await session.outbox.settled()
        let id = try #require(session.outbox.sendings.first?.id)

        #expect(session.outbox.edit(id, in: session))
        session.outbox.write(id, text: String(repeating: "a", count: 501))
        #expect(!session.send(unsent: id))
        #expect(session.editingUnsent != nil, "the sheet stays")
        session.outbox.write(id, text: "short")
        #expect(session.send(unsent: id))
        #expect(await spun { await server.posts.count == 2 })
        #expect(!session.outbox.edit(id, in: session), "nothing opens on a text that is out")
        #expect(!session.send(unsent: id))
        await gate.open()
        await session.outbox.settled()
        #expect(await server.keys == [id.uuidString, id.uuidString])
    }

    @Test("Discarding asks first, names the text, and says the text is gone only once the file no longer holds it")
    func discarded() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.error(.timedOut)])
        let (session, _) = try await run(server, disk: disk)
        #expect(post("quince-harbour, to be discarded", in: session))
        await session.outbox.settled()
        let entry = try #require(session.outbox.sendings.first)

        SaidStrip.pressed(OutboxPressed(press: .discard, id: entry.id), in: session)
        #expect(session.discardingUnsent == UnsentAsk(id: entry.id))
        #expect(session.outbox.sendings.count == 1, "nothing goes while it is only asked")
        let question = ShellQuestion.discard(entry)
        // It may have been posted: nothing says it is unsent, only that this device forgets it.
        #expect(question.title == "Forget this post here?")
        #expect(question.line == "Only this device's copy is deleted. If social.example took it, it stays posted there.")
        #expect(question.help == "“quince-harbour, to be discarded” may have been posted already. Forgetting it here takes nothing back: if it was posted it stays posted, and is taken back from its own row.")
        #expect(question.choices.map(\.label) == ["Forget it here"])
        #expect(question.choices.map(\.role) == [.destructive] && question.cancel != nil)
        let unsent = ShellQuestion.discard(ShellOutbox.Sending(unsent: entry.unsent, standing: .failed(.unreachable)))
        #expect(unsent.title == "Discard this post?" && unsent.help == nil)
        #expect(unsent.line == "“quince-harbour, to be discarded” is deleted from this device, and is not sent.")

        // The write that takes it off the disk, held: until it returns the line still stands.
        let write = Gate()
        let guardWrite = hangGuard(write)
        defer { guardWrite.cancel() }
        let texts = session.persistUnsent
        session.persistUnsent = { await write.wait(); return await texts?() ?? false }
        session.discardingUnsent = nil
        session.outbox.discardSoon(entry.id, in: session)
        for _ in 0..<50 { await Task.yield() }
        #expect(session.outbox.sendings.count == 1, "not said gone while the file still holds its words")
        #expect(try disk.holds("quince-harbour"))

        await write.open()
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        #expect(try disk.texts().isEmpty)
        #expect(try !disk.holds("quince-harbour"), "nothing of it is readable in the file")
        #expect(await server.posts.count == 1)
    }

    // MARK: - Not sent, or may have been posted

    @Test("\"Was not sent\" is said only where the request never reached a server that could act on it, or the source answered that it would not; everything else may have been posted")
    func whatIsKnownNotToHaveGone() {
        let neverLeft: [URLError.Code] = [
            .badURL, .unsupportedURL, .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
            .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .appTransportSecurityRequiresSecureConnection,
            .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired,
        ]
        for code in neverLeft { #expect(ShellOutbox.notSent(URLError(code)) == .unreachable, "\(code)") }
        let mayHaveLeft: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .cancelled, .secureConnectionFailed, .badServerResponse, .cannotParseResponse,
            .zeroByteResource, .httpTooManyRedirects, .redirectToNonExistentLocation, .cannotDecodeContentData,
            .resourceUnavailable, .unknown,
        ]
        for code in mayHaveLeft { #expect(ShellOutbox.notSent(URLError(code)) == nil, "\(code)") }

        #expect(ShellOutbox.notSent(MastodonAuthError.signedOut) == .refused)
        #expect(ShellOutbox.notSent(MastodonAuthError.http(401)) == .refused)
        #expect(ShellOutbox.notSent(MastodonAuthError.http(403)) == .refused)
        for status in [400, 404, 410, 413, 422] { #expect(ShellOutbox.notSent(MastodonAuthError.http(status)) == .declined) }
        // What stands in front of a source can answer these after the source made the post.
        for status in [408, 409, 425, 429, 499, 500, 502, 503, 504, 599, 302] { #expect(ShellOutbox.notSent(MastodonAuthError.http(status)) == nil, "\(status)") }
        #expect(ShellOutbox.notSent(MastodonWriteError.noSource) == .unreachable)
        #expect(ShellOutbox.notSent(MastodonWriteError.unfindable) == .unreachable)
        #expect(ShellOutbox.notSent(MastodonWriteError.unreadable) == nil)
        #expect(ShellOutbox.notSent(OutwardRefusal.noSource) == .unreachable)
        #expect(ShellOutbox.notSent(CancellationError()) == nil)
        struct Unnamed: Error {}
        #expect(ShellOutbox.notSent(Unnamed()) == nil, "what nobody named is not known to be unsent")
    }

    @Test("A fault past the door, a connection lost and a request cancelled are not \"was not sent\": the text may have been posted, and the file says it was asked",
          arguments: [PostServer.Answer.http(500), .http(502), .http(504), .http(429), .http(408), .error(.networkConnectionLost),
                      .error(.cancelled), .error(.secureConnectionFailed)])
    private func itMayHaveGone(_ answer: PostServer.Answer) async throws {
        let disk = Disk()
        defer { disk.remove() }
        let (session, _) = try await run(PostServer([answer]), disk: disk)
        #expect(post("the very 500 a real Mastodon gives", in: session))
        await session.outbox.settled()
        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.standing == .unconfirmed)
        #expect(line(entry, in: session).contains("may have been posted"))
        #expect(try disk.texts().first?.standing == .asked)
        #expect(try disk.texts().first?.askedAt != nil, "and when: no earlier post can be it")
    }

    // MARK: - Seen to have arrived

    @Test("A post's words and a text's are compared with no white space, and a name with its host as the name alone")
    func theWordsCompared() {
        #expect(ShellOutbox.words("@ada@social.example  yes,\nand   more ") == ShellOutbox.words("@ada yes, and more"))
        #expect(ShellOutbox.words("a b") != ShellOutbox.words("a c"))
        #expect(ShellOutbox.words("mail me@example.org") == "mailme@example.org", "an address is not a name")
    }

    /// A run holding one text that may have been posted, asked at about now.
    private func maybePosted(
        _ words: String = "did this go", own: [String?] = [], then script: [PostServer.Answer] = [], disk: Disk? = nil,
        holding notes: [Note] = []
    ) async throws -> (ShellSession, PostServer, ShellOutbox.Sending) {
        let server = PostServer([.error(.timedOut)] + script, own: own)
        let (session, _) = try await run(server, holding: notes, disk: disk)
        #expect(post(words, in: session))
        await session.outbox.settled()
        return (session, server, try #require(session.outbox.sendings.first))
    }

    private func landed(_ json: String, in session: ShellSession) async throws {
        let note = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: Source(host: Self.host, kind: .mastodon), categories: [.home], sent: .now())
        await session.store.ingest([note])
        await session.reloadFromStore()
    }

    @Test("A read that lands the post lets the text go by itself, with nothing said and nothing sent: by its writer, at its source, published since it was asked, with its words")
    func seenToHaveArrived() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let (session, server, entry) = try await maybePosted("did this  go\nafter all", disk: disk)
        var heard: [String] = []
        session.said.announce = { heard.append($0) }

        // Not it: somebody else's, one published before it was asked, and other words.
        try await landed(Self.status("did this go after all", by: "other", id: "70"), in: session)
        try await landed(Self.status("did this go after all", after: -3600, id: "71"), in: session)
        try await landed(Self.status("did this go at all", id: "72"), in: session)
        try await landed(Self.status("did this go after all", answering: "9", id: "73"), in: session)
        // Nor the same words posted long after its source would still have made it.
        try await landed(Self.status("did this go after all", after: ShellOutbox.keyLife + 120, id: "75"), in: session)
        #expect(session.outbox.sendings.map(\.id) == [entry.id], "none of those is this text")
        #expect(session.said.lines.isEmpty)

        try await landed(Self.status("did this go after all", id: "74"), in: session)
        #expect(session.outbox.sendings.isEmpty, "the line goes when the post is seen")
        await session.outbox.settled()
        #expect(try disk.texts().isEmpty)
        // Said once, as a line that asks nothing and goes at its press.
        #expect(heard == ["Your post was found on social.example: it had been posted, and is no longer waiting here."])
        #expect(session.said.lines.map(\.what) == [.found(entry.id, answer: false)])
        #expect(SaidStrip.symbol(of: session.said.lines[0]) != SaidStrip.symbol)
        session.said.takeDown(session.said.lines[0].id)
        #expect(session.said.lines.isEmpty)
        #expect(await server.posts.count == 1)
    }

    @Test("A text that was never asked, or is known not to have gone, is nobody's post: a post with its words does not take it away")
    func onlyWhatMayHaveLanded() async throws {
        let server = PostServer([.error(.notConnectedToInternet)])
        let (session, _) = try await run(server)
        #expect(post("the same words", in: session))
        await session.outbox.settled()
        try await landed(Self.status("the same words"), in: session)
        #expect(session.outbox.sendings.count == 1)
    }

    @Test("An answer is let go only by an answer to the same post")
    func anAnswerSeenToHaveArrived() async throws {
        let server = PostServer([.error(.timedOut)])
        let (session, _) = try await run(server, holding: [Self.root()])
        let post = DummyItem(try #require(session.notes.first))
        #expect(session.openAnswer(to: post, in: post))
        let target = try #require(session.answering)
        session.answerDrafts[target.id] = "@ada@social.example yes"
        #expect(session.send(answer: target))
        await session.outbox.settled()
        #expect(session.outbox.sendings.first?.standing == .unconfirmed)

        try await landed(Self.status("@ada yes", id: "80"), in: session)
        try await landed(Self.status("@ada yes", answering: "8", id: "81"), in: session)
        #expect(session.outbox.sendings.count == 1, "a post, and an answer to another post, are not it")
        try await landed(Self.status("@ada yes", answering: "9", id: "82"), in: session)
        #expect(session.outbox.sendings.isEmpty, "as its source writes the name, without its host")
    }

    @Test("Send again on a text that may have been posted looks first, and where the writer's own posts hold it, lets it go and sends nothing")
    func lookedForAndFound() async throws {
        let disk = Disk()
        defer { disk.remove() }
        // Among its writer's newest: a post to one person alone, an old one, and the text.
        let own = "[\(Self.status("a word to one person", id: "60")),\(Self.status("from long ago", after: -90_000, id: "61")),\(Self.status("did this go"))]"
        let (session, server, entry) = try await maybePosted(own: [own], disk: disk)

        #expect(session.outbox.again(entry.id, in: session))
        await session.outbox.settled()

        #expect(session.notes.map(\.body) == ["did this go"], "exactly the one post is landed, and nothing else the look read")
        #expect(session.notes.first?.categories == [.home, .public], "as a post just written is")
        #expect(session.said.lines.map(\.what) == [.found(entry.id, answer: false)])

        #expect(await server.looks == 1, "one read, and no second request")
        #expect(await server.posts.count == 1)
        #expect(session.outbox.sendings.isEmpty)
        #expect(session.resendingUnsent == nil)
        #expect(session.notes.contains { $0.body == "did this go" }, "and the post is on the page")
        #expect(try disk.texts().isEmpty)
    }

    @Test("Not found, and asked longer ago than its source keeps the key: the person is asked first, told it may post twice and where to look; Cancel sends nothing, and the yes sends it under the key it had")
    func notFoundPastTheKeysLife() async throws {
        let (session, server, entry) = try await maybePosted(own: ["[\(Self.status("somebody's other post", id: "60"))]"])
        session.outbox.now = { Date().addingTimeInterval(ShellOutbox.keyLife + 1) }
        let revision = await session.store.revision

        #expect(session.outbox.again(entry.id, in: session))
        await session.outbox.settled()

        #expect(session.notes.isEmpty, "a look that finds nothing lands nothing")
        #expect(await session.store.revision == revision, "and leaves the store untouched")

        #expect(await server.looks == 1, "looked, and not sent")
        #expect(await server.posts.count == 1)
        #expect(session.resendingUnsent == UnsentAsk(id: entry.id))
        #expect(session.raisesOverPages)
        #expect(session.outbox.sendings.first?.standing == .unconfirmed)
        let question = ShellQuestion.resend(entry, changed: false)
        #expect(question.title == "Send this post anyway?")
        #expect(question.line == "It may have been posted to social.example already. Sent again now, it may be posted twice.")
        #expect(question.help == "Fediqo looked and could not tell. Reload your Home, or open your posts on social.example, to see whether it is there before sending.")
        #expect(question.choices.map(\.label) == ["Send anyway"] && question.choices.map(\.role) == [.destructive])
        #expect(question.cancel != nil)

        session.resendingUnsent = nil
        await session.outbox.settled()
        #expect(await server.posts.count == 1, "Cancel sends nothing")

        #expect(session.outbox.sendAnyway(entry.id, in: session))
        await session.outbox.settled()
        #expect(await server.keys == [entry.id.uuidString, entry.id.uuidString])
        #expect(session.outbox.sendings.isEmpty)
    }

    @Test("A look that could not be had asks first too, however lately the text was asked")
    func theLookFailed() async throws {
        let (session, server, entry) = try await maybePosted(own: [nil])
        #expect(session.outbox.again(entry.id, in: session))
        await session.outbox.settled()
        #expect(await server.looks == 1)
        #expect(await server.posts.count == 1)
        #expect(session.resendingUnsent == UnsentAsk(id: entry.id))
        #expect(session.outbox.sendings.first?.standing == .unconfirmed)
    }

    // MARK: - Not on disk

    @Test("A text that could not be written to this device is not sent: it stands in memory saying so, with Send anyway, Copy and Discard — whether the write failed or this run has no store to write — and Send anyway is the person's to press")
    func notKeptNotSent() async throws {
        let server = PostServer()
        let (session, _) = try await run(server)
        // What the app answers where the write failed, and where this run has no store file.
        session.persistUnsent = { false }
        var heard: [String] = []
        session.said.announce = { heard.append($0) }

        #expect(post("only in memory", in: session))
        await session.outbox.settled()

        #expect(await server.posts.isEmpty, "the request did not leave")
        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.standing == .unkept && entry.unsent.text == "only in memory")
        #expect(entry.unsent.standing != .asked && entry.unsent.askedAt == nil, "never held as asked: it was not")
        #expect(await session.store.unsentHeld().first?.standing == .fresh)
        #expect(line(entry, in: session) == "Your post could not be kept on this device, so it was not sent to social.example. Sent now, it would be lost if this did not finish.")
        #expect(heard.last == line(entry, in: session))
        #expect(presses(entry, in: session) == [.anyway, .copy, .discard])
        #expect(!session.outbox.again(entry.id, in: session))

        SaidStrip.pressed(OutboxPressed(press: .anyway, id: entry.id), in: session)
        await session.outbox.settled()
        #expect(await server.keys == [entry.id.uuidString])
        #expect(session.outbox.sendings.isEmpty && session.notes.map(\.body) == ["only in memory"])
    }

    // MARK: - What changed while something was awaited

    @Test("Somebody else signing in while a text is being written down as asked: the request does not leave, and the text is not held as asked")
    func replacedDuringTheWrite() async throws {
        let server = PostServer()
        let (session, tokens) = try await run(server)
        let write = Gate()
        let watchdog = hangGuard(write)
        defer { watchdog.cancel() }
        var writes = 0
        // The first write is the text as taken; the second is it as asked, held here.
        session.persistUnsent = {
            writes += 1
            if writes == 2 { await write.wait() }
            return true
        }
        #expect(post("pressed as me", in: session))
        #expect(await spun { writes == 2 })
        try tokens.save(Self.token(Self.host, "tok-2"))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        await write.open()
        await session.outbox.settled()

        #expect(await server.posts.isEmpty, "nothing went out as somebody else")
        let entry = try #require(session.outbox.sendings.first)
        #expect(entry.standing == .failed(.unreachable))
        #expect(entry.unsent.askedAt == nil, "it was never asked")
        #expect(await session.store.unsentHeld().first?.standing == .unreachable)
    }

    @Test("A source removed while its text is on the wire leaves nothing of the text behind, in memory or in the file; and a text being discarded is not sent from under the discard")
    func goneWhileItWaited() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer([.error(.timedOut), .error(.notConnectedToInternet)], holding: [0: gate])
        let (session, _) = try await run(server, hosts: [Self.host, Self.other], disk: disk)
        #expect(post("on the wire as its source goes", in: session))
        #expect(await spun { await server.posts.count == 1 })

        await session.remove(host: Self.host)
        #expect(session.outbox.sendings.isEmpty)
        await gate.open()
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        #expect(await session.store.unsentHeld().isEmpty, "the answer coming back wrote nothing of it down again")
        #expect(try disk.texts().isEmpty)

        // A discard, held at its write: Send again does nothing meanwhile.
        let elsewhere = PostServer([.error(.notConnectedToInternet)], host: Self.other)
        let (other, _) = try await run(elsewhere, hosts: [Self.other])
        #expect(post("to be discarded", to: Self.other, in: other))
        await other.outbox.settled()
        let id = try #require(other.outbox.sendings.first?.id)
        let write = Gate()
        let second = hangGuard(write)
        defer { second.cancel() }
        other.persistUnsent = { await write.wait(); return true }
        other.outbox.discardSoon(id, in: other)
        for _ in 0..<50 { await Task.yield() }
        #expect(!other.outbox.again(id, in: other))
        #expect(!other.outbox.edit(id, in: other))
        await write.open()
        await other.outbox.settled()
        #expect(other.outbox.sendings.isEmpty)
        #expect(await other.store.unsentHeld().isEmpty)
        #expect(await elsewhere.posts.count == 1)
    }

    // MARK: - Not said to be gone while the file holds it

    private static let unremoved = "Your post for social.example could not be removed from this device. Its words are still kept here: discard it again to try once more."

    /// A run holding one text known not to have gone, whose writes of the texts fail while
    /// the flag it hands back is up — and every write of the store with them, where `whole`.
    @MainActor
    private final class Failing {
        var on = true
    }

    private func unwritable(
        _ words: String, hosts: [String] = [host], disk: Disk, whole: Bool = false
    ) async throws -> (ShellSession, PostServer, UUID, Failing) {
        let server = PostServer([.error(.notConnectedToInternet)])
        let (session, _) = try await run(server, hosts: hosts, disk: disk)
        #expect(post(words, in: session))
        await session.outbox.settled()
        let failing = Failing()
        let texts = session.persistUnsent
        session.persistUnsent = { failing.on ? false : await texts?() ?? false }
        if whole, let store = session.persist { session.persist = { failing.on ? false : await store() } }
        return (session, server, try #require(session.outbox.sendings.first?.id), failing)
    }

    @Test("A discard whose write did not land is not said to be gone: the line stands, saying aloud that it could not be removed from this device, with Discard alone; nothing sends or opens it; and Discard again — no second question — takes it off the disk")
    func discardNotWritten() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let (session, server, id, failing) = try await unwritable("larkspur-ridge, to be discarded", disk: disk)
        var heard: [String] = []
        session.said.announce = { heard.append($0) }

        await session.outbox.discard(id, in: session)

        let entry = try #require(session.outbox.sendings.first, "it did not silently vanish")
        #expect(entry.standing == .unremoved)
        #expect(try disk.holds("larkspur-ridge"), "the file still holds its words")
        #expect(line(entry, in: session) == Self.unremoved)
        #expect(heard == [Self.unremoved], "and a listener is told")
        #expect(OutboxWords.line(entry, hold: nil, whom: nil, language: .taiwanese)
            == "你要送往 social.example 的貼文沒辦法從這個裝置移除。它的文字還留在這裡：再丟棄一次試試。")
        #expect(presses(entry, in: session) == [.discard])
        #expect(OutboxWords.symbol(entry) == SaidStrip.symbol)
        #expect(!session.outbox.again(id, in: session) && !session.outbox.edit(id, in: session))
        #expect(!session.outbox.sendAnyway(id, in: session) && !session.outbox.sendUnkept(id, in: session))
        session.outbox.write(id, text: "typed over it")
        #expect(session.outbox.sendChanged(id, in: session) == nil)

        // Tried again while the disk still refuses: it stands as it stood.
        SaidStrip.pressed(OutboxPressed(press: .discard, id: id), in: session)
        #expect(session.discardingUnsent == nil, "the yes was given: it is not asked again")
        await session.outbox.settled()
        #expect(session.outbox.sendings.first?.standing == .unremoved)

        failing.on = false
        SaidStrip.pressed(OutboxPressed(press: .discard, id: id), in: session)
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        #expect(try disk.texts().isEmpty)
        #expect(try !disk.holds("larkspur-ridge"))
        #expect(await server.posts.count == 1)
    }

    @Test("Removing a source whose texts could not be taken off the disk does not leave them unsaid: each stands again as not removed from this device — not as a text whose source is gone — and Discard takes it off")
    func removedNotWritten() async throws {
        let disk = Disk()
        defer { disk.remove() }
        // Nothing can be written: a Remove waits for a save of the whole store too, which
        // would take the texts out with it where it landed.
        let (session, _, id, failing) = try await unwritable(
            "marram-dune, as its source goes", hosts: [Self.host, Self.other], disk: disk, whole: true
        )
        var heard: [String] = []
        session.said.announce = { heard.append($0) }

        await session.remove(host: Self.host)

        #expect(!session.isAdded(Self.host))
        let entry = try #require(session.outbox.sendings.first, "its words are in the file: it is not said to be gone")
        #expect(entry.id == id && entry.standing == .unremoved)
        #expect(try disk.holds("marram-dune"))
        #expect(line(entry, in: session) == Self.unremoved)
        #expect(heard.contains(Self.unremoved))
        #expect(presses(entry, in: session) == [.discard])
        #expect(await session.store.unsentHeld().isEmpty, "the store let it go: only the file is behind")

        failing.on = false
        SaidStrip.pressed(OutboxPressed(press: .discard, id: id), in: session)
        await session.outbox.settled()
        #expect(session.outbox.sendings.isEmpty)
        #expect(try disk.texts().isEmpty)
        #expect(try !disk.holds("marram-dune"))
    }

    @Test("A text that could not be taken off the disk is off it once a save of the whole store lands: its line goes with nobody pressing, and so does what was said of anything else not yet off this device")
    func aSaveThatLandsTakesItOff() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let (session, _, id, failing) = try await unwritable("sorrel-quay words", disk: disk, whole: true)
        await session.outbox.discard(id, in: session)
        #expect(await !session.saveNow(.posts))
        #expect(session.outbox.sendings.first?.standing == .unremoved && session.said.lines.count == 1)
        #expect(try disk.holds("sorrel-quay"))

        failing.on = false
        session.saveSoon()
        await session.saved()

        #expect(session.outbox.sendings.isEmpty, "the line still says the file holds what it no longer does")
        #expect(session.said.lines.isEmpty)
        #expect(try disk.texts().isEmpty && !disk.holds("sorrel-quay"))
    }

    @Test("A post that landed while the write taking its text out of the file failed: the line goes — the post is there — and the save behind the landing takes the row out")
    func landedNotWritten() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let (session, _) = try await run(PostServer(), disk: disk)
        let texts = session.persistUnsent
        var writes = 0
        // The text as taken, the text as asked, and then the write that takes it out: failed.
        session.persistUnsent = {
            writes += 1
            return writes < 3 ? await texts?() ?? false : false
        }
        #expect(post("sorrel-bank, landed", in: session))
        await session.outbox.settled()

        #expect(writes == 3)
        #expect(session.outbox.sendings.isEmpty && session.notes.map(\.body) == ["sorrel-bank, landed"])
        await session.saved()
        #expect(try disk.texts().isEmpty, "the next save wrote the texts again")
    }

    @Test("A text seen to have arrived while the write taking it out of the file failed: the line goes, and a save is asked for that takes the row out")
    func arrivedNotWritten() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let (session, _, entry) = try await maybePosted("thrift-cove, did it go", disk: disk)
        session.persistUnsent = { false }

        try await landed(Self.status("thrift-cove, did it go"), in: session)
        #expect(session.outbox.sendings.isEmpty)
        #expect(session.said.lines.map(\.what) == [.found(entry.id, answer: false)])
        await session.outbox.settled()
        await session.saved()
        #expect(try disk.texts().isEmpty, "not left for the next launch to draw as maybe posted")
    }

    @Test("A run that reads back the row of a text whose post the last run landed lets it go at once — by its writer, at its source, published when it was asked, with its words — and does not draw it as maybe posted")
    func aStaleRowAtLaunch() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let (first, _) = try await run(PostServer(), disk: disk)
        // The fixture's source publishes at this moment.
        first.outbox.now = { Date(timeIntervalSince1970: 1_717_200_000) }
        var asked: Unsent?
        let texts = first.persistUnsent
        first.persistUnsent = {
            if let row = await first.store.unsentHeld().first, row.standing == .asked { asked = row }
            return await texts?() ?? false
        }
        #expect(post("campion-lane, landed", in: first))
        await first.outbox.settled()
        await first.saved()
        #expect(try disk.texts().isEmpty)
        // The write that took it out never landed: the file holds the row as it was asked.
        let row = try #require(asked)
        try await StoreFile(at: disk.dir).save(unsent: [row])

        let (second, _) = try await run(PostServer(), disk: disk)

        #expect(second.notes.map(\.body) == ["campion-lane, landed"])
        #expect(second.outbox.sendings.isEmpty, "its post is held: it is not drawn as maybe posted")
        #expect(second.said.lines.map(\.what) == [.found(row.id, answer: false)])
        await second.outbox.settled()
        #expect(try disk.texts().isEmpty)
    }

    @Test("A source removed while a text's own write has not reached the store: that write is not taken afterwards, nothing of the text is written once Remove has said done, and its send comes back to nothing")
    func removedBeforeItsOwnWrite() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer()
        let (session, _) = try await run(server, hosts: [Self.host, Self.other], disk: disk)
        let hold = Gate()
        let watchdog = hangGuard(hold)
        defer { watchdog.cancel() }
        session.outbox.holding = { await hold.wait() }
        // What the store held of the texts at each write made after Remove said it was done.
        var late: [String] = []
        var done = false
        let texts = session.persistUnsent
        session.persistUnsent = {
            if done { late += await session.store.unsentHeld().map(\.text) }
            return await texts?() ?? false
        }
        #expect(post("yarrow-field, held before its write", in: session))
        // Its send has taken the write to wait on: Remove finds none to wait for.
        #expect(await spun { session.outbox.sendings.first?.standing == .onItsWay })

        await session.remove(host: Self.host)
        done = true
        #expect(session.outbox.sendings.isEmpty)
        #expect(try !disk.holds("yarrow-field"))

        await hold.open()
        await session.outbox.settled()
        #expect(late.isEmpty, "a write from before the letting go put the text back")
        #expect(await session.store.unsentHeld().isEmpty)
        #expect(try disk.texts().isEmpty)
        #expect(try !disk.holds("yarrow-field"))
        #expect(await server.posts.isEmpty)
    }

    // MARK: - A handle is its source's word

    @Test("A handle a source sent is drawn in a line of ours with no direction mark, control character or line break of its own, for who wrote a text and for who is signed in — and who wrote it is told by the id, whatever the handle says")
    func handlesMadeFit() async throws {
        let server = PostServer([.error(.notConnectedToInternet)])
        let (session, tokens) = try await run(server)
        #expect(post("written as me", in: session))
        await session.outbox.settled()
        let entry = try #require(session.outbox.sendings.first)
        func token(_ access: String, _ id: String, _ handle: String) -> MastodonToken {
            MastodonToken(
                host: Self.host, accessToken: access, clientID: "cid", clientSecret: "csecret", scopes: Self.writing,
                accountID: id, handle: handle
            )
        }
        func fit(_ line: String) -> Bool {
            line.unicodeScalars.allSatisfy {
                ![.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            }
        }

        // Somebody else, whose source spells them with an override, a bell and a line break.
        let raw = "@oth\u{202E}er\u{0007}\n\u{2066}@social.example"
        try tokens.save(token("tok-2", "2", raw))
        session.mastodon.refresh()
        #expect(session.mastodon.reader(host: Self.host)?.handle == raw, "kept as sent, for what it is compared with")
        #expect(session.outbox.hold(entry, in: session) == .otherAccount(here: "@other @social.example"))
        let said = line(entry, in: session)
        #expect(said == "Your post was written as @me@social.example, and social.example is signed in as @other @social.example. Sign in as @me@social.example to send it.")
        #expect(fit(said))

        // The writer's own handle, as a row written by an earlier build may hold it.
        var dirty = entry.unsent
        dirty.writer = "@m\u{202E}e\u{200B}\r\n@social.example"
        for hold in [ShellOutbox.Hold.otherAccount(here: nil), .otherAccount(here: "@other@social.example")] {
            let line = OutboxWords.line(ShellOutbox.Sending(unsent: dirty, standing: .failed(.unreachable)), hold: hold, whom: nil)
            #expect(fit(line) && line.contains("@me @social.example"), "\(hold)")
        }

        // The writer again under another sign-in, spelt otherwise: the id says who it is.
        try tokens.save(token("tok-3", "1", "@renamed\u{202E}@social.example"))
        session.mastodon.refresh()
        #expect(session.outbox.hold(entry, in: session) == nil)
        // And a post is theirs by the handle as its source sent it, never by one made fit.
        dirty.standing = .asked
        dirty.askedAt = Date()
        let theirs = Note(
            id: "https://\(Self.host)/users/me/statuses/5", source: Source(host: Self.host, kind: .mastodon),
            author: "Me", handle: dirty.writer ?? "", body: "written as me", postedAt: Date(), categories: [.home],
            audience: .everyone, statusID: "5"
        )
        #expect(ShellOutbox.isPost(theirs, of: dirty, answering: nil))
    }

    // MARK: - The sign-in the look went with

    @Test("A sign-in replaced while a text is looked for among its writer's posts — the same account under another sign-in — takes in nothing the look read: the text stays as it was, and the person is asked before anything is sent")
    func replacedDuringTheLook() async throws {
        let look = Gate()
        let watchdog = hangGuard(look)
        defer { watchdog.cancel() }
        let server = PostServer([.error(.timedOut)], own: ["[\(Self.status("did this go"))]"], looking: look)
        let (session, tokens) = try await run(server)
        #expect(post("did this go", in: session))
        await session.outbox.settled()
        let entry = try #require(session.outbox.sendings.first)
        let revision = await session.store.revision

        #expect(session.outbox.again(entry.id, in: session))
        #expect(await spun { await server.looks == 1 })
        try tokens.save(Self.token(Self.host, "tok-3", knownAs: "1"))
        session.mastodon.refresh()
        #expect(session.outbox.hold(entry, in: session) == nil, "the premise: the writer still, by the id")
        await look.open()
        await session.outbox.settled()

        #expect(session.notes.isEmpty, "what the old sign-in's read brought is taken in for nobody")
        #expect(await session.store.revision == revision)
        #expect(session.said.lines.isEmpty)
        #expect(session.outbox.sendings.map(\.standing) == [.unconfirmed], "the text stays as it was")
        #expect(session.resendingUnsent == UnsentAsk(id: entry.id))
        #expect(await server.posts.count == 1)
    }

    // MARK: - Two windows over one store

    /// A second window beside `first`: a session and an outbox of its own over the same store,
    /// the same sign-ins and the same file, as a Mac's second window is. It has adopted what
    /// the store holds, and follows nothing by itself.
    private func window(beside first: ShellSession) async -> ShellSession {
        let second = ShellSession(http: FixtureHTTP(), store: first.store, mastodon: first.mastodon)
        second.said.announce = { _ in }
        second.persist = first.persist
        second.persistUnsent = first.persistUnsent
        await second.reloadFromStore()
        await second.adoptUnsent()
        return second
    }

    @Test("A text discarded in one window is gone from the other as the store says so, and from the file; and where it stood in the second was the store's word of it")
    func discardedInOneWindowIsGoneInTheOther() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.http(422)])
        let (first, _) = try await run(server, disk: disk)
        #expect(post("juniper-anvil words", in: first))
        await first.outbox.settled()
        let second = await window(beside: first)
        let following = Task { await second.followStore() }
        defer { following.cancel() }

        let drawn = try #require(second.outbox.sendings.first)
        #expect(drawn == first.outbox.sendings.first, "the second window draws what the first does")
        #expect(drawn.standing == .failed(.declined))
        #expect(presses(drawn, in: second) == [.again, .edit, .discard])

        await first.outbox.discard(drawn.id, in: first)

        #expect(first.outbox.sendings.isEmpty)
        #expect(await spun { second.outbox.sendings.isEmpty }, "the second window still offers a text the first discarded")
        #expect(try disk.texts().isEmpty)
        #expect(await server.posts.count == 1)
    }

    @Test("A text that lands through one window is drawn as on its way in the other while it is out, with nothing to press, and is gone from both when it lands")
    func landedInOneWindowIsGoneInTheOther() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer([.error(.notConnectedToInternet), .yes], holding: [1: gate])
        let (first, _) = try await run(server)
        #expect(post("hello twice", in: first))
        await first.outbox.settled()
        let second = await window(beside: first)
        let following = Task { await second.followStore() }
        defer { following.cancel() }
        let id = try #require(second.outbox.sendings.first?.id)
        #expect(second.outbox.sendings.first?.standing == .failed(.unreachable))

        #expect(first.outbox.again(id, in: first))
        #expect(await spun { await server.posts.count == 2 })
        // The request is held at the source: the other window says so, and offers nothing.
        #expect(await spun { second.outbox.sendings.first?.standing == .onItsWay })
        #expect(presses(try #require(second.outbox.sendings.first), in: second).isEmpty)
        #expect(!second.outbox.again(id, in: second) && !second.outbox.edit(id, in: second))

        await gate.open()
        await first.outbox.settled()
        #expect(first.outbox.sendings.isEmpty)
        #expect(await spun { second.outbox.sendings.isEmpty }, "the second window still holds a text that landed")
        #expect(await spun { second.notes.map(\.body) == ["hello twice"] })
        #expect(await server.posts.count == 2)
    }

    @Test("Send again pressed in two windows, the second while the first's request is on the wire and before it has heard: one request leaves, and the second draws the text as on its way")
    func sendAgainInTwoWindowsSendsOnce() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer([.error(.notConnectedToInternet), .yes], holding: [1: gate])
        let (first, _) = try await run(server)
        #expect(post("only once", in: first))
        await first.outbox.settled()
        let second = await window(beside: first)
        let id = try #require(second.outbox.sendings.first?.id)

        #expect(first.outbox.again(id, in: first))
        #expect(await spun { await server.posts.count == 2 })
        // Held at the source, and the second window has not looked at the store since: its
        // line still says it was not sent, with Send again live.
        #expect(second.outbox.sendings.first?.standing == .failed(.unreachable))
        #expect(second.outbox.again(id, in: second), "the press is taken: only the store can say who sends")
        await second.outbox.settled()

        #expect(await server.posts.count == 2, "the second window sent the text the first has on the wire")
        #expect(second.outbox.sendings.first?.standing == .onItsWay)
        #expect(presses(try #require(second.outbox.sendings.first), in: second).isEmpty)

        await gate.open()
        await first.outbox.settled()
        await second.reloadFromStore()
        #expect(first.outbox.sendings.isEmpty && second.outbox.sendings.isEmpty)
        #expect(await server.posts.count == 2)
        #expect(await first.store.unsentHeld().isEmpty)
        #expect(first.notes.map(\.body) == ["only once"])
    }

    @Test("A text that may have been posted, sent again from two windows at once — each looked, neither found it, and the first's request is on the wire: the store gives the sending to one, and the other sends nothing")
    func theStoreGivesTheSendingToOne() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer([.http(500), .yes, .yes], holding: [1: gate], own: ["[]", "[]"])
        let (first, _) = try await run(server)
        #expect(post("one of two", in: first))
        await first.outbox.settled()
        let second = await window(beside: first)
        let id = try #require(second.outbox.sendings.first?.id)
        #expect(second.outbox.sendings.first?.standing == .unconfirmed && second.outbox.mayHaveBeenPosted(id))

        #expect(first.outbox.again(id, in: first))
        #expect(await spun { await server.posts.count == 2 })
        // Held at the source. What the store holds of the text is what the second window
        // already has — asked, as it was — so nothing but who is sending it says it is out.
        #expect(await first.store.unsentHeld() == [try #require(second.outbox.sendings.first?.unsent)])
        #expect(second.outbox.again(id, in: second))
        await second.outbox.settled()

        #expect(await server.looks == 2, "the second window looked for it too")
        #expect(await server.posts.count == 2, "two windows sent one text at once")
        #expect(second.outbox.sendings.first?.standing == .onItsWay)

        await gate.open()
        await first.outbox.settled()
        await second.reloadFromStore()
        #expect(first.outbox.sendings.isEmpty && second.outbox.sendings.isEmpty)
        #expect(await server.posts.count == 2)
    }

    @Test("Send again in a window that has not heard the text was discarded in another: the store will not hold it, so nothing is sent and its line goes")
    func sendAgainOnATextDiscardedElsewhereSendsNothing() async throws {
        let disk = Disk()
        defer { disk.remove() }
        let server = PostServer([.http(422)])
        let (first, _) = try await run(server, disk: disk)
        #expect(post("thistle-harbour words", in: first))
        await first.outbox.settled()
        let second = await window(beside: first)
        let id = try #require(second.outbox.sendings.first?.id)
        second.editingUnsent = UnsentAsk(id: id)

        await first.outbox.discard(id, in: first)
        // Not looked at the store since: Send again is live on a text that is gone.
        #expect(presses(try #require(second.outbox.sendings.first), in: second) == [.again, .edit, .discard])
        #expect(second.outbox.again(id, in: second))
        await second.outbox.settled()

        #expect(await server.posts.count == 1, "a discarded text was posted")
        #expect(second.outbox.sendings.isEmpty, "the line of a text that is gone stands")
        #expect(second.editingUnsent == nil, "a sheet on a text that is gone stays up")
        #expect(await first.store.unsentHeld().isEmpty)
        #expect(try disk.texts().isEmpty && !disk.holds("thistle-harbour"))
    }

    @Test("A text one window sent and got no answer for may have been posted in every window: the other looks first, and one that has not heard yet and presses Send again sends nothing")
    func askedThroughAnotherWindowIsNotSentBlind() async throws {
        let server = PostServer([.http(422), .http(500)], own: [nil])
        let (first, _) = try await run(server)
        #expect(post("maybe there", in: first))
        await first.outbox.settled()
        let second = await window(beside: first)
        let id = try #require(second.outbox.sendings.first?.id)
        #expect(!second.outbox.mayHaveBeenPosted(id))

        #expect(first.outbox.again(id, in: first))
        await first.outbox.settled()
        #expect(first.outbox.sendings.first?.standing == .unconfirmed)
        // The second window has not heard: to it the text was not sent, and Send again sends.
        #expect(second.outbox.sendings.first?.standing == .failed(.declined))
        #expect(second.outbox.again(id, in: second))
        await second.outbox.settled()

        #expect(await server.posts.count == 2, "sent again on a press made before it was known it may have landed")
        #expect(second.outbox.sendings.first?.standing == .unconfirmed)
        #expect(second.outbox.mayHaveBeenPosted(id))
        // And from there it is looked for before it is sent, as in the window that sent it.
        #expect(second.outbox.again(id, in: second))
        await second.outbox.settled()
        #expect(await server.looks == 1)
        #expect(await server.posts.count == 2)
        #expect(second.resendingUnsent?.id == id, "a look that could not be had asks first")
    }

    @Test("Discard in a window that has not heard another is sending the text: nothing is discarded under the request, and the line is drawn as on its way")
    func aTextBeingSentElsewhereIsNotDiscarded() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer([.error(.notConnectedToInternet), .yes], holding: [1: gate])
        let (first, _) = try await run(server)
        #expect(post("not under it", in: first))
        await first.outbox.settled()
        let second = await window(beside: first)
        let id = try #require(second.outbox.sendings.first?.id)

        #expect(first.outbox.again(id, in: first))
        #expect(await spun { await server.posts.count == 2 })
        await second.outbox.discard(id, in: second)

        #expect(await first.store.unsentHeld().map(\.id) == [id], "discarded while its request was on the wire")
        #expect(second.outbox.sendings.first?.standing == .onItsWay)

        await gate.open()
        await first.outbox.settled()
        await second.reloadFromStore()
        #expect(second.outbox.sendings.isEmpty && first.notes.map(\.body) == ["not under it"])
    }

    @Test("A sheet open on a text in one window closes when another window starts sending it, and what was typed there is in the sheet again where the text comes back as not sent")
    func aSheetOnATextSentElsewhereCloses() async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer([.error(.notConnectedToInternet), .http(422)], holding: [1: gate])
        let (first, _) = try await run(server)
        #expect(post("as written", in: first))
        await first.outbox.settled()
        let second = await window(beside: first)
        let id = try #require(second.outbox.sendings.first?.id)
        #expect(second.outbox.edit(id, in: second))
        second.outbox.write(id, text: "typed over it")
        #expect(second.editingUnsent?.id == id)

        #expect(first.outbox.again(id, in: first))
        #expect(await spun { await server.posts.count == 2 })
        await second.reloadFromStore()

        #expect(second.editingUnsent == nil, "a sheet whose Send can send nothing stays up")
        #expect(second.outbox.sendings.first?.standing == .onItsWay)

        await gate.open()
        await first.outbox.settled()
        await second.reloadFromStore()
        #expect(second.outbox.sendings.first?.standing == .failed(.declined))
        #expect(second.outbox.edit(id, in: second))
        #expect(second.outbox.draft(id) == "typed over it" && second.outbox.changed(id) == "typed over it")
        #expect(await server.texts == ["as written", "as written"])
    }

    @Test("One sender a text, decided in the store: the first to take it has it until it gives it back or the text is let go, and a text let go of is not held again")
    func oneSenderATextInTheStore() async {
        let store = ItemStore()
        let text = Unsent(host: Self.host, text: "words", audience: .everyone)
        let (one, two) = (UUID(), UUID())
        await store.hold(text)
        let before = await store.unsentRevision

        #expect(await store.claim(unsent: text.id, for: one))
        #expect(await store.claim(unsent: text.id, for: one), "its own sender is refused it")
        #expect(await !store.claim(unsent: text.id, for: two))
        #expect(await store.unsentView().senders == [text.id: one])
        await store.release(unsent: text.id, from: two)
        #expect(await !store.claim(unsent: text.id, for: two), "given back by somebody who did not have it")
        await store.release(unsent: text.id, from: one)
        #expect(await store.claim(unsent: text.id, for: two))
        #expect(await store.unsentRevision == before, "who is sending a text is nothing a save writes")

        let mark = await store.unsentMark
        await store.letGo(unsent: text.id)
        let view = await store.unsentView()
        #expect(view.texts.isEmpty && view.senders.isEmpty && view.gone == [text.id] && view.mark > mark)
        #expect(await !store.hold(text))
    }

    // MARK: - The words

    @Test("Every sentence and every press of the outbox has words in each language, and the two Chinese files agree")
    func everyWord() throws {
        let kinds = ["post", "answer"]
        var keys = ["sending", "looking", "failed", "refused", "declined", "unconfirmed", "unkept", "unremoved", "hold.signedOut",
                    "hold.noSource", "hold.other", "hold.other.unknown", "hold.unnamed", "discard.title",
                    "discard.title.unconfirmed", "resend.title"]
            .flatMap { key in kinds.map { "outbox.\(key).\($0)" } }
        keys += ["outbox.sending.answer.to", "outbox.hold.answered.answer", "outbox.discard.line",
                 "outbox.discard.line.unconfirmed", "outbox.discard.detail.unconfirmed", "outbox.discard.confirm.unconfirmed",
                 "outbox.edit.title", "outbox.edit.title.unconfirmed", "outbox.edit.goesTo", "outbox.resend.line",
                 "outbox.resend.line.changed", "outbox.resend.detail", "outbox.resend.confirm", "question.unsent.go",
                 "outbox.found.post", "outbox.found.answer", "work.purpose.ownPosts"]
        keys += OutboxWords.Press.allCases.flatMap { ["outbox.\($0.rawValue)", "outbox.\($0.rawValue).spoken"] }
        for key in keys {
            let english = L10n.t(key, language: .english), chinese = L10n.t(key, language: .taiwanese)
            #expect(english != key && chinese != key && english != chinese, "\(key) has no words of its own in a language")
        }
        #expect(L10n.count("question.unsent.go", 1, language: .english) == "The 1 text waiting to be sent to it is deleted.")
        for press in OutboxWords.Press.allCases {
            #expect(OutboxWords.spoken(press, host: Self.host).contains(Self.host), "a listener is told which source")
        }
        let unsent = Unsent(host: Self.host, text: "x", audience: .followers)
        #expect(UnsentSheet.goesTo(unsent) == "Goes to social.example, private")
        // Every way a line can stand says something of its own.
        let all: [ShellOutbox.Standing] = [.onItsWay, .looking, .unconfirmed, .unkept, .unremoved, .failed(.refused), .failed(.declined), .failed(.unreachable)]
        let said = all.map { OutboxWords.line(ShellOutbox.Sending(unsent: unsent, standing: $0), hold: nil, whom: nil) }
        #expect(Set(said).count == all.count)
        #expect(OutboxWords.line(ShellOutbox.Sending(unsent: unsent, standing: .failed(.unreachable)), hold: .noSource, whom: nil)
            == "social.example is no longer a source here, so your post cannot be sent.")
        // Where to look is said in every language, for a text that may have been posted.
        for language in [DummyLanguage.english, .taiwanese] {
            let maybe = OutboxWords.line(ShellOutbox.Sending(unsent: unsent, standing: .unconfirmed), hold: nil, whom: nil, language: language)
            #expect(maybe.components(separatedBy: Self.host).count == 3, "\(language): it names the source, and where to look")
        }
        #expect(OutboxWords.opening("two\nlines " + String(repeating: "word ", count: 40)).hasPrefix("two lines word"))
        #expect(OutboxWords.opening(String(repeating: "word ", count: 40)).count <= 81)
    }

    // MARK: - The strip, hosted

    private struct Page: View {
        let session: ShellSession

        var body: some View {
            Color.clear.modifier(SaidStrip(said: session.said, session: session))
        }
    }

    private func hosted(
        _ session: ShellSession, width: CGFloat, layout: ShellLayout, type: DynamicTypeSize = .large, corner: CGSize = .zero
    ) -> SaidProbe {
        let probe = SaidProbe()
        let view = NSHostingView(
            rootView: Page(session: session)
                .environment(\.shellSaidProbe, probe)
                .environment(\.shellFloatingCorner, corner)
                .environment(\.shellLayout, layout)
                .dynamicTypeSize(type)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            view.layoutSubtreeIfNeeded()
        }
        return probe
    }

    private static func ideal(_ view: some View, _ type: DynamicTypeSize) -> CGSize {
        NSHostingView(rootView: view.fixedSize().dynamicTypeSize(type)).fittingSize
    }

    private static func wrapped(_ text: some View, width: CGFloat, _ type: DynamicTypeSize) -> CGFloat {
        NSHostingView(
            rootView: text.fixedSize(horizontal: false, vertical: true).frame(width: width).dynamicTypeSize(type)
        ).fittingSize.height
    }

    /// A run holding one text that did not arrive and, behind it in the strip, one line of
    /// something else not done.
    private func failedOnce(host: String = host) async throws -> (ShellSession, ShellOutbox.Sending) {
        let server = PostServer([.error(.notConnectedToInternet)], host: host)
        let (session, _) = try await run(server, hosts: [host])
        #expect(post("words that did not arrive", to: host, in: session))
        await session.outbox.settled()
        session.said.say(Said(.notice(.dismiss), .refused, host: host))
        return (session, try #require(session.outbox.sendings.first))
    }

    @Test("What is being sent is a line in the strip with nothing to press; what did not arrive is drawn before every other line, with its three presses",
          arguments: [ShellLayout.wide, .narrow])
    func drawnInTheStrip(_ layout: ShellLayout) async throws {
        let gate = Gate()
        let watchdog = hangGuard(gate)
        defer { watchdog.cancel() }
        let server = PostServer(holding: [0: gate])
        let (sending, _) = try await run(server)
        #expect(post("on its way", in: sending))
        let width: CGFloat = layout == .wide ? 600 : 320
        let out = hosted(sending, width: width, layout: layout)
        let outName = StripLine.id(try #require(sending.outbox.sendings.first?.id))
        #expect(out.frames[.line(outName)] != nil && out.frames[.words(outName)] != nil)
        #expect(OutboxWords.Press.allCases.allSatisfy { out.frames[.press(outName, $0)] == nil })
        #expect(out.frames[.close(outName)] == nil, "no press takes down what is being sent")
        await gate.open()
        await sending.outbox.settled()

        let (session, entry) = try await failedOnce()
        let probe = hosted(session, width: width, layout: layout)
        let name = StripLine.id(entry.id)
        let line = try #require(probe.frames[.line(name)])
        for press in [OutboxWords.Press.again, .edit, .discard] {
            let frame = try #require(probe.frames[.press(name, press)], "\(press) is not drawn")
            #expect(line.insetBy(dx: -0.5, dy: -0.5).contains(frame))
        }
        #expect(probe.frames[.press(name, .copy)] == nil)
        let other = probe.frames[.line(session.said.lines[0].id)]
        if layout == .wide {
            #expect(try #require(other).minY >= line.maxY - 0.5, "the text that waits stands first")
        } else {
            #expect(other == nil && probe.frames[.more] != nil, "a narrow page draws it alone, the rest behind the count")
        }
    }

    @Test("At 320 points, beside the compose button, a text that did not arrive is not cut: its sentence at the height it asks for, and each press at the size it asks for, clear of the others and of the button",
          arguments: [DummyFontSize.standard.dynamicType, DummyFontSize.largest.dynamicType, DynamicTypeSize.accessibility2])
    func nothingCutAt320(_ type: DynamicTypeSize) async throws {
        let width: CGFloat = 320
        let corner = FediqoRootView.composeCorner(canCompose: true)
        let (session, entry) = try await failedOnce(host: "a-rather-long-instance-name.example")
        let probe = hosted(session, width: width, layout: .narrow, type: type, corner: corner)
        let name = StripLine.id(entry.id)

        let edge = width - corner.width
        for (part, frame) in probe.frames {
            #expect(frame.minX >= -0.5 && frame.maxX <= edge + 0.5, "\(type): \(part) runs under the compose button or off the page")
        }
        let words = try #require(probe.frames[.words(name)], "\(type): the line is not drawn")
        let asks = Self.wrapped(Text(line(entry, in: session)).shellFont(.meta), width: words.width, type)
        #expect(words.height >= asks - 0.5, "\(type): the sentence is cut: \(words.height) of \(asks)")
        var drawn: [CGRect] = []
        for press in [OutboxWords.Press.again, .edit, .discard] {
            let frame = try #require(probe.frames[.press(name, press)], "\(type): \(press) is not drawn")
            let ideal = Self.ideal(ShellLinkButton(OutboxWords.word(press)) {}, type)
            // `fittingSize` is whole points, rounded up.
            #expect(frame.width >= ideal.width - 1 && frame.height >= ideal.height - 1, "\(type): \(press) is squeezed: \(frame.size) of \(ideal)")
            #expect(frame.minY >= words.maxY - 0.5, "\(type): \(press) lies over the sentence")
            #expect(drawn.allSatisfy { !$0.insetBy(dx: 0.5, dy: 0.5).intersects(frame) }, "\(type): \(press) lies over another press")
            drawn.append(frame)
        }
    }
}
