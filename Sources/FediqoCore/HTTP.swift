import Foundation
import os

public protocol HTTPClient: Sendable {
    func data(from url: URL) async throws -> (Data, HTTPURLResponse)
}

/// GET over HTTPS, under a ceiling on how much body this device will take. Tests inject a
/// client; the live one is a URLSession.
public struct URLSessionClient: HTTPClient, Sendable {
    /// 128 MiB.
    ///
    /// What this function actually carries is bounded by Mastodon's 16 MB image ceiling
    /// (`MAX_IMAGE_SIZE`). A video never comes through here: the viewer hands the URL to
    /// `AVPlayer`, which does its own transfer, so the 99 MB `MAX_VIDEO_SIZE` case — the one a
    /// generous default is usually argued from — is the one case this path will not see.
    /// 128 MiB is therefore not a working size but a last line: high enough that no legitimate
    /// object can ever reach it even if an instance raises its own ceilings, low enough that a
    /// hostile one cannot spend the reader's whole memory on a single response.
    ///
    /// It is the only thing this file bounds, and it bounds one response. Nothing here limits
    /// how many responses are in flight at once, so the memory a screenful of rows can hold is
    /// this times however many fetches the caller allows — the count belongs to the caller,
    /// which is the only layer that knows how many rows are on screen. A caller that knows it
    /// is asking for something small — a timeline page, a thumbnail — should also build its
    /// client with a ceiling to match rather than lean on this one.
    public static let defaultByteLimit = 128 << 20

    let session: URLSession
    private let byteLimit: Int
    /// Whether every redirect must stay on the request's own origin, and not only one carrying a
    /// token. The sign-in's client sets it: its bodies carry the client secret, the code and the
    /// token itself.
    let sameOriginOnly: Bool

    public init(
        session: URLSession = .shared,
        byteLimit: Int = URLSessionClient.defaultByteLimit,
        sameOriginOnly: Bool = false
    ) {
        self.session = session
        self.byteLimit = byteLimit
        self.sameOriginOnly = sameOriginOnly
    }

    public func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await send(request)
    }

    /// Any request, under the same rules as `data(from:)`: `https` only, this app's agent, the
    /// ceiling. The sign-in's POSTs and its `Authorization` header come through here.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, Host.isFetchable(url) else {
            throw URLError(.unsupportedURL)
        }
        var request = request
        request.setValue(Fediqo.userAgent, forHTTPHeaderField: "User-Agent")

        let body: Data
        let response: URLResponse?
        do {
            (body, response) = try await CappedBody.load(
                request, in: session, limit: byteLimit, sameOriginOnly: sameOriginOnly
            )
        } catch {
            // The delegate runs on the session's queue, where `Task.isCancelled` is not visible,
            // so a reader walking away races the ceiling tripping and the ceiling usually wins.
            // Here we are back in the caller's task and can tell the two apart. It matters
            // downstream: a refusal is a fact about the address that a cache may remember for
            // good, and a scroll must never write one.
            if Task.isCancelled {
                throw URLError(.cancelled)
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (body, http)
    }
}

/// Sends a request that is not a plain GET — a form POST, or one carrying a token.
public protocol HTTPSender: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSessionClient: HTTPSender {
    /// The client for a signed-in source's traffic: an ephemeral session, so no cookie and no
    /// cached response of a reader's own timeline is written to disk; a 1 MiB ceiling, which no
    /// token, app registration or page of statuses comes near; and no redirect off the origin a
    /// request was sent to, whatever it carries.
    public static func signedIn() -> URLSessionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSessionClient(
            session: URLSession(configuration: configuration), byteLimit: 1 << 20,
            sameOriginOnly: true
        )
    }
}

