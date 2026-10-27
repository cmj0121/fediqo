import FediqoCore
import Foundation
import Observation

/// What this device hides of what it already held, because the person muted or blocked
/// somebody at a source — or a whole server — and chose that what was held of them is hidden
/// here (#314).
///
/// **Beside a timeline's rules, and none of them.** A rule leaves a post out of a timeline and
/// says which rule did; this leaves the post where it stands, drawn as one line that says why:
/// who was muted or blocked, at which source. Every timeline draws it alike — the source no
/// longer hands such posts over, and this is what the device does with the ones it already had.
///
/// **Written down only once the source has said the mute or the block is done**, and taken off
/// once it says it is taken back — from this device; a mute for a time hides until its end, as
/// the source said it.
///
/// **The person's own list, kept as one** (`file`): beside the index where the app hands a file
/// in, under a key of the preferences where it hands none — and in memory alone where it hands
/// neither, as a test and a launch made for a picture do. Versioned, and **never written over
/// what cannot be read**: a hide dropped would show what the person chose not to see.
@MainActor
@Observable
final class ShellHides {
    /// One hide.
    struct Hide: Codable, Hashable, Sendable {
        enum Why: String, Codable, Sendable {
            case muted, blocked, server
        }

        /// The source the hidden posts came through, in lower case.
        let host: String
        /// `@user@host` of the person, as the source spelt it — nothing for a whole server.
        let handle: String?
        /// The server, for a whole server's block — nothing for one person.
        let server: String?
        let why: Why
        /// Until when, where the mute was for a time.
        let until: Date?

        /// Whether `item`'s own maker is whom this hides: by handle, whatever its case, or by the
        /// server their handle names.
        func hides(handle other: String?, at at: String) -> Bool {
            guard at.lowercased() == host, let other, !other.isEmpty else { return false }
            if let handle { return other.caseInsensitiveCompare(handle) == .orderedSame }
            guard let server, let named = other.split(separator: "@").last else { return false }
            return named.lowercased() == server
        }

        func lasts(at now: Date) -> Bool { until.map { now < $0 } ?? true }
    }

    private struct Kept: Codable {
        let version: Int
        let hides: [Hide]
    }

    static let version = 1
    static let key = "fediqo.hides"

    private(set) var hides: [Hide] = []
    /// Whether what is kept could not be read: nothing is then written over it, and it is read
    /// again before it is next asked or changed — a device locked at launch unlocks later.
    private(set) var unreadable = false
    /// What was changed while what is kept could not be read, in order: done over it once it is.
    @ObservationIgnored private var pending: [([Hide]) -> [Hide]] = []
    /// When each hide of this run was made, on the count `ticket` reads: a read that set out
    /// before a hide was made says nothing of it (`heard`).
    @ObservationIgnored private var born: [Hide: Int] = [:]
    @ObservationIgnored private var count = 0
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let file: ListFile?

    init(defaults: UserDefaults? = nil, file: ListFile? = nil) {
        self.defaults = defaults
        self.file = file
        if let read = read() { hides = read } else { unreadable = true }
    }

    /// What is kept: nothing where nothing is, and no answer where it cannot be read.
    private func read() -> [Hide]? {
        let data: Data?
        switch file?.read() {
        case .unread?, .notKnown?: return nil
        case .data(let kept)?: data = kept
        case .some(.none): data = nil
        case nil: data = defaults?.data(forKey: Self.key)
        }
        guard let data else { return [] }
        guard let kept = try? JSONDecoder().decode(Kept.self, from: data), kept.version == Self.version else { return nil }
        return kept.hides
    }

    /// What is kept read again where it could not be: what was changed meanwhile is done over
    /// it, and written down.
    private func readAgainIfUnread() {
        guard unreadable, let read = read() else { return }
        unreadable = false
        let changed = !pending.isEmpty
        hides = pending.reduce(read) { $1($0) }
        pending = []
        if changed { save() }
    }

    private func save() {
        guard !unreadable, let data = try? JSONEncoder().encode(Kept(version: Self.version, hides: hides)) else { return }
        if let file {
            file.write(data)
        } else {
            defaults?.set(data, forKey: Self.key)
        }
    }

    /// One change: made, and written down — or, while what is kept cannot be read, kept to be
    /// made over it once it can.
    private func change(_ op: @escaping ([Hide]) -> [Hide]) {
        readAgainIfUnread()
        let before = hides
        hides = op(hides)
        guard hides != before else { return }
        if unreadable { pending.append(op) } else { save() }
    }

    /// A mark to hand `heard`: taken when a read of how the reader stands sets out.
    func ticket() -> Int { count }

    /// What is held of the person `handle` names at `host` hidden from here on, `why`.
    func hide(_ handle: String, at host: String, _ why: Hide.Why, until: Date? = nil) {
        let host = host.lowercased()
        let made = Hide(host: host, handle: handle, server: nil, why: why, until: until)
        count += 1
        born[made] = count
        change { hides in
            hides.filter { !($0.host == host && $0.handle?.caseInsensitiveCompare(handle) == .orderedSame && $0.why == why) } + [made]
        }
    }

