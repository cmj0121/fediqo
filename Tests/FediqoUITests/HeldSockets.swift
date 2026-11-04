import Foundation
import Synchronization
@testable import FediqoCore

/// Sockets held by the check: each open is counted and handed a stream the check says things on,
/// and what is said on it is kept. Refused where `refuse` names a status.
final class HeldSockets: SocketOpener, Sendable {
    let refuse: Int?
    private let state = Mutex<(opened: Int, sent: [String], told: AsyncThrowingStream<String, any Error>.Continuation?, asked: [URLRequest])>(
        (0, [], nil, [])
    )

    init(refuse: Int? = nil) {
        self.refuse = refuse
    }

    var opened: Int { state.withLock { $0.opened } }
    var sent: [String] { state.withLock { $0.sent } }
    var asked: [URLRequest] { state.withLock { $0.asked } }
    var told: AsyncThrowingStream<String, any Error>.Continuation? { state.withLock { $0.told } }

    func open(_ request: URLRequest) async throws -> OpenSocket {
        state.withLock { $0.asked.append(request) }
        if let refuse { throw SocketRefused(status: refuse) }
        let (messages, told) = AsyncThrowingStream<String, any Error>.makeStream()
        state.withLock {
            $0.opened += 1
            $0.told = told
        }
        return OpenSocket(messages: messages, send: { [self] text in self.keep(text) })
    }

    private func keep(_ text: String) {
        state.withLock { $0.sent.append(text) }
    }
}
