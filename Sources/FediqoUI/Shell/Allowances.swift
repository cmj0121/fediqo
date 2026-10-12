import FediqoCore
import Foundation

/// What reaches beyond a source the person added, each only because the person asked for it
/// (#220): one list of named entries, and nothing else anywhere.
///
/// **Data, not conditionals.** The gate (`SourceWork.admission`), a forum's browser
/// (`ForumWebEngine.decide`) and the rules a page loads under (`PageRules`) all read this list and
/// nothing else, and every act an entry lets through is written to the run's record with the
/// entry's `id` (`SourceAct.allowedBy`). So what is let through is said in one place — and the
/// list the person edits in Preferences (#226, `AllowanceBook`) is this one, handed in.
struct Allowance: Identifiable, Equatable, Sendable {
    /// Which entry: one the app starts with, by name, or one the person added (#226), by the host
    /// it lets through and the source it serves — so an act's line can name it after the entry is
    /// gone, and one host added twice for one source is one entry.
    struct ID: RawRepresentable, Hashable, Sendable {
        let rawValue: String

        init(rawValue: String) { self.rawValue = rawValue }

        /// The directory of servers, while a source is being added.
        static let directory = ID(rawValue: "directory")
        /// Cloudflare's browser check in front of a forum, in its own browser.
        static let forumChallenge = ID(rawValue: "forumChallenge")
        /// The check a forum's sign-in shows to prove a person is there.
        static let personCheck = ID(rawValue: "personCheck")
        /// A page the person follows away from a forum's sign-in.
        static let signInPage = ID(rawValue: "signInPage")
        /// The server somebody lives on, asked what it says of them at their page's press (#310).
        static let personHome = ID(rawValue: "personHome")

        /// The entries the app starts with, in the order the list shows them.
        static let builtIn: [ID] = [.directory, .forumChallenge, .personCheck, .signInPage, .personHome]

        private static let ownPrefix = "own:"

        /// The person's own entry letting `host` through for `source`, both folded.
        static func own(host: String, source: String) -> ID {
            ID(rawValue: ownPrefix + host + "@" + source)
        }

        /// Whether the person added it.
        var isOwn: Bool { rawValue.hasPrefix(Self.ownPrefix) }

        /// The host a person's own entry lets through; nil for one the app starts with.
        var ownHost: String? {
            guard isOwn, let at = rawValue.lastIndex(of: "@") else { return nil }
            return String(rawValue[rawValue.index(rawValue.startIndex, offsetBy: Self.ownPrefix.count)..<at])
        }

        /// The entry as a line of the record names it, in the shell's language.
        func name(language: DummyLanguage? = nil) -> String {
            if let host = ownHost { return String(format: L10n.t("allow.own.name", language: language), host) }
            return L10n.t("allow.\(rawValue).title", language: language)
        }
    }

    /// When an entry applies.
    enum When: Sendable {
        /// While the person is adding a source: the browse step of the add sheet.
        case adding
        /// On any page in a forum's own browser, the sign-in included.
        case forumPage
        /// Only while the person has a forum's sign-in in front of them.
        case signingIn
        /// Only at a press that names the one host it reaches, and for one request of it
        /// (`SourceWork.press`): the entry lists no host, and lets nothing through unpressed.
        case pressed
    }

    /// What it lets through.
    enum Reach: Sendable, Equatable {
        /// A request the app makes, for this purpose, to one of `hosts`.
        case request(SourceWork.Purpose)
        /// A frame, script or picture a page pulls in from one of `hosts`.
        case frame
        /// The page itself moving to any host at all.
        case navigation
    }

    /// A host an entry lets through: that host, or it and every host under it; and, where named,
    /// only addresses whose path starts with `path`.
    struct Pattern: Equatable, Sendable {
        let host: String
        var subdomains = false
        var path = "/"
        /// `https`, always, in the app. A test serves its pages under a scheme of its own.
        var scheme = "https"

        func matches(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == scheme, let there = url.host()?.lowercased() else {
                return false
            }
            let hostMatches = there == host || (subdomains && there.hasSuffix("." + host))
            return hostMatches && (url.path.isEmpty ? "/" : url.path).hasPrefix(path)
        }

