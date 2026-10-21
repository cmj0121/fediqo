import FediqoCore
import Foundation

/// What one post is being written as (#332, X0 §1): its words and everything the composer's
/// controls set on it, **one value a sheet is handed** — the new post the composer holds, and
/// the change of a published post its sheet holds, each its own so neither writes over the
/// other.
///
/// **What it may be, as well as what it is.** The rules a sheet reads — whether it can go, what
/// a file or a poll added to it would be refused for — are functions of the value and of what
/// its source said it takes, so a sheet and a test read the same answer. Where the post goes,
/// whose it is and when it is sent are the sheet's: a change's source is the post's own, and a
/// time to send and a quote are added beside these when their sheets come.
struct PostDraft: Equatable {
    var text = ""
    /// The cover line. Empty is none.
    var cover = ""
    /// The language, folded where it is taken from a source. Empty is none, and is not sent.
    var language = ""
    /// Whether the post covers its media, where that was chosen. Nothing is not a no.
    var coversMedia: Bool?
    /// The files, in order. On a change, the files already on the post are here too, each with
    /// the id its source gave it and no bytes (`kept`).
    var media: [UnsentMedia] = []
    /// The poll it is written with (#331), or nothing. Never beside a file.
    var poll: NewPoll?
    /// Who may read it. Fixed on a change: the source takes none (X0 §1).
    var audience: Audience = .everyone

    /// Whether `piece` was on the post before this draft: it has its source's id and no bytes
    /// of this device's, so nothing is uploaded for it and no byte ceiling is asked of it.
    static func kept(_ piece: UnsentMedia) -> Bool {
        piece.bytes.isEmpty && !(piece.remoteID ?? "").isEmpty
    }

    /// Whether the files are within what the source said it takes. A file already on the post
    /// is held to the count and its description, and to nothing about bytes it never had here.
    func attachmentsOK(_ limits: MastodonMediaLimits) -> Bool {
        guard media.count <= limits.count else { return false }
        for piece in media {
            if piece.description.count > limits.descriptionLimit { return false }
            if Self.kept(piece) { continue }
            if !limits.allows(piece.mime) { return false }
            if let ceiling = limits.byteLimit(for: piece.mime), piece.bytes.count > ceiling { return false }
        }
        return true
    }

    /// Why one more file would be refused, or nothing where it may be added.
    func refusal(adding bytes: Data, type: String, description: String, within limits: MastodonMediaLimits) -> MastodonWriteRefusal? {
        if media.count >= limits.count { return .tooMany(count: limits.count) }
        if !limits.allows(type) { return .kind }
        if let ceiling = limits.byteLimit(for: type), bytes.count > ceiling { return .tooLarge(limit: ceiling) }
        if description.count > limits.descriptionLimit { return .description(limit: limits.descriptionLimit) }
        return nil
    }

    /// Why the poll cannot go as it is, or nothing where it can, or there is none.
    func pollRefusal(within limits: MastodonPollLimits) -> MastodonWriteRefusal? {
        poll?.refusal(within: limits)
    }

    /// A fresh poll for this draft: two empty choices, one to choose, for a day — or the
    /// shortest run the source takes, where a day is not among them. Nothing where it carries
    /// a file: a Mastodon takes no post with both.
    func freshPoll(within limits: MastodonPollLimits) -> NewPoll? {
        guard media.isEmpty else { return nil }
        var poll = NewPoll.fresh
        let runs = limits.offeredRuns
        if !runs.contains(poll.runs) { poll.runs = runs.first ?? poll.runs }
        return poll
    }

    /// One more empty choice, up to as many as the source takes.
    mutating func addChoice(within limits: MastodonPollLimits) {
        guard var poll, poll.choices.count < limits.choices else { return }
        poll.choices.append("")
        self.poll = poll
    }

    /// One choice off the poll, where it has more than the two a poll needs.
    mutating func removeChoice(at index: Int) {
        guard var poll, poll.choices.indices.contains(index), poll.choices.count > MastodonPollLimits.leastChoices else {
            return
        }
        poll.choices.remove(at: index)
        self.poll = poll
    }

    /// Whether it may go: words or files, within `limit`, through a source, with its files and
    /// its poll as the source takes them. A cover alone cannot.
    func canSend(limit: Int, hasSource: Bool, media limits: MastodonMediaLimits, polls: MastodonPollLimits) -> Bool {
        ComposerSheet.canSend(
            text: text, limit: limit, hasSource: hasSource, cover: cover, attachments: media.count,
            attachmentsOK: attachmentsOK(limits),
            pollOK: poll == nil || (media.isEmpty && pollRefusal(within: polls) == nil)
        )
    }
}

/// What a sheet's extras and poll write through, beside the draft itself (#332): what the
/// draft's source said it takes, what each place says, and the presses that ask the session for
/// something — a file, a choice remembered as made. **One value for the composer and the
/// change sheet**, so the two draw the same controls from the same rules.
struct DraftControls {
    var host: String
    var limit: Int
    var media: MastodonMediaLimits
    var polls: MastodonPollLimits
    var mediaNote: String?
    var pollSays: String?
    /// The runs a poll may be given, in the order offered.
    var runs: [Int]
    var addMedia: () -> Void
    var addPoll: () -> Void
    var chooseLanguage: (String) -> Void
    var chooseCoversMedia: (Bool) -> Void

    /// The composer's: the new post's source, and the session's own presses.
    @MainActor
    static func composer(_ session: ShellSession, limit: Int) -> DraftControls {
        let polls = session.composePollLimits
        return DraftControls(
            host: session.composeHost ?? "", limit: limit,
            media: session.composeHost.map { session.mediaLimits(of: $0) } ?? .unstated,
            polls: polls, mediaNote: session.composeMediaNote, pollSays: session.composePollSays,
            runs: polls.offeredRuns,
            addMedia: { session.composeAddMedia() }, addPoll: { session.composeAddPoll() },
            chooseLanguage: { session.chooseLanguage($0) }, chooseCoversMedia: { session.chooseCoversMedia($0) }
        )
    }
}
