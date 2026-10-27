import FediqoCore
import Foundation
import SwiftUI

// What the reader bookmarked and favourited at a Mastodon, read as two of its categories (#317).
//
// **Read where the sign-in may read them, and asked for where it may not.** Like Home, they are
// read with every reload that reads the source as the reader — and only once the sign-in holds
// the part that reads them (`MastodonPart.marks`), which no sign-in is asked for unless the person
// presses for it. The place that offers them is the source's own `…`: where the sign-in holds
// the part, its item reads them again now; where it does not, the item is the part's lock, says
// why, and its press puts the question that says what the source's page will ask before it
// opens (`ShellSession.askFor`). Signed out, it is there and dim, as Lists is.
//
// **Rows stand at their publish time**, as in every timeline, and a timeline that reads them says
// at its foot that this is not the order they were marked in (`MarksOrderFoot`).
//
// **A read that fails changes nothing.** `MastodonMarks.read` lands a category whole or not at
// all, and what could not be read is the reload's to say, as for any timeline.

extension MastodonSessions {
    /// The categories of the reader's marks the sign-in held at `host` may read (#317), in the
    /// order they are offered — none where no sign-in is held, or it holds neither word.
    func marksRead(host raw: String) -> [FediqoCore.Category] {
        guard let held = heldParts[raw.lowercased()] else { return [] }
        return [.bookmarks, .favourites].filter { MastodonParts.readsMarks($0, in: held.scopes) }
    }
}

extension ShellReload {
    /// The categories of the reader's marks `categories` asks of `source` — every one the sign-in
    /// may read where it names none — read and landed, one after the other. Whether every one came
    /// back; a reader walking away is not a failure, and a sign-in the server ended is told.
    ///
    /// `thorough` is a read the person asked for — a reload, a press, a sign-in — which walks on
    /// past every mark held so that each is decided; the wait's stops where it meets what is held
    /// (`MastodonMarks.read`).
    ///
    /// **One read of a category at a source at a time**, whichever way it was asked — a reload,
    /// the wait, a press of the source's item, a sign-in: one asked while another is on its way
    /// asks nothing, and is as read as that one will be. The store tells a read outrun by a later
    /// one apart all the same (`ItemStore.beginMarks`); this keeps the second off the wire.
    func readMarks(
        _ source: Source, for categories: Set<FediqoCore.Category>?, thorough: Bool = true, in session: ShellSession
    ) async -> Bool {
        let host = source.host
        let marks = session.mastodon.marksRead(host: host).filter { categories?.contains($0) ?? true }
        var read = true
        for category in marks {
            guard !Task.isCancelled else { break }
            let stretch = Stretch(host: host, category: category)
            guard !marksReading.contains(stretch), let reading = marksReader(category, of: source, in: session) else { continue }
            marksReading.insert(stretch)
            defer { marksReading.remove(stretch) }
            do {
                try await asReader(host) { try await reading.read(category, thorough: thorough) }
            } catch MastodonAuthError.signedOut {
                session.mastodon.endedByServer(host: host)
                noteSignedOut(category, of: host)
                return false
            } catch {
                if Cancellation.happened(error) {
                    noteStopped(host)
                    return read
                }
                noteUnread(category, of: host, error)
                NetLog.auth.error("\(NetLog.line("read marks", host: host, error: error), privacy: .public)")
                read = false
            }
        }
        return read
    }

    /// The stretch of a category of marks below `floor`, as an ask for more (#87), ended by a
    /// sign-out or a Clear before anything it brings lands. Hands back the mark the source says
    /// the next stretch begins below, nothing at the list's end.
    func olderMarks(_ category: FediqoCore.Category, of source: Source, below floor: String, in session: ShellSession) async throws -> String? {
        // Signed out since this was worked out: a walk away, as a sign-out ends a read on its way.
        guard let reading = marksReader(category, of: source, in: session) else { throw CancellationError() }
        return try await asReader(source.host) { try await reading.older(category, than: floor) }
    }

