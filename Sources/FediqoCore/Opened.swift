import Foundation

/// What belongs with one opened item, read off references among what is held (#293).
///
/// **A reference is read when an item is opened, and here is where.** Above the item is what it
/// refers to: the post it answers, and what that answers, as far up as held items go. Below is
/// what refers to it: every held item that answers it, and what answers those; the held items
/// that quote it; the held reblogs of it. Nothing is asked of anybody to build this — a read of
/// the thread is one way items come to be held, and what it brought shows because it is held
/// and refers, as an answer a search brought does.
///
/// **Within the item's own source, always.** A reference names its target by `Note.id` or by the
/// source's own id for it; either is looked up among what that one source handed over, and
/// neither is ever an address.
public struct Opened: Equatable, Sendable {
    /// What the item answers, the start of the chain first. Each answers the one before it.
    public var above: [Note] = []
    /// Every held item that answers it, or answers one that does: an answer directly after what
    /// it answers and before that one's next answer, the older answer first under each post.
    public var below: [Note] = []
    /// The posts of `below` that stand at the first step with nothing held between them and the
    /// item: what a read of the thread said belongs to it, answering a post that is not here —
    /// one the reader may not see, or one since deleted. **Known for the run that read the
    /// thread, and no longer**: which posts a source handed over as one thread is not a
    /// reference and is not kept, so after a relaunch with the network off such an answer has
    /// no place here until the thread is read again. It stands in All either way.
    public var loose: Set<NoteKey> = []
    /// The held items that quote it and do not also answer in its thread, the older first.
    public var quoting: [Note] = []
    /// The held reblogs of it, the newest first. **In no thread**: a reblog answers nothing.
    public var reblogs: [Note] = []

    /// The post each row here quotes, where it is held — by the quoting row's key. What a row's
    /// quote is drawn from (#293): the quoting post keeps only its reference.
    public var quoted: [NoteKey: Note] = [:]

    public init() {}

    /// Whether nothing held belongs with the item.
    public var isAlone: Bool { above.isEmpty && below.isEmpty && quoting.isEmpty && reblogs.isEmpty }

    /// Every post drawn as a row of its own around the item.
    public var rows: [Note] { above + below + quoting }

    /// What belongs with `root` among `held`. Nothing around a reblog, which is in no thread:
    /// opening one opens the post it reblogs.
    ///
    /// Each post once, so a loop in a stranger's references ends.
    ///
    /// `said` is what a read of the thread around `root` handed over as its answers, this run
    /// (`loose`). Each of those no reference places under `root` stands after the answers that
    /// are placed, under the highest held post it answers up to, the older first.
    public static func around(_ root: Note, among held: [Note], said: Set<NoteKey> = []) -> Opened {
        guard !root.isReblog else { return Opened() }
        let host = root.source.host
        var byKey: [NoteKey: Note] = [:]
        var byStatus: [String: Note] = [:]
        for note in held where note.source.host == host && !note.isReblog {
            byKey[note.key] = note
            if let id = note.statusID, byStatus[id] == nil { byStatus[id] = note }
        }
        // The item itself, as the caller holds it: a reference to it resolves to it.
        byKey[root.key] = root
        if let id = root.statusID { byStatus[id] = root }
        func target(of reference: Reference) -> Note? {
            if let id = reference.id, let named = byKey[NoteKey(host: host, id: id)] { return named }
            return reference.statusID.flatMap { byStatus[$0] }
        }
        func answered(by note: Note) -> Note? {
            note.refs.first { $0.kind == .answers }.flatMap(target)
        }

        var opened = Opened()
        var seen: Set<NoteKey> = [root.key]
        var up = answered(by: root)
        while let parent = up, seen.insert(parent.key).inserted {
            opened.above.insert(parent, at: 0)
            up = answered(by: parent)
        }

        var answers: [NoteKey: [Note]] = [:]
        var quotes: [Note] = []
        for note in held where note.source.host == host && note.key != root.key {
            if note.isReblog {
                let reblogs = note.refs.first { $0.kind == .reblogs }
                if reblogs.flatMap(target)?.key == root.key { opened.reblogs.append(note) }
                continue
            }
            if let parent = answered(by: note) { answers[parent.key, default: []].append(note) }
            if note.refs.contains(where: { $0.kind == .quotes && target(of: $0)?.key == root.key }) {
                quotes.append(note)
            }
        }
        var stack = oldestFirst(answers[root.key] ?? []).reversed().map { $0 }
        while let next = stack.popLast() {
            guard seen.insert(next.key).inserted else { continue }
            opened.below.append(next)
            stack += oldestFirst(answers[next.key] ?? []).reversed()
        }
        for note in oldestFirst(held.filter { said.contains($0.key) && !$0.isReblog && $0.source.host == host }) {
            guard !seen.contains(note.key) else { continue }
            var top = note
            var climbed: Set<NoteKey> = [note.key]
            while let parent = answered(by: top), !seen.contains(parent.key), climbed.insert(parent.key).inserted {
                top = parent
            }
            opened.loose.insert(top.key)
            var stack = [top]
            while let next = stack.popLast() {
                guard seen.insert(next.key).inserted else { continue }
                opened.below.append(next)
                stack += oldestFirst(answers[next.key] ?? []).reversed()
            }
        }
        opened.quoting = oldestFirst(quotes.filter { !seen.contains($0.key) })
        opened.reblogs.sort { ($0.postedAt, $0.id) > ($1.postedAt, $1.id) }
        for row in opened.rows + [root] {
            if let key = row.quotedKey, let post = byKey[key], post.key != row.key { opened.quoted[row.key] = post }
        }
        return opened
    }

    /// By when each was posted; and two posted in the same second, by the id their source gave
    /// them — the shorter first and then by spelling, which is the order of the numbers a source
    /// counts its posts with, and an order all the same where the ids are no numbers.
    private static func oldestFirst(_ notes: [Note]) -> [Note] {
        func place(_ note: Note) -> (Date, Int, String, String) {
            (note.postedAt, note.statusID?.utf8.count ?? 0, note.statusID ?? "", note.id)
        }
        return notes.sorted { place($0) < place($1) }
    }
}
