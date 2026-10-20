import Foundation

// A Mastodon poll as its source hands it over (#331): inside a status, and alone — the answer
// to a vote. Read the one way in both places, so a vote's answer and a read of the post say
// the same of one poll.

/// Mastodon's `Poll`, in the fields a row draws and a vote is sent by.
///
/// **Lenient to the field**: a figure, a moment or a list of a shape this build cannot read is
/// none of that, and never costs the reader the poll — nor the status it is on, which reads it
/// leniently as a whole (`StatusDTO.poll`). A poll with no id, or no choices, is no poll: there
/// would be nothing to show and nowhere to send a vote.
struct PollDTO: Decodable, Sendable {
    let id: String?
    let expiresAt: StatusDTO.LenientMoment?
    let expired: StatusDTO.Lenient<Bool>?
    let multiple: StatusDTO.Lenient<Bool>?
    let votesCount: StatusDTO.Lenient<Int>?
    let votersCount: StatusDTO.Lenient<Int>?
    /// Absent on a read made signed out, as `StatusDTO.reblogged` is.
    let voted: StatusDTO.Lenient<Bool>?
    let ownVotes: StatusDTO.Lenient<[Int]>?
    let options: [Option]?

    struct Option: Decodable, Sendable {
        let title: String?
        /// `null` where the source keeps the figure back until the poll ends.
        let votesCount: StatusDTO.Lenient<Int>?
    }

    /// The poll this says, or nothing where it names none.
    var poll: Poll? {
        guard let id, !id.isEmpty, let options, !options.isEmpty else { return nil }
        return Poll(
            id: id,
            choices: options.map { Poll.Choice(title: $0.title ?? "", votes: $0.votesCount?.value) },
            multiple: multiple?.value ?? false,
            endsAt: expiresAt?.value,
            expired: expired?.value ?? false,
            votes: votesCount?.value,
            voters: votersCount?.value,
            voted: voted?.value,
            ownVotes: ownVotes?.value ?? []
        )
    }
}
