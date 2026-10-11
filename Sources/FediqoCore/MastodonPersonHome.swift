import Foundation

/// Why the server somebody lives on gave no account of them.
public enum PersonHomeError: Error, Equatable, Sendable {
    /// It answered, and not with them: it is no Mastodon, it refused, or what it sent is no
    /// account — or is somebody else's.
    case noAccount
    /// It is a Mastodon, and it knows nobody of that name: a 404 said as a Mastodon says one.
    case nobody
    /// It did not answer in a way that could be read at all: not reached, not in time, more
    /// than an account is, or sent on to another server.
    case unread
}

/// The server somebody lives on, asked what it says of them (#310): one ask, by their name,
/// of `/api/v1/accounts/lookup` — the ask a source's own people are found by.
///
/// **A host nobody added, named by a handle.** So everything about the ask is the least there
/// is: it is made only where the person pressed for it, once, and it is the only ask this type
/// has — no posts, no lists, no reading on, nothing followed from the answer.
///
/// **Never as anybody.** The one way in is a client that fetches an address and nothing more
/// (`HTTPClient`): there is no door here a sign-in could be handed to, so no token of any
/// source can ride to a server its owner never signed in to.
///
/// **Only who was asked for.** An answer is theirs where it names the very handle asked — name
/// and server both — and is no account otherwise: a server asked for one person does not get
/// to answer with another.
///
/// **No picture is taken from it.** Their face, the picture at the head of their profile and
/// the pictures their words are partly written in are addresses of that server's choosing;
/// what is handed back has none of them, so nothing drawn from it fetches anything.
///
/// **Bounded as a person always is** (`AccountDTO.asPerson`, `Person`): read field by field,
/// each one made fit where it enters. How much body may arrive, how long it may take and
/// where a redirect may lead are the client's, which whoever asks hands in already bounded —
/// in the app, `SourceReach.personHome`.
public struct MastodonPersonHome: Sendable {
    private let reader: MastodonPerson
    private let home: Source

    public init(http: any HTTPClient, host: String) {
        reader = MastodonPerson(http: HearsNobody(inner: http), host: host)
        // No source of the person's: only the name the answer is read against.
        home = Source(host: host, kind: .mastodon)
    }

    /// What this server says of whoever `address` names. Asks nothing, and throws
    /// `noAccount`, where the address is not a handle of this very server.
    public func person(_ address: PersonAddress) async throws -> Person {
        guard case .handle = address, address.host == home.host else { throw PersonHomeError.noAccount }
        let said: Person
        do {
            said = try await reader.person(handle: address.asked, source: home)
        } catch {
            if Cancellation.happened(error) || error is PersonHomeError { throw error }
            throw Self.answered(error) ? PersonHomeError.noAccount : PersonHomeError.unread
        }
        guard address.exactly(said) else { throw PersonHomeError.noAccount }
        return Person(
            source: home, accountID: said.accountID, handle: said.handle, name: said.name, words: said.words,
            fields: said.fields, tally: said.tally, hidesLists: said.hidesLists, locked: said.locked, sort: said.sort,
            moved: said.moved, suspended: said.suspended, limited: said.limited
        )
    }

    /// Whether `error` is a server that answered — with a refusal, with nobody, or with what is
    /// no account — and not an ask that never came back whole.
    private static func answered(_ error: any Error) -> Bool {
        error is PersonReadError || error is MastodonRequestError
    }
}

/// The client the ask goes out on, hearing one thing a reader of people does not: a 404 said
/// as a Mastodon says one — `{"error":…}` — is that server knowing nobody of the name. A 404
/// said any other way — a forum's page, a web server's — is a server that is no Mastodon, and
/// is handed on as it came.
private struct HearsNobody: HTTPClient {
    private struct Refusal: Decodable {
        let error: String
    }

    let inner: any HTTPClient

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        let answer = try await inner.data(from: url)
        if answer.1.statusCode == 404, (try? JSONDecoder().decode(Refusal.self, from: answer.0)) != nil {
            throw PersonHomeError.nobody
        }
        return answer
    }
}
