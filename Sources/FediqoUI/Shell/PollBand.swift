import FediqoCore
import SwiftUI

// A post's poll, drawn (#331): its choices, how each stands where the source says, when it
// ends, whether the reader voted — and the vote itself, where the post offers one.
//
// **Two shapes for the two surfaces a row has.** A row in a list is one height whatever it
// carries (#245), so there the poll is one line under the words that says what it is and how it
// stands, and a press on it opens the whole poll beside the row (`PollLine`). The post opened to
// be read draws the whole poll under its words (`PollBand`). Both read the poll the same way,
// through `PollWords`, so the line and the band cannot say two things of one poll.

/// What a poll says, as functions of the poll, the moment and the press — asserted without a
/// view, for `ItemActs`' reason.
@MainActor
enum PollWords {
    /// The poll as it is drawn: as its source last said it, and while a vote is out, with what
    /// that vote chose as the reader's own. The figures are the source's until it answers.
    static func drawn(_ poll: Poll, chosen: [Int]?) -> Poll {
        chosen.map { poll.with(voted: true, ownVotes: $0) } ?? poll
    }

    /// Whether the poll takes a vote from this row now: the post offers one, the poll has not
    /// ended, the reader has not voted in it, and no vote on it is out.
    static func votable(_ poll: Poll, acting: ItemActing, now: Date = Date()) -> Bool {
        acting.vote != nil && acting.acts.offers(.vote) && acting.chosen == nil
            && !poll.ended(at: now) && poll.voted != true
    }

    /// The poll's one line: what it is, how many voted, and when it ends or that it ended —
    /// and that the reader voted, where they did, or that the figures wait for the end.
    static func summary(_ poll: Poll, now: Date = Date(), language: DummyLanguage? = nil) -> String {
        var parts = [L10n.t("poll.title", language: language)]
        if let votes = poll.multiple ? (poll.voters ?? poll.votes) : poll.votes {
            parts.append(L10n.count(poll.multiple ? "poll.voters" : "poll.votes", votes, language: language))
        }
        if poll.voted == true { parts.append(L10n.t("poll.voted", language: language)) }
        parts.append(ends(poll, now: now, language: language))
        if poll.countsHidden, !poll.ended(at: now) { parts.append(L10n.t("poll.hidden", language: language)) }
        return parts.joined(separator: L10n.t("poll.joiner", language: language))
    }

    /// When it ends, as a time from now, or that it has ended. A poll that never ends says so.
    static func ends(_ poll: Poll, now: Date = Date(), language: DummyLanguage? = nil) -> String {
        if poll.ended(at: now) { return L10n.t("poll.ended", language: language) }
        guard let endsAt = poll.endsAt else { return L10n.t("poll.open", language: language) }
        let said = relative(L10n.locale(language)).localizedString(for: endsAt, relativeTo: now)
        return String(format: L10n.t("poll.ends", language: language), said)
    }

    /// One formatter of a time from now per locale, made the first time a poll's line asks for
    /// it: a timeline draws a line for every poll on it, and every draw asks again.
    private static var relatives: [String: RelativeDateTimeFormatter] = [:]

    private static func relative(_ locale: Locale) -> RelativeDateTimeFormatter {
        if let made = relatives[locale.identifier] { return made }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        relatives[locale.identifier] = formatter
        return formatter
    }

    /// How choice `index` stands, as a share in the shell's language, where the source says.
    static func share(_ poll: Poll, _ index: Int, language: DummyLanguage? = nil) -> String? {
        poll.share(of: index).map { $0.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale(language))) }
    }

    /// What a listener is told of one choice: its words, how it stands where that is said,
    /// and whether it is the reader's own vote.
    static func spokenChoice(_ poll: Poll, _ index: Int, language: DummyLanguage? = nil) -> String {
        guard poll.choices.indices.contains(index) else { return "" }
        var parts = [poll.choices[index].title]
        if let share = share(poll, index, language: language) {
            let votes = poll.choices[index].votes ?? 0
            parts.append(String(format: L10n.t("poll.choice.stands", language: language), share, L10n.count("poll.votes", votes, language: language)))
        }
        if poll.chose(index) { parts.append(L10n.t("poll.choice.yours", language: language)) }
        return parts.joined(separator: ", ")
    }

    /// Why a poll takes no vote from this row, where it is not that it ended or was voted in:
    /// the sign-in's standing to writing (`ItemActing.voteLock`), or the reason the post offers
    /// no act at all. Nothing where a vote is offered, the list does not act — **and nothing
    /// where the poll ended or the reader voted**, which its own line says, and which no
    /// sign-in would change.
    static func why(_ poll: Poll, _ acting: ItemActing, now: Date = Date(), language: DummyLanguage? = nil) -> String? {
        if acting.acts.offers(.vote) || poll.ended(at: now) || poll.voted == true { return nil }
        if let lock = acting.voteLock {
            return String(format: L10n.t(lock.place.key, language: language), lock.host)
        }
        return acting.acts.refused.map { ItemActs.refusalLine($0, language: language) }
    }

    /// The glyph beside a choice: a box to tick, or a ring to choose, where a vote may be
    /// made; the reader's own vote marked; nothing marked otherwise.
    static func glyph(_ poll: Poll, _ index: Int, picked: Bool, votable: Bool) -> String {
        if votable {
            if poll.multiple { return picked ? "checkmark.square.fill" : "square" }
            return picked ? "largecircle.fill.circle" : "circle"
        }
        return poll.chose(index) ? "checkmark.circle.fill" : "circle"
    }
}

