import Foundation

// A post's poll (#331): what its source says of it — its choices, how each stands where the
// source says, when it ends, and what the reader chose — and the poll a new post is written
// with, held to what the source says it takes.

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
    /// order, one to choose or several alike. A poll whose author changed either is another
    /// question, whose votes its source started again — under the same id (#332).
    func asksTheSame(as other: Poll) -> Bool {
        id == other.id && multiple == other.multiple && choices.map(\.title) == other.choices.map(\.title)
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
    ///
    /// `revised` is that the later copy is the post as its author changed it since (#332): a
    /// change starts a poll's run again, and opens one that had ended, so its word on whether it
    /// has ended is taken as it is. Otherwise a poll once ended stays so.
    static func later(_ later: Poll?, over held: Poll?, reader: Bool, revised: Bool = false) -> Poll? {
        guard let later else { return nil }
        guard let held, later.asksTheSame(as: held) else { return later }
        guard reader else {
            // The figures the reader's own vote came back with stand over a copy sent before it.
            let figures = held.voted == true && later.voted != true ? held : later
            return Poll(
                id: later.id, choices: figures.choices, multiple: later.multiple, endsAt: later.endsAt,
                expired: revised ? later.expired : later.expired || held.expired, votes: figures.votes,
                voters: figures.voters, voted: held.voted, ownVotes: held.ownVotes
            )
        }
        return later.voted == nil ? later.with(voted: held.voted, ownVotes: held.ownVotes) : later
    }

    /// The poll a row holds once `stale` — a copy its source's own word says was read before the
    /// row was (`Note.isEarlier`, #286) — has landed over `held`, the same poll asking the same.
    ///
    /// **Only its figures are taken**, as a stale copy's counts are, and what it says of the
    /// reader only where `reader` (`later`'s rule). **What the poll is stays the held one's**:
    /// when it ends, whether it has, one or several — a change since may have started its run
    /// again or opened it (#332) — and a figure the held copy keeps back stays kept back, one
    /// the stale copy keeps back stays as held.
    static func stale(_ stale: Poll, over held: Poll, reader: Bool) -> Poll {
        guard stale.asksTheSame(as: held), let taken = later(stale, over: held, reader: reader) else { return held }
        return Poll(
            id: held.id,
            choices: zip(held.choices, taken.choices).map { was, now in
                Choice(title: was.title, votes: was.votes == nil ? nil : now.votes ?? was.votes)
            },
            multiple: held.multiple, endsAt: held.endsAt, expired: held.expired,
            votes: taken.votes ?? held.votes, voters: taken.voters ?? held.voters,
            voted: taken.voted, ownVotes: taken.ownVotes
        )
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

/// A poll a new post is written with (#331): its choices, whether the reader may choose more
/// than one, how long it runs, and whether the figures stay hidden until it ends.
public struct NewPoll: Hashable, Sendable, Codable {
    /// The choices as typed. Only those with something in them are sent (`said`).
    public var choices: [String]
    public var multiple: Bool
    /// How long it runs, in seconds.
    public var runs: Int
    public var hidesTotals: Bool

    /// What a new poll starts as: two empty choices, one to choose, a day, figures shown.
    public static let fresh = NewPoll(choices: ["", ""], multiple: false, runs: 86_400, hidesTotals: false)

    public init(choices: [String], multiple: Bool = false, runs: Int = 86_400, hidesTotals: Bool = false) {
        self.choices = choices
        self.multiple = multiple
        self.runs = runs
        self.hidesTotals = hidesTotals
    }

    /// The choices that are sent: each trimmed, and the empty ones left out.
    public var said: [String] {
        choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Why this poll would be refused here, within what the source said it takes — or nothing
    /// where it may go. Checked before anything is sent, so the words typed are never lost to
    /// a refusal the source would have made.
    public func refusal(within limits: MastodonPollLimits) -> MastodonWriteRefusal? {
        let said = said
        if said.count < MastodonPollLimits.leastChoices || said.count > limits.choices {
            return .pollChoices(most: limits.choices)
        }
        if said.contains(where: { $0.count > limits.choiceLength }) { return .pollChoiceLength(limit: limits.choiceLength) }
        if Set(said).count != said.count { return .pollSameChoice }
        if runs < limits.shortest || runs > limits.longest {
            return .pollRuns(shortest: limits.shortest, longest: limits.longest)
        }
        return nil
    }
}

/// How large a poll a Mastodon says it takes, read off the instance document beside its media
/// ceilings (`MastodonMediaLimits`).
///
/// **Lenient, and never the reason a host could not be read.** A document that says nothing of
/// polls is `unstated`: Mastodon's own numbers, which are what a Mastodon that says nothing takes.
public struct MastodonPollLimits: Equatable, Sendable {
    /// Fewer than two choices is no poll, on every Mastodon.
    public static let leastChoices = 2
    /// The same, asked of these limits: what a composer holds a poll to with them in hand.
    public var leastChoices: Int { Self.leastChoices }

    /// How many choices one poll may have.
    public let choices: Int
    /// How long one choice may be.
    public let choiceLength: Int
    /// The shortest and the longest a poll may run, in seconds.
    public let shortest: Int
    public let longest: Int

    /// What stands where the document says nothing of polls: Mastodon's own.
    public static let unstated = MastodonPollLimits(choices: 4, choiceLength: 50, shortest: 300, longest: 2_629_746)

    /// How long a poll may be asked to run, as the composer offers it: five minutes to a week.
    public static let runs = [300, 1800, 3600, 21_600, 86_400, 259_200, 604_800]

    public init(choices: Int, choiceLength: Int, shortest: Int, longest: Int) {
        self.choices = max(Self.leastChoices, choices)
        self.choiceLength = max(1, choiceLength)
        self.shortest = max(0, shortest)
        self.longest = max(self.shortest, longest)
    }

    /// `document` read for its poll limits, or `unstated` where it says nothing of them. Each
    /// figure it does not state is Mastodon's own.
    public init(document: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: document)) as? [String: Any],
              let configuration = root["configuration"] as? [String: Any],
              let polls = configuration["polls"] as? [String: Any]
        else {
            self = .unstated
            return
        }
        let plain = Self.unstated
        self.init(
            choices: MastodonMediaLimits.positive(polls["max_options"]) ?? plain.choices,
            choiceLength: MastodonMediaLimits.positive(polls["max_characters_per_option"]) ?? plain.choiceLength,
            shortest: MastodonMediaLimits.positive(polls["min_expiration"]) ?? plain.shortest,
            longest: MastodonMediaLimits.positive(polls["max_expiration"]) ?? plain.longest
        )
    }

    /// The runs the composer offers here: those within what the source takes, and where none
    /// is, the shortest it takes.
    public var offeredRuns: [Int] {
        let within = Self.runs.filter { $0 >= shortest && $0 <= longest }
        return within.isEmpty ? [shortest] : within
    }
}
