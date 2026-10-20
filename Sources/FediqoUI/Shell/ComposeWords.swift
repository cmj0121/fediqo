import FediqoCore
import Foundation

/// What the composer says of a poll or a file it is written with (#331, #328), as functions of
/// the refusal and the figures — here, apart from the sheet that draws them, so they are
/// asserted without one, and every refusal is worded in one place.
enum ComposeWords {
    /// What a refusal of a poll or a file says, before anything is sent: in the words the
    /// person is asked to change it by, with the source's own figures.
    static func refusalLine(_ refusal: MastodonWriteRefusal, host: String, language: DummyLanguage? = nil) -> String {
        switch refusal {
        case .pollChoices(let most):
            return String(format: L10n.t("compose.poll.choices", language: language), host, most)
        case .pollChoiceLength(let limit):
            return String(format: L10n.t("compose.poll.choiceLength", language: language), limit)
        case .pollSameChoice:
            return L10n.t("compose.poll.same", language: language)
        case .pollRuns:
            return String(format: L10n.t("compose.poll.runs.refused", language: language), host)
        case .pollWithMedia:
            return String(format: L10n.t("compose.poll.withMedia", language: language), host)
        case .tooLarge(let limit):
            return String(format: L10n.t("compose.media.tooLarge", language: language), host, MastodonWrite.bytesNamed(limit))
        case .tooMany(let count):
            return String(format: L10n.t("compose.media.tooMany", language: language), host, count)
        case .kind:
            return String(format: L10n.t("compose.media.kind", language: language), host)
        case .description(let limit):
            return String(format: L10n.t("compose.media.description.over", language: language), limit)
        case .vote:
            return String(format: L10n.t("said.act.vote.declined", language: language), host)
        }
    }

    /// How long a poll runs, as a person says it: "1 day", "30 minutes".
    static func runsLine(_ seconds: Int, language: DummyLanguage? = nil) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale(language)
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
    }
}
