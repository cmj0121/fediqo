import Foundation
import Testing
@testable import FediqoCore

/// #347: the table of what a Mastodon sign-in may be asked for, and the one function that
/// makes a page's words from it.
///
/// Held against the strings a sign-in asks today (`MastodonOAuth.scopes`), which every kept
/// registration and every kept token was made with: the table has to give them back byte for
/// byte, or a sign-in made before it would read as another one.
@Suite("The parts a Mastodon sign-in may be asked for")
struct MastodonSignInPartsTests {
    private typealias Part = MastodonPart

    private static func words(_ scopes: String) -> [String] {
        scopes.split(separator: " ").map(String.init)
    }

    /// The table as it shipped. **A line here is changed only by adding one**: a part's words
    /// are what a held sign-in is read by.
    private static let shipped: [(Part, own: String, besideActing: String)] = [
        (.reading, "read:statuses read:lists read:accounts", ""),
        (.search, "read:search", ""),
        (.acting, "write:statuses write:favourites", ""),
        (.bookmarks, "write:bookmarks", ""),
        (.notices, "read:notifications", "write:notifications"),
        (.follows, "read:follows write:follows", ""),
        (.account, "write:accounts", ""),
    ]

    @Test("Every part's words are the ones it shipped with, in the order it shipped; no word belongs to two parts; and they are the words a sign-in asks today")
    func theTableHasNotMoved() {
        #expect(Part.allCases == Self.shipped.map(\.0))
        for (part, own, beside) in Self.shipped {
            #expect(part.words == Self.words(own), "\(part)")
            #expect(part.wordsBesideActing == Self.words(beside), "\(part)")
        }
        let every = Part.allCases.flatMap { $0.words + $0.wordsBesideActing }
        #expect(Set(every).count == every.count)

        #expect((Part.reading.words + Part.search.words).joined(separator: " ") == MastodonOAuth.reading)
        #expect(Part.reading.words.joined(separator: " ") == MastodonOAuth.readingWithoutSearch)
        #expect(Part.acting.words.joined(separator: " ") == MastodonOAuth.writing)
        #expect(Part.bookmarks.words == [MastodonOAuth.bookmarking])
        #expect(Part.notices.words == [MastodonOAuth.noticing])
    }

    /// What this app asked of a server for each choice before any of it was read off the table,
    /// written out word for word: every registration and every token kept was made with one of
    /// these twelve.
    private static let r = "read:statuses read:lists read:accounts"
    private static let w = "write:statuses write:favourites"
    private static let b = "write:bookmarks"
    private static let n = "read:notifications"
    private static let d = "write:notifications"

    @Test("What a page asks of a server for each of the sign-in choices is the string it was, to the byte: each choice, the same without search, without bookmarks and without either, and each part by itself")
    func whatIsAskedIsWhatWasAsked() {
        let (r, w, b, n, d) = (Self.r, Self.w, Self.b, Self.n, Self.d)
        let s = "read:search"

        let reads: [String] = ["\(r) \(s)", r]
        let sees: [String] = ["\(r) \(s) \(n)", "\(r) \(n)"]
        let acts: [String] = ["\(r) \(s) \(w) \(b)", "\(r) \(w) \(b)", "\(r) \(s) \(w)", "\(r) \(w)"]
        // Each choice, and the same without search, without bookmarks, and without either.
        func every(_ writing: Bool, _ notices: Bool) -> [String] {
            [(true, true), (false, true), (true, false), (false, false)].map {
                MastodonOAuth.scopes(search: $0.0, writing: writing, bookmarks: $0.1, notices: notices)
            }
        }
        #expect(every(false, false) == reads + reads)
        #expect(every(false, true) == sees + sees)
        #expect(every(true, false) == acts)
        let everything: [String] = ["\(r) \(s) \(w) \(b) \(n) \(d)", "\(r) \(w) \(b) \(n) \(d)", "\(r) \(s) \(w) \(n) \(d)", "\(r) \(w) \(n) \(d)"]
        #expect(every(true, true) == everything)

        #expect(MastodonOAuth.scopes(writing: false) == "\(r) \(s)")
        #expect(MastodonOAuth.scopes(writing: false, bookmarks: false) == "\(r) \(s)")
        #expect(MastodonOAuth.scopes(writing: false, notices: true) == "\(r) \(s) \(n)")
        #expect(MastodonOAuth.scopes(writing: false, bookmarks: false, notices: true) == "\(r) \(s) \(n)")
        #expect(MastodonOAuth.scopes(writing: true) == "\(r) \(s) \(w) \(b)")
        #expect(MastodonOAuth.scopes(writing: true, bookmarks: false) == "\(r) \(s) \(w)")
        #expect(MastodonOAuth.scopes(writing: true, notices: true) == everything[0])
        #expect(MastodonOAuth.scopes(writing: true, bookmarks: false, notices: true) == everything[2])

        #expect(MastodonOAuth.reading == "\(r) \(s)")
        #expect(MastodonOAuth.readingWithoutSearch == r)
        #expect(MastodonOAuth.writing == w)
        #expect(MastodonOAuth.bookmarking == b)
        #expect(MastodonOAuth.noticing == n)
    }

