import Foundation
import Observation
import FediqoCore

@MainActor
@Observable
final class ServerPickerModel {
    enum Probe: Equatable {
        case idle
        case checking(String)
        /// What the server said about itself. Nothing has been written down yet.
        case found(InstanceInfo)
        case failed(SourceFailure)
    }

    let socialProtocol: SocialProtocol

    var typed: String = ""
    private(set) var suggestions: [SuggestedServer] = []
    private(set) var origin: DirectoryOrigin = .builtIn
    private(set) var loadingSuggestions = true
    private(set) var probe: Probe = .idle

    private let directory = ServerDirectory()
    private let registry = SourceRegistry.standard()

    init(socialProtocol: SocialProtocol) {
        self.socialProtocol = socialProtocol
    }

    var canSubmit: Bool {
        if case .checking = probe { return false }
        return Server.looksLikeHost(typed)
    }

    /// A server this app already reads. The screen still shows what it found -- looking is
    /// never refused -- but there is nothing left to decide.
    func alreadyReading(_ info: InstanceInfo, among servers: [Server]) -> Bool {
        servers.contains { $0.host == info.host }
    }

    func loadSuggestions() async {
        loadingSuggestions = true
        let result = await directory.suggested()
        suggestions = result.servers
        origin = result.origin
        loadingSuggestions = false
    }

    /// Asks a server what it is, and stops there. What comes back goes on the screen; whether
    /// to read it is the reader's next decision and not this one. A hostname that never answers
    /// fails here rather than in the timeline.
    func look(host: String) async {
        let normalised = Server.normalise(host)
        guard let client = registry.client(for: socialProtocol) else {
            probe = .failed(.unsupported(socialProtocol))
            return
        }
        probe = .checking(normalised)
        do {
            probe = .found(try await client.instance(host: normalised))
        } catch let failure as SourceFailure {
            probe = .failed(failure)
        } catch {
            probe = .failed(.transport(error.localizedDescription))
        }
    }

    /// The server that was looked at, as something to write down.
    func server(from info: InstanceInfo) -> Server {
        Server(host: info.host, socialProtocol: socialProtocol, title: info.title)
    }

    func clear() {
        probe = .idle
    }
}
