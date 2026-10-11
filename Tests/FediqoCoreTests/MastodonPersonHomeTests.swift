import Foundation
import Testing
@testable import FediqoCore

/// #310, the ask of the server somebody lives on, in the half of it Core holds: one ask by
/// their name with no sign-in, an answer that is theirs or is no account, and nothing taken
/// from it that would be fetched. Read from what a real 4.6.6 answered
/// (`MastodonPersonHomeCaptures`).
@Suite("The server somebody lives on, asked what it says of them")
struct MastodonPersonHomeTests {
    private typealias Captures = MastodonPersonHomeCaptures

    private static let lookup = MastodonPerson.lookupPath

    private static func ask(_ name: String) -> String { "\(lookup)?acct=\(name)" }

    private static func address(_ name: String, at host: String = Captures.host) throws -> PersonAddress {
        try #require(PersonAddress(typed: "@\(name)@\(host)"))
    }

    private func home(_ routes: [String: PeopleServer.Answer]) -> (MastodonPersonHome, PeopleServer) {
        let server = PeopleServer(routes)
        return (MastodonPersonHome(http: server, host: Captures.host), server)
    }

    /// A wire whose asker walked away.
    private struct WalkedAway: HTTPClient {
        func data(from url: URL) async throws -> (Data, HTTPURLResponse) { throw URLError(.cancelled) }
    }

    @Test("One ask, of that server alone, by the name without the server's and with no sign-in, brings who was asked for — their name, words, fields, counts and what has become of the account — and none of the pictures the answer names; asked in other letters than the account is spelled in, it is still theirs")
    func askedByName() async throws {
        let (reader, server) = home([Self.ask(Captures.personName): .json(Captures.person)])
        let person = try await reader.person(try Self.address(Captures.personName))
        #expect(await server.asked == [Self.ask(Captures.personName)])
        #expect(await server.hosts == [Captures.host])
        #expect(await server.bearers.isEmpty)
        #expect(person.handle == "@\(Captures.personName)@\(Captures.host)" && person.livesHere)
        #expect(person.name == "Per :fediqo_mark: Son" && person.words.contains("Reads #fediqo309"))
        #expect(person.fields.map(\.name) == ["Site", "Pronouns :fediqo_mark:"] && person.fields[0].verifiedAt != nil)
        #expect(person.tally == Person.Tally(posts: 9, following: 4, followers: 8))
        // The answer names a face, a head picture and a picture its words are written in.
        #expect(Captures.person.contains("/avatars/original/") && Captures.person.contains("custom_emojis/images"))
        #expect(person.avatarURL == nil && person.headerURL == nil && person.emojis.isEmpty)

        let capitals = Captures.personName.uppercased()
        let (other, asked) = home([Self.ask(capitals): .json(Captures.person)])
        #expect(try await other.person(try Self.address(capitals)).accountID == person.accountID)
        #expect(await asked.asked == [Self.ask(capitals)])
    }

    @Test("A suspended account, a limited one and one that moved are each answered with the account, and say which: suspended, limited, and where they went")
    func whatBecameOfThem() async throws {
        let (reader, _) = home([
            Self.ask(Captures.goneName): .json(Captures.gone), Self.ask(Captures.limitedName): .json(Captures.limited),
            Self.ask(Captures.movedName): .json(Captures.moved),
        ])
        let gone = try await reader.person(try Self.address(Captures.goneName))
        #expect(gone.suspended && !gone.limited && gone.words.isEmpty)
        let limited = try await reader.person(try Self.address(Captures.limitedName))
        #expect(limited.limited && !limited.suspended)
        let moved = try await reader.person(try Self.address(Captures.movedName))
        #expect(moved.moved?.handle == Captures.movedTo)
    }

    @Test("An answer about anybody but the one asked for is no account: somebody of another server, and somebody else of the same one")
    func onlyWhoWasAsked() async throws {
        for body in [Captures.far, Captures.limited] {
            let (reader, server) = home([Self.ask(Captures.personName): .json(body)])
            await #expect(throws: PersonHomeError.noAccount) { try await reader.person(try Self.address(Captures.personName)) }
            #expect(await server.asked.count == 1)
        }
    }