/// One response pulled down under a ceiling, refused three ways.
///
/// `URLSession`'s async convenience API buffers the whole body before it returns, so a ceiling
/// laid over it can only ever be applied to bytes already spent — a hostile instance offering a
/// 2 GB attachment gets 2 GB of the reader's memory first and is refused afterwards. It also
/// drives its own internal task delegate, so a `URLSessionDataDelegate` handed to it is never
/// asked anything: wired both at session level and per task via `data(for:delegate:)` and
/// probed, it saw no callbacks at all — not `didReceive response:`, not even `didComplete`.
/// The same delegate on a real `dataTask` sees all three.
///
/// So: `didReceive response:` answers `.cancel` and the body never moves, which catches the
/// instance that declares its size honestly. A `Content-Length` can also be absent —
/// `NSURLSessionTransferSizeUnknown`, which is every chunked response — so the running total in
/// `didReceive data:` is the backstop, and it cancels where it trips rather than at the end.
/// And `willPerformHTTPRedirection` puts the same `https` rule on the second wire boundary a
/// redirect opens, because `URLSession` will otherwise follow a 302 down to plain `http` and
/// hand back a body nobody re-checks the scheme of.
///
/// A server that declares *less* than it sends is not a third case: today's `URLSession`
/// truncates the body at the advertised `Content-Length` by itself — measured, 1,024 bytes
/// delivered out of 25 MB streamed. That is undocumented platform behaviour, not a contract:
/// `expectedContentLength` is documented as advisory and says nothing about truncating, and
/// nothing here would notice if it stopped. It is a bonus, and it must never be the reason
/// somebody deletes the running total, which is what actually covers that case.
final class CappedBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var body = Data()
        var response: URLResponse?
        /// Why this device is refusing, set once and never overwritten — the first reason to
        /// arrive is the true one, and a later callback must not talk it down.
        var refusal: URLError?
        var continuation: CheckedContinuation<(Data, URLResponse?), any Error>?
    }

    private let limit: Int
    private let sameOriginOnly: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(limit: Int, sameOriginOnly: Bool) {
        self.limit = limit
        self.sameOriginOnly = sameOriginOnly
    }

    /// The response for `request`, or `URLError.dataLengthExceedsMaximum` where it was bigger
    /// than `limit`. Cancelling the calling `Task` cancels the transfer rather than leaving it
    /// to run to completion — a data task behind a continuation does not inherit cooperative
    /// cancellation on its own.
    static func load(
        _ request: URLRequest,
        in session: URLSession,
        limit: Int,
        sameOriginOnly: Bool = false
    ) async throws -> (Data, URLResponse?) {
        let sink = CappedBody(limit: limit, sameOriginOnly: sameOriginOnly)
        let task = session.dataTask(with: request)
        task.delegate = sink
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sink.state.withLock { $0.continuation = continuation }
                task.resume()
                // A task cancelled before the continuation was installed has already had
                // `onCancel` run, so its `didComplete` may have landed in the window where
                // there was nothing to resume and been dropped — which is a caller hung with no
                // error and no timeout. Re-check here, where the continuation does exist.
                // `take()` makes this safe to do unconditionally.
                if Task.isCancelled {
                    sink.abandon()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Hands the continuation over at most once. Both resume sites go through here, so whichever
    /// of them arrives first is the only one that can resume and a double resume is unreachable.
    private func take() -> (
        continuation: CheckedContinuation<(Data, URLResponse?), any Error>?,
        refusal: URLError?,
        response: URLResponse?,
        body: Data
    ) {
        state.withLock { state in
            let taken = (state.continuation, state.refusal, state.response, state.body)
            state.continuation = nil
            state.body = Data()
            return taken
        }
    }

    private func abandon() {
        take().continuation?.resume(throwing: URLError(.cancelled))
    }

    /// First reason in wins. Every write to `refusal` goes through here except the one inside
    /// `didReceive data:`, which already holds the lock and says so at the site.
    private func refuse(_ error: URLError) {
        state.withLock {
            if $0.refusal == nil {
                $0.refusal = error
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let declared = response.expectedContentLength
        let tooBig = declared != NSURLSessionTransferSizeUnknown && declared > Int64(limit)
        state.withLock { $0.response = response }
        if tooBig {
            refuse(URLError(.dataLengthExceedsMaximum))
        }
        completionHandler(tooBig ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tripped = state.withLock { state -> Bool in
            guard state.refusal == nil else { return false }
            state.body.append(data)
            guard state.body.count > limit else { return false }
            // Let go of what came before the trip here rather than at completion: the point of
            // the ceiling is that this much memory is not held.
            state.body = Data()
            // The one write that does not go through `refuse(_:)`. It cannot: the lock is
            // already held here and `OSAllocatedUnfairLock` is not re-entrant, so calling the
            // helper would deadlock. That makes the `guard state.refusal == nil` at the top of
            // this block load-bearing — it is the whole of first-write-wins for this write, and
            // relaxing it would let a size trip quietly overwrite a refused redirect with a
            // milder reason. Everywhere else, `refuse(_:)` is what keeps that invariant.
            state.refusal = URLError(.dataLengthExceedsMaximum)
            return true
        }
        if tripped {
            dataTask.cancel()
        }
    }

    /// A redirect is a second wire boundary, and `Host.isFetchable` is the rule at every one of
    /// them. Refusing outright rather than quietly not following it is the honest answer: a
    /// downgraded target is an instance trying something, not a page that moved.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, Host.isFetchable(url),
              Self.mayFollow(from: task.originalRequest, to: url, sameOriginOnly: sameOriginOnly)
        else {
            refuse(URLError(.unsupportedURL))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// A request carrying a token — or any request, where `sameOriginOnly` — may only be
    /// redirected within its own origin: scheme, host and port. **Refused rather than stripped
    /// and followed**: a follow without the token comes back 401 from wherever it lands, and a
    /// 401 is what signs the reader out.
    static func mayFollow(from original: URLRequest?, to url: URL, sameOriginOnly: Bool = false) -> Bool {
        let carriesToken = original?.value(forHTTPHeaderField: "Authorization") != nil
        guard sameOriginOnly || carriesToken else { return true }
        guard let from = original?.url else { return false }
        return origin(from) == origin(url)
    }

    private static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(url.host()?.lowercased() ?? ""):\(port)"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let outcome = take()
        guard let continuation = outcome.continuation else { return }
        if let refusal = outcome.refusal {
            continuation.resume(throwing: refusal)
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: (outcome.body, outcome.response))
        }
    }
}
