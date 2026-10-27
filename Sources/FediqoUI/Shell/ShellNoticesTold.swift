import FediqoCore
import Foundation
import Observation
import UserNotifications

/// Whether the system may show this app's own notices, as the system says.
enum SystemNoticeStanding: Equatable, Sendable {
    /// Never asked: the first turn of the switch asks.
    case unasked
    case allowed
    /// Refused, in the system's own settings: nothing here asks again.
    case refused
}

/// The system's notices, behind a seam: what a check holds, since what the system shows cannot be
/// seen with no screen.
protocol SystemNotices: Sendable {
    func standing() async -> SystemNoticeStanding
    /// Asks the person, once — the system answers again with no question after that.
    func ask() async -> Bool
    func post(id: String, title: String, body: String) async
}

/// The system's own, over `UNUserNotificationCenter`. Built by the app alone: a test process has
/// no bundle the centre will serve.
struct UserSystemNotices: SystemNotices {
    func standing() async -> SystemNoticeStanding {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .unasked
        case .denied: .refused
        default: .allowed
        }
    }

    func ask() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// No system at all: what every session has until the app hands in the system's own.
struct NoSystemNotices: SystemNotices {
    func standing() async -> SystemNoticeStanding { .refused }
    func ask() async -> Bool { false }
    func post(id: String, title: String, body: String) async {}
}

/// The person is told of a new notice while Fediqo runs (#324).
///
/// **The person's choice, one source at a time, off until made**, and kept in this device's
/// preferences beside `ShellLines`' — never in the store. Chosen, the source's own line is held
/// while Fediqo runs (`ShellLines.wants`), whatever page is in front, and each notice it tells:
/// - **is listed** — the notices page reads again, in place, as its reload would (`read`), so what
///   is drawn there is what a read draws, gathered as a read gathers it;
/// - **raises the count** where notices are reached, unless that page is in front — and only for
///   a kind the person keeps told: one switched off tells nothing, and is still listed;
/// - **and is shown as the system's own notice** only where the person turned that on, which is
///   when the system is asked, and never at launch. Refused there, the switch stays off, says so,
///   and nothing asks again; the count works all the same.
///
/// **A notice the source holds back is never told**: it is never on the line
/// (`MastodonNoticeLineCaptures`). **Signed in for less than notices need, it is not offered**: the
/// place says the notices part's own sentence, and its press asks for that part.
@MainActor
@Observable
final class ShellNoticesTold {
    /// What one source's choice is.
    struct Choice: Codable, Equatable {
        var on = false
        var system = false
        /// The kinds that tell nothing, by the word they are narrowed by (`Notice.Kind.narrowedAs`).
        var off: Set<String> = []
    }

    /// What the source's page offers.
    enum Offer: Equatable {
        case choice(Choice, systemRefused: Bool)
        /// Signed in, without the notices part: its own sentence, and the press asks for it.
        case locked(String)
        /// Not signed in: the sentence, and the press asks to sign in with notices ticked.
        case signIn(String)
        /// A source that tells no notices.
        case cannot(String)
    }

    nonisolated static let key = "fediqo.notices.told"

    private(set) var choices: [String: Choice]
    /// Notices told since the notices page was last in front.
    private(set) var count = 0
    /// Whether the system said no: the switch then stays off, and nothing asks again.
    private(set) var systemRefused = false

    @ObservationIgnored var pageInFront = false {
        didSet { if pageInFront { count = 0 } }
    }
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored let system: any SystemNotices
    /// Whether a read of the notices is on its way for what was told, and whether another was
    /// told meanwhile: what was told is listed by one read after the one out.
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var again = false

    init(defaults: UserDefaults? = nil, system: any SystemNotices = NoSystemNotices()) {
        self.defaults = defaults
        self.system = system
        let kept = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Choice].self, from: $0) }
        choices = kept ?? [:]
    }

    func choice(host: String) -> Choice {
        choices[host.lowercased()] ?? Choice()
    }

    private func keep(_ choice: Choice, host raw: String) {
        choices[raw.lowercased()] = choice
        if let data = try? JSONEncoder().encode(choices) { defaults?.set(data, forKey: Self.key) }
    }

    func choose(_ on: Bool, host: String) {
        var choice = choice(host: host)
        choice.on = on
        keep(choice, host: host)
    }

    func tell(_ narrowedAs: String, _ on: Bool, host: String) {
        var choice = choice(host: host)
        if on { choice.off.remove(narrowedAs) } else { choice.off.insert(narrowedAs) }
        keep(choice, host: host)
    }

    /// The system's notices for `host`, turned on: the system is asked now, and only where it has
    /// never been. Refused, the switch stays off and says so.
    func chooseSystem(_ on: Bool, host: String) async {
        var choice = choice(host: host)
        guard on else {
            choice.system = false
            keep(choice, host: host)
            return
        }
        switch await system.standing() {
        case .allowed: choice.system = true
        case .refused: systemRefused = true
        case .unasked:
            if await system.ask() { choice.system = true } else { systemRefused = true }
        }
        keep(choice, host: host)
    }

    /// The sources told of now, sorted: chosen, a Mastodon, signed in, and holding the notices part.
    func hosts(in session: ShellSession) -> [String] {
        let mastodons = Set(session.sources.filter { $0.kind == .mastodon }.map { $0.host.lowercased() })
        return choices.filter { host, choice in
            choice.on && mastodons.contains(host) && session.mastodon.isSignedIn(host: host)
                && session.mastodon.place(.notices, host: host) == nil
        }.keys.sorted()
    }

    func offer(host raw: String, in session: ShellSession) -> Offer? {
        let host = raw.lowercased()
        guard let source = session.sources.first(where: { $0.host.lowercased() == host }) else { return nil }
        guard source.kind == .mastodon else {
            return .cannot(String(format: L10n.t("source.told.cannot"), source.host))
        }
        guard session.mastodon.isSignedIn(host: host) else {
            return .signIn(String(format: L10n.t("source.told.signIn"), source.host))
        }
        if let place = session.mastodon.place(.notices, host: host) {
            let words = L10n.t(place.key)
            return .locked(words.contains("%@") ? String(format: words, source.host) : words)
        }
        return .choice(choice(host: host), systemRefused: systemRefused)
    }

    /// The press on the dim line: the notices part asked for where a sign-in is held, and the
    /// read-or-act question with notices ticked where none is — each saying what more is asked
    /// before the source's page opens.
    func press(host: String, in session: ShellSession) {
        if session.mastodon.isSignedIn(host: host) {
            session.askFor([.notices], host: host)
        } else {
            _ = session.askSignIn(host: host, ticking: [.notices])
        }
    }

    /// One notice told on `host`'s line: listed, counted and shown as the choice says.
    func told(_ notice: Notice, in session: ShellSession) async {
        let choice = choice(host: notice.source.host)
        if !choice.off.contains(notice.kind.narrowedAs) {
            if !pageInFront { count += 1 }
            if choice.system, !systemRefused {
                await system.post(
                    id: notice.id, title: notice.source.host, body: NoticeWords.spoken(notice)
                )
            }
        }
        await list(in: session)
    }

    /// The notices page's own read, once for every notice told while one is out.
    private func list(in session: ShellSession) async {
        guard !reading else {
            again = true
            return
        }
        reading = true
        defer { reading = false }
        repeat {
            again = false
            await session.noticeList.read(in: session)
        } while again
    }

    /// The notices page came in front: nothing is waiting to be seen.
    func seen() {
        count = 0
    }
}