        /// As the list shows it: `*.` where it takes every host under it, and its path where it
        /// names one.
        var text: String {
            (subdomains ? "*." : "") + host + (path == "/" ? "" : path)
        }

        /// As WebKit's content rules read an address: no alternation, so one rule per pattern.
        /// Every character a regular expression reads as more than itself is escaped, so a host
        /// or a path can only ever match itself.
        var urlFilter: String {
            "^" + scheme + "://" + (subdomains ? "([^/]*\\.)?" : "") + Self.escaped(host) + Self.escaped(path)
        }

        static func escaped(_ text: String) -> String {
            let special: Set<Character> = ["\\", "^", "$", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|"]
            return String(text.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
        }
    }

    let id: ID
    let when: When
    let reach: Reach
    /// Empty for `navigation`, which lets the page go anywhere.
    let hosts: [Pattern]
    /// The source a person's own entry serves, folded; nil for one the app starts with. An own
    /// entry applies only to that source: its forum's pages, and what that source points to.
    var source: String? = nil

    /// What is let through when the person has changed nothing. What is let through now is
    /// `AllowanceBook`'s, handed to `SourceWork` (#226).
    static let standing: [Allowance] = [
        Allowance(
            id: .directory, when: .adding, reach: .request(.directory),
            hosts: [Pattern(host: ServerDirectory.host)]
        ),
        Allowance(
            id: .forumChallenge, when: .forumPage, reach: .frame,
            hosts: [Pattern(host: "challenges.cloudflare.com")]
        ),
        Allowance(
            id: .personCheck, when: .signingIn, reach: .frame,
            hosts: [
                // reCAPTCHA
                Pattern(host: "www.google.com", path: "/recaptcha/"),
                Pattern(host: "www.gstatic.com", path: "/recaptcha/"),
                Pattern(host: "recaptcha.net", subdomains: true),
                // hCaptcha
                Pattern(host: "hcaptcha.com", subdomains: true),
                // Geetest
                Pattern(host: "geetest.com", subdomains: true),
                // Tencent
                Pattern(host: "captcha.qq.com", subdomains: true),
                Pattern(host: "captcha.gtimg.com"),
            ]
        ),
        Allowance(id: .signInPage, when: .signingIn, reach: .navigation, hosts: []),
        Allowance(id: .personHome, when: .pressed, reach: .request(.personHome), hosts: []),
    ]

    /// The server a handle names as somebody's home, as a press may reach it — or nothing,
    /// and then no press is offered: the name came out of a handle or a server's answer, and
    /// the device itself would be the one to go there.
    ///
    /// **A name, as a host the person adds is one** (`AllowanceBook.host`): no scheme, port,
    /// path or credentials, no brackets, two labels or more of letters, digits and inner
    /// hyphens — a name in another script in its ASCII spelling — and no address in digits.
    ///
    /// **And one that could be registered.** Its last label is letters alone, or the ASCII
    /// spelling of a name in another script: so no address in any form — `0x7f.0x1` is one to
    /// a resolver. And it is none of the names kept for a device and the network it is on.
    ///
    /// **What this does not cover.** A registered name is not looked up before it is asked:
    /// one that resolves to this device or to an address on its network is asked all the same.
    @MainActor
    static func homeServer(_ named: String) -> String? {
        guard case .success(let host) = AllowanceBook.host(named), host == named.lowercased(),
              let last = host.split(separator: ".").last,
              last.hasPrefix("xn--") || last.allSatisfy(\.isLetter), !notRegistered.contains(String(last))
        else { return nil }
        return host
    }

    /// The last labels nobody can register: kept for this device, the network it is on, and
    /// names that are never in the public tree (RFC 6761, RFC 6762, RFC 7686, RFC 8375,
    /// RFC 9476, the three ICANN set aside for private networks, and the ones private networks
    /// name themselves by all the same).
    private static let notRegistered: Set<String> = [
        "localhost", "local", "localdomain", "internal", "intranet", "private", "lan", "home", "corp", "arpa", "test",
        "invalid", "onion", "alt",
    ]

    /// The person's own entry: what `source`'s forum pages pull in from `host`, and what `source`
    /// points to there. Both are folded by the caller.
    static func own(host: String, for source: String) -> Allowance {
        Allowance(
            id: .own(host: host, source: source), when: .forumPage, reach: .frame,
            hosts: [Pattern(host: host)], source: source
        )
    }

    /// Whether this entry, where it applies, lets `url` through.
    func allows(_ url: URL) -> Bool {
        reach == .navigation || hosts.contains { $0.matches(url) }
    }

    /// The entries that apply `in` a context — `signingIn` also takes every `forumPage` entry —
    /// on the pages `of` a source: a person's own entry applies only on its own source's.
    static func applying(_ when: When, in list: [Allowance] = standing, of source: String? = nil) -> [Allowance] {
        let folded = source.map(SourceWork.fold)
        return list.filter { entry in
            let applies = entry.when == when || (when == .signingIn && entry.when == .forumPage)
            guard let bound = entry.source else { return applies }
            return applies && bound == folded
        }
    }

    // MARK: - As the list says it (#226)

    /// What it is.
    func title(language: DummyLanguage? = nil) -> String { id.ownHost ?? id.name(language: language) }

    /// What it lets through.
    func what(language: DummyLanguage? = nil) -> String {
        guard let source else { return L10n.t("allow.\(id.rawValue).what", language: language) }
        return String(format: L10n.t("allow.own.what", language: language), source)
    }

    /// When it applies.
    func whenText(language: DummyLanguage? = nil) -> String {
        if let source { return String(format: L10n.t("allow.when.own", language: language), source) }
        return switch when {
        case .adding: L10n.t("allow.when.adding", language: language)
        case .forumPage: L10n.t("allow.when.forumPage", language: language)
        case .signingIn: L10n.t("allow.when.signingIn", language: language)
        case .pressed: L10n.t("allow.when.pressed", language: language)
        }
    }

    /// Why it is there.
    func why(language: DummyLanguage? = nil) -> String {
        L10n.t(source == nil ? "allow.\(id.rawValue).why" : "allow.own.why", language: language)
    }

    /// The hosts it lets through, as the list shows them; a sentence where it goes anywhere.
    func hostsText(language: DummyLanguage? = nil) -> String {
        if reach == .navigation { return L10n.t("allow.hosts.anywhere", language: language) }
        if when == .pressed { return L10n.t("allow.hosts.pressed", language: language) }
        return hosts.map(\.text).joined(separator: ", ")
    }
}

/// What the person decided about what reaches beyond a source (#226): which of the entries the
/// app starts with are off, and the hosts they added for a source. **Only decisions** — never a
/// host reached or when — kept on this device so the list outlives a relaunch: **in a file
/// beside the index** (#344, `file`), unreadable while the device is locked, moved there once
/// from the preference key earlier builds kept it under. Only a book handed no file — a test,
/// a preview — keeps to the key.
///
/// **A list that could not be read is not an empty one** (`unread`): nothing beyond a source is
/// let through, no switch and no host is changed, and nothing is written — an empty list
/// written over the one a locked device holds would switch back on what the person switched
/// off. It stays so until it is read (`reread`).
///
/// Every change is handed at once to `SourceWork` (`allow`), which the gate, a forum's browser and
/// the rules its pages load under all read: nothing waits for a relaunch.
///
/// **A source let go takes its own entries with it** (`sourcesChanged`): a host added for a source
/// exists only to serve it, and nothing left behind may name a source the person removed (#221).
@MainActor
@Observable
final class AllowanceBook {
    /// The app's own, on its file beside the store and `SourceWork.shared`. A test builds its
    /// own. **First touched after `kept` is said** (`FediqoRootView.onlyToSources`), which is
    /// after the store was opened: nothing of the list is read on a device still locked.
    static let shared = AllowanceBook(defaults: .standard, work: .shared, file: kept)