    @Test("What a kept sign-in is read as holding is what it was read as: by every word of a part, word by word, in any order, and never by a word that only contains one")
    func whatIsHeldIsReadAsItWas() {
        let (r, w, b, n, d) = (Self.r, Self.w, Self.b, Self.n, Self.d)
        let rows: [(String?, writes: Bool, bookmarks: Bool, notices: Bool, dismisses: Bool, searches: Bool)] = [
            (nil, false, false, false, false, false),
            ("", false, false, false, false, false),
            (r, false, false, false, false, false),
            ("\(r) read:search", false, false, false, false, true),
            ("\(r) read:search \(w)", true, false, false, false, true),
            ("write:favourites \(r) write:statuses", true, false, false, false, false),
            ("\(r) write:statuses", false, false, false, false, false),
            ("\(r) \(w) \(b)", true, true, false, false, false),
            ("\(r) \(b)", false, true, false, false, false),
            ("\(r) \(n)", false, false, true, false, false),
            ("\(r) \(w) \(n) \(d)", true, false, true, true, false),
            ("\(r) \(d)", false, false, false, true, false),
            ("read write", false, false, false, false, true),
            ("write", false, false, false, false, false),
            ("\(r) write:statuses:more write:favourites2 write:bookmarksx xread:notifications read:searches", false, false, false, false, false),
        ]
        for row in rows {
            let said = row.0 ?? "nothing"
            #expect(MastodonOAuth.writes(row.0) == row.writes, "\(said)")
            #expect(MastodonOAuth.bookmarks(row.0) == row.bookmarks, "\(said)")
            #expect(MastodonOAuth.notices(row.0) == row.notices, "\(said)")
            #expect(MastodonOAuth.dismisses(row.0) == row.dismisses, "\(said)")
            #expect(MastodonOAuth.searches(row.0) == row.searches, "\(said)")
        }
    }

    @Test("A page that widens a sign-in asks for what it holds and what was ticked, in the table's order whichever brought the word — so a sign-in reached in two steps asks the string one reached in one does")
    func aWiderPageIsOneStringHoweverReached() {
        #expect(MastodonParts.page(held: nil, ticked: []) == "")
        let reading = MastodonOAuth.scopes(writing: false)
        let acting = MastodonOAuth.scopes(writing: true)
        let actingBare = MastodonOAuth.scopes(writing: true, bookmarks: false)
        let noticing = MastodonOAuth.scopes(writing: false, notices: true)
        let everything = MastodonOAuth.scopes(writing: true, notices: true)

        #expect(MastodonParts.page(held: reading, ticked: [.acting, .bookmarks]) == acting)
        #expect(MastodonParts.page(held: actingBare, ticked: [.bookmarks]) == acting)
        #expect(MastodonParts.page(held: reading, ticked: [.notices]) == noticing)
        #expect(MastodonParts.page(held: acting, ticked: [.notices]) == everything)
        #expect(MastodonParts.page(held: noticing, ticked: [.acting, .bookmarks]) == everything)
        #expect(MastodonParts.page(held: MastodonOAuth.readingWithoutSearch, ticked: [.search]) == reading)

        // Held in another order, or ticking what is held: the same string.
        let turned = Self.words(acting).reversed().joined(separator: " ")
        #expect(MastodonParts.page(held: turned, ticked: [.reading, .notices]) == everything)
        #expect(MastodonParts.page(held: acting, ticked: []) == acting)
    }

    @Test("Nothing rides along: a rider never answered is not added by a page about another part, and dismissing is asked only where notices or acting is what was ticked and both are then held")
    func nothingRidesAlong() {
        let actingBare = MastodonOAuth.scopes(writing: true, bookmarks: false)
        let withoutSearch = MastodonOAuth.readingWithoutSearch
        #expect(MastodonParts.page(held: actingBare, ticked: [.notices])
            == MastodonOAuth.scopes(writing: true, bookmarks: false, notices: true), "no bookmarks unticked")
        #expect(MastodonParts.page(held: withoutSearch, ticked: [.notices]) == "\(withoutSearch) read:notifications", "no search unticked")

