import Foundation
import os

// A line held open to a source, which tells what is new as it happens (#325).
//
// `HTTPSender` hands back one whole body per ask, which is right for every read this app makes
// and wrong for this one: the answer never ends while the line is open. So a line is a seam of its
// own, injected as `HTTPSender` is, so a test holds it and hands the events in by hand.
//
// **Server-sent events, not a WebSocket** (Mastodon 4.6.6 answers both, `MastodonLineCaptures`).
// The request is an ordinary GET: its header carries the token as every other ask's does, the
// address is built from the token's own host by the same door, and a redirect is refused as it is
// for every request that carries a token — here every redirect, since a line has nowhere to move
// to. A WebSocket would be a second transport with rules of its own for each of those.

/// One event a source told on a line: its name and what it carried, as server-sent events frame
/// them. A name the line did not give is `message`, as the format says.
public struct LineEvent: Equatable, Sendable {
    public let name: String
    public let data: String

    public init(name: String, data: String) {
        self.name = name
        self.data = data
    }
}

/// A line opened: the answer's head, and the events as they come — finished where the source ends
/// the line, failing where it drops. **Letting go of `events` ends the line.**
public struct OpenLine: Sendable {
    public let response: HTTPURLResponse
    public let events: AsyncThrowingStream<LineEvent, any Error>

    public init(response: HTTPURLResponse, events: AsyncThrowingStream<LineEvent, any Error>) {
        self.response = response
        self.events = events
    }
}

/// Opens a line. Returns once the answer's head has come — **which is when the line is open**, and
/// what a caller reads what it may have missed after — and throws where it never came. An answer
/// that is no 2xx comes back with its events already finished: what it means is the caller's.
public protocol LineOpener: Sendable {
    func open(_ request: URLRequest) async throws -> OpenLine
}

/// Server-sent events read off bytes as they come (the WHATWG framing): `event:` names the next
/// event, each `data:` adds a line to it, a blank line hands it over, and a line opening with `:`
/// is a comment — the beat a source sends to keep a line alive, and Mastodon's `:)` as it opens.
///
/// **No line longer than `longestLine`**: the bytes of one line are held until it ends, and a
/// source that never ends one is refused rather than let fill the device.
public struct ServerSentEvents: Sendable {
    /// 1 MiB, the same ceiling a signed-in read's whole body has (`URLSessionClient.signedIn`): no
    /// post is near it.
    public static let longestLine = 1 << 20

    private let limit: Int
    private var pending = Data()
    private var name = ""
    private var data: [String] = []

    public init(longestLine: Int = ServerSentEvents.longestLine) {
        limit = longestLine
    }

    /// The events `bytes` completes, in order. Throws `URLError(.dataLengthExceedsMaximum)` where a
    /// line runs past the ceiling.
    public mutating func feed(_ bytes: Data) throws -> [LineEvent] {
        pending.append(bytes)
        var events: [LineEvent] = []
        while let end = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<end]
            if line.last == 0x0D { line = line.dropLast() }
            pending = Data(pending[pending.index(after: end)...])
            if let event = take(String(decoding: line, as: UTF8.self)) { events.append(event) }
        }
        guard pending.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return events
    }

    /// One line of the format: an event where it ends one.
    private mutating func take(_ line: String) -> LineEvent? {
        guard !line.isEmpty else {
            defer {
                name = ""
                data = []
            }
            guard !data.isEmpty else { return nil }
            return LineEvent(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))
        }
        guard !line.hasPrefix(":") else { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            let after = line[line.index(after: colon)...]
            value = after.hasPrefix(" ") ? after.dropFirst() : after
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}

/// A line over `URLSession`, under the same rules as every request this app makes: `https` only,
/// this app's agent, the gate (`Outward`), and no redirect at all.
public struct URLSessionLines: LineOpener {
    let session: URLSession
    let watchedOnly: Bool

    public init(session: URLSession, watchedOnly: Bool = true) {
        self.session = session
        self.watchedOnly = watchedOnly
    }

    /// The session a signed-in source's lines go out on: nothing kept on disk and no cookie, as
    /// `URLSessionClient.signedIn()`. **No answer is waited on for longer than a minute** with
    /// nothing said: Mastodon beats every fifteen seconds, so a line silent for four beats has
    /// dropped. However long the line stays open is not bounded.
    public static func signedIn() -> URLSessionLines {
        let configuration = URLSessionClient.memoryOnlyConfiguration()
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = .infinity
        return URLSessionLines(session: URLSession(configuration: configuration))
    }

    public func open(_ request: URLRequest) async throws -> OpenLine {
        guard let url = request.url, Host.isFetchable(url) else { throw URLError(.unsupportedURL) }
        guard !watchedOnly || Outward.admitted else {
            NetLog.network.fault(
                "\(NetLog.line("unwatched", host: url.host() ?? "", error: OutwardRefusal.unwatched), privacy: .public)"
            )
            throw OutwardRefusal.unwatched
        }
        var request = request
        request.setValue(Fediqo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return try await LineSink.open(request, in: session)
    }
}

/// One line's delegate: hands the head over once, then every event as it is read, then how it
/// ended. Ends the task when whoever reads the events lets go of them.
final class LineSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var opening: CheckedContinuation<OpenLine, any Error>?
        var events: AsyncThrowingStream<LineEvent, any Error>.Continuation?
        var reader = ServerSentEvents()
        /// Whoever reads the events let go of them: the line ends, and ending it is no failure.
        var letGo = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    static func open(_ request: URLRequest, in session: URLSession) async throws -> OpenLine {
        let sink = LineSink()
        let task = session.dataTask(with: request)
        task.delegate = sink
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sink.state.withLock { $0.opening = continuation }
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let (events, continuation) = AsyncThrowingStream<LineEvent, any Error>.makeStream()
        let ok = (200..<300).contains(http.statusCode)
        continuation.onTermination = { [weak self, weak dataTask] _ in
            self?.state.withLock { $0.letGo = true }
            dataTask?.cancel()
        }
        let opening = state.withLock { state -> CheckedContinuation<OpenLine, any Error>? in
            let opening = state.opening
            state.opening = nil
            if ok { state.events = continuation }
            return opening
        }
        if !ok { continuation.finish() }
        opening?.resume(returning: OpenLine(response: http, events: events))
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (told, continuation, refused) = state.withLock { state -> ([LineEvent], AsyncThrowingStream<LineEvent, any Error>.Continuation?, (any Error)?) in
            do {
                return (try state.reader.feed(data), state.events, nil)
            } catch {
                let events = state.events
                state.events = nil
                return ([], events, error)
            }
        }
        for event in told { continuation?.yield(event) }
        if let refused {
            continuation?.finish(throwing: refused)
            dataTask.cancel()
        }
    }

    /// No redirect is followed: the answer that would move the line is its answer, no 2xx.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (opening, events, letGo) = state.withLock { state in
            let taken = (state.opening, state.events, state.letGo)
            state.opening = nil
            state.events = nil
            return taken
        }
        opening?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error, !letGo, !Cancellation.happened(error) {
            events?.finish(throwing: error)
        } else {
            events?.finish()
        }
    }
}
