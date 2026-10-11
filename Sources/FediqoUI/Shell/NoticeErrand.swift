import FediqoCore
import Foundation

// A notice opens by walking in the timeline place, and leaving that walk comes back to the line
// pressed: `PlaceErrand`, from `.notices`. What is here is the post it opens being held first.

extension ShellSession {
    /// The post a notice is about, held as a thread's posts are held — through the store, saved,
    /// and what is drawn renewed from it — and the row it now is. **Held on opening and not
    /// before**: a favourite of an old post does not put that post in a timeline unasked.
    ///
    /// Nothing where the store would not take it: a post older than the person keeps, which a
    /// conversation cannot open from. The page says so on the line.
    func landed(noticePost note: Note) async -> String? {
        let row = note.key.rowID
        if heldNote(row) == nil {
            await store.ingest([note], ifSourceHere: note.source.host)
            saveSoon()
            await reloadFromStore()
        }
        return heldNote(row) == nil ? nil : row
    }
}