    /// The file the app's own book keeps its list in, said before `shared` is first touched.
    static var kept: ListFile?

    /// Why the list is not known this run (#344), where it is not.
    enum Unknown: Equatable {
        /// What is kept is there and would not be read.
        case notRead
        /// Nothing is kept, and the device cannot say that nothing is — a run with no canary:
        /// it will not let a first list be made.
        case cannotKeep
    }

    /// Why what is kept is not known, or nil where it was read.
    private(set) var unknown: Unknown?
    /// What is kept would not be read, or cannot be said: the list is not known this run.
    var unread: Bool { unknown != nil }
    /// The last change would not be written down: what is shown is not what is kept. Handed
    /// to `work` with the list, where every session reads it and says so (`ShellSession.kept`).
    private(set) var unwritten = false

    /// The entries the app starts with that the person switched off.
    private(set) var off: Set<Allowance.ID> = []
    /// The hosts the person added, oldest first.
    private(set) var own: [Allowance] = []

    @ObservationIgnored let work: SourceWork
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let file: ListFile?

    static let key = "fediqo.allowances"

    /// What an added host could not be.
    enum Refusal: Error, Equatable {
        /// Not a host: empty, spaced, one label, or a label that is not letters, digits and
        /// inner hyphens.
        case notAHost
        /// A pattern with `*`: one host is added at a time.
        case wildcard
        /// An address by number, or in brackets: a source's pictures are named by host.
        case address
        /// A port: an entry lets a host through on the web's own ports.
        case port
        /// A path, a query or a fragment: an entry is for a whole host.
        case path
        /// The source's own host, which needs no entry.
        case itsOwnHost
        /// Already on the list for that source.
        case alreadyThere
        /// The list could not be read this run, and nothing is added to what is not known.
        case unread
    }

