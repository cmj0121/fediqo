import Foundation

/// Which Fediqo this is (#143): what the build was stamped with when it was made, read back out
/// of the app's own Info.plist, and nothing else.
///
/// **It reports; it never corrects.** The version and the build number are the two
/// `scripts/version.sh` worked out and `Apps/Makefile` or the release lane handed to
/// `xcodebuild`; the revision and whether the checkout differed from it arrive the same way, as
/// `FEDIQO_SOURCE_REVISION` and `FEDIQO_SOURCE_DIRTY`, which `project.yml` writes into the two keys
/// below. Whatever those say is what the page says — a `0.1.0` is shown as `0.1.0` even while the
/// work in hand is for a later milestone, because deciding what a build should call itself is a
/// person's decision made in `VERSION`, and a page that second-guessed it would be the one place
/// in the app that disagreed with the store.
///
/// **Absent is said, never filled in.** A build nobody stamped — a `swift test`, or Xcode run on
/// the generated project without the Makefile — carries an empty value, or no key at all, or
/// under some tools the setting's own name unexpanded. All three read as `nil` here and the page
/// says "not recorded"; none of them is shown as if it were a revision.
///
/// A value type over a dictionary, not a view, so every acceptance line — the rows, the words
/// for an absent stamp, the marker for unrecorded changes, the text one Copy puts on the
/// clipboard — is asserted headlessly. It reads a dictionary it is handed and asks nothing of
/// the network, the store or the disk.
struct BuildStamp: Equatable, Sendable {
    /// Fediqo's own keys, since nothing Apple defines means "the commit". `project.yml` names the
    /// same two, and a test holds both Info.plists to them.
    static let revisionKey = "FediqoSourceRevision"
    static let dirtyKey = "FediqoSourceDirty"

    /// Whether the checkout differed from `revision` when the build was asked for.
    enum Changes: Equatable, Sendable {
        /// Built from exactly the commit named.
        case none
        /// The checkout had changes — edited, added or not yet tracked — that no commit records.
        case uncommitted
        /// The build said nothing either way.
        case unrecorded
    }

    /// `CFBundleShortVersionString`, as the app reports it.
    let version: String?
    /// `CFBundleVersion`, as the app reports it.
    let build: String?
    /// The whole commit hash the build was made from.
    let revision: String?
    let changes: Changes

    init(version: String?, build: String?, revision: String?, changes: Changes) {
        self.version = version
        self.build = build
        self.revision = revision
        self.changes = changes
    }

    /// Read out of an Info.plist dictionary — `Bundle.main.infoDictionary` in the app.
    init(info: [String: Any]?) {
        version = Self.stamped(info?["CFBundleShortVersionString"])
        build = Self.stamped(info?["CFBundleVersion"])
        revision = Self.stamped(info?[Self.revisionKey])
        switch Self.stamped(info?[Self.dirtyKey]) {
        case "NO": changes = .none
        case "YES": changes = .uncommitted
        default: changes = .unrecorded
        }
    }

    /// This process's own. Read once: an Info.plist does not change under a running app.
    static let main = BuildStamp(info: Bundle.main.infoDictionary)

    /// A value the build actually wrote, exactly as written, or `nil`. Empty is what
    /// `project.yml` leaves when nothing was stamped, and `$(…)` is a setting some tool failed to
    /// expand; neither is a value.
    static func stamped(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, !text.hasPrefix("$(") else { return nil }
        return text
    }

    /// One line of the page: what it is, and what this build says.
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
        /// Drawn in the monospaced reading face: a hash is read character by character.
        var isReading = false
    }

    /// What the page shows, in order. Where there is no revision there is no Changes row, since
    /// there is nothing for a change to be a change from.
    func rows(language: DummyLanguage? = nil) -> [Row] {
        let missing = L10n.t("about.missing", language: language)
        var rows = [
            Row(label: L10n.t("about.version", language: language), value: version ?? missing),
            Row(label: L10n.t("about.build", language: language), value: build ?? missing),
        ]
        guard let revision else {
            rows.append(Row(
                label: L10n.t("about.source", language: language),
                value: L10n.t("about.source.none", language: language)
            ))
            return rows
        }
        rows.append(Row(label: L10n.t("about.source", language: language), value: revision, isReading: true))
        rows.append(Row(
            label: L10n.t("about.changes", language: language),
            value: L10n.t(Self.changesKey(changes), language: language)
        ))
        return rows
    }

    static func changesKey(_ changes: Changes) -> String {
        switch changes {
        case .none: "about.changes.none"
        case .uncommitted: "about.changes.uncommitted"
        case .unrecorded: "about.missing"
        }
    }

    /// Everything the page shows, as one text for a report: a title line, then one line a row,
    /// in the page's own words and order, so what is pasted is what was read.
    func copyText(language: DummyLanguage? = nil) -> String {
        let format = L10n.t("about.line", language: language)
        let lines = rows(language: language).map { String(format: format, $0.label, $0.value) }
        return ([L10n.t("about.title", language: language)] + lines).joined(separator: "\n")
    }
}
