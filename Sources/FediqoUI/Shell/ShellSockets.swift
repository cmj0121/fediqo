import FediqoCore
import Foundation

/// The one line held to each source, shared by everything heard of it (#459).
///
/// **Opened by the first stream asked of it, closed a moment after the last is let go.** Home and
/// notices, and direct posts, each ask for their stream (`hear`) and get it back to read as they
/// would read a line of its own; the socket carries every stream asked of it, and asking for one
/// more, or letting one go, is said on it. The moment's grace (`linger`) is for a stream let go and
/// asked again at once — what is wanted changing — which then opens nothing.
///
/// **One act on the record a socket**, under the gate as every line's: begun as it opens and ended
/// as it closes, whatever it carried meanwhile.
///
/// **A source that will not open one is heard line by line** (`apart`), as it was before, for the
/// rest of the run: `hear` hands back nothing, and the caller opens a line of its own. A drop ends
/// every stream it carried as a dropped line ends, and the next stream asked opens it again.
@MainActor
final class ShellSockets {
    /// The gate did not let the socket out: nothing is heard, as for a line it does not let out.
    struct Shut: Error {}

    let opener: (any SocketOpener)?
    /// How long a socket carrying nothing is kept, in case a stream is asked again: but for a test.
    let linger: @Sendable () async throws -> Void
    nonisolated static let lingering: Duration = .seconds(2)

    /// The sources whose socket was refused this run, by its answer — or 0 where it failed to open
    /// `tries` times running with no answer to say why: heard line by line.
    private(set) var apart: [String: Int] = [:]
    /// How many times running each source's socket failed to open, with no answer.
    private var failed: [String: Int] = [:]
    /// A socket that fails this many times running to open, the source answering nothing, is not
    /// asked again this run: whatever stands in front of the source does not carry one, and its
    /// lines are heard as before rather than nothing being heard at all.
    nonisolated static let tries = 2
    private var held: [String: Held] = [:]
    private var opening: [String: Task<Held, any Error>] = [:]

    /// One socket held, and the streams it carries now, each to whoever asked for it.
    @MainActor
    final class Held {
        let socket: OpenSocket
        let accessToken: String
        /// Each stream carried, to the one reader of it now, known by `id`.
        var streams: [MastodonStream: (id: UUID, told: AsyncThrowingStream<LineEvent, any Error>.Continuation)] = [:]
        var hearing: Task<Void, Never>?
        var closing: Task<Void, Never>?
        var closed = false
        let end: () -> Void

        init(socket: OpenSocket, accessToken: String, end: @escaping () -> Void) {
            self.socket = socket
            self.accessToken = accessToken
            self.end = end
        }
    }