    @Test("A Mastodon that knows nobody of the name says so — a 404 in its own words — and that is apart from a server that answers without them and gave no account: one that answers only its members, a forum's page with a 404 or a 200, a 404 with nothing in it, a list, a failure of its own; one that does not answer whole was not read; an asker who walked away is told only that")
    func theOutcomes() async throws {
        let address = try Self.address(Captures.personName)
        let (knows, _) = home([Self.ask(Captures.personName): .json(Captures.missing, status: 404)])
        await #expect(throws: PersonHomeError.nobody) { try await knows.person(address) }
        let answered: [PeopleServer.Answer] = [
            .json(Captures.membersOnly, status: 401), .json(Captures.forumPage, status: 404), .json("", status: 404),
            .json(Captures.missing, status: 410), .json(Captures.forumPage), .json("[]"), .json("", status: 500),
            .json("", status: 429),
        ]
        for answer in answered {
            let (reader, _) = home([Self.ask(Captures.personName): answer])
            await #expect(throws: PersonHomeError.noAccount) { try await reader.person(address) }
        }
        for routes in [[Self.ask(Captures.personName): PeopleServer.Answer.fail], [:]] {
            let (reader, _) = home(routes)
            await #expect(throws: PersonHomeError.unread) { try await reader.person(address) }
        }
        let left = MastodonPersonHome(http: WalkedAway(), host: Captures.host)
        do {
            _ = try await left.person(address)
            Issue.record("an ask walked away from answered")
        } catch {
            #expect(Cancellation.happened(error))
        }
    }

    @Test("Nothing is asked for an address that is not a handle of that very server: a handle of another, and the address of a page")
    func onlyItsOwn() async throws {
        let (reader, server) = home([Self.ask(Captures.personName): .json(Captures.person)])
        let elsewhere = try Self.address(Captures.personName, at: "elsewhere.example")
        let page = try #require(PersonAddress(typed: "https://\(Captures.host)/@\(Captures.personName)"))
        for address in [elsewhere, page] {
            await #expect(throws: PersonHomeError.noAccount) { try await reader.person(address) }
        }
        #expect(await server.asked.isEmpty)
    }

    @Test("The door to the server somebody lives on cannot be built with a sign-in: its one way in takes a client that fetches an address, and its file names no token, no signed-in door and no sender")
    func noSignInCanRide() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/FediqoCore/MastodonPersonHome.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.components(separatedBy: "init(").count == 2, "one way in")
        #expect(text.contains("public init(http: any HTTPClient, host: String)"))
        for word in ["MastodonAuthorized", "MastodonToken", "HTTPSender", "Authorization", "door:", "URLRequest"] {
            #expect(!text.contains(word), "\(word)")
        }
    }
}

// On `HTTPTests` so it shares its serialisation: `StubURLProtocol` is one global stub.
extension HTTPTests {
    private static let stranger = "urlprotocol.test"

    private static func strangerAddress() throws -> PersonAddress {
        try #require(PersonAddress(typed: "@far@\(stranger)"))
    }

    @Test("The client an ask of a server nobody added goes out on keeps no cookie and sends none, on a session of its own that writes nothing to disk, with the ceiling and the origin rule it had; and the log is not given that server's name")
    func strangerClientKeepsNoCookie() throws {
        let plain = URLSessionClient().capped(to: 1 << 20).stayingOnOrigin()
        let client = plain.forAStranger()
        let configuration = client.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(client.session !== URLSessionClient.memoryOnly)
        #expect(client.byteLimit == 1 << 20)
        #expect(client.sameOriginOnly)
        #expect(client.watchedOnly)

        let asked = try #require(URL(string: "https://\(Self.stranger)/api/v1/accounts/lookup?acct=far"))
        #expect(plain.logged(asked) == Self.stranger)
        #expect(client.logged(asked) == NetLog.unnamed)
        #expect(!NetLog.unnamed.contains(Self.stranger))
    }

    @Test("An ask of the server somebody lives on that is answered with a redirect to another host, to another port or to plain http is not followed: nothing is asked where it points, and the server was not read")
    func strangerRedirectIsNotFollowed() async throws {
        let address = try Self.strangerAddress()
        for target in ["https://elsewhere.test/x", "https://\(Self.stranger):8443/x", "http://\(Self.stranger)/x"] {
            StubURLProtocol.prepare(status: 200, body: Data(MastodonPersonHomeCaptures.person.utf8), http: true, redirect: target)
            defer { StubURLProtocol.reset() }
            let client = URLSessionClient(session: StubURLProtocol.session(), watchedOnly: false)
            let home = MastodonPersonHome(http: client.capped(to: 1 << 20).stayingOnOrigin(), host: Self.stranger)
            await #expect(throws: PersonHomeError.unread, "\(target)") { try await home.person(address) }
            let last = try #require(StubURLProtocol.lastRequest()?.url)
            #expect(last.path() == MastodonPerson.lookupPath, "\(target)")
            #expect(last.host() == Self.stranger, "\(target)")
            #expect(last.port == nil, "\(target)")
        }
    }
}
