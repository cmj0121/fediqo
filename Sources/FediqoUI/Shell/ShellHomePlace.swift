import FediqoCore
import Foundation
import Observation
import SwiftUI

/// Where a signed-in Mastodon says this reader stopped in Home, and the line that names both
/// places (#316).
///
/// **Off until it is chosen, and one host at a time.** Nothing here is asked of a host that is
/// not in `ShellStopped`. The timeline in front is asked only where what it wants of that host
/// includes Home — its usual reads, or a rule that names Home — and never for Trends.
///
/// **The row being read, and not the newest post.** It is told when that row has settled, or
/// when the timeline is left. A row older than the post the source already names is not sent:
/// the source's own post has to be on this device to know, and where it is not, nothing is
/// written over it. A read that failed is not written over either. The press that stays is the
/// one that may send an older row. The press that goes there only moves the list, the way a row
/// is already brought on screen, and appearing the line moves nothing.
@MainActor
@Observable
final class ShellHomePlace {
    /// The two places, or why the line cannot offer them.
    enum Line: Equatable {
        /// `here` is the row being read. `there` is the row the source names. Both are row ids.
        case apart(host: String, here: String, there: String)
        case missing(host: String)
        case failed(host: String)
    }

    /// What the press that goes to the source's post asks the list to do. Nothing until that
    /// press: the line appearing does not set it.
    struct Move: Equatable {
        enum How: Equatable {
            /// A keyboard or a pointer: the selection, which the list already centres.
            case select
            /// A finger: the mark kept, which the list already puts at the top.
            case keep
        }

        let rowID: String
        let how: How
    }

    /// The switch, where this host has a Mastodon sign-in. Locked until the sign-in holds
    /// acting: the press asks, and nothing is written down before it is held.
    struct Offer: Equatable {
        enum Shape: Equatable {
            case locked(String)
            case toggle
        }

        let shape: Shape
        var on: Bool
    }

    private struct Heard {
        enum Read: Equatable {
            case unknown
            /// The source has not been told.
            case none
            case place(HomePlace)
            case failed
        }

        var read: Read = .unknown
        /// The id last claimed for a tell, so a second one does not send it again.
        var told: String?
        var fault = false
    }

    private(set) var line: Line?
    private(set) var move: Move?
    /// The row the line and a tell use: the mark under a finger, the selection otherwise.
    private(set) var readingID: String?

    @ObservationIgnored private var touch = false
    @ObservationIgnored private var finger: String?
    @ObservationIgnored private var selected: String?
    @ObservationIgnored private var front: TimelineQuery?
    @ObservationIgnored private var drifting = false
    /// Opened under a finger before the list had laid a whole row out. The first whole row is
    /// told; a row only half on screen is not, and later movement waits for settle or leave.
    @ObservationIgnored private var awaitingLayout = false
    @ObservationIgnored private var heard: [String: Heard] = [:]
    @ObservationIgnored private var readTicket: [String: Int] = [:]
    @ObservationIgnored private var tellTicket: [String: Int] = [:]
    @ObservationIgnored private var openTicket = 0
    @ObservationIgnored private var inflight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var flight: [String: Int] = [:]

    /// Hosts `timeline` tells where Home was left: switched on, and asked for Home.
    static func hostsTold(
        timeline: TimelineQuery, written: [TimelineDefinition], sources: [Source], stopped: Set<String>
    ) -> [String] {
        let asks = CompiledTimeline(timeline.definition(among: written), sources: sources).sourcesToAsk()
        return asks.compactMap { ask in
            let host = ask.host.lowercased()
            guard stopped.contains(host) else { return nil }
            guard ask.categories == nil || ask.categories?.contains(.home) == true else { return nil }
            return host
        }
    }

    func offer(host: String, in session: ShellSession) -> Offer? {
        guard session.mastodon.token(host: host) != nil else { return nil }
        let on = session.stopped.hosts.contains(host.lowercased())
        if let place = session.mastodon.place(.acting, host: host) {
            let words = L10n.t(place.key)
            let sentence = words.contains("%@") ? String(format: words, host) : words
            return Offer(shape: .locked(sentence), on: false)
        }
        return Offer(shape: .toggle, on: on)
    }

    /// The locked switch. Asks for acting and does not turn the host on.
    func pressLocked(host: String, in session: ShellSession) {
        guard session.mastodon.place(.acting, host: host) != nil else { return }
        session.askFor([.acting], host: host)
    }

