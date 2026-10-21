import FediqoCore
import Foundation

/// What the sheet that changes one's own post says (#332, X0 §1 and §6), and the one rule it
/// warns by — functions of the post's source and the draft, so a test reads what is drawn.
@MainActor
enum ChangeWords {
    /// The sheet's first line: where the post is and who may read it, and what it answers where
    /// it answers — the three things a change cannot move.
    static func whereLine(host: String, audience: Audience?, answering: String?, language: DummyLanguage? = nil) -> String {
        let reach = audience.map { L10n.t(ComposerSheet.visibilityKey($0), language: language) }
        var line = reach.map { String(format: L10n.t("change.where", language: language), host, $0) } ?? host
        if let answering, !answering.isEmpty {
            line += " · " + String(format: L10n.t("change.answering", language: language), answering)
        }
        return line
    }

    /// A waiting quote's fixed line (#330): that what it quotes stays. Nothing for a waiting post
    /// that quotes nothing.
    static func waitingQuoteLine(_ post: WaitingPost?, language: DummyLanguage? = nil) -> String? {
        guard let post, post.quoting != nil else { return nil }
        return L10n.t("change.waiting.quote", language: language)
    }

    static func fixedLine(language: DummyLanguage? = nil) -> String {
        L10n.t("change.fixed", language: language)
    }

    /// Whether `draft` starts the post's poll again, so that every vote in it is lost — Mastodon
    /// 4.6.6's own rule (`Poll.restarted`, asked of the server in #332): its choices differ in
    /// their words, number or order, one-choice became several or back, or the poll is taken
    /// off. Never where the post had no poll.
    static func resets(_ source: PostSource, _ draft: PostDraft) -> Bool {
        source.poll?.restarted(by: draft.poll) ?? false
    }

    /// The votes a reset loses, where the source said how many — nothing where it keeps the
    /// figures back, or said none.
    static func votes(_ source: PostSource) -> Int? {
        source.poll?.votes
    }

    /// The line under the poll while the draft would start it again: with the votes it holds
    /// where the source said, and without a figure where it did not.
    static func resetLine(_ source: PostSource, language: DummyLanguage? = nil) -> String {
        guard let votes = votes(source) else { return L10n.t("change.poll.reset.unsaid", language: language) }
        return String(format: L10n.t("change.poll.reset", language: language), votes)
    }

    /// Whether Save asks first: only where the change loses votes there are (Decision 8, §7.2).
    static func asksAtSave(_ source: PostSource, _ draft: PostDraft) -> Bool {
        resets(source, draft) && (votes(source) ?? 0) > 0
    }

    /// The question Save asks before it loses votes.
    static func question(_ source: PostSource, host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "arrow.counterclockwise",
            title: L10n.t("change.poll.ask.title", language: language),
            line: String(format: L10n.t("change.poll.ask.line", language: language), votes(source) ?? 0, host),
            help: nil,
            choices: [.init("save", L10n.t("change.poll.ask.confirm", language: language), role: .destructive)],
            cancel: L10n.t("profile.discard.keep", language: language)
        )
    }

    /// The line under a poll that has ended: a change keeps it only by opening it again for a
    /// run chosen anew, or takes it off — the source takes no run of nothing.
    static func endedLine(language: DummyLanguage? = nil) -> String {
        L10n.t("change.poll.ended", language: language)
    }

    /// The runs a changed poll may be given: what is left of its own run first, where it is
    /// not one the source offers, then the source's.
    static func runs(_ draft: PostDraft, offered: [Int]) -> [Int] {
        guard let left = draft.poll?.runs, left > 0, !offered.contains(left) else { return offered }
        return [left] + offered
    }

    /// A file already on the post, as the draft holds it: its id and description, no bytes.
    static func kept(_ media: PostSource.Media, at index: Int) -> UnsentMedia {
        let named = media.previewURL?.lastPathComponent
        let name = named.flatMap { $0.isEmpty ? nil : $0 } ?? "\(media.kind.rawValue) \(index + 1)"
        return UnsentMedia(
            bytes: Data(), mime: "\(media.kind.rawValue)/*", name: name, description: media.description,
            remoteID: media.id
        )
    }

    /// The draft a change starts from: the post as its source says it was written, at `now`,
    /// who may read it as the row says (fixed).
    static func draft(from source: PostSource, audience: Audience?, now: Date = Date()) -> PostDraft {
        PostDraft(
            text: source.text, cover: source.spoiler, language: source.language ?? "",
            coversMedia: source.sensitive,
            media: source.media.enumerated().map { kept($0.element, at: $0.offset) },
            poll: source.pollDraft(now: now), audience: audience ?? .everyone
        )
    }
}
