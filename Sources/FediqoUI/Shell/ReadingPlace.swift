import Foundation

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

/// The place reading stopped at, kept on this device (#273).
///
/// **In the preferences, not the store**, beside the timelines the reader wrote:
/// every `fediqo.*` default already goes out with what is taken away and comes back with what is
/// read back, and the index gains no table.
///
/// **The shape is versioned** — this build writes `{"version":1,"timeline":…}` with `lamp`, `top`
/// and `thread` where the place names them. **Any later shape change bumps `version`.** The load
/// **fails closed**, as `WrittenTimelineStore`'s does: another version, a field this build does
/// not know or a value of another type is no place, and is never written over. A timeline id this
/// build does not know is the one thing read past, as All — the same answer `TimelineQuery` gives
/// everywhere else.
struct ReadingPlaceStore {
    static let version = 1

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
    /// Refused while what is kept cannot be read: it is never written over, whoever asks.
    func save(_ place: ReadingPlace) {
        switch kept() {
        case .unreadable: return
        case .place(let held): guard held != place else { return }
        case .nothing: break
        }
        let row = Row(
            version: Self.version,
            timeline: place.timeline.id,
            lamp: place.lamp,
            top: place.top,
            thread: place.thread
        )
        guard let data = try? JSONEncoder().encode(row) else { return }
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

private struct Row: Codable {
    var version: Int
    var timeline: String
    var lamp: String?
    var top: String?
    var thread: String?
}
