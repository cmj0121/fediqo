import FediqoCore
import Foundation
import Observation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    /// Whether Fediqo is the app in front: then the person is told in Fediqo, not by the system.
    @MainActor func inFront() -> Bool
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

    @MainActor func inFront() -> Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }
}

extension Notification.Name {
    /// Fediqo became the app in front.
    static var fediqoCameForward: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }
}

/// What the system says of the notices it showed for Fediqo (#428): a press on one goes to the
/// session's `ShellNoticesTold`, and none is shown while Fediqo is in front. Installed by the app
/// alone (`listen`), before its launch ends: a test process has no bundle the centre will serve.
@MainActor
public final class SystemNoticePresses: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = SystemNoticePresses()

    override init() { super.init() }

    /// Who a press goes to.
    weak var told: ShellNoticesTold? {
        didSet {
            guard let told, let waiting else { return }
            self.waiting = nil
            told.systemPressed(id: waiting)
        }
    }
    /// A press from before there was anybody to tell: one that launched Fediqo.
    private var waiting: String?

    public func listen() {
        UNUserNotificationCenter.current().delegate = self
    }

    func pressed(id: String) {
        if let told { told.systemPressed(id: id) } else { waiting = id }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        Task { @MainActor in SystemNoticePresses.shared.pressed(id: id) }
        done()
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        done([])
    }
}

/// No system at all: what every session has until the app hands in the system's own.
struct NoSystemNotices: SystemNotices {
    func standing() async -> SystemNoticeStanding { .refused }
    func ask() async -> Bool { false }
    func post(id: String, title: String, body: String) async {}
    @MainActor func inFront() -> Bool { false }
}