    /// The switch, once acting is held. Off sends nothing further and forgets what was read.
    func setOn(_ on: Bool, host raw: String, in session: ShellSession) async {
        guard offer(host: raw, in: session)?.shape == .toggle else { return }
        let host = raw.lowercased()
        if on {
            session.stopped.turnOn(host)
            guard let front, Self.hostsTold(
                timeline: front, written: session.written, sources: session.sources, stopped: session.stopped.hosts
            ).contains(host) else { return }
            await fetch(host, in: session)
            if !drifting { await tell(readingID, on: front, backward: false, in: session) }
            refreshLine(in: session)
        } else {
            session.stopped.turnOff(host)
            // A read still on the wire must not write this host back, or a tell waiting on it
            // would send after the switch is off.
            readTicket[host] = (readTicket[host] ?? 0) + 1
            heard[host] = nil
            refreshLine(in: session)
        }
    }

    /// The timeline became the one in front. A second call for the same timeline does not ask again.
    func opened(
        _ timeline: TimelineQuery, reading row: String?, touch now: Bool, tellSettled: Bool, in session: ShellSession
    ) async {
        touch = now
        // Nil under a finger is the list not laid out yet. A row already noted is the one
        // being read; wiping it would tell nothing once the list has settled.
        let fingerNotLaidOut = now && row == nil && readingID != nil
        if !fingerNotLaidOut {
            if now { finger = row } else { selected = row }
            readingID = row
        }
        awaitingLayout = now && readingID == nil
        guard front != timeline else {
            refreshLine(in: session)
            return
        }
        openTicket += 1
        let ticket = openTicket
        front = timeline
        let hosts = Self.hostsTold(
            timeline: timeline, written: session.written, sources: session.sources, stopped: session.stopped.hosts
        )
        for host in hosts {
            await fetch(host, in: session)
            guard openTicket == ticket else { return }
        }
        if tellSettled, !drifting {
            await tell(readingID, on: timeline, backward: false, in: session)
        }
        guard openTicket == ticket else { return }
        refreshLine(in: session)
    }

    /// `from` was left on `leaving`, and `to` is now in front.
    func switched(
        from: TimelineQuery, to: TimelineQuery, leaving: String?, arriving: String?, touch now: Bool,
        in session: ShellSession
    ) async {
        await tell(leaving, on: from, backward: false, in: session)
        front = nil
        // An explicit nil — a search's results — is not a list that has not laid out.
        if arriving == nil {
            readingID = nil
            if now { finger = nil } else { selected = nil }
        }
        await opened(to, reading: arriving, touch: now, tellSettled: true, in: session)
    }

    /// The timeline was left on `rowID`. A later open of it asks again.
    func left(_ rowID: String?, on timeline: TimelineQuery, in session: ShellSession) async {
        await tell(rowID, on: timeline, backward: false, in: session)
        if front == timeline {
            front = nil
            line = nil
        }
    }

    /// The mark moved. Updates the row the line names and does not tell: a half-visible row
    /// and a row passed while the list is moved are not where reading settled.
    func fingerNoted(_ id: String?, in session: ShellSession) async {
        guard touch, readingID != id else { return }
        finger = id
        readingID = id
        refreshLine(in: session)
    }

    /// The first row wholly on screen after an open that had not seen one. Later whole rows
    /// only move the line; settle and leave tell those.
    func wholeNoted(_ id: String?, in session: ShellSession) async {
        let first = awaitingLayout
        if first { awaitingLayout = false }
        if touch || readingID == nil {
            finger = id
            if readingID != id {
                readingID = id
                refreshLine(in: session)
            }
        }
        guard first, touch, !drifting, let id, let front else { return }
        await tell(id, on: front, backward: false, in: session)
    }

    func selectionNoted(_ id: String?, in session: ShellSession) {
        selected = id
        guard !touch, readingID != id else { return }
        readingID = id
        refreshLine(in: session)
    }

    func mode(touch now: Bool, row: String?, in session: ShellSession) {
        touch = now
        if now { finger = row } else { selected = row }
        guard readingID != row else { return }
        readingID = row
        refreshLine(in: session)
    }

    /// The list is moving: a row it passes is not told.
    func moving() { drifting = true }

    /// The list is still. The row being read is told, once.
    func settled(in session: ShellSession) async {
        drifting = false
        guard let front else { return }
        await tell(readingID, on: front, backward: false, in: session)
    }

    /// Stay on the row being read. The one tell that may send an older id.
    func here(in session: ShellSession) async {
        guard case .apart(_, let row, _) = line, let front else { return }
        await tell(row, on: front, backward: true, in: session)
    }