    /// A place where marks may be missing below `post`, reached (#317): read down as the reader.
    /// Nothing where signed out since it was drawn.
    func readDownMarks(_ category: FediqoCore.Category, of host: String, below post: NoteKey, in session: ShellSession) async throws {
        guard let source = session.sources.first(where: { $0.host == host }),
              let reading = marksReader(category, of: source, in: session)
        else { return }
        try await asReader(host) { try await reading.readDown(category, below: post) }
    }

    /// What reads `category` of the reader's marks at `source`: its sign-in's door, named on the
    /// wire as every timeline of the source is (`names(of:)`) and bounded by the reload's
    /// deadline. Nothing where no sign-in is held there.
    private func marksReader(_ category: FediqoCore.Category, of source: Source, in session: ShellSession) -> MastodonMarks? {
        guard let token = session.mastodon.token(host: source.host) else { return nil }
        let door = session.mastodon.authorized(
            token: token, within: deadline, for: .timeline, name: Self.names(of: source)(category)
        )
        return MastodonMarks(door: door, store: session.store)
    }

    /// The lowest floor held of each stretch of marks `query` reads (#317) **that is due to be
    /// read on from it**: one this run has not read on yet, and so has no next of the source's
    /// own (`ShellStretches`). Read off the store, which reads the file's rows of it in; nothing
    /// for a stretch with nothing held, whose first stretch a reload reads, nor for one read to
    /// its end — and nothing asked of the store where `query` reads no marks at all.
    static func marksFloors(_ query: TimelineQuery, in session: ShellSession, after stretches: ShellStretches = ShellStretches()) async -> [Stretch: String] {
        let sources = session.sources
        let asks = CompiledTimeline(query.definition(among: session.written), sources: sources).sourcesToAsk()
        var floors: [Stretch: String] = [:]
        for ask in asks {
            for category in session.mastodon.marksRead(host: ask.host) where ask.categories?.contains(category) ?? true {
                let stretch = Stretch(host: ask.host, category: category)
                guard stretches.nextMarks(stretch) == nil, !stretches.marksEnded.contains(stretch),
                      let floor = await session.store.lowestMark(host: ask.host, category: category),
                      floor != MastodonMarks.end
                else { continue }
                floors[stretch] = floor
            }
        }
        return floors
    }
}

extension ShellSession {
    /// The categories of the reader's marks the sign-in at `host` may read (#317) — what a page
    /// asks, so that no page that draws has to know which kind of source keeps sign-ins.
    func readableMarks(host: String) -> [FediqoCore.Category] {
        mastodon.marksRead(host: host)
    }

    /// The lock of what reads the reader's marks at `host`, where the sign-in does not hold it.
    func marksLock(host: String) -> PartWords.Place? {
        mastodon.place(.marks, host: host)
    }

    /// The press on a source row's marks item (#317): where the sign-in may read them, they are
    /// read again now, as the reader; where it may be asked for them, the question is put — sent
    /// nothing until its yes. Nothing otherwise.
    func pressMarks(host raw: String) async {
        let host = raw.lowercased()
        guard Self.rowActsLive(at: stage, checking: checking), mastodon.isSignedIn(host: host),
              let source = sources.first(where: { $0.host == host })
        else { return }
        if let place = mastodon.place(.marks, host: host) {
            if place.asks { askFor([.marks], host: host) }
            return
        }
        // One read of each at a time, the reload's and this one's alike (`ShellReload.readMarks`).
        guard !mastodon.marksRead(host: host).isEmpty else { return }
        rowRefusal = nil
        let read = await reload.readMarks(source, for: nil, in: self)
        await reloadFromStore()
        if !read, isAdded(host) { rowRefusal = (host: host, key: "account.source.marks.unread") }
    }