    /// What is held of everybody of `server`, at `host`, hidden from here on.
    func hide(server: String, at host: String) {
        let host = host.lowercased(), server = server.lowercased()
        let made = Hide(host: host, handle: nil, server: server, why: .server, until: nil)
        count += 1
        born[made] = count
        change { hides in hides.filter { !($0.host == host && $0.server == server) } + [made] }
    }

    /// The person's hide for `why` taken off: their mute, or their block, was taken back.
    func show(_ handle: String, at host: String, _ why: Hide.Why, since ticket: Int = .max) {
        let host = host.lowercased()
        change { [born] hides in
            hides.filter {
                !($0.host == host && $0.handle?.caseInsensitiveCompare(handle) == .orderedSame && $0.why == why
                    && born[$0, default: 0] <= ticket)
            }
        }
    }

    /// A server's hide taken off: its block was taken back.
    func show(server: String, at host: String, since ticket: Int = .max) {
        let host = host.lowercased(), server = server.lowercased()
        change { [born] hides in hides.filter { !($0.host == host && $0.server == server && born[$0, default: 0] <= ticket) } }
    }

    /// What a read of how the reader stands to the person `handle` names at `host` said, taken
    /// to what is hidden of them (#314): **a mute or a block the source says is no longer there —
    /// taken back elsewhere, or ended — hides nothing more here**, and so of the server they live
    /// on. Only of hides made before the read set out (`ticket`): one made since is newer than it.
    func heard(_ standing: PersonStanding, of handle: String, server: String?, at host: String, since ticket: Int) {
        if !standing.muting { show(handle, at: host, .muted, since: ticket) }
        if !standing.blocking { show(handle, at: host, .blocked, since: ticket) }
        if !standing.serverBlocked, let server { show(server: server, at: host, since: ticket) }
    }

    /// Every hide of `host` let go: the source was removed.
    func letGo(at host: String) {
        let host = host.lowercased()
        change { hides in hides.filter { $0.host != host } }
    }

    /// The hide that stands over `item` at `now`, where one does: of who made it, or — on a
    /// reblog's row — of whose post it shows. A block is said before a mute, a person before a
    /// server.
    func hide(of item: DummyItem, at now: Date = Date()) -> Hide? {
        readAgainIfUnread()
        guard !hides.isEmpty else { return nil }
        let makers = [item.handle] + item.reblogged.map(\.handle)
        let standing = hides.filter { hide in hide.lasts(at: now) && makers.contains { hide.hides(handle: $0, at: item.source.host) } }
        return standing.min { Self.rank($0.why) < Self.rank($1.why) }
    }

    private static func rank(_ why: Hide.Why) -> Int {
        switch why {
        case .blocked: 0
        case .muted: 1
        case .server: 2
        }
    }
}

/// What a hidden row says in place of the post (#314): why it is hidden, as one line — who was
/// muted or blocked, where — and the glyph beside it.
struct HiddenHere: Equatable {
    let symbol: String
    let words: String
    /// Whether it is a warning that opens on asking (#338): the row then offers to show the post.
    var opens = false

    /// A post the person's filter at its source caught (#338), named as the source names the
    /// filter: hidden, or covered with a warning that opens on asking. **The server's**, said as
    /// such, and never a rule's.
    init(filter hit: ServerFilterHit, host: String, language: DummyLanguage? = nil) {
        symbol = "line.3.horizontal.decrease.circle"
        switch hit.action {
        case .hide:
            words = String(format: L10n.t("hidden.filter", language: language), LineText.oneLine(hit.title), host)
        case .warn, .blur, .unknown:
            words = String(format: L10n.t("hidden.filter.warn", language: language), LineText.oneLine(hit.title), host)
            opens = true
        }
    }

    init(_ hide: ShellHides.Hide, language: DummyLanguage? = nil) {
        switch hide.why {
        case .muted:
            symbol = "speaker.slash"
            words = String(format: L10n.t("hidden.muted", language: language), LineText.oneLine(hide.handle ?? ""), hide.host)
        case .blocked:
            symbol = "hand.raised"
            words = String(format: L10n.t("hidden.blocked", language: language), LineText.oneLine(hide.handle ?? ""), hide.host)
        case .server:
            symbol = PersonActing.serverBlockedSymbol
            words = String(format: L10n.t("hidden.server", language: language), hide.server ?? "", hide.host)
        }
    }
}

extension ShellSession {
    /// Lets go of what this device holds of `authors` (#314) — the person's answer to a mute or a
    /// block — as a letting go by dates is let go (`letGo(span:host:)`): waited for, saved, and
    /// what is drawn read again. A post the person keeps stays. How many went.
    func letGo(by authors: HeldAuthors) async -> Int {
        await holdingStill {
            let told = await store.noticesRevision
            let went = await store.letGo(by: authors)
            guard went > 0 else {
                if await store.noticesRevision != told { await saveNow(.posts) }
                return 0
            }
            await reloadFromStore()
            await saveNow(.posts) { [weak self] in
                await self?.wordsLetGo()
                await self?.readStoreBytes()
            }
            return went
        }
    }
}
