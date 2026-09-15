import Foundation

public enum JoinError: Error, Equatable, Sendable {
    case invalidHost
    case unreachable
    case unsupportedKind(ProtocolKind)
    case publicTimelineFailed
}

public struct MastodonJoin: Sendable {
    /// The server answered, with a status that says no.
    private static func isRefusal(_ error: MastodonRequestError) -> Bool {
        if case .http = error { return true }
        return false
    }

    private let http: any HTTPClient
    private let store: ItemStore
    private let catalogues: EmojiCatalogueStore

    public init(http: any HTTPClient, store: ItemStore, catalogues: EmojiCatalogueStore) {
        self.http = http
        self.store = store
        self.catalogues = catalogues
    }

    public func join(host raw: String) async throws {
        let host: String
        do {
            host = try Host.parse(raw)
        } catch is HostError {
            throw JoinError.invalidHost
        }

        let kind: ProtocolKind
        do {
            kind = try await Detector(http: http).detect(raw)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DetectError {
            switch error {
            case .invalidHost: throw JoinError.invalidHost
            case .unreachable: throw JoinError.unreachable
            }
        } catch {
            throw JoinError.unreachable
        }

        guard kind == .mastodon else { throw JoinError.unsupportedKind(kind) }

        let source = Source(host: host, kind: .mastodon)
        let client = MastodonClient(http: http, host: host)

        async let pub = client.publicTimeline(source: source)
        async let trend: [Note] = {
            do {
                return try await client.trending(source: source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return []
            }
        }()

        let publicNotes: [Note]
        do {
            publicNotes = try await pub
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MastodonRequestError where Self.isRefusal(error) {
            throw JoinError.publicTimelineFailed
        } catch is DecodingError {
            // It answered; the answer was not a timeline. A proxy page, a fork with a
            // schema of its own, a date nobody can parse — the host is reachable and
            // the reader would waste their time looking at the network.
            throw JoinError.publicTimelineFailed
        } catch {
            // No answer at all: a dropped connection, a TLS failure, a name that does
            // not resolve. That one is worth checking a network over.
            throw JoinError.unreachable
        }
        let trendingNotes = try await trend

        await store.add(source)
        await store.ingest(publicNotes + trendingNotes)

        // Last, and not waited for. The reader pressed a button to get a timeline and the
        // timeline is now in the store; a catalogue is the largest of the answers a big
        // instance sends, and holding the join open for it would spend the reader's whole wait
        // on pictures for shortcodes that may not be on the page. Asked only for a server that
        // was actually joined, so a host this device refused leaves nothing behind.
        await catalogues.refresh(host: host) { try await client.customEmojis() }
    }
}
