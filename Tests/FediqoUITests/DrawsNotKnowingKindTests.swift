import FediqoCore
import Foundation
import Testing

/// A file that draws does not learn which kind of source it draws for (#289, held where it can
/// be held until the one shared way of asking is built).
///
/// Read off the source, by two rules of thumb, each told from a file's text with its comments
/// gone — a line that is only a comment, and what follows a `//` that stands after a space:
///
/// - **A file draws** when it declares a view: it spells `: View` or `some View`.
/// - **A file knows the kind** when it names a `Mastodon…` type, `ProtocolKind`, or a kind
///   outright — `.mastodon`, `.discuz` and every other case of `ProtocolKind` but `.unknown`,
///   which other things than a kind are called too. The cases are asked of `ProtocolKind`
///   itself, so a kind added later is held to this with nothing changed here. Whatever is
///   reached by a kind's name counts with them: `session.mastodon`, `reach.discuz(…)`.
///
/// A file under `Sources/FediqoUI` that does both fails this, unless it is one of the files
/// that did on the day the rule was written — and those are a list that may only shrink. A new
/// file that draws is held to it by being there: nothing is added anywhere for it.
///
/// What this cannot tell: a file that only asks, which goes on holding a Mastodon client; a
/// forum's own types, which no rule here names; a kind decided in a file that does not draw
/// and handed to one that does. And a name that stands inside a string is taken for one in
/// the code.
@Suite("A file that draws does not know which kind of source it draws for")
struct DrawsNotKnowingKindTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Where the files held to this are, from the repository's root.
    private static let held = "Sources/FediqoUI"

    /// The files that drew and knew the kind on 2026-10-13, each by how many times it names
    /// one. **Nothing is added here, and no count is raised**: a file that draws reads whether
    /// something is offered from `SourceOffers`. A count that falls is lowered here, and a file
    /// that no longer does both is taken off, so what is left is what is still to undo.
    private static let knewThen: [String: Int] = [
        "Sources/FediqoUI/FediqoRootView.swift": 8,
        "Sources/FediqoUI/Shell/AccountPane.swift": 4,
        "Sources/FediqoUI/Shell/ComposerSheet.swift": 1,
        "Sources/FediqoUI/Shell/ForumPosts.swift": 1,
        "Sources/FediqoUI/Shell/JoinSheet.swift": 10,
        "Sources/FediqoUI/Shell/MastodonLeftNotice.swift": 5,
        "Sources/FediqoUI/Shell/NoticeActs.swift": 2,
        "Sources/FediqoUI/Shell/NoticesPane.swift": 3,
        "Sources/FediqoUI/Shell/SearchFound.swift": 13,
        "Sources/FediqoUI/Shell/ShellFollowedTags.swift": 18,
        "Sources/FediqoUI/Shell/ShellMore.swift": 40,
        "Sources/FediqoUI/Shell/ShellPartAsk.swift": 33,
        "Sources/FediqoUI/Shell/ShellReadOn.swift": 9,
        "Sources/FediqoUI/Shell/ShellReload.swift": 55,
        "Sources/FediqoUI/Shell/SourceMark.swift": 14,
        "Sources/FediqoUI/Shell/SourcePreviewView.swift": 24,
        "Sources/FediqoUI/Shell/SourceRow.swift": 37,
        "Sources/FediqoUI/Shell/TimelinePane.swift": 1,
        "Sources/FediqoUI/Shell/UsageSources.swift": 3,
    ]

    /// `text` with its comments gone and its white space folded.
    static func folded(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            // What follows on a line of code. After a space, so an address in a string stays whole.
            .map { line in line.range(of: " //").map { line[..<$0.lowerBound] } ?? line }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func matches(_ pattern: String, in folded: String) -> [String] {
        // The system's, as `GuardedTests` reads the source.
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.matches(in: folded, range: NSRange(folded.startIndex..., in: folded))
            .compactMap { Range($0.range, in: folded).map { String(folded[$0]) } }
    }

    /// Whether `text` declares a view.
    static func draws(_ text: String) -> Bool {
        !matches(#"(: |\bsome )View\b"#, in: folded(text)).isEmpty
    }

    /// Each time `text` names which kind of source it is for, as it is spelled.
    static func kindsNamed(in text: String) -> [String] {
        let kinds = ProtocolKind.allCases.filter { $0 != .unknown }.map(\.rawValue).joined(separator: "|")
        return matches(#"\bMastodon[A-Z]\w*|\bProtocolKind\b|\.(?:"# + kinds + #")\b"#, in: folded(text))
    }

    /// What is wrong with `files` against `listed`, each said so that it says what to do.
    static func complaints(of files: [(path: String, text: String)], listed: [String: Int]) -> [String] {
        var said: [String] = []
        var seen: Set<String> = []
        for file in files.sorted(by: { $0.path < $1.path }) where draws(file.text) {
            let named = kindsNamed(in: file.text)
            guard !named.isEmpty else { continue }
            seen.insert(file.path)
            let which = Set(named).sorted().joined(separator: ", ")
            guard let allowed = listed[file.path] else {
                said.append(
                    "\(file.path) draws, and names which kind of source it draws for: \(which). "
                        + "Whether something is offered at a source is read from `SourceOffers`, which answers for every kind; "
                        + "a file is not added to the list for it."
                )
                continue
            }
            if named.count > allowed {
                said.append(
                    "\(file.path) draws, and names a kind of source \(named.count) times, more than the \(allowed) it is listed with: \(which). "
                        + "Whether something is offered at a source is read from `SourceOffers`; the count is not raised for it."
                )
            } else if named.count < allowed {
                said.append("\(file.path) names a kind of source \(named.count) times now, not \(allowed): lower its count in the list to \(named.count).")
            }
        }
        for path in listed.keys.sorted() where !seen.contains(path) {
            said.append("\(path) no longer both draws and names a kind of source: take it off the list.")
        }
        return said
    }

    /// Every Swift file held to this, by its path from the repository's root.
    private static func sources() throws -> [(path: String, text: String)] {
        let walk = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(held), includingPropertiesForKeys: nil))
        return try walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { file in
            (String(file.path.dropFirst(root.path.count + 1)), try String(contentsOf: file, encoding: .utf8))
        }
    }

    @Test("Each way of naming a kind is one the reading of the source catches", arguments: [
        "let client = MastodonClient(base: source.baseURL)",
        "let follows: MastodonTagFollows",
        "func mark(_ kind: ProtocolKind) -> String",
        "if source.kind == .mastodon { Button(title, action: follow) }",
        "switch kind { case .discuz, .discourse: BoardPicker() default: EmptyView() }",
        "guard source.kind != .misskey else { return }",
        "let signedIn = session.mastodon.isSignedIn(host: source.host)",
        "let client = session.reach.discuz(host, for: .timeline, within: deadline)",
        "let shown = sources.filter { $0.kind == .lemmy } // the ones with boards",
    ])
    func caught(line: String) {
        #expect(!Self.kindsNamed(in: "    \(line)\n").isEmpty)
    }

    @Test("What `SourceOffers` answers, a comment, a longer name, the word itself and a kind nobody knows are not")
    func notCaught() {
        let fine = """
            if source.kind.offers.people { Button(title, action: follow) }
            // if source.kind == .mastodon { … }
            /// A `MastodonClient` is held by the file that asks, not by this one.
            let said = offers.writes // not `.mastodon`, and not `ProtocolKind`
            let mark = row.mastodonish
            let other: NotProtocolKind = .mastodonLike
            let title = "Mastodon"
            if quote.state == .unknown { EmptyView() }
            """
        #expect(Self.kindsNamed(in: fine).isEmpty, "\(Self.kindsNamed(in: fine))")
    }

    @Test("A file draws when it declares a view, and not when it only speaks of one", arguments: [
        ("struct FollowButton: View {", true),
        ("var body: some View {", true),
        ("func marked() -> some View {", true),
        ("struct Row<Content: View>: Equatable {", true),
        ("/// Drawn by `PersonPane`, a `View`.", false),
        ("// struct FollowButton: View {", false),
        ("func follow(_ person: Person) async { } // pressed in a View", false),
        ("let preview: Preview", false),
        ("struct Overview: Sendable {", false),
    ])
    func drawing(line: String, draws: Bool) {
        #expect(Self.draws("    \(line)\n") == draws)
    }

    @Test("A new file that draws and knows is refused, with where the answer belongs; one that only asks, or only draws, is not")
    func aNewFile() {
        let knows = "    let client = MastodonClient(base: base)\n    if kind == .mastodon { }\n"
        let drawing = "struct FollowButton: View {\n    var body: some View { EmptyView() }\n"
        let said = Self.complaints(of: [
            ("Sources/FediqoUI/Shell/Asks.swift", knows),
            ("Sources/FediqoUI/Shell/Draws.swift", drawing + "}\n"),
            ("Sources/FediqoUI/Shell/Both.swift", drawing + knows + "}\n"),
        ], listed: [:])
        #expect(said.count == 1)
        let both = said.first ?? ""
        #expect(both.hasPrefix("Sources/FediqoUI/Shell/Both.swift draws"))
        #expect(both.contains(".mastodon, MastodonClient") && both.contains("`SourceOffers`"))
    }

    @Test("A listed file may name a kind as often as it did: more is refused, fewer asks for the count lowered, and none for the file taken off")
    func theListOnlyShrinks() {
        let path = "Sources/FediqoUI/Shell/Listed.swift"
        func file(naming times: Int) -> [(path: String, text: String)] {
            [(path, "struct Listed: View {\n" + String(repeating: "    if kind == .discuz { }\n", count: times) + "}\n")]
        }
        #expect(Self.complaints(of: file(naming: 2), listed: [path: 2]).isEmpty)

        let more = Self.complaints(of: file(naming: 3), listed: [path: 2])
        #expect(more.count == 1)
        #expect(more.first?.contains("3 times, more than the 2 it is listed with") == true && more.first?.contains("`SourceOffers`") == true)

        #expect(Self.complaints(of: file(naming: 1), listed: [path: 2]) == ["\(path) names a kind of source 1 times now, not 2: lower its count in the list to 1."])
        #expect(Self.complaints(of: file(naming: 0), listed: [path: 2]) == ["\(path) no longer both draws and names a kind of source: take it off the list."])
        #expect(Self.complaints(of: [], listed: [path: 2]) == ["\(path) no longer both draws and names a kind of source: take it off the list."])
    }

    @Test("No file of the screens that draws names a kind of source, but the ones that did — and none of those more than it did")
    func theSource() throws {
        let files = try Self.sources()
        #expect(files.count > 100, "the source was found")
        #expect(files.filter { Self.draws($0.text) }.count > 50, "and what draws in it is told")
        // The two a person's page is drawn by, which following is about to change.
        for name in ["PersonPane.swift", "PersonRow.swift"] {
            let file = try #require(files.first { $0.path == "\(Self.held)/Shell/\(name)" })
            #expect(Self.draws(file.text), "\(name) is a file that draws")
        }
        let said = Self.complaints(of: files, listed: Self.knewThen)
        #expect(said.isEmpty, "\(said.joined(separator: "\n"))")
    }
}
