import FediqoCore
import Foundation
import SwiftUI

/// Where the reader stopped reading: which timeline, the post the lamp was on, the row at the top
/// of the stream, and the conversation that was open (#273).
///
/// **No tab.** Preferences and Account are pages the rail reaches, not places reading stops at;
/// which of them comes up is the launch's to say.
///
/// **Ids, and nothing they stand for.** A post named here may have been let go by the time it is
/// read again, and a timeline deleted; what to land on then is the landing's to say, against what
/// this device holds on that day.
struct ReadingPlace: Equatable, Sendable {
    var timeline: TimelineQuery
    /// The post the lamp was on, or nothing where none was lit.
    var lamp: String?
    /// The row at the top of the stream, as it was last left scrolled.
    var top: String?
    /// The post whose conversation was open, or nothing where the reader was on the stream.
    var thread: String?

    init(timeline: TimelineQuery, lamp: String? = nil, top: String? = nil, thread: String? = nil) {
        self.timeline = timeline
        self.lamp = lamp
        self.top = top
        self.thread = thread
    }
}

extension ReadingPlace {
    /// The half of the place the root view holds: the lamp and the walk are its, as the timeline
    /// and the top row are the session's.
    struct Standing: Equatable, Sendable {
        var lamp: String?
        var thread: String?

        init(lamp: String? = nil, thread: String? = nil) {
            self.lamp = lamp
            self.thread = thread
        }
    }

    /// What the root's lamp, walk and search say of the timeline in front.
    ///
    /// **The stream's own lamp, whatever is in front of it.** Inside a conversation the lamp is
    /// on one of its posts and under a search it is on a result, and neither is where the
    /// timeline was left: that is the row the walk was taken from, or the post the search parked
    /// — what leaving either gives back.
    ///
    /// **The conversation in front, or the one a page was read out of.** A person's page and a
    /// tag's are not places reading stops at, so with one of them in front no conversation is
    /// named.
    static func standing(lamp: String?, walk: ShellWalk, searching: Bool, parked: String?) -> Standing {
        var standing = Standing(lamp: lamp)
        if searching {
            standing.lamp = parked
        } else if !walk.isEmpty {
            standing.lamp = walk.streamLamp
        }
        if case .thread(let id) = walk.beneath { standing.thread = id }
        return standing
    }

    /// The root view's half of this place.
    var standing: Standing { Standing(lamp: lamp, thread: thread) }
}

extension ReadingPlace {
    /// The timeline this place comes back to among the tabs there are today, or nothing where
    /// there are none — nothing joined, which is no place to come back to (#273). One that has
    /// since been deleted, or a Trends no source offers any more, is All.
    func timeline(among queries: [TimelineQuery]) -> TimelineQuery? {
        guard !queries.isEmpty else { return nil }
        return queries.contains(timeline) ? timeline : .all
    }

    /// What to land on, given this place as it was kept and what this device holds today (#273).
    ///
    /// **Each part is asked on its own, and one that fails takes no other with it.** The timeline
    /// is `timeline(among:)`. The lamp and the top row are each kept only where that timeline's
    /// list — `rows`, asked of the timeline landed on and of no other — still holds them: what is
    /// kept can name a post let go since, and a row of a timeline deleted since. The conversation
    /// is kept where `holds` still has its post, in any list or held aside.
    ///
    /// What comes of the answer is `TimelinePane.landing`'s: the lamp, else the top row, else the
    /// top of the timeline. Nothing here is written, and nothing held is touched to ask it.
    func landing(
        among queries: [TimelineQuery],
        rows: (TimelineQuery) -> [String],
        holds: (String) -> Bool
    ) -> ReadingPlace? {
        guard let timeline = timeline(among: queries) else { return nil }
        let list = Set(rows(timeline))
        return ReadingPlace(
            timeline: timeline,
            lamp: lamp.flatMap { list.contains($0) ? $0 : nil },
            top: top.flatMap { list.contains($0) ? $0 : nil },
            thread: thread.flatMap { holds($0) ? $0 : nil }
        )
    }
}

