import FediqoCore
import Foundation
import Observation

/// In-memory session: unsigned sources, All and Trends, and the Account add flow.
@MainActor
@Observable
final class ShellSession {
    enum Catalog: Equatable {
        case loading
        case failed
        case empty
        case ready([CatalogServer])
    }

    let http: any HTTPClient
    let store: ItemStore

    var queries: [DummyTimeline] = DummyTimeline.shipped
    var timelineID: String?
    var sources: [Source] = []
    var notes: [Note] = []

    var hostname = ""
    var catalog: Catalog = .loading
    var checking = false
    var progressHost = ""
    var refuse: String?

    init(http: any HTTPClient, store: ItemStore = ItemStore()) {
        self.http = http
        self.store = store
    }

    var availability: ShellAvailability {
        ShellAvailability(queryIDs: Set(queries.map(\.id)), signedIn: false)
    }

    func isAdded(_ domain: String) -> Bool {
        let host = domain.lowercased()
        return sources.contains { $0.host == host }
    }

    func loadCatalog() async {
        if case .ready = catalog { return }
        if case .empty = catalog { return }
        catalog = .loading
        do {
            let servers = try await ServerDirectory(http: http).servers()
            catalog = servers.isEmpty ? .empty : .ready(servers)
        } catch is CancellationError {
            return
        } catch {
            catalog = .failed
        }
    }

    func pick(_ server: CatalogServer) async {
        hostname = server.domain
        await add()
    }

    func add() async {
        guard !checking else { return }
        let raw = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        refuse = nil
        let parsed: String
        do {
            parsed = try Host.parse(raw)
        } catch {
            refuse = String(format: L10n.t("account.refuse.unknown"), raw)
            return
        }
        progressHost = parsed
        if isAdded(parsed) {
            refuse = L10n.t("account.refuse.duplicate")
            return
        }
        checking = true
        defer { checking = false }
        do {
            try await MastodonJoin(http: http, store: store).join(host: raw)
            sources = await store.sources()
            notes = await store.all()
            if queries.isEmpty {
                queries = [DummyTimeline(id: "all"), DummyTimeline(id: "trends")]
                timelineID = "all"
            }
        } catch is CancellationError {
            return
        } catch let error as JoinError {
            refuse = Self.refuseMessage(error, raw: raw, host: parsed)
        } catch {
            refuse = L10n.t("account.refuse.network")
        }
    }

    private static func refuseMessage(_ error: JoinError, raw: String, host: String) -> String {
        switch error {
        case .unsupportedKind(let kind) where kind == .unknown:
            String(format: L10n.t("account.refuse.unknown"), host)
        case .unsupportedKind(let kind):
            String(format: L10n.t("account.refuse.kind"), host, kind.displayName)
        case .invalidHost:
            String(format: L10n.t("account.refuse.unknown"), raw)
        case .unreachable, .publicTimelineFailed:
            L10n.t("account.refuse.network")
        }
    }
}