/// The whole poll: each choice and how it stands, its line, and the vote.
///
/// **What is chosen before the press is this view's alone**, and goes with it: nothing is sent
/// until Vote, and the press is the session's (`ShellSession.vote`) — once, refused where the
/// poll does not take it.
struct PollBand: View {
    let poll: Poll
    let acting: ItemActing

    @State private var picked: Set<Int> = []
    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .body) private var barHeight: CGFloat = 28

    var body: some View {
        let shown = PollWords.drawn(poll, chosen: acting.chosen)
        let votable = PollWords.votable(poll, acting: acting)
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ForEach(Array(shown.choices.indices), id: \.self) { index in
                choice(shown, index, votable: votable)
            }
            foot(shown, votable: votable)
            if let why = PollWords.why(shown, acting) { lock(why) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func choice(_ shown: Poll, _ index: Int, votable: Bool) -> some View {
        let spoken = PollWords.spokenChoice(shown, index)
        if votable {
            Button {
                pick(index)
            } label: {
                choiceFace(shown, index, votable: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(picked.contains(index) ? .isSelected : [])
        } else {
            choiceFace(shown, index, votable: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    /// One choice: its glyph and words, its share at the far end, over a bar as long as its share.
    private func choiceFace(_ shown: Poll, _ index: Int, votable: Bool) -> some View {
        let share = shown.share(of: index) ?? 0
        let mine = shown.chose(index)
        return HStack(spacing: ShellSpace.snug) {
            Image(systemName: PollWords.glyph(shown, index, picked: picked.contains(index), votable: votable))
                .foregroundStyle(mine || picked.contains(index) ? ShellChrome.phosphor(colorScheme) : ShellChrome.inkDim(colorScheme))
            Text(verbatim: shown.choices[index].title)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(2)
            Spacer(minLength: ShellSpace.snug)
            if let said = PollWords.share(shown, index) {
                Text(said)
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize()
            }
        }
        .padding(.horizontal, ShellSpace.snug)
        .frame(minHeight: barHeight)
        .background(alignment: .leading) { bar(share) }
        .contentShape(Rectangle())
    }

    private func bar(_ share: Double) -> some View {
        GeometryReader { room in
            RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous)
                .fill(ShellChrome.well(colorScheme))
                .frame(width: room.size.width * share)
        }
        .accessibilityHidden(true)
    }

    private func foot(_ shown: Poll, votable: Bool) -> some View {
        let line = PollWords.summary(shown)
        return HStack(spacing: ShellSpace.snug) {
            Text(line)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(line)
            Spacer(minLength: ShellSpace.snug)
            if let read = acting.readPoll {
                ShellIconButton("arrow.clockwise", name: "poll.read", action: read)
            }
            if votable {
                Button(L10n.t("poll.vote")) { send() }
                    .disabled(picked.isEmpty)
                    .accessibilityLabel(L10n.t("poll.vote"))
            }
        }
    }

    /// Why no vote is taken here, and where the sign-in can be asked for what a vote needs, the
    /// press that asks — which names what the source's page will ask before it opens.
    @ViewBuilder
    private func lock(_ why: String) -> some View {
        let line = Text(why)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        if let ask = acting.askToVote {
            Button(action: ask) { line }
                .buttonStyle(.plain)
                .accessibilityLabel(why)
        } else {
            line
        }
    }

    private func pick(_ index: Int) {
        if poll.multiple {
            if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
        } else {
            picked = [index]
        }
    }

    private func send() {
        let choices = picked.sorted()
        guard !choices.isEmpty else { return }
        acting.vote?(choices)
        picked = []
    }
}

/// A poll on a row in a list: one line under the words, and a press on it opens the whole poll
/// beside the row (#331). **One line, so the row keeps its one height** (#245): what a stranger's
/// poll of thirty choices would otherwise do to every row under it.
///
/// Under a cover it is drawn with the words and is no press: what the cover keeps back, it keeps
/// back whole.
struct PollLine: View {
    let poll: Poll
    let acting: ItemActing
    let covered: Bool

    @State private var open = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let line = PollWords.summary(PollWords.drawn(poll, chosen: acting.chosen))
        if covered {
            face(line)
        } else {
            Button { open = true } label: { face(line) }
                .buttonStyle(.plain)
                .accessibilityLabel(line)
                .accessibilityHint(L10n.t("poll.open.hint"))
                .popover(isPresented: $open) {
                    PollBand(poll: poll, acting: acting)
                        .padding(ShellSpace.step)
                        .frame(minWidth: 280, idealWidth: 340)
                        .background(ShellChrome.page(colorScheme))
                }
        }
    }

    private func face(_ line: String) -> some View {
        HStack(spacing: ShellSpace.tight) {
            Image(systemName: "chart.bar.xaxis")
            Text(line)
                .lineLimit(1)
        }
        .shellFont(.meta)
        .foregroundStyle(ShellChrome.inkDim(colorScheme))
    }
}
