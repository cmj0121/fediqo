import Foundation
import os

// One line to a source that carries everything heard from it (#459).
//
// A server-sent line carries one stream: the reader's own, or their direct posts, each on a line of
// its own (`Line.swift`). A WebSocket to the same source carries as many as are asked for on it, and
// what it carries changes by saying so on it — so hearing one more thing, or one fewer, changes what
// is asked on the line rather than how many lines there are.
//
// **Under the rules of every other line**: `https` addresses only (said as `wss` on the wire), this
// app's agent, the gate (`Outward`), the token in the header as every other ask carries it, and no
// redirect at all. An answer that is no upgrade is a refusal, with its status, and what it means is
// the caller's: a source whose proxy will not upgrade is heard as it was before, line by line.

/// A socket opened: what it says as it comes — finished where the source ends it, failing where it
/// drops — and a way to say something on it. **Letting go of `messages` ends the socket.**
public struct OpenSocket: Sendable {
    public let messages: AsyncThrowingStream<String, any Error>
    public let send: @Sendable (String) async throws -> Void

    public init(messages: AsyncThrowingStream<String, any Error>, send: @escaping @Sendable (String) async throws -> Void) {
        self.messages = messages
        self.send = send
    }
}

/// A socket the source would not open: its answer's status, which was no upgrade.
public struct SocketRefused: Error, Equatable, Sendable {
    public let status: Int

    public init(status: Int) {
        self.status = status
    }
}

/// Opens a socket. Returns once it is open — **which is when it is heard from** — and throws
/// `SocketRefused` where the source answered with no upgrade, and what the network threw where it
/// did not answer.
public protocol SocketOpener: Sendable {
    func open(_ request: URLRequest) async throws -> OpenSocket
}

/// A socket over `URLSession`, under the rules `URLSessionLines` keeps.
public struct URLSessionSockets: SocketOpener {
    let session: URLSession
    let watchedOnly: Bool
    /// How often the socket is asked whether it is still there: a socket that does not answer has
    /// dropped. Mastodon answers at once.
    let beat: Duration

    public init(session: URLSession, watchedOnly: Bool = true, beat: Duration = .seconds(30)) {
        self.session = session
        self.watchedOnly = watchedOnly
        self.beat = beat
    }

    /// The session a signed-in source's socket goes out on: nothing kept on disk and no cookie, as
    /// `URLSessionLines.signedIn()`.
    public static func signedIn() -> URLSessionSockets {
        let configuration = URLSessionClient.memoryOnlyConfiguration()
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = .infinity
        return URLSessionSockets(session: URLSession(configuration: configuration))
    }

    public func open(_ request: URLRequest) async throws -> OpenSocket {
        guard let url = request.url, Host.isFetchable(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw URLError(.unsupportedURL) }
        guard !watchedOnly || Outward.admitted else {
            NetLog.network.fault(
                "\(NetLog.line("unwatched", host: url.host() ?? "", error: OutwardRefusal.unwatched), privacy: .public)"
            )
            throw OutwardRefusal.unwatched
        }
        parts.scheme = "wss"
        guard let address = parts.url else { throw URLError(.badURL) }
        var asked = request
        asked.url = address
        asked.setValue(Fediqo.userAgent, forHTTPHeaderField: "User-Agent")
        return try await SocketSink.open(asked, in: session, beat: beat)
    }
}

/// One socket's delegate: says when it opened, or why it did not, then hands every message over as
/// it comes. Ends the task when whoever reads the messages lets go of them.
final class SocketSink: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// No message longer than a server-sent line may be (`ServerSentEvents.longestLine`).
    static let longestMessage = ServerSentEvents.longestLine

    private let opening = OSAllocatedUnfairLock<CheckedContinuation<Void, any Error>?>(initialState: nil)

    static func open(_ request: URLRequest, in session: URLSession, beat: Duration) async throws -> OpenSocket {
        let sink = SocketSink()
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = longestMessage
        task.delegate = sink
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                sink.opening.withLock { $0 = continuation }
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            task.cancel()
        }
        let (messages, told) = AsyncThrowingStream<String, any Error>.makeStream()
        let hearing = Task {
            do {
                while !Task.isCancelled {
                    switch try await task.receive() {
                    case .string(let text): told.yield(text)
                    case .data(let data): told.yield(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                }
                told.finish()
            } catch {
                if Cancellation.happened(error) || Task.isCancelled { told.finish() } else { told.finish(throwing: error) }
            }
        }
        let beating = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: beat) } catch { return }
                let answered: Bool = await withCheckedContinuation { continuation in
                    task.sendPing { continuation.resume(returning: $0 == nil) }
                }
                if !answered {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        told.onTermination = { _ in
            hearing.cancel()
            beating.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
        return OpenSocket(messages: messages, send: { try await task.send(.string($0)) })
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opening.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
    }

    /// No redirect is followed: the answer that would move the socket is its answer, no upgrade.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let waiting = opening.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }
        guard let waiting else { return }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
            NetLog.network.notice("\(NetLog.line("socket", host: task.originalRequest?.url?.host() ?? "", status: status), privacy: .public)")
            waiting.resume(throwing: SocketRefused(status: status))
        } else {
            waiting.resume(throwing: error ?? URLError(.badServerResponse))
        }
    }
}
