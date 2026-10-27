import FediqoCore
import Foundation
import Observation

// Posts written to named people, read as conversations (#326): what is asked, when, and what the
// sheet holds of the answers — and marking one read, and removing one from the list.
//
// **Asked when the sheet opens, and when the person presses.** One page at the opening, the next
// at the foot's press, from the top again at Try again. One ask on the wire for the sheet.
//
// **Read with what reads a timeline, changed with the conversations part.** A sign-in that reads
// can open the list. Marking one read and removing one are asked only where that part is held,
// and a failure of either leaves the list this device drew as it was.
//
// **A page that set out before a removal does not bring the line back.** The count moves when a
// removal starts and when a read starts, and a read applies only while it is still the latest.

/// Every list of conversations opened this run, by host.
@MainActor
@Observable
final class ShellDirects {
    private struct Held {
        var lines: [DirectLine] = []
        var notes: [String: Note] = [:]
        var next: String?
        var asking = false
        var failed = false
        var footFailed = false
        var answered = false
        var generation = 0
        var old: Set<String> = []
        var removeFailed: Set<String> = []
        /// Conversations removed here: a read that still lists one does not put it back.
        var gone: Set<String> = []
    }

    /// The host whose list is up, where one is.
    var shown: String?
    /// Who a conversation's answer goes to, by the row of its post: the other people, each a
    /// whole handle. The open list wins; a held note of the conversation answers after a relaunch.
    private(set) var people: [String: [String]] = [:]