    /// As it is kept: the decisions, and nothing else. **A key that is missing is empty**, and
    /// the other still read: a list with no hosts keeps the switches it had.
    private struct Kept: Codable {
        var off: [String] = []
        var own: [Own] = []

        struct Own: Codable {
            let host: String
            let source: String
        }

        init(off: [String], own: [Own]) {
            self.off = off
            self.own = own
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            off = (try? container.decodeIfPresent([String].self, forKey: .off)) ?? []
            own = (try? container.decodeIfPresent([Own].self, forKey: .own)) ?? []
        }
    }

    init(defaults: UserDefaults, work: SourceWork, file: ListFile? = nil) {
        self.defaults = defaults
        self.file = file
        self.work = work
        load()
        work.allow(effective)
    }

    /// The list read again off where it is kept — after a take-away was read back (#247), which
    /// replaced them under this object. What the gate lets through changes with it.
    func reread() {
        off = []
        own = []
        // What is shown from here is what is kept: nothing of an earlier change is unwritten.
        unwritten = false
        load()
        work.allow(effective)
    }

    private func load() {
        let data: Data?
        switch file?.read() {
        case .unread?:
            unknown = .notRead
            return
        case .notKnown?:
            unknown = .cannotKeep
            return
        case .data(let kept)?: data = kept
        case .some(.none): data = nil
        case nil: data = defaults.data(forKey: Self.key)
        }
        unknown = nil
        if let data, let kept = try? JSONDecoder().decode(Kept.self, from: data) {
            off = Set(kept.off.map(Allowance.ID.init(rawValue:)).filter(Allowance.ID.builtIn.contains))
            // Read as though typed again: what would be refused now is not let through, and a
            // host kept twice is one entry.
            for kept in kept.own {
                guard case .success(let host) = Self.host(kept.host) else { continue }
                let source = SourceWork.fold(kept.source)
                let entry = Allowance.own(host: host, for: source)
                guard !source.isEmpty, SourceWork.fold(host) != source, !own.contains(where: { $0.id == entry.id })
                else { continue }
                own.append(entry)
            }
        }
    }

    /// Every entry the list shows: the app's own, then the person's.
    var entries: [Allowance] { Allowance.standing + own }

    /// What is let through now — nothing, while the list is not known: what the person
    /// switched off is not let through for want of reading that they did.
    var effective: [Allowance] { unread ? [] : Allowance.standing.filter { !off.contains($0.id) } + own }

    func isOn(_ id: Allowance.ID) -> Bool { !unread && !off.contains(id) }

    /// Switches one of the app's own entries off or on again. A person's own entry is removed,
    /// not switched.
    func set(_ id: Allowance.ID, on: Bool) {
        guard !unread, Allowance.ID.builtIn.contains(id), on == off.contains(id) else { return }
        if on { off.remove(id) } else { off.insert(id) }
        changed()
    }