    /// Go to the post the source names. Moves the list and sends nothing.
    func there(touch now: Bool) {
        guard case .apart(_, _, let row) = line else { return }
        touch = now
        move = Move(rowID: row, how: now ? .keep : .select)
    }

    func clearMove() { move = nil }

    private func fetch(_ host: String, in session: ShellSession) async {
        let ticket = (readTicket[host] ?? 0) + 1
        readTicket[host] = ticket
        flight[host] = ticket
        let task = Task { @MainActor in
            await self.load(host, ticket: ticket, in: session)
        }
        inflight[host] = task
        await task.value
        if flight[host] == ticket { inflight[host] = nil }
    }

    private func load(_ host: String, ticket: Int, in session: ShellSession) async {
        guard let door = session.mastodon.authorized(host: host, for: .timeline) else { return }
        let read: Heard.Read
        do {
            let place = try await MastodonHomePlace(door: door).read()
            read = place.map { .place($0) } ?? .none
        } catch {
            read = .failed
        }
        guard readTicket[host] == ticket else { return }
        var heard = self.heard[host] ?? Heard()
        heard.read = read
        if read != .failed { heard.fault = false }
        self.heard[host] = heard
        refreshLine(in: session)
    }

    /// Tells `rowID` where that row is a Home post of a host `timeline` asks for Home.
    /// `backward` is the press that stays: without it, a row older than the source's post is
    /// not sent, and a source post this device does not hold is not written over.
    private func tell(_ rowID: String?, on timeline: TimelineQuery, backward: Bool, in session: ShellSession) async {
        guard let rowID, let note = homeNote(rowID, in: session) else { return }
        let host = note.source.host.lowercased()
        guard Self.hostsTold(
            timeline: timeline, written: session.written, sources: session.sources, stopped: session.stopped.hosts
        ).contains(host) else { return }
        if let pending = inflight[host] { await pending.value }
        guard Self.hostsTold(
            timeline: timeline, written: session.written, sources: session.sources, stopped: session.stopped.hosts
        ).contains(host) else { return }
        guard maySend(note, backward: backward, in: session) else { return }
        guard let door = session.mastodon.authorized(host: host, for: .timeline) else { return }
        let ticket = (tellTicket[host] ?? 0) + 1
        tellTicket[host] = ticket
        var heard = self.heard[host] ?? Heard()
        let previous = heard.told
        heard.told = note.id
        self.heard[host] = heard
        do {
            let place = try await MastodonHomePlace(door: door).tell(lastReadID: note.id)
            guard tellTicket[host] == ticket, var now = self.heard[host] else { return }
            now.read = .place(place)
            now.told = note.id
            now.fault = false
            self.heard[host] = now
        } catch {
            guard tellTicket[host] == ticket, var now = self.heard[host] else { return }
            if now.told == note.id { now.told = previous }
            now.fault = true
            self.heard[host] = now
        }
        refreshLine(in: session)
    }

    private func maySend(_ note: Note, backward: Bool, in session: ShellSession) -> Bool {
        let host = note.source.host.lowercased()
        guard let heard = heard[host] else { return false }
        if heard.told == note.id { return false }
        switch heard.read {
        case .unknown, .failed:
            return false
        case .none:
            return true
        case .place(let place):
            if place.lastReadID == note.id { return false }
            guard let source = session.heldNote(key: NoteKey(host: host, id: place.lastReadID)) else { return false }
            if !backward, note.postedAt < source.postedAt { return false }
            return true
        }
    }

    private func homeNote(_ rowID: String, in session: ShellSession) -> Note? {
        guard let note = session.note(ofRow: rowID), note.categories.contains(.home) else { return nil }
        return note
    }

    private func refreshLine(in session: ShellSession) {
        guard let front, let row = readingID, let note = homeNote(row, in: session) else {
            line = nil
            return
        }
        let host = note.source.host.lowercased()
        guard Self.hostsTold(
            timeline: front, written: session.written, sources: session.sources, stopped: session.stopped.hosts
        ).contains(host), let heard = heard[host] else {
            line = nil
            return
        }
        if heard.fault || heard.read == .failed {
            line = .failed(host: host)
            return
        }
        guard case .place(let place) = heard.read else {
            line = nil
            return
        }
        if place.lastReadID == note.id {
            line = nil
            return
        }
        guard let source = session.heldNote(key: NoteKey(host: host, id: place.lastReadID)) else {
            line = .missing(host: host)
            return
        }
        line = .apart(host: host, here: note.key.rowID, there: source.key.rowID)
    }
}
