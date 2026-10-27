import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #316: Home is told where reading stopped only after that is chosen, and the line names both
/// places without moving the list.
@Suite("Where Home was left")
@MainActor
struct HomePlaceTests {
    private static let host = "m.example"
    private static let other = "n.example"

    private actor Wire: HTTPSender {
        struct Asked: Equatable, Sendable {
            let method: String
            let host: String
            let path: String
            let query: String
            let form: String
        }

        private(set) var asked: [Asked] = []
        private var place: String?
        private var failGet = false
        private var postStatus = 200
        private var holdGet = false
        private var held: CheckedContinuation<Void, Never>?

        func configure(place: String? = nil, failGet: Bool = false, postStatus: Int = 200, holdGet: Bool = false) {
            self.place = place
            self.failGet = failGet
            self.postStatus = postStatus
            self.holdGet = holdGet
        }

        /// Lets a held GET answer. Nothing where none is waiting.
        func release() {
            held?.resume()
            held = nil
            holdGet = false
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            let method = request.httpMethod ?? "GET"
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            asked.append(Asked(
                method: method, host: url.host ?? "", path: url.path, query: url.query ?? "", form: form
            ))
            if method == "GET", holdGet {
                await withCheckedContinuation { held = $0 }
            }
            if method == "GET", failGet { throw URLError(.cannotConnectToHost) }
            let status = method == "POST" ? postStatus : 200
            let id = method == "POST" ? Self.sent(form) : place
            let body = id.map { #"{"home":{"last_read_id":"\#($0)"}}"# } ?? "{}"
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }

        /// The ids a Home place was told, in order.
        func told() -> [String] {
            asked.filter { $0.method == "POST" && $0.path == "/api/v1/markers" }.map { Self.sent($0.form) ?? "" }
        }

        func got() -> [Asked] {
            asked.filter { $0.method == "GET" && $0.path == "/api/v1/markers" }
        }

        private static func sent(_ form: String) -> String? {
            guard let value = form.split(separator: "=", maxSplits: 1).last else { return nil }
            return value.removingPercentEncoding ?? String(value)
        }
    }

    private func note(_ id: String, at: TimeInterval, host: String = HomePlaceTests.host, home: Bool = true) -> Note {
        Note(
            id: id, source: Source(host: host, kind: .mastodon), author: "A", handle: "@a@\(host)",
            body: id, postedAt: Date(timeIntervalSince1970: at), categories: home ? [.home] : [.public]
        )
    }

    private func scopes(_ parts: MastodonPart...) -> String {
        parts.flatMap(\.words).joined(separator: " ")
    }

    private func session(
        _ wire: Wire, scopes: String, hosts: [String] = [HomePlaceTests.host], stopped: ShellStopped? = nil
    ) throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        for host in hosts {
            try tokens.save(MastodonToken(
                host: host, accessToken: "t", clientID: "c", clientSecret: "s", scopes: scopes
            ))
        }
        let mastodon = MastodonSessions(tokens: tokens, sender: wire)
        mastodon.work = SourceWork()
        let session = ShellSession(http: FixtureHTTP(), mastodon: mastodon, stopped: stopped)
        session.work = SourceWork()
        session.sources = hosts.map { Source(host: $0, kind: .mastodon) }
        return session
    }

    @Test("Off, nothing asks a source where Home was left")
    func off() async throws {
        let wire = Wire()
        let session = try session(wire, scopes: scopes(.reading, .acting))
        session.notes = [note("new", at: 3)]
        await session.homePlace.opened(.all, reading: note("new", at: 3).key.rowID, touch: false, tellSettled: true, in: session)
        await session.homePlace.left(session.notes[0].key.rowID, on: .all, in: session)
        #expect(await wire.asked.isEmpty)
        #expect(session.homePlace.line == nil && session.homePlace.move == nil)
    }