    /// Adds `typed` for `source`: a host, perhaps with `http(s)://` in front and one `/` after it,
    /// and nothing more (`host`). Answers why not where it is refused.
    @discardableResult
    func add(_ typed: String, for source: String) -> Refusal? {
        guard !unread else { return .unread }
        let host: String
        switch Self.host(typed) {
        case .success(let read): host = read
        case .failure(let refusal): return refusal
        }
        let source = SourceWork.fold(source)
        guard SourceWork.fold(host) != source else { return .itsOwnHost }
        let entry = Allowance.own(host: host, for: source)
        guard !own.contains(where: { $0.id == entry.id }) else { return .alreadyThere }
        own.append(entry)
        changed()
        return nil
    }

    func remove(_ id: Allowance.ID) {
        guard !unread, own.contains(where: { $0.id == id }) else { return }
        own.removeAll { $0.id == id }
        changed()
    }

    /// The sources the person had when last told; nil until the first time.
    @ObservationIgnored private var seen: Set<String>?

    /// The sources the app opened with. Where the store was `read` whole, a host added for a
    /// source not among them goes — removed while the app was not running to see it. Where it
    /// was not — set aside as unreadable, or written by a newer build — nothing is taken as
    /// removed, and such a host stays on the list, reaching nothing, until its source is back or
    /// it is removed by hand.
    func launched(with hosts: [String], read: Bool) {
        let now = Set(hosts.map(SourceWork.fold))
        seen = now
        guard read else { return }
        let left = own.filter { now.contains($0.source ?? "") }
        guard left.count != own.count else { return }
        own = left
        changed()
    }

    /// The sources the person has now. **A source let go takes the hosts added for it**: they
    /// are removed from the list, and from what is kept. The first time, where `launched` was not
    /// told, only says which sources there are.
    func sourcesChanged(_ hosts: some Sequence<String>) {
        let now = Set(hosts.map(SourceWork.fold))
        defer { seen = now }
        guard let seen else { return }
        let gone = seen.subtracting(now)
        let left = own.filter { !gone.contains($0.source ?? "") }
        guard left.count != own.count else { return }
        own = left
        changed()
    }

    /// A host as typed, lower case and in its ASCII spelling, or why it is not one. An `http`
    /// or `https` in front of it, and one `/` after it, are read past; anything else that is not
    /// a host is refused, and the refusal says which.
    ///
    /// **Only letters, digits and hyphens, label by label**, after a name in another script is
    /// spelled in ASCII: this is what goes into the rules a page loads under, and nothing in it
    /// may be read as more than itself.
    static func host(_ typed: String) -> Result<String, Refusal> {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return .failure(.notAHost) }
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.hasSuffix("/") { text.removeLast() }
        if text.contains("*") { return .failure(.wildcard) }
        if text.contains("[") || text.contains("]") { return .failure(.address) }
        if text.contains("://") || text.contains("@") || text.contains("\\") { return .failure(.notAHost) }
        if text.contains(where: { "/?#".contains($0) }) { return .failure(.path) }
        if text.contains(":") { return .failure(.port) }
        guard let ascii = URL(string: "https://" + text)?.host(percentEncoded: false)?.lowercased(),
              ascii.count <= 253
        else { return .failure(.notAHost) }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        let letters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.allSatisfy(letters.contains)
                && label.first != "-" && label.last != "-"
        }) else { return .failure(.notAHost) }
        if labels.last!.allSatisfy(\.isNumber) { return .failure(.address) }
        return .success(ascii)
    }

    private func changed() {
        // Never over a list that was not read.
        guard !unread else { return }
        let kept = Kept(
            off: Allowance.ID.builtIn.filter(off.contains).map(\.rawValue),
            own: own.compactMap { entry in entry.source.map { Kept.Own(host: entry.hosts[0].host, source: $0) } }
        )
        // At the act, whole and atomic: nothing of it waits for a save or for leaving.
        if let data = try? JSONEncoder().encode(kept) {
            if let file {
                // Not written, what is shown is not what is kept: said, not passed over.
                unwritten = !file.write(data)
            } else {
                defaults.set(data, forKey: Self.key)
            }
        }
        work.allow(effective, written: !unwritten)
    }
}