/// What the session has in front, as the root view answers its moving (#273): the timeline, and
/// how many times a kept place was landed on.
///
/// **One value and one handler, because the two are answered in an order.** A read back lands on
/// a place while another timeline is in front, so both move at once: the switch ends the walk
/// that stood on the list replaced, and only then is the landing's own conversation opened —
/// answered the other way round, the switch would end the conversation just come back to. Two
/// handlers of one pass run in no order anybody wrote down; `answers(after:)` is the order, and
/// a test asks it.
struct ShellFront: Equatable, Sendable {
    var timeline: TimelineQuery?
    var landings: Int

    enum Answer: Equatable, Sendable {
        /// Another timeline is in front: `FediqoRootView.timelineSwitched`.
        case switched(from: TimelineQuery?, to: TimelineQuery?)
        /// A kept place was landed on: the root stands on its half of it.
        case landed
    }

    /// What the root does about having moved here from `left`, in the order it does it.
    func answers(after left: ShellFront) -> [Answer] {
        var answers: [Answer] = []
        if timeline != left.timeline { answers.append(.switched(from: left.timeline, to: timeline)) }
        if landings != left.landings { answers.append(.landed) }
        return answers
    }
}

/// The place reading stopped at, kept on this device (#273).
///
/// **In the preferences, not the store**, beside the timelines the reader wrote:
/// every `fediqo.*` default already goes out with what is taken away and comes back with what is
/// read back, and the index gains no table.
///
/// **The shape is versioned** — this build writes `{"version":1,"timeline":…}` with `lamp`, `top`
/// and `thread` where the place names them. **Any later shape change bumps `version`.** The load
/// **fails closed**, as `WrittenTimelineStore`'s does: another version, a field this build does
/// not know, a value of another type or one larger than any place this build writes (`maxBytes`)
/// is no place, and is never written over — not by a move, not by a source removed, not as
/// nothing comes to be joined. A timeline id this build does not know is the one thing read past,
/// as All — the same answer `TimelineQuery` gives everywhere else.
///
/// **One exception, and it is not this type's to decide**: a place a read back brought that this
/// build cannot read is taken away (`discardUnreadable()`, asked by `ShellSession.adoptReadBack`
/// alone). What stays unread on a device is what a newer build of the app wrote there, and is
/// that build's to come back to; what arrives in a package was never this device's, and kept it
/// would switch coming back off here for good.
struct ReadingPlaceStore {
    static let version = 1

    /// More than a place can be: a timeline's id and three row ids, a few hundred bytes. What
    /// is larger is not read at all, so nothing that came from outside is parsed at any length.
    static let maxBytes = 4096

    let defaults: UserDefaults
    var key = "fediqo.place"

    /// The place kept, or nothing where none is kept or what is kept cannot be read.
    func load() -> ReadingPlace? {
        switch kept() {
        case .place(let place): place
        case .nothing, .unreadable: nil
        }
    }

    /// Written only where it differs from what is kept: the pane reports a new top
    /// row on every row that passes, and most of what it reports is the place already here.
    /// Refused while what is kept cannot be read: it is never written over, whoever asks — and
    /// the answer is false then, so whoever asked need not ask again for every row that passes.
    @discardableResult
    func save(_ place: ReadingPlace) -> Bool {
        switch kept() {
        case .unreadable: return false
        case .place(let held): guard held != place else { return true }
        case .nothing: break
        }
        write(place)
        return true
    }

    /// Nothing is kept from here: nothing is joined, and there is no place to come back to.
    /// What cannot be read is left as it is.
    func remove() {
        if case .unreadable = kept() { return }
        defaults.removeObject(forKey: key)
    }