    @Test("Without acting the switch is the part's own sentence, and the press asks before anything is written")
    func asksBeforeItIsOn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "fediqo.home-place.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = ListFiles(directory: directory, defaults: defaults, protected: .always).stopped
        let wire = Wire()
        let session = try session(wire, scopes: scopes(.reading), stopped: ShellStopped(defaults: defaults, file: file))
        let offer = try #require(session.homePlace.offer(host: Self.host, in: session))
        let place = try #require(session.mastodon.place(.acting, host: Self.host))
        let words = L10n.t(place.key)
        let sentence = words.contains("%@") ? String(format: words, Self.host) : words
        #expect(offer.shape == .locked(sentence) && offer.on == false)
        session.homePlace.pressLocked(host: Self.host, in: session)
        #expect(session.partAsks.open?.ticked.contains(.acting) == true)
        #expect(session.stopped.hosts.isEmpty)
        #expect((try? Data(contentsOf: file.url)) == nil)
        await session.homePlace.setOn(true, host: Self.host, in: session)
        let asked = await wire.asked
        #expect(session.stopped.hosts.isEmpty && asked.isEmpty)
    }

    @Test("On, opening a timeline that reads Home asks once, and Trends or a timeline that does not are not asked")
    func asksWhenHomeIsRead() async throws {
        let wire = Wire()
        await wire.configure(place: "src")
        let session = try session(wire, scopes: scopes(.reading, .acting))
        session.notes = [note("src", at: 2), note("new", at: 3)]
        await session.homePlace.opened(.all, reading: nil, touch: false, tellSettled: false, in: session)
        #expect(await wire.got().isEmpty)
        await session.homePlace.setOn(true, host: Self.host, in: session)
        await session.homePlace.opened(.all, reading: nil, touch: false, tellSettled: false, in: session)
        let got = await wire.got()
        #expect(got.count == 1 && got.allSatisfy { $0.host == Self.host && $0.query.contains("home") })
        let rule = try #require(Rule.category(.public, in: .every, sources: session.sources))
        let written = TimelineDefinition(name: "Public", rules: [rule])
        session.written = [written]
        await session.homePlace.opened(.written(written.id), reading: nil, touch: false, tellSettled: false, in: session)
        await session.homePlace.opened(.trends, reading: nil, touch: false, tellSettled: false, in: session)
        #expect(await wire.got().count == 1)
    }

    @Test("Leaving on a newer Home row tells that id once; an older row, a row that is not Home, and a post that just arrived do not")
    func tellsTheRowBeingRead() async throws {
        let wire = Wire()
        await wire.configure(place: "src")
        let session = try session(wire, scopes: scopes(.reading, .acting))
        let older = note("old", at: 1)
        let source = note("src", at: 2)
        let newer = note("new", at: 3)
        let publicRow = note("pub", at: 4, home: false)
        session.notes = [older, source, newer, publicRow]
        session.stopped.turnOn(Self.host)
        session.homePlace.moving()
        await session.homePlace.opened(.all, reading: newer.key.rowID, touch: false, tellSettled: true, in: session)
        #expect(await wire.told().isEmpty, "a row still moving is not told")
        await session.homePlace.settled(in: session)
        await session.homePlace.left(newer.key.rowID, on: .all, in: session)
        #expect(await wire.told() == ["new"])
        session.notes.append(note("arrived", at: 5))
        #expect(await wire.told() == ["new"])

        let olderWire = Wire()
        await olderWire.configure(place: "src")
        let olderSession = try self.session(olderWire, scopes: scopes(.reading, .acting))
        olderSession.notes = [older, source]
        olderSession.stopped.turnOn(Self.host)
        await olderSession.homePlace.opened(.all, reading: older.key.rowID, touch: false, tellSettled: true, in: olderSession)
        await olderSession.homePlace.left(older.key.rowID, on: .all, in: olderSession)
        #expect(await olderWire.told().isEmpty)
        #expect(olderSession.homePlace.move == nil)

        let publicWire = Wire()
        await publicWire.configure(place: "src")
        let onPublic = try self.session(publicWire, scopes: scopes(.reading, .acting))
        onPublic.notes = [publicRow, source]
        onPublic.stopped.turnOn(Self.host)
        await onPublic.homePlace.opened(.all, reading: publicRow.key.rowID, touch: false, tellSettled: true, in: onPublic)
        await onPublic.homePlace.left(publicRow.key.rowID, on: .all, in: onPublic)
        #expect(await publicWire.told().isEmpty && onPublic.homePlace.line == nil)
    }

    @Test("The source's post not held here is not written over, and the line does not move the list")
    func missingDoesNotMove() async throws {
        let wire = Wire()
        await wire.configure(place: "gone")
        let session = try session(wire, scopes: scopes(.reading, .acting))
        let newer = note("new", at: 3)
        session.notes = [newer]
        session.stopped.turnOn(Self.host)
        await session.homePlace.opened(.all, reading: newer.key.rowID, touch: false, tellSettled: true, in: session)
        #expect(session.homePlace.line == .missing(host: Self.host))
        session.homePlace.there(touch: false)
        #expect(session.homePlace.move == nil)
        await session.homePlace.left(newer.key.rowID, on: .all, in: session)
        #expect(await wire.told().isEmpty)
        #expect(session.homePlace.move == nil)
    }

    @Test("The line names the row's own source, and neither press moves the list until the one that goes there, which does not tell an older id")
    func theTwoPresses() async throws {
        let wire = Wire()
        await wire.configure(place: "b-src")
        let session = try session(wire, scopes: scopes(.reading, .acting), hosts: [Self.host, Self.other])
        let here = note("b-now", at: 1, host: Self.other)
        let there = note("b-src", at: 3, host: Self.other)
        session.notes = [note("a-now", at: 2), here, there]
        session.stopped.turnOn(Self.host)
        session.stopped.turnOn(Self.other)
        await session.homePlace.opened(.all, reading: here.key.rowID, touch: false, tellSettled: true, in: session)
        let got = await wire.got()
        #expect(Set(got.map(\.host)) == Set([Self.host, Self.other]))
        #expect(session.homePlace.line == .apart(host: Self.other, here: here.key.rowID, there: there.key.rowID))
        let before = await wire.told()
        #expect(session.homePlace.move == nil && before.isEmpty)
        session.homePlace.there(touch: false)
        #expect(session.homePlace.move == ShellHomePlace.Move(rowID: there.key.rowID, how: .select))
        session.homePlace.clearMove()
        session.homePlace.there(touch: true)
        #expect(session.homePlace.move == ShellHomePlace.Move(rowID: there.key.rowID, how: .keep))
        #expect(await wire.told().isEmpty)
        session.homePlace.clearMove()
        await session.homePlace.here(in: session)
        #expect(await wire.told() == ["b-now"] && session.homePlace.move == nil)
    }

    @Test("A failed read or tell changes neither the switch nor where the list sits")
    func failureChangesNothing() async throws {
        let unread = Wire()
        await unread.configure(failGet: true)
        let session = try session(unread, scopes: scopes(.reading, .acting))
        let newer = note("new", at: 3)
        session.notes = [newer, note("src", at: 2)]
        session.stopped.turnOn(Self.host)
        await session.homePlace.opened(.all, reading: newer.key.rowID, touch: false, tellSettled: true, in: session)
        #expect(session.homePlace.line == .failed(host: Self.host))
        #expect(session.stopped.hosts == Set([Self.host]) && session.homePlace.move == nil)
        await session.homePlace.left(newer.key.rowID, on: .all, in: session)
        #expect(await unread.told().isEmpty)
        #expect(session.stopped.hosts == Set([Self.host]) && session.homePlace.move == nil)

        let refused = Wire()
        await refused.configure(place: "src", postStatus: 500)
        let telling = try self.session(refused, scopes: scopes(.reading, .acting))
        telling.notes = [newer, note("src", at: 2)]
        telling.stopped.turnOn(Self.host)
        await telling.homePlace.opened(.all, reading: newer.key.rowID, touch: false, tellSettled: true, in: telling)
        #expect(telling.homePlace.line == .failed(host: Self.host))
        #expect(telling.stopped.hosts == Set([Self.host]) && telling.homePlace.move == nil)
    }

    @Test("A finger's first row, noted once the list has laid out, is told, and an open that has not seen it yet does not wipe it")
    func fingerLandsWhileStill() async throws {
        let wire = Wire()
        await wire.configure(place: "src")
        let session = try session(wire, scopes: scopes(.reading, .acting))
        let newer = note("new", at: 3)
        let reading = note("read", at: 2.5)
        session.notes = [note("src", at: 2), reading, newer]
        session.stopped.turnOn(Self.host)
        await session.homePlace.opened(.all, reading: nil, touch: true, tellSettled: true, in: session)
        #expect(await wire.told().isEmpty)
        await session.homePlace.fingerNoted(newer.key.rowID, in: session)
        #expect(await wire.told().isEmpty, "a row only half on screen is not told")
        await session.homePlace.wholeNoted(reading.key.rowID, in: session)
        #expect(await wire.told() == ["read"])
        await session.homePlace.wholeNoted(newer.key.rowID, in: session)
        #expect(await wire.told() == ["read"], "a later row waits until the list settles or is left")

        let kept = Wire()
        await kept.configure(place: "src")
        let earlier = try self.session(kept, scopes: scopes(.reading, .acting))
        earlier.notes = [note("src", at: 2), newer]
        earlier.stopped.turnOn(Self.host)
        earlier.homePlace.mode(touch: true, row: newer.key.rowID, in: earlier)
        await earlier.homePlace.opened(.all, reading: nil, touch: true, tellSettled: true, in: earlier)
        #expect(await kept.told() == ["new"])
    }

    @Test("Turning the switch off while the read is still out sends nothing")
    func offWhileTheReadIsOut() async throws {
        let wire = Wire()
        await wire.configure(place: "src", holdGet: true)
        let session = try session(wire, scopes: scopes(.reading, .acting))
        let newer = note("new", at: 3)
        session.notes = [note("src", at: 2), newer]
        session.stopped.turnOn(Self.host)
        let opening = Task {
            await session.homePlace.opened(.all, reading: newer.key.rowID, touch: false, tellSettled: false, in: session)
        }
        var spins = 0
        while await wire.got().isEmpty {
            spins += 1
            try #require(spins < 100, "the read never left")
            await Task.yield()
        }
        let leaving = Task { await session.homePlace.left(newer.key.rowID, on: .all, in: session) }
        await Task.yield()
        await session.homePlace.setOn(false, host: Self.host, in: session)
        await wire.release()
        await opening.value
        await leaving.value
        #expect(await wire.told().isEmpty)
        #expect(session.stopped.hosts.isEmpty && session.homePlace.move == nil)
    }

    @Test("The pane asks the mark where a finger left, which the next list does not drop")
    func paneAsksTheMark() throws {
        let mark = ShellReadingMark()
        mark.list(["row"], of: "home")
        mark.whole(["row"], of: "home")
        #expect(mark.id == "row")
        mark.list([], of: "trends")
        #expect(mark.id == nil)
        #expect(mark.left() == "row")
        let pane = try ShellSource.shell("TimelinePane")
        #expect(pane.contains("let row = touch ? session.readingMark.left() : selectedID"))
    }

    @Test("The sentences are in each language, and the two Chinese tables stay the same")
    func sentences() throws {
        let keys = [
            "source.you.stopped", "source.you.stopped.help", "home.place.line", "home.place.here",
            "home.place.there", "home.place.missing", "home.place.failed",
        ]
        for key in keys {
            let english = L10n.t(key, language: .english)
            let taiwan = L10n.t(key, language: .taiwanese)
            #expect(english != key && taiwan != key && taiwan != english)
            #expect(!english.contains("%d") && !taiwan.contains("%d"))
        }
        let resources = ShellSource.root.appendingPathComponent("Resources")
        let taiwan = try Data(contentsOf: resources.appendingPathComponent("zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
    }
}