        // Reading alone is never asked to dismiss.
        #expect(!MastodonOAuth.dismisses(MastodonParts.page(held: MastodonOAuth.reading, ticked: [.notices])))
        // Holding both, and never asked to dismiss: a page about something else does not ask.
        let both = "\(actingBare) read:notifications"
        #expect(MastodonParts.page(held: both, ticked: [.bookmarks]) == "\(MastodonOAuth.scopes(writing: true)) read:notifications")
        // Half of acting is not acting.
        let half = "\(MastodonOAuth.reading) write:statuses"
        #expect(MastodonParts.page(held: half, ticked: [.notices]) == "\(half) read:notifications")
        // Once held it is carried, as every held word is.
        let dismissing = MastodonOAuth.scopes(writing: true, bookmarks: false, notices: true)
        #expect(MastodonParts.page(held: dismissing, ticked: [.bookmarks]) == MastodonOAuth.scopes(writing: true, notices: true))
    }

    @Test("A held word the table does not know is on no page — the whole of reading, as a source names what an older or another app's token holds, among them — and no page names a word that is neither held nor a ticked part's")
    func anUnknownHeldWordIsLeftOut() {
        let reading = MastodonOAuth.reading
        #expect(MastodonParts.page(held: "\(reading) read:mutes write:nonsense", ticked: [.notices]) == "\(reading) read:notifications")
        #expect(MastodonParts.page(held: "read write", ticked: [.reading]) == MastodonOAuth.readingWithoutSearch)
        // What a real source said a sign-in for everything holds (`MastodonSignInCaptures.wholeInfo`).
        #expect(MastodonParts.page(held: "read write", ticked: []) == "")

        let known = Set(Part.allCases.flatMap { $0.words + $0.wordsBesideActing })
        let helds: [String?] = [nil, reading, MastodonOAuth.scopes(writing: true), MastodonOAuth.scopes(writing: true, notices: true), "read write:statuses"]
        let ticks: [Set<Part>] = [[], [.reading], [.search], [.acting], [.bookmarks], [.notices], [.acting, .notices], Set(Part.allCases)]
        for held in helds {
            let had = Set(Self.words(held ?? ""))
            for ticked in ticks {
                let named = Set(ticked.flatMap { $0.words + $0.wordsBesideActing })
                let page = Set(Self.words(MastodonParts.page(held: held, ticked: ticked)))
                let allowed = had.intersection(known).union(named)
                #expect(page.isSubset(of: allowed), "\(held ?? "nothing") + \(ticked.map(\.rawValue).sorted())")
                let carried = had.intersection(known)
                #expect(page.isSuperset(of: carried), "nothing held and known is dropped")
            }
        }
    }

    /// Sign-ins as this app, an earlier build of it, a package or another app could have left
    /// them: nothing written down; reading with and without search; acting with and without
    /// bookmarks; each with notices; each with follows, whole and in half; a part held in
    /// half; words this build's table has no part for, whole and in half; the source's one
    /// word for every read and every write; and one held in another order.
    private static var helds: [String?] {
        let (r, w, b, n, d) = (Self.r, Self.w, Self.b, Self.n, Self.d)
        let plain = [r, "\(r) read:search", "\(r) \(w)", "\(r) read:search \(w)", "\(r) \(w) \(b)", "\(r) read:search \(w) \(b)"]
        var all: [String?] = [nil, ""]
        for held in plain {
            all.append(held)
            all.append("\(held) \(n)")
            if held.contains(w) { all.append("\(held) \(n) \(d)") }
            all.append("\(held) read:follows write:follows")
            all.append("\(held) read:follows")
            all.append("\(held) read:mutes write:mutes")
            all.append("\(held) read:mutes")
        }
        all += ["\(r) write:statuses", "read:statuses", "read write", "read", "write", "\(r) write", "read \(w) \(b)"]
        all.append("\(d) \(n) \(b) write:favourites write:statuses read:search read:accounts read:lists read:statuses")
        return all
    }

    private static var everyTick: [Set<Part>] {
        (0 ..< (1 << Part.allCases.count)).map { bits in
            Set(Part.allCases.enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element))
        }
    }

    @Test("Over every sign-in a device could hold, every set of parts ticked and both answers to read-or-act, a page carries no word its question did not name: only what is held and known, and the words of what was ticked; a rider only where ticked; no word that acts where the answer was to read only; and each word once, in the table's order")
    func noPageCarriesAWordItsQuestionDidNotName() {
        let table = Self.shipped.flatMap { Self.words($0.own) + Self.words($0.besideActing) }
        let acting = Set(Self.words(Self.w))
        for held in Self.helds {
            let had = Set(Self.words(held ?? ""))
            let carried = had.intersection(table)
            for ticked in Self.everyTick {
                for readOnly in [false, true] {
                    let asked = MastodonParts.page(held: held, ticked: ticked, readOnly: readOnly)
                    let page = Self.words(asked)
                    let said = "\(held ?? "nothing") + \(ticked.map(\.rawValue).sorted()) read only: \(readOnly) → \(asked)"

                    var named = Set(ticked.flatMap(\.words))
                    if ticked.contains(.notices) || ticked.contains(.acting) { named.insert(Self.d) }
                    #expect(Set(page).isSubset(of: carried.union(named)), "\(said)")

                    let bookmarksNamed: Bool = had.contains(Self.b) || ticked.contains(.bookmarks)
                    let bookmarksRode: Bool = page.contains(Self.b) && !bookmarksNamed
                    #expect(!bookmarksRode, "\(said)")
                    let searchNamed: Bool = had.contains("read:search") || ticked.contains(.search)
                    let searchRode: Bool = page.contains("read:search") && !searchNamed
                    #expect(!searchRode, "\(said)")
                    let both: Bool = acting.isSubset(of: page) && page.contains(Self.n)
                    let dismissingNamed: Bool = had.contains(Self.d) || both
                    let dismissingRode: Bool = page.contains(Self.d) && !dismissingNamed
                    #expect(!dismissingRode, "\(said)")

                    let acts = page.filter { $0.hasPrefix("write") }
                    let reads = carried.filter { $0.hasPrefix("read:") }
                    if readOnly {
                        #expect(acts.isEmpty, "\(said)")
                        #expect(Set(page).isSuperset(of: reads), "\(said)")
                    } else {
                        #expect(Set(page).isSuperset(of: carried), "\(said)")
                    }

                    let places = page.compactMap { table.firstIndex(of: $0) }
                    #expect(places == places.sorted(), "\(said)")
                    #expect(Set(places).count == page.count, "\(said)")
                }
            }
        }
    }

    @Test("Answering read only asks for no word that acts: what was held to act is dropped, the ones granted in place among them, and every word held to read is kept — while read and act keeps everything held")
    func readOnlyDropsEveryWordThatActs() {
        let (r, w, b, n, d) = (Self.r, Self.w, Self.b, Self.n, Self.d)
        let reads: Set<Part> = [.reading, .search]
        let everything = "\(r) read:search \(w) \(b) \(n) \(d)"
        #expect(MastodonParts.page(held: everything, ticked: reads, readOnly: true) == "\(r) read:search \(n)")
        #expect(MastodonParts.page(held: "\(r) \(w)", ticked: reads, readOnly: true) == "\(r) read:search")
        #expect(MastodonParts.page(held: nil, ticked: reads, readOnly: true) == MastodonOAuth.reading)
        #expect(MastodonParts.page(held: nil, ticked: reads.union([.notices]), readOnly: true) == MastodonOAuth.scopes(writing: false, notices: true))
        // Ticking what acts beside that answer asks for none of it: of follows, the word that reads.
        #expect(MastodonParts.page(held: everything, ticked: Set(Part.allCases), readOnly: true) == "\(r) read:search \(n) read:follows")
        #expect(MastodonParts.page(held: nil, ticked: [.acting, .bookmarks], readOnly: true) == "")

        let acts = reads.union([.acting, .bookmarks])
        #expect(MastodonParts.page(held: everything, ticked: acts) == everything)
        #expect(MastodonParts.page(held: "\(r) \(n)", ticked: acts) == everything)
    }

    @Test("The source's one word for every read, or for every write, is a word the table does not know: it is on no page and is not spelt out into the words it covers, so a page asks for those only where they were ticked")
    func aCoarseHeldWordIsNotSpeltOut() {
        let (r, w, n) = (Self.r, Self.w, Self.n)
        #expect(MastodonParts.page(held: "read", ticked: []) == "")
        #expect(MastodonParts.page(held: "write", ticked: []) == "")
        #expect(MastodonParts.page(held: "read write", ticked: [.notices]) == n)
        #expect(MastodonParts.page(held: "read write", ticked: [.reading, .notices]) == "\(r) \(n)", "holding every write is not holding the acting part: dismissing is not asked")
        #expect(MastodonParts.page(held: "read \(w)", ticked: [.reading, .notices]) == "\(r) \(w) \(n) write:notifications")
        #expect(MastodonParts.page(held: "\(r) write", ticked: [.search]) == "\(r) read:search")
        #expect(MastodonParts.page(held: "read write", ticked: [.reading, .search], readOnly: true) == MastodonOAuth.reading)
        // Read as held for searching, as before; never as a part held.
        #expect(MastodonOAuth.searches("read"))
        #expect(!MastodonOAuth.writes("write"))
        #expect(!MastodonOAuth.notices("read"))
        #expect(!MastodonParts.holds(.reading, in: "read"))
        #expect(!MastodonParts.holds(.acting, in: "write"))
    }

    @Test("A part is held by every one of its words and by nothing less")
    func aPartIsHeldByEveryWord() {
        for part in Part.allCases {
            let own = part.words.joined(separator: " ")
            #expect(MastodonParts.holds(part, in: own), "\(part)")
            #expect(MastodonParts.holds(part, in: "other:word \(part.words.reversed().joined(separator: " "))"), "\(part)")
            #expect(!MastodonParts.holds(part, in: part.words.dropLast().joined(separator: " ")), "\(part)")
            #expect(!MastodonParts.holds(part, in: nil), "\(part)")
            #expect(!MastodonParts.holds(part, in: ""), "\(part)")
            #expect(!MastodonParts.holds(part, in: own + "x"), "\(part)")
        }
        #expect(MastodonParts.holdsBesideActing(.notices, in: "write:notifications"))
        #expect(!MastodonParts.holdsBesideActing(.notices, in: "read:notifications"))
        #expect(!MastodonParts.holdsBesideActing(.acting, in: "write:statuses write:favourites"), "a part with no such word holds none")
    }

    @Test("One place alone makes the words a page asks for: no file but the table's spells a scope word, and the files a sign-in is made in join no words into a string but to narrow what was asked by what was answered")
    func oneMakerOfAPagesWords() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root.deleteLastPathComponent()
        }
        let sources = root.appending(path: "Sources")
        let word = try Regex(#""[^"]*\b(read|write|follow|push|profile|admin):[a-z_]+[^"]*""#)
        let coarse = try Regex(#""(read|write)""#)
        var spelt: [String] = []
        var joins: [String: Int] = [:]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let name = file.lastPathComponent
            let core = file.path.contains("/FediqoCore/")
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if name != "MastodonParts.swift", line.contains(word) || (core && line.contains(coarse)) {
                    spelt.append("\(name):\(number + 1)")
                }
                if line.contains(#"joined(separator: " ")"#) { joins[name, default: 0] += 1 }
            }
        }
        #expect(spelt.isEmpty, "a scope word is spelt in \(spelt)")
        #expect(joins["MastodonParts.swift"] == 1, "the table's file joins words in \(joins["MastodonParts.swift"] ?? 0) places")
        #expect(joins["MastodonAuth.swift"] == 1, "MastodonAuth.swift joins words in \(joins["MastodonAuth.swift"] ?? 0) places")
        for name in ["MastodonTokens.swift", "Writing.swift", "MastodonSignIn.swift"] {
            #expect(joins[name] == nil, "\(name) joins words")
        }
        // What is registered for, and what a page asks on a registration, are each the table's
        // words with some taken away: by the host's own list, and by what the registration holds.
        let registration = try String(contentsOf: sources.appending(path: "FediqoCore/MastodonRegistration.swift"), encoding: .utf8)
        let joining = registration.split(separator: "\n").filter { $0.contains(#"joined(separator: " ")"#) }
        #expect(joining.count == 2 && joining.allSatisfy { $0.contains(".filter(") }, "a registration's words are made, not narrowed")

        let auth = try String(contentsOf: sources.appending(path: "FediqoCore/MastodonAuth.swift"), encoding: .utf8)
        let narrowing = try #require(auth.components(separatedBy: "static func named(").dropFirst().first)
        #expect(narrowing.components(separatedBy: "\n    }\n").first?.contains(#"joined(separator: " ")"#) == true, "the one join is not the narrowing")
        let choice = try #require(auth.components(separatedBy: "public static func scopes(").dropFirst().first)
        #expect(choice.components(separatedBy: "\n    }\n").first?.contains("MastodonParts.page(") == true, "a choice's words are not the page's")
    }
}