    /// The posts of a source the person removed are no longer named (#221): the lamp, the top
    /// row and the conversation each go where the row is that host's, and the rest of the place
    /// stays. Written only where one of them went; what cannot be read is left as it is.
    func forget(host: String) {
        guard case .place(var place) = kept() else { return }
        let host = host.lowercased()
        func names(_ row: String?) -> Bool {
            row.flatMap(NoteKey.init(rowID:))?.host.lowercased() == host
        }
        guard names(place.lamp) || names(place.top) || names(place.thread) else { return }
        if names(place.lamp) { place.lamp = nil }
        if names(place.top) { place.top = nil }
        if names(place.thread) { place.thread = nil }
        write(place)
    }

    /// What is kept and cannot be read is taken away — the one exception to never writing over
    /// it, and only for what a read back brought. A place that can be read, and none, are left.
    func discardUnreadable() {
        guard case .unreadable = kept() else { return }
        defaults.removeObject(forKey: key)
    }

    /// A place too large to be read back is not written: it would be kept and never read again.
    private func write(_ place: ReadingPlace) {
        let row = Row(
            version: Self.version,
            timeline: place.timeline.id,
            lamp: place.lamp,
            top: place.top,
            thread: place.thread
        )
        guard let data = try? JSONEncoder().encode(row), data.count <= Self.maxBytes else { return }
        defaults.set(data, forKey: key)
    }

    private enum Kept {
        case nothing
        case place(ReadingPlace)
        case unreadable
    }

    /// Nothing kept only where nothing is under the key: a value of another type there is
    /// something this build cannot read, not an absence.
    private func kept() -> Kept {
        guard let value = defaults.object(forKey: key) else { return .nothing }
        guard let data = value as? Data,
              data.count <= Self.maxBytes,
              Self.knowsEveryField(data),
              let row = try? JSONDecoder().decode(Row.self, from: data),
              row.version == Self.version
        else { return .unreadable }
        let place = ReadingPlace(
            timeline: TimelineQuery(id: row.timeline),
            lamp: row.lamp,
            top: row.top,
            thread: row.thread
        )
        return .place(place)
    }

    /// Whether the object holds only the fields this version writes. A field added by a later
    /// shape that forgot to bump `version` is still not read past.
    private static func knowsEveryField(_ data: Data) -> Bool {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return Set(top.keys).isSubset(of: ["version", "timeline", "lamp", "top", "thread"])
    }
}

/// Tells the session where the root view's half of the place stands, each time it moves (#273):
/// the lamp and the walk are the root's own state, and the session is what writes the place.
///
/// **Read a tick after it moved, as it then is, and not as this pass saw it.** A timeline switched
/// is answered on the same pass by the pane, which lights the arrived-at timeline's own post, and
/// by the root, which ends the walk; the lamp this pass was drawn with is still the one left.
/// **Only while the pane is drawn.** With the timeline place not in front nobody relights the
/// lamp for the timeline arrived at — one removed from Preferences, say — and what is told is the
/// lamp as it was left. Whether a lamp belongs to the list it is read back into is the landing's
/// to say.
///
/// **Told where the timeline changes, though the lamp may read the same**: the session forgets
/// the lamp of the timeline it left as it leaves, and a post two timelines both hold may be what
/// each was left on.
///
/// A modifier of its own, so the root view's chain gains one line and no closure.
struct KeepsReadingPlace: ViewModifier {
    let session: ShellSession
    /// What the root stands on as this pass was drawn: what says that it moved.
    let standing: ReadingPlace.Standing
    /// What the root stands on, read when it is asked.
    let now: @MainActor () -> ReadingPlace.Standing

    private struct Moved: Equatable {
        let timeline: TimelineQuery?
        let standing: ReadingPlace.Standing
    }

    func body(content: Content) -> some View {
        content.onChange(of: Moved(timeline: session.timelineID, standing: standing)) { _, _ in
            Task { @MainActor in session.stands(now()) }
        }
    }
}

private struct Row: Codable {
    var version: Int
    var timeline: String
    var lamp: String?
    var top: String?
    var thread: String?
}