/// The person is told of a new notice while Fediqo runs (#324).
///
/// **The person's choice, one source at a time, off until made**, and kept in this device's
/// preferences beside `ShellLines`' — never in the store. Chosen, the source's own line is held
/// while Fediqo runs (`ShellLines.wants`), whatever page is in front, and each notice it tells:
/// - **is listed** — the notices page reads again, in place, as its reload would (`read`), so what
///   is drawn there is what a read draws, gathered as a read gathers it;
/// - **moves the count** where notices are reached — **the source's own** (#429), read after each
///   read of the notices and each round that reaches the source, never tallied here, so it agrees
///   with the source's other clients. A kind the person switched off is left out by asking the source
///   to. Opening the page tells the source they are read, where the sign-in may
///   (`NoticesToldControl` says where it may not), and what it decides then is the count. A refusal
///   or a failure is said, and the count stands as it last said;
/// - **and is shown as the system's own notice** only where the person turned that on, which is
///   when the system is asked, and never at launch. Refused there, the switch stays off, says so,
///   and nothing asks again; the count works all the same. **A favourite is not** (#462), unless
///   the person switched favourites on for that source too: it is counted and listed as any other,
///   and interrupts nobody unasked.
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
        /// Whether a favourite is shown as the system's notice too (#462): off until the person turns
        /// it on, as a favourite asks for no answer.
        var systemFavourites = false

        /// Whether a notice of `kind` is shown as the system's notice, the system allowing.
        func showsSystem(_ kind: Notice.Kind) -> Bool {
            guard system, !off.contains(kind.narrowedAs) else { return false }
            return kind != .favourite || systemFavourites
        }
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

    /// Why a source's count is not being drawn as its word.
    enum CountSaid: Equatable {
        /// It refused or failed: the last word stands.
        case failed
        /// It answered that it has no such count.
        case none
    }

    nonisolated static let key = "fediqo.notices.told"

    private(set) var choices: [String: Choice]
    /// How many are unread at each source told of, as it last said.
    private(set) var counts: [String: Int] = [:]
    /// Why a source's count is not its word just now, by host.
    private(set) var countSaid: [String: CountSaid] = [:]
    /// Every source's last word, added. What is drawn is `count(in:)`.
    var count: Int { counts.values.reduce(0, +) }
    /// Whether the system said no: the switch then stays off, and nothing asks again.
    private(set) var systemRefused = false

    @ObservationIgnored var pageInFront = false
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored let system: any SystemNotices
    /// Whether a read of the notices is on its way for what was told, and which sources told more
    /// meanwhile: what was told is listed by one read of each after the one out.
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var again: Set<String> = []
    /// The notices told this run, by id, oldest first: one told again is not told twice, and a press
    /// on the system's notice opens the one it showed. Only the last `keptTold` are kept.
    @ObservationIgnored private var toldThisRun: [String: Notice] = [:]
    @ObservationIgnored private var toldOrder: [String] = []
    nonisolated static let keptTold = 200
    /// The system's notice just pressed, by its id, until the root takes it.
    private(set) var pressedID: String?

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
        if !on {
            counts[host.lowercased()] = nil
            countSaid[host.lowercased()] = nil
        }
    }

    /// Favourites shown as the system's notices too, at `host`, or not (#462).
    func chooseSystemFavourites(_ on: Bool, host: String) {
        var choice = choice(host: host)
        choice.systemFavourites = on
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

    /// One notice told on `host`'s line: listed, shown as the choice says (`Choice.showsSystem`), and the count read again
    /// with the list (`afterRead`).
    func told(_ notice: Notice, in session: ShellSession) async {
        guard toldThisRun[notice.id] == nil else { return }
        toldThisRun[notice.id] = notice
        toldOrder.append(notice.id)
        if toldOrder.count > Self.keptTold { toldThisRun[toldOrder.removeFirst()] = nil }
        let choice = choice(host: notice.source.host)
        if choice.showsSystem(notice.kind), !systemRefused, !system.inFront() {
            await system.post(id: notice.id, title: notice.source.host, body: NoticeWords.spoken(notice))
        }
        await list(host: notice.source.host, in: session)
    }

    /// The list read again with nothing counted or shown: the line just opened, so what was told
    /// while none was is brought in (#426), or the source said requests let through have landed.
    ///
    /// **Only that source**, and a reading on out is left to land (`ShellNoticeList.readTop`).
    func caughtUp(host: String, in session: ShellSession) async {
        await list(host: host, in: session)
    }

    /// The system's notice with this id was pressed (#428).
    func systemPressed(id: String) {
        pressedID = id
    }

    /// What was pressed, once: the notice to open, or nothing where this run did not tell it, which
    /// still brings the person to the notices page.
    func takePressed() -> Notice? {
        defer { pressedID = nil }
        return pressedID.flatMap { toldThisRun[$0] }
    }

    /// The notices page's own read of the source that told, once for all it told while one is out.
    private func list(host raw: String, in session: ShellSession) async {
        again.insert(raw.lowercased())
        guard !reading else { return }
        reading = true
        defer { reading = false }
        while let host = again.popFirst() {
            await session.noticeList.readTop(host: host, in: session)
        }
    }

    // MARK: - The source's count

    /// The notices page came in front, or left: in front, the source is told they are read.
    func pageCame(_ inFront: Bool, in session: ShellSession) async {
        pageInFront = inFront
        if inFront { await afterRead(in: session) }
    }

    /// Fediqo came back in front of other windows: with the page up, what it shows is now seen.
    func cameForward(in session: ShellSession) async {
        if pageInFront { await afterRead(in: session) }
    }

    /// What is drawn where notices are reached: the count of sources told of now, so one signed out
    /// of or removed draws nothing from the moment it went, with or without a read.
    func count(in session: ShellSession) -> Int {
        let hosts = hosts(in: session)
        return counts.filter { hosts.contains($0.key) }.values.reduce(0, +)
    }

    private func prune(keeping hosts: [String]) {
        for known in Set(counts.keys).union(countSaid.keys).subtracting(hosts) {
            counts[known] = nil
            countSaid[known] = nil
        }
    }

    /// A read of the notices landed, of every source or of `only`: **with the page up and Fediqo
    /// really in front** the source is told how far — behind other windows nobody has seen them —
    /// and each says its count.
    func afterRead(only: String? = nil, in session: ShellSession) async {
        let hosts = hosts(in: session)
        prune(keeping: hosts)
        for host in hosts where only == nil || only?.lowercased() == host {
            if pageInFront, system.inFront() { await tellRead(host, in: session) }
            await readCount(host: host, in: session)
        }
    }

    /// Where the source answered a round of reading, its count is read with it.
    func roundAnswered(host raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        let hosts = hosts(in: session)
        prune(keeping: hosts)
        guard hosts.contains(host) else { return }
        await readCount(host: host, in: session)
    }

    private func readCount(host: String, in session: ShellSession) async {
        guard let sent = session.mastodon.token(host: host) else { return }
        let left = excluded(host: host, in: session)
        let door = session.mastodon.authorized(token: sent, within: session.noticeList.deadline, for: .notices)
        let result = await ShellNoticeActs.run(session.reach.notices(door)) { try await $0.unreadCount(excluding: left) }
        guard ShellNoticeActs.counts(result, of: host, sentWith: sent, in: session) == .held,
              hosts(in: session).contains(host) // Told off, or the source removed, while this was out.
        else { return }
        switch result {
        case .success(let told):
            counts[host] = told
            countSaid[host] = nil
        case .failure(MastodonAuthError.http(404)):
            counts[host] = nil
            countSaid[host] = CountSaid.none
        case .failure(let error) where Cancellation.happened(error):
            break
        case .failure:
            if countSaid[host] != .failed { session.showToast(String(format: L10n.t("source.told.count.failed"), host)) }
            countSaid[host] = .failed
        }
    }

    /// The kinds the source's page lists switches for: those it has not said it lacks (#430).
    func kinds(host: String, in session: ShellSession) -> [String] {
        let known = session.quoting.hosts
        return NoticeWords.kinds { known?.has($0, at: host.lowercased()) ?? .unsaid }
    }

    /// The source's own words for the kinds switched off, **only those it has** (#430). **Everything
    /// else as one** is no word of the source's, and cannot be asked for: those stay counted.
    private func excluded(host: String, in session: ShellSession) -> [String] {
        choice(host: host).off.intersection(kinds(host: host, in: session)).subtracting([Notice.Kind.unknownKinds]).sorted()
    }

    /// What the source's page says of why the count may not move as expected: the source did not
    /// answer, has no count, or this sign-in cannot tell it what was read. Nothing where all is well.
    func countWords(host: String, in session: ShellSession) -> String? {
        switch countSaid[host.lowercased()] {
        case .failed: String(format: L10n.t("source.told.count.failed"), host)
        case .none?: String(format: L10n.t("source.told.count.none"), host)
        case nil: session.mastodon.place(.acting, host: host) == nil ? nil : String(format: L10n.t("source.told.count.readOnly"), host)
        }
    }

    /// The source told the person has read what is held of it, where the sign-in may. A conflict
    /// with another client's telling is left to the next read; any other refusal or failure is said,
    /// and nothing on this device moves.
    private func tellRead(_ host: String, in session: ShellSession) async {
        guard session.mastodon.place(.acting, host: host) == nil, let sent = session.mastodon.token(host: host),
              let newest = session.noticeList.reaches[host]?.notices.map(\.newestID).max(by: { StatusID.later($1, than: $0) })
        else { return }
        let door = session.mastodon.authorized(token: sent, within: session.noticeList.deadline, for: .write)
        let result = await ShellNoticeActs.run(session.reach.notices(door)) { try await $0.tellRead(upTo: newest) }
        guard ShellNoticeActs.counts(result, of: host, sentWith: sent, in: session) == .held else { return }
        switch result {
        case .success, .failure(MastodonAuthError.http(409)): break
        case .failure(let error) where Cancellation.happened(error): break
        case .failure: session.showToast(String(format: L10n.t("source.told.mark.failed"), host))
        }
    }
}

extension ShellNoticesTold.Choice {
    /// **A choice kept from before a part of it was asked is read as it was made**: what it does
    /// not say is the part's default, and nothing it does say is lost. Out here, so the memberwise
    /// one stands too.
    init(from decoder: any Decoder) throws {
        let kept = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            on: try kept.decodeIfPresent(Bool.self, forKey: .on) ?? false,
            system: try kept.decodeIfPresent(Bool.self, forKey: .system) ?? false,
            off: try kept.decodeIfPresent(Set<String>.self, forKey: .off) ?? [],
            systemFavourites: try kept.decodeIfPresent(Bool.self, forKey: .systemFavourites) ?? false
        )
    }
}
