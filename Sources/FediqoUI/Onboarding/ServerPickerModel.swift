import Foundation
import Observation
import FediqoCore

@MainActor
@Observable
final class ServerPickerModel {
    enum Probe: Equatable {
        case idle
        case checking(String)
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

    func loadSuggestions() async {
        loadingSuggestions = true
        let result = await directory.suggested()
        suggestions = result.servers
        origin = result.origin
        loadingSuggestions = false
    }

    /// Asks the server whether it is one before it is written down as a source. A hostname
    /// that never answers should fail here, not in the timeline.
    func adopt(host: String) async -> Server? {
        let normalised = Server.normalise(host)
        guard let client = registry.client(for: socialProtocol) else {
            probe = .failed(.unsupported(socialProtocol))
            return nil
        }
        probe = .checking(normalised)
        do {
            let instance = try await client.instance(host: normalised)
            probe = .idle
            return Server(host: instance.host, socialProtocol: socialProtocol, title: instance.title)
        } catch let failure as SourceFailure {
            probe = .failed(failure)
            return nil
        } catch {
            probe = .failed(.transport(error.localizedDescription))
            return nil
        }
    }
}
