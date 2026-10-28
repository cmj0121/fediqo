import SwiftUI

/// What a timeline's head says of a list that used to explain itself at its foot (#402).
///
/// A timeline that reads bookmarks or favourites explains its order through a (?) — the order is
/// not news. A Trends source that has nothing more is a line of the status mark: that is true
/// only until the next reload, and what it describes is missing from the list.
@MainActor
enum TimelineStatus {
    /// The (?) on a timeline that reads the reader's marks, or nothing where it does not.
    static func marksKey(readsMarks: Bool) -> String? {
        readsMarks ? "timeline.marks.order" : nil
    }

    /// One line a Trends source that has no more of what is rising to give. Counted, because
    /// those posts are missing until a reload reads from the top, and Again is that reload.
    static func ended(
        _ hosts: [String], reload: @escaping () -> Void, language: DummyLanguage? = nil
    ) -> [StatusLine] {
        hosts.compactMap { host in
            guard let words = ShellReload.trendsEndLine([host], language: language) else { return nil }
            return StatusLine(
                id: "trends:" + host, host: host, words: words, standsOut: true,
                press: .readAgain(host, language: language, act: reload)
            )
        }
    }
}
