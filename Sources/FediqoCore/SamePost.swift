import Foundation

// What counts as the same post (#113).
//
// **Sameness is a fact the sources stated, never a likeness this app judged.** There is no
// threshold here, no score and no figure anybody could move: #1 refuses algorithms, and an
// answer that is nearly right merges two people's words, which is worse than never merging at
// all. Nothing below reads a word of anybody's post.
//
// **The fact used is the name the post was given where it was written.** A Mastodon-shaped
// server sends `uri` with every status — the address that post was minted at, on the server its
// author wrote it on. A second instance that federates the post copies that address over
// verbatim, because it is not that instance's to mint. So two servers handing this device one
// status hand over one name for it, and they are the ones who said so. `Note.id` has carried it
// since 0.1.0 and #10 keyed a row by the host *beside* it, which is why one post is two rows
// today; this names the other half of that key.
//
// **What a boost carries is the post, not the boost.** `StatusDTO.asNote` already reads a boost
// through its `reblog`, so the name on a boost's copy is the name of the status it carries. Two
// people boosting one thing is one post arriving twice, and that falls out of the name rather
// than being answered a second time here.
//
// **Two posts that merely read alike are two posts.** Two people who wrote the same sentence
// were given two names by their servers, and one person who wrote it twice was given two names
// as well. Nothing here could tell those cases apart by the words, and nothing here tries.
//
// **A forum names its own and nothing else.** A Discourse topic and a Discuz! thread are held
// under an id this device qualifies with the host it was read from, because a forum makes no
// statement about any other server's post — so a forum's copies only ever gather with copies
// from that same forum, which is to say with themselves.

/// The post a note is a copy of, as the source that handed the copy over named it.
///
/// **Carried, never parsed.** What is inside is a name a server minted, and this app neither
/// folds it, trims it nor decides that two spellings of it mean one post. Any of those would be
/// this app judging a likeness at the one place that must hold only a fact. Two copies are one
/// post when the two names their sources stated are the same name, character for character.
public struct PostIdentity: Hashable, Sendable {
    /// What the source stated, exactly as it stated it.
    public let stated: String

    /// Made only from a note, by `Note.post`. There is no post this app can name that a source
    /// did not name first, so there is no way in from outside.
    init(stated: String) {
        self.stated = stated
    }
}

extension Note {
    /// Which post this copy is of, or nothing where its source named no post at all.
    ///
    /// **Nothing means merged with nothing**, and never "merged on something weaker". A copy
    /// whose source stated no name for the post is a copy this device cannot show to be anybody
    /// else's post, so it stands on its own — which is what this app already did before #113 and
    /// is the safe answer of the two.
    public var post: PostIdentity? {
        if let statusID, Self.inventedID(host: source.host, statusID: statusID) == id { return nil }
        return PostIdentity(stated: id)
    }
}

extension Note {
    /// The id a Mastodon copy is held under where its server sent no `uri` for the post: a name
    /// **this device** made up, out of the host that handed the copy over and the id that host
    /// gave it.
    ///
    /// **Minted here and recognised here, in the one function**, which is the rule `NoteKey`
    /// states about folding said about names instead: a second spelling of this shape, written
    /// where the answer is read, would be a second rule that only agrees with the first today.
    ///
    /// It has always carried the reading host, so a made-up name has never matched another
    /// source's copy and this was never a bug that could be seen. It is answered anyway, because
    /// "nothing is merged that cannot be shown to be the same post" has to be true of what the
    /// code says and not only of what its strings happen to look like.
    static func inventedID(host: String, statusID: String) -> String {
        "https://\(host)/statuses/\(statusID)"
    }
}

/// Which of the copies this device holds are copies of one post (#113).
public enum SamePost {
    /// The copies gathered into the posts they are copies of.
    ///
    /// Each group holds the copies of one post in the order they were handed in, and the groups
    /// come in the order of their first copy — so a caller that hands in store order gets store
    /// order back, and nothing here re-orders anything. A copy whose source named no post is a
    /// group of one.
    ///
    /// **The grouping does not depend on the order it was handed.** Which copies are together is
    /// decided one copy at a time, by the name its own source gave it, so shuffling the list
    /// moves the groups about without moving a copy between them — and a third copy arriving
    /// joins the group its name puts it in without disturbing the two already there.
    public static func gathered(_ notes: [Note]) -> [[Note]] {
        var groups: [[Note]] = []
        var byPost: [PostIdentity: Int] = [:]
        for note in notes {
            guard let post = note.post, let at = byPost[post] else {
                note.post.map { byPost[$0] = groups.count }
                groups.append([note])
                continue
            }
            groups[at].append(note)
        }
        return groups
    }
}