    /// Whether `query` names a category of marks of a source that reads it (#317) — where its
    /// foot says rows stand by when they were published, not when they were marked. Not a
    /// timeline of everything, which names none: nothing there is said to stand by its mark.
    ///
    /// **Worked out once for what it depends on** — the timeline's rules, the sources, and what
    /// each sign-in may read — and kept until one of those changes, not on every drawing.
    func readsMarks(_ query: TimelineQuery) -> Bool {
        let asked = MarksOrderAsked(
            definition: query.definition(among: written), sources: sources,
            reads: sources.map { mastodon.marksRead(host: $0.host) }
        )
        if let said = marksOrderSaid, said.asked == asked { return said.says }
        let asks = CompiledTimeline(asked.definition, sources: sources).sourcesToAsk()
        let says = asks.contains { ask in
            mastodon.marksRead(host: ask.host).contains { ask.categories?.contains($0) == true }
        }
        marksOrderSaid = (asked, says)
        return says
    }
}

/// What whether a timeline's foot says its marks stand by publish time depends on (#317).
struct MarksOrderAsked: Equatable {
    let definition: TimelineDefinition
    let sources: [Source]
    let reads: [[FediqoCore.Category]]
}

extension SourceRow {
    /// How the marks item of a row's `…` is drawn (#317): its glyph, what it says, and its look —
    /// **or nothing, for a kind of source that has no such thing**, whose menu lists only what
    /// it has (the rule for acts only one kind has, beside following and muting).
    ///
    /// **It says why where it is not offered**: signed out — dim, not now, as Lists is. Where the
    /// sign-in does not hold what reads them (`place`), the item is that part's lock and its own
    /// line: live where its press puts the question, dim where the source has none to give or is
    /// being asked now.
    @MainActor
    static func marksMark(
        _ row: SourceRow, actsLive: Bool, reads: Bool, place: PartWords.Place?, language: DummyLanguage? = nil
    ) -> ShellMark? {
        let named = String(format: L10n.t("account.source.marks.read", language: language), row.source.host)
        guard row.source.kind.offers.marks else { return nil }
        guard row.signedIn else { return ShellMark(marksSymbol, named, look: .dim(.notNow)) }
        if let place {
            let line = String(format: L10n.t(place.key, language: language), row.source.host)
            let dim: DimReason = place.kind == .none ? .never : .notNow
            return ShellMark(permissionSymbol, line, look: actsLive && place.asks ? .live : .dim(dim))
        }
        return ShellMark(marksSymbol, named, look: actsLive && reads ? .live : .dim(.notNow))
    }

    /// The glyph of the marks item: a bookmark, the first of the two, and a glyph no other item
    /// of the menu wears.
    static let marksSymbol = "bookmark"

    /// How the conversations item of a row's `…` is drawn (#326). **Always drawn**, the same
    /// glyph on every source: live where the sign-in may read them, and dim with the shared
    /// reason where it may not. Where reading is not held, the item is that part's lock.
    @MainActor
    static func directsMark(
        _ row: SourceRow, actsLive: Bool, reads: Bool, place: PartWords.Place?, language: DummyLanguage? = nil
    ) -> ShellMark {
        let named = String(format: L10n.t("account.source.conversations", language: language), row.source.host)
        guard row.source.kind.offers.conversations else { return ShellMark(directsSymbol, named, look: .dim(.never)) }
        guard row.signedIn else { return ShellMark(directsSymbol, named, look: .dim(.notNow)) }
        if let place {
            let line = String(format: L10n.t(place.key, language: language), row.source.host)
            if actsLive, place.asks { return ShellMark(directsSymbol, line, look: .dim(.askAgain)) }
            let dim: DimReason = place.kind == .none ? .never : .notNow
            return ShellMark(directsSymbol, line, look: .dim(dim))
        }
        return ShellMark(directsSymbol, named, look: actsLive && reads ? .live : .dim(.notNow))
    }

    /// The glyph of the conversations item, worn live and dim alike.
    static let directsSymbol = "bubble.left.and.bubble.right"
}
