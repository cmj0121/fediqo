import FediqoCore
import Foundation

/// Whoever wrote a post, as something the shell can open — **a person, and not a source**.
///
/// ## Why this exists at all
///
/// The face and the name are on every row and pressing them did nothing, so the author was a fact
/// a reader could read and not somebody they could open (#99). Opening them needs a value: a row
/// is one post, and a person is whoever wrote it, which is a different thing with a different
/// identity and a different list under it.
///
/// ## What a person is identified by
///
/// **The host and the handle, and the host is not optional.** One handle on two servers is two
/// people as far as this device is concerned — the same rule `DummyItem.id` keeps one level down,
/// where a note two hosts carry is two rows (#10). A person built without the host would gather
/// somebody else's posts under this one's face the moment two instances share a name.
///
/// **The name is the fallback, and it is a forum's ordinary case.** A Discuz! thread row carries
/// an author and no handle at all, so a person there is a name on a host. That is weaker than a
/// handle and it is what the forum gives; nothing is invented to make it look stronger.
///
/// ## What it is not
///
/// **Not a source.** A source is a server the reader joined, with a sign-in, boards and a Clear
/// button; none of that is a fact about a person, and a person page that grew them would be the
/// source page wearing a face. **Not a protocol's own profile page replayed**, which #99 rules out
/// in as many words. **And nothing is fetched for it** — what this device already holds of theirs
/// is what there is, which is 0.4.0's line and 0.5.0's boundary.
public struct DummyPerson: Identifiable, Hashable, Sendable {
    /// The server this person was read through — never their own instance, for the reason
    /// `DummyItemRow.avatar` gives about an address. It is where this device met them.
    public let host: String
    /// What they call themselves, as they wrote it, pictures and all.
    public let name: String
    /// How to find them again, where the shape has such an idea. A forum has none.
    public let handle: String?
    /// Their picture, where the post carried an address for one.
    public let avatarURL: URL?
    /// The pictures their name is partly written in, as the post that named them carried them.
    /// Carried rather than looked up, for `DummyItem.emojis`' reason: the post's own list is the
    /// one that draws their name the way they wrote it.
    public let emojis: [CustomEmoji]

    /// **The handle where there is one, the name where there is not, and the host always.**
    ///
    /// Joined on the record separator, which is `NoteKey.rowID`'s own choice one layer down and
    /// for the same reason: neither a hostname nor anything a server sends can contain it, so two
    /// people cannot be folded into one by a name that happens to read like an id.
    public var id: String { "\(host)\u{1e}\(handle ?? name)" }

    /// Whoever wrote this row, or nothing where the row names nobody.
    ///
    /// **Nothing rather than an empty person**, which is what makes "a row with no author offers
    /// no press" a fact rather than a habit: there is no value to open, so no call site can be
    /// written that opens one.
    public init?(_ item: DummyItem) {
        let handle = (item.handle?.isEmpty == true) ? nil : item.handle
        guard !item.author.isEmpty || handle != nil else { return nil }
        host = item.source.host
        name = item.author
        self.handle = handle
        avatarURL = item.avatarURL
        emojis = item.emojis
    }

    /// Whether this person wrote that note.
    ///
    /// **The host first, and then the strongest name the note carries.** A handle is compared to a
    /// handle and a bare name to a bare name; a person known by a handle never matches a note that
    /// carries only a name, because "somebody called this" is not "somebody". Gathering on the
    /// weaker key would put a stranger's posts on this person's page, which is the one failure a
    /// page like this must not have.
    public func wrote(_ note: Note) -> Bool {
        guard note.source.host == host else { return false }
        let theirs = note.handle.isEmpty ? nil : note.handle
        if let handle { return theirs == handle }
        return theirs == nil && note.author == name
    }

    /// What this device already holds of theirs, newest first.
    ///
    /// **Filtered as notes and mapped afterwards.** The store is the whole of what this device
    /// holds — ten thousand notes is a size this app measures itself against — and building a row
    /// for every one of them to throw nearly all of them away would be that work on every pass of
    /// the pane's body. The comparison is three string reads; the row is an id, a source and a
    /// list of attachments.
    ///
    /// **Newest first, and no rule applied.** A timeline's order is whatever its rules say; this
    /// is not a timeline, it is everything of theirs that is here, and the reader's question of a
    /// person's page is what they said last.
    public static func held(of person: DummyPerson, in notes: [Note]) -> [DummyItem] {
        notes.filter(person.wrote)
            .sorted { $0.postedAt > $1.postedAt }
            .map(DummyItem.init)
    }
}
