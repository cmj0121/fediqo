import Foundation

public enum JoinError: Error, Equatable, Sendable {
    case invalidHost
    case unreachable
    case unsupportedKind(ProtocolKind)
    case publicTimelineFailed
}

public struct MastodonJoin: Sendable {
    private let http: any HTTPClient
    private let store: ItemStore

    public init(http: any HTTPClient, store: ItemStore) {
        self.http = http
        self.store = store
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
        } catch {
            throw JoinError.publicTimelineFailed
        }
        let trendingNotes = try await trend

        await store.add(source)
        await store.ingest(publicNotes + trendingNotes)
    }
}