    init(
        opener: (any SocketOpener)? = nil,
        linger: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: ShellSockets.lingering) }
    ) {
        self.opener = opener
        self.linger = linger
    }

    /// Whether `host`'s streams are each heard on a line of their own, its socket refused this run.
    func heardApart(_ host: String) -> Bool { apart[host.lowercased()] != nil }

    /// The sources a socket is held to now.
    var heldHosts: Set<String> { Set(held.keys) }

    /// `stream` of `host`, on its one socket — opened for it where none is held — until what is
    /// handed back is let go. **Nothing where it is not to be heard so**: no socket is made here, or
    /// the source refused one. Throws `Shut` where the gate did not let the socket out, and what
    /// the network threw where it did not open.
    func hear(
        _ stream: MastodonStream, host raw: String, token: MastodonToken, work: SourceWork
    ) async throws -> AsyncThrowingStream<LineEvent, any Error>? {
        let host = raw.lowercased()
        guard let opener, apart[host] == nil else { return nil }
        let socket: Held
        do {
            socket = try await held(host, token: token, work: work, opener: opener)
        } catch let refused as SocketRefused {
            apart[host] = refused.status
            return nil
        } catch let shut as Shut {
            throw shut
        } catch where !Cancellation.happened(error) {
            failed[host, default: 0] += 1
            guard failed[host, default: 0] >= Self.tries else { throw error }
            apart[host] = 0
            return nil
        }
        failed[host] = nil
        socket.closing?.cancel()
        socket.closing = nil
        // One reader a stream: one asked again takes it over, and the one before ends.
        socket.streams[stream]?.told.finish()
        let (events, told) = AsyncThrowingStream<LineEvent, any Error>.makeStream()
        let reader = UUID()
        socket.streams[stream] = (reader, told)
        told.onTermination = { [weak self, weak socket] _ in
            Task { @MainActor in
                guard let self, let socket else { return }
                self.letGo(stream, of: host, on: socket, reader: reader)
            }
        }
        do {
            try await socket.socket.send(MastodonSocket.subscribe(stream))
        } catch {
            told.finish(throwing: error)
            throw error
        }
        return events
    }

    /// The socket held to `host` under `token`, or opened now: once, whoever asks while it opens.
    private func held(_ host: String, token: MastodonToken, work: SourceWork, opener: any SocketOpener) async throws -> Held {
        if let socket = held[host] {
            guard socket.accessToken != token.accessToken else { return socket }
            // Another sign-in: what the one before carried is not this one's to hear.
            close(socket, of: host, dropped: nil)
        }
        if let open = opening[host] { return try await open.value }
        let open = Task { @MainActor () throws -> Held in
            guard let (opened, end) = try await work.openLine(host: host, name: nil, {
                try await MastodonSocket(token: token, opener: opener).open()
            }) else { throw Shut() }
            let socket = Held(socket: opened, accessToken: token.accessToken, end: end)
            socket.hearing = Task { [weak self, weak socket] in
                var dropped: (any Error)?
                do {
                    for try await message in opened.messages {
                        guard let (streams, event) = MastodonSocket.heard(message) else { continue }
                        // A message names the stream it is of as the stream is asked for by: a list
                        // or a hashtag by its word and its id or name (#460).
                        guard let stream = MastodonStream(named: streams) else { continue }
                        socket?.streams[stream]?.told.yield(event)
                    }
                } catch {
                    dropped = error
                }
                guard !Task.isCancelled, let self, let socket else { return }
                self.close(socket, of: host, dropped: dropped ?? URLError(.networkConnectionLost))
            }
            return socket
        }
        opening[host] = open
        defer { opening[host] = nil }
        let socket = try await open.value
        held[host] = socket
        return socket
    }

    /// `stream` let go by its reader: no longer asked of the source, and the socket closed a moment
    /// after it carries nothing.
    private func letGo(
        _ stream: MastodonStream, of host: String, on socket: Held, reader: UUID
    ) {
        // Taken over meanwhile by another reader of it, or the socket already closed.
        guard !socket.closed, socket.streams[stream]?.id == reader else { return }
        socket.streams[stream] = nil
        let send = socket.socket.send
        Task { try? await send(MastodonSocket.unsubscribe(stream)) }
        guard socket.streams.isEmpty, socket.closing == nil else { return }
        let linger = linger
        socket.closing = Task { [weak self, weak socket] in
            do { try await linger() } catch { return }
            guard let self, let socket, socket.streams.isEmpty else { return }
            self.close(socket, of: host, dropped: nil)
        }
    }

    /// `socket` closed: every stream it carried ends — failing as a dropped line does, where it
    /// dropped — and its act on the record ends.
    private func close(_ socket: Held, of host: String, dropped: (any Error)?) {
        if held[host] === socket { held[host] = nil }
        guard !socket.closed else { return }
        socket.closed = true
        let streams = socket.streams
        socket.streams = [:]
        socket.hearing?.cancel()
        socket.closing?.cancel()
        socket.end()
        for (_, told) in streams.values {
            if let dropped { told.finish(throwing: dropped) } else { told.finish() }
        }
    }
}
