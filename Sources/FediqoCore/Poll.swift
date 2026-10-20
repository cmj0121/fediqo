import Foundation

// A post's poll (#331): what its source says of it — its choices, how each stands where the
// source says, when it ends, and what the reader chose.

/// A poll on a post, as its source last said it.
///
/// **Two kinds of fact, as a post has.** What the poll is and how it stands — its choices, the
/// figures beside them, when it ends — is the source's word about the post, and later copies
/// win as counts do. Whether the reader voted, and for what, is the source's word about its
/// signed-in reader (`ReaderMark.voted`): a read made signed out says nothing of it, and a read
/// sent before the reader's own vote landed says nothing newer than that vote.
///
/// **Bounded wherever one is made**, as everything a stranger's server hands over is: no more
/// than `mostChoices` choices, each a line of no more than `choiceLength`, figures that are not
/// negative, and the reader's own choices only those that name a choice.
public struct Poll: Hashable, Sendable {
    /// The most choices a poll is held with. Mastodon takes four by default and lets an admin
    /// raise it; a source handing over hundreds is not one whose rows should grow without end.
    public static let mostChoices = 32
    /// How long one choice may run on a line of ours.
    public static let choiceLength = 200

    /// One choice and how it stands.
    public struct Choice: Hashable, Sendable {
        public let title: String
        /// How many voted for it, where the source says — nothing where it keeps the figures
        /// back until the poll ends, which is not none.
        public let votes: Int?

        public init(title: String, votes: Int?) {
            self.title = title
            self.votes = votes
        }
    }

    /// The poll's own id at its source: what a vote and a read of it are sent to.
    public let id: String
    public let choices: [Choice]
    /// Whether the reader may choose more than one.
    public let multiple: Bool
    /// When it ends, where it ends at all.
    public let endsAt: Date?
    /// Whether the source said it has ended.
    public let expired: Bool
    /// How many votes there are, every choice together, where the source says.
    public let votes: Int?
    /// How many people voted, where the source says: on a poll of several choices, what a
    /// choice's share is of.
    public let voters: Int?
    /// Whether the reader voted, where the source says — nothing on a read made signed out.
    public private(set) var voted: Bool?
    /// Which choices the reader voted for, by their place, where the source says.
    public private(set) var ownVotes: [Int]

    public init(
        id: String, choices: [Choice], multiple: Bool = false, endsAt: Date? = nil, expired: Bool = false,
        votes: Int? = nil, voters: Int? = nil, voted: Bool? = nil, ownVotes: [Int] = []
    ) {
        self.id = id
        let held = Array(choices.prefix(Self.mostChoices)).map {
            Choice(title: LineText.oneLine($0.title, limit: Self.choiceLength), votes: $0.votes.flatMap { $0 >= 0 ? $0 : nil })
        }
        self.choices = held
        self.multiple = multiple
        self.endsAt = endsAt
        self.expired = expired
        self.votes = votes.flatMap { $0 >= 0 ? $0 : nil }
        self.voters = voters.flatMap { $0 >= 0 ? $0 : nil }
        self.voted = voted
        self.ownVotes = Self.named(ownVotes, among: held.count)
    }

    /// The reader's choices, each once, in order, and only one that names a choice of `count`.
    private static func named(_ ownVotes: [Int], among count: Int) -> [Int] {
        var seen: Set<Int> = []
        return ownVotes.filter { (0..<count).contains($0) && seen.insert($0).inserted }.sorted()
    }

    /// Whether it has ended by `now`: its source said so, or the moment it ends has passed.
    public func ended(at now: Date = Date()) -> Bool {
        expired || (endsAt.map { $0 <= now } ?? false)
    }

    /// Whether its source keeps any choice's figure back — counts hidden until the end.
    public var countsHidden: Bool {
        choices.contains { $0.votes == nil }
    }

    /// The share of the votes choice `index` has, from nothing to one, where the source says
    /// how it stands. **Of the people who voted**, on a poll of several choices, where the
    /// source says how many: there every voter may pick each choice, and the shares do not add
    /// to one. Nothing where the figure is kept back, and nothing for a poll nobody voted in.
    public func share(of index: Int) -> Double? {
        guard choices.indices.contains(index), let mine = choices[index].votes else { return nil }
        let whole = multiple ? (voters ?? votes) : (votes ?? choices.compactMap(\.votes).reduce(0, +))
        guard let whole, whole > 0 else { return nil }
        return min(1, Double(mine) / Double(whole))
    }

    /// Whether the reader voted for choice `index`, as its source says.
    public func chose(_ index: Int) -> Bool {
        ownVotes.contains(index)
    }

    /// Whether `other` is this same poll asking the same: one id, the same choices in the same
    /// order. A poll whose author changed its choices is another question, whose votes its
    /// source started again.
    func asksTheSame(as other: Poll) -> Bool {
        id == other.id && choices.map(\.title) == other.choices.map(\.title)
    }

    /// This poll as it stands, with `voted` and `ownVotes` as what is said of the reader —
    /// nothing and none, for a poll that says nothing of them. Its choices are as they were
    /// held: they were made fit for a line once, when the poll was made.
    public func with(voted: Bool?, ownVotes: [Int] = []) -> Poll {
        var poll = self
        poll.voted = voted
        poll.ownVotes = Self.named(ownVotes, among: choices.count)
        return poll
    }

    /// The poll a row holds once `later` — a copy read after `held` — has landed over it.
    ///
    /// **How it stands is the later copy's**, as counts are, and nothing where the later copy
    /// carries no poll: a read of the post itself is the whole of what its source says of it,
    /// and a post whose poll was taken off by an edit has none. **What it says of the reader is
    /// the later copy's only where `reader`** — the copy was not sent before the reader's own
    /// vote landed (#291) — and where it says anything: a read made signed out leaves what was
    /// held. Where it is not taken, neither are the figures, so a read on its way when the
    /// reader voted does not draw the poll without their vote. A poll whose choices changed is
    /// another question and is the later copy's whole.
    static func later(_ later: Poll?, over held: Poll?, reader: Bool) -> Poll? {
        guard let later else { return nil }
        guard let held, later.asksTheSame(as: held) else { return later }
        guard reader else {
            // The figures the reader's own vote came back with stand over a copy sent before it.
            let figures = held.voted == true && later.voted != true ? held : later
            return Poll(
                id: later.id, choices: figures.choices, multiple: later.multiple, endsAt: later.endsAt,
                expired: later.expired || held.expired, votes: figures.votes, voters: figures.voters,
                voted: held.voted, ownVotes: held.ownVotes
            )
        }
        return later.voted == nil ? later.with(voted: held.voted, ownVotes: held.ownVotes) : later
    }
}

/// Why a vote is not sent: refused here, before anything was asked of the source.
public enum PollRefusal: Equatable, Sendable {
    /// The poll has ended.
    case ended
    /// The reader voted in it already.
    case voted
    /// What was chosen is not a vote this poll takes: nothing, more than one where it takes
    /// one, or a choice it does not have.
    case choices
}

extension Poll {
    /// Why a vote for `choices` would be refused here, or nothing where it may be sent.
    public func refusal(of choices: [Int], at now: Date = Date()) -> PollRefusal? {
        if ended(at: now) { return .ended }
        if voted == true { return .voted }
        let picked = Set(choices)
        guard !picked.isEmpty, picked.count == choices.count, picked.allSatisfy(self.choices.indices.contains),
              multiple || picked.count == 1
        else { return .choices }
        return nil
    }
}