    private var pages: [String: Held] = [:]
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)

    func close() { shown = nil }

    /// What the sheet of `host` draws, or nothing where nobody is signed in there.
    func said(at raw: String, in session: ShellSession) -> DirectsSaid? {
        let host = raw.lowercased()
        guard session.sources.contains(where: { $0.host == host }), session.mastodon.isSignedIn(host: host) else { return nil }
        var said = DirectsSaid(host: host)
        said.lock = session.mastodon.place(.conversations, host: host)
        guard let page = pages[host] else { return said }
        said.lines = page.lines
        said.old = page.old
        said.removeFailed = page.removeFailed
        said.failedBanner = page.failed && !page.lines.isEmpty
        said.reading = page.failed && page.lines.isEmpty ? .failed : page.answered ? .said : .asking
        said.asking = page.asking
        if page.answered, !page.asking {
            said.foot = page.footFailed ? .failed : page.next != nil ? .more : nil
        }
        return said
    }

    /// The sheet put up for `host`, and its list asked where it is not already being asked.
    func show(_ raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        shown = host
        if pages[host]?.asking == true { return }
        await load(host, in: session)
    }

    /// The list asked from the top.
    func again(_ raw: String, in session: ShellSession) async {
        await load(raw.lowercased(), in: session)
    }

    /// The foot's press: the page after what is drawn.
    func readOn(_ raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        guard pages[host]?.answered == true, pages[host]?.asking != true, pages[host]?.next != nil else { return }
        await load(host, in: session, onward: true)
    }

    /// Opens conversation `id` as the thread of its latest post. Marked read where the sign-in
    /// may, and opened either way once this device holds the post. A post the keep window
    /// refused is said on the line and not opened.
    func open(_ id: String, at raw: String, in session: ShellSession, then onOpen: (String) -> Void) async {
        let host = raw.lowercased()
        guard let line = pages[host]?.lines.first(where: { $0.id == id }), let row = line.statusRow else { return }
        let generation = pages[host]?.generation ?? 0
        if let note = pages[host]?.notes[id] {
            await keep([id: note], host: host, in: session)
        }
        guard pages[host]?.generation == generation else { return }
        guard session.heldNote(row) != nil else {
            pages[host]?.old.insert(id)
            return
        }
        if session.mastodon.place(.conversations, host: host) == nil {
            await markRead(id, at: host, generation: generation, in: session)
        }
        guard pages[host]?.generation == generation else { return }
        shown = nil
        onOpen(row)
    }

    /// Removes conversation `id` from the list, after the question's yes. The posts stay. A
    /// refusal leaves the line where it is.
    func remove(_ id: String, at raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        guard pages[host] != nil, session.mastodon.place(.conversations, host: host) == nil,
              let door = session.mastodon.authorized(host: host, within: deadline, for: .conversation, name: .conversations)
        else { return }
        pages[host]?.generation += 1
        let generation = pages[host]?.generation ?? 0
        let note = pages[host]?.notes[id]
        do {
            try await MastodonDirects(door: door).remove(id)
            pages[host]?.gone.insert(id)
            pages[host]?.lines.removeAll { $0.id == id }
            pages[host]?.notes[id] = nil
            pages[host]?.old.remove(id)
            pages[host]?.removeFailed.remove(id)
            if let note {
                await session.store.release(note.key, from: .conversations)
                session.saveSoon()
                await session.reloadFromStore()
            }
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
            if pages[host]?.generation == generation { pages[host]?.removeFailed.insert(id) }
        } catch {
            if pages[host]?.generation == generation { pages[host]?.removeFailed.insert(id) }
        }
    }

    /// Who an answer written on `item` or on `root` goes to, where either is a conversation's
    /// post: the people kept for it, or those written on the held note.
    func locked(touching item: String, root: String, itemNote: Note?, rootNote: Note?) -> [String] {
        if let held = people[item] ?? people[root], !held.isEmpty { return held }
        for note in [itemNote, rootNote] {
            if let note, note.categories.contains(.conversations), !note.mentions.isEmpty { return note.mentions }
        }
        return []
    }

    private func load(_ host: String, in session: ShellSession, onward: Bool = false) async {
        guard session.isSignedIn(host: host), session.directsReads(host: host) else { return }
        if pages[host]?.asking == true { return }
        if pages[host] == nil { pages[host] = Held() }
        pages[host]?.generation += 1
        let generation = pages[host]?.generation ?? 0
        let cursor = onward ? pages[host]?.next : nil
        pages[host]?.asking = true
        if onward { pages[host]?.footFailed = false } else { pages[host]?.failed = false }
        guard let door = session.mastodon.authorized(host: host, within: deadline, for: .conversation, name: .conversations) else {
            if pages[host]?.generation == generation { pages[host]?.asking = false }
            return
        }
        do {
            let read = try await MastodonDirects(door: door).page(after: cursor)
            guard pages[host]?.generation == generation else { return }
            await keep(read.notes, host: host, in: session)
            guard pages[host]?.generation == generation else { return }
            let gone = pages[host]?.gone ?? []
            let arrived = read.lines.filter { !gone.contains($0.id) }
            var notes = read.notes
            notes = notes.filter { !gone.contains($0.key) }
            if onward {
                let had = Set(pages[host]?.lines.map(\.id) ?? [])
                pages[host]?.lines += arrived.filter { !had.contains($0.id) }
                for (id, note) in notes where pages[host]?.notes[id] == nil { pages[host]?.notes[id] = note }
            } else {
                pages[host]?.lines = arrived
                pages[host]?.notes = notes
                pages[host]?.old = []
                pages[host]?.removeFailed = []
            }
            pages[host]?.next = read.next
            pages[host]?.answered = true
            pages[host]?.failed = false
            pages[host]?.footFailed = false
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
        } catch is PagingError {
            guard pages[host]?.generation == generation else { return }
            pages[host]?.next = nil
            pages[host]?.answered = true
        } catch {
            guard pages[host]?.generation == generation else { return }
            if onward { pages[host]?.footFailed = true } else { pages[host]?.failed = true }
        }
        if pages[host]?.generation == generation { pages[host]?.asking = false }
    }

    private func markRead(_ id: String, at host: String, generation: Int, in session: ShellSession) async {
        guard let door = session.mastodon.authorized(host: host, within: deadline, for: .conversation, name: .conversations) else { return }
        do {
            try await MastodonDirects(door: door).markRead(id)
            guard pages[host]?.generation == generation else { return }
            if let index = pages[host]?.lines.firstIndex(where: { $0.id == id }) {
                pages[host]?.lines[index].unread = false
            }
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
        } catch {
            session.showToast(L10n.t("conversations.markFailed"))
        }
    }

    /// The notes land, and who is in each conversation is written on the post — the reader left
    /// out — so an answer after a relaunch still names the same people.
    private func keep(_ notes: [String: Note], host: String, in session: ShellSession) async {
        await session.store.ingest(Array(notes.values), ifSourceHere: host)
        let reader = session.mastodon.reader(host: host)?.handle
        for (id, note) in notes {
            let handles = Self.without(reader, note.mentions)
            await session.store.direct(note.key, conversation: id, mentions: handles)
            people[note.key.rowID] = handles
        }
        session.saveSoon()
        await session.reloadFromStore()
    }

    /// `handles` without the reader, once each, in order.
    private static func without(_ reader: String?, _ handles: [String]) -> [String] {
        let mine = reader?.lowercased()
        var seen = Set<String>()
        return handles.filter { handle in
            let key = handle.lowercased()
            if key == mine { return false }
            return seen.insert(key).inserted
        }
    }
}

extension ShellSession {
    /// The lock of what reads conversations at `host`, where the sign-in does not hold reading.
    /// Nothing where nobody is signed in: the row then says not now, as its other reads do.
    func directsLock(host: String) -> PartWords.Place? {
        guard isSignedIn(host: host) else { return nil }
        return mastodon.place(.reading, host: host)
    }

    /// Whether the sign-in at `host` may read posts written to named people.
    func directsReads(host: String) -> Bool {
        isSignedIn(host: host) && directsLock(host: host) == nil
    }

    /// The press on a source row's conversations item (#326): the list, where the sign-in may
    /// read it; the question, where it may be asked for reading. Nothing otherwise.
    func pressDirects(host raw: String) async {
        let host = raw.lowercased()
        guard Self.rowActsLive(at: stage, checking: checking), isSignedIn(host: host),
              let source = sources.first(where: { $0.host == host }), source.kind.offers.conversations
        else { return }
        if let place = directsLock(host: host) {
            if place.asks { askFor([.reading], host: host) }
            return
        }
        await directs.show(host, in: self)
    }
}
