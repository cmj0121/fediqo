import Foundation

public enum JoinError: Error, Equatable, Sendable {
    case invalidHost
    case unreachable
    case unsupportedKind(ProtocolKind)
    case publicTimelineFailed
    /// The server answered with a refusal of its own — a filter in front of it decided this app
    /// was a robot, or the forum requires a key. Distinct from every other failure because it is
    /// the only one where the host is fine, the spelling is fine, and the reader is being turned
    /// away on purpose.
    case refused(Int)
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
        try await ingest(host: host)
    }

    /// Everything after the host is known to speak Mastodon. Separate so that a dispatcher that
    /// has already asked what a host speaks does not ask a stranger's server twice.
    func ingest(host: String) async throws {
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

/// A forum joined, and its front page read.
///
/// The same shape as the microblog join and for the same reasons: the host is asked for its front
/// page **before** it is added, so a server that answers the detector and then refuses the thing
/// the reader actually wants does not leave a source behind that draws an empty timeline.
///
/// No catalogue is fetched. A forum's emoji are not a per-server dictionary a client can read the
/// way Mastodon's are, so there is nothing to hold and nothing to clear.
public struct DiscourseJoin: Sendable {
    private let http: any HTTPClient
    private let store: ItemStore

    public init(http: any HTTPClient, store: ItemStore) {
        self.http = http
        self.store = store
    }

    func ingest(host: String) async throws {
        let source = Source(host: host, kind: .discourse)
        let client = DiscourseClient(http: http, host: host)

        let topics: [Note]
        do {
            topics = try await client.latest(source: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DiscourseRequestError {
            switch error {
            // The server answered, and the answer was no. Kept apart from every other failure
            // because it is the one the reader can sometimes do something about, and the one
            // that is never their spelling.
            case .refused(let status): throw JoinError.refused(status)
            case .http, .invalidURL: throw JoinError.publicTimelineFailed
            }
        } catch is DecodingError {
            // It answered, and the answer was not a forum's front page. A filter's challenge
            // page and a fork with a schema of its own arrive here alike.
            throw JoinError.publicTimelineFailed
        } catch {
            throw JoinError.unreachable
        }

        await store.add(source)
        await store.ingest(topics)
    }
}

/// A Discuz! forum joined, and its front page read.
///
/// `DiscourseJoin`'s shape exactly, and for the same reason rather than out of symmetry: the host
/// is asked for the page the reader actually wants **before** the source is added, so a server
/// that answers the detector and then hands back a challenge, a notice page or markup nobody can
/// read does not leave a source behind that draws nothing forever.
///
/// That reason is stronger here than it was there. Discourse's front page is a documented public
/// read and five forums in six answer it; Discuz!'s is a page, and `install-e.example` — an
/// install that detects perfectly — shows a signed-out reader **no threads at all**, on every
/// board and on the guide page alike. Joining it on the strength of the detection would be
/// exactly the empty source this ordering exists to prevent.
///
/// No catalogue is fetched, for the reason `DiscourseJoin` gives: a forum's emoji are not a
/// per-server dictionary a client can read, so there is nothing to hold and nothing to clear.
public struct DiscuzJoin: Sendable {
    private let http: any HTTPClient
    private let store: ItemStore

    public init(http: any HTTPClient, store: ItemStore) {
        self.http = http
        self.store = store
    }

    func ingest(host: String) async throws {
        let source = Source(host: host, kind: .discuz)
        let client = DiscuzClient(http: http, host: host)

        let threads: [Note]
        do {
            threads = try await client.latest(source: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DiscuzRequestError {
            switch error {
            // The server answered, and the answer was no. Its own number, kept.
            case .refused(let status):
                throw JoinError.refused(status)
            // **Also a refusal, and it gets 403 whatever status it arrived with.** A challenge
            // page is a filter turning this app away and is routinely dressed as a 200; the
            // forum's own notice page is the forum turning this reader away and is *always* a
            // 200. Reporting either as its literal status would tell the reader "that worked",
            // and `JoinError.refused` is the one case that says the host is fine, the spelling is
            // fine, and somebody said no on purpose — which is true of both. 403 is the number
            // that refusal means, and it is what the reader's message is written from.
            case .challenged, .restricted:
                throw JoinError.refused(403)
            // It answered, and there was no forum front page in it: a 404, bytes in no encoding
            // this device knows, or a page whose thread table nobody could find. A reader sent to
            // check their spelling by one of these is being sent to look for a fault that might
            // well be theirs — which is the distinction `refused` above is protecting.
            case .noThreads, .http, .invalidURL, .undecodable:
                throw JoinError.publicTimelineFailed
            }
        } catch {
            throw JoinError.unreachable
        }

        await store.add(source)
        await store.ingest(threads)
    }
}

/// What a reader's "add a source" actually calls. Asks the host what it speaks, once, and hands
/// it to whoever reads that.
///
/// **One detection, not one per protocol.** Every join used to begin by asking a stranger's server
/// what it was; a dispatcher that let each of them ask again would double that traffic for every
/// protocol added, against servers that did nothing to deserve it.
public struct SourceJoin: Sendable {
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

        switch kind {
        case .mastodon:
            try await MastodonJoin(http: http, store: store, catalogues: catalogues)
                .ingest(host: host)
        case .discourse:
            try await DiscourseJoin(http: http, store: store).ingest(host: host)
        case .discuz:
            try await DiscuzJoin(http: http, store: store).ingest(host: host)
        default:
            throw JoinError.unsupportedKind(kind)
        }
    }
}
