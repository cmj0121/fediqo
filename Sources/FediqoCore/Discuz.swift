import Foundation

/// A Discuz! forum, read the way this app reads everything else — one unauthenticated GET — and
/// unlike everything else, read out of **markup rather than a document**.
///
/// **There is no API to ask.** Discourse publishes `/latest.json` and five forums out of six
/// answer it; Discuz! publishes nothing a client may rely on. Measured on three open installs
/// (`install-a.example` X3.4, `install-b.example` X3.5, `install-c.example` X5.0) plus `install-e.example`:
/// `/api/mobile/index.php?module=forumindex` is **404** on every one of them — the mobile JSON
/// API is an administrator's setting and it is off by default — and `forum.php?mod=rss` is either
/// the literal words `RSS Disabled` or the ordinary HTML page with no feed in it at all. What is
/// left is the page a reader sees, so that is what is read.
///
/// **Which page.** `/forum.php?mod=guide&view=newthread` — 最新发表, the newest threads across
/// every board — is this forum's front page, and it is Discourse's `/latest.json` in the one way
/// that matters: fifty discussions, each naming its own board, in one request. Its sibling
/// `view=new` (最新回复) is ordered by the last reply instead, and was deliberately not used:
/// a row here stores **when the thread was posted**, so a list ordered by other people's answers
/// would hand the reader a page of years-old threads wearing today's position. Measured on
/// `install-c.example`, the first row of `view=new` was posted in 2024.
///
/// **What varies, and what does not.** Three installs, three major versions, and no two of them
/// address a thread the same way — `thread-620795-1-1.html`, `forum.php?mod=viewthread&tid=…`,
/// and on `install-b.example` an SEO slug, `-paid-discuz-x5-0-english-language-pack-82-1-1.html`.
/// What all three share is the table: `<tbody id="normalthread_<tid>">` around a row whose cells
/// are `td.icn`, `th`, then the `td.by` / `td.num` run this file reads. So the **structure** is
/// what is parsed and the **addresses are not read at all** — see `DiscuzThread.asNote`.
public struct DiscuzClient: Sendable {
    private let http: any HTTPClient
    private let host: String

    public init(http: any HTTPClient, host: String) {
        self.http = http
        self.host = host
    }

    /// The forum's front page: the newest threads, from every board, newest first.
    public func latest(source: Source) async throws -> [Note] {
        guard let url = Host.httpsURL(
            host: host,
            path: "/forum.php",
            query: [
                URLQueryItem(name: "mod", value: "guide"),
                URLQueryItem(name: "view", value: "newthread"),
            ]
        ) else {
            throw DiscuzRequestError.invalidURL
        }
        return try await read(url, source: source)
    }

    /// One board's thread list.
    ///
    /// The same page as the guide with one column fewer, and the same parser reads both. A board
    /// listing names its board **once**, in the heading, because every row on it is in the same
    /// board; the guide page names it per row.
    ///
    /// `named` is what the index called this board, and it is a *fallback* for the heading rather
    /// than a replacement for it: the page's own `<h1>` is the board's current name as the forum
    /// spells it today, and a name the reader subscribed to months ago may be stale. It is used
    /// only where the page named no board at all.
    public func board(_ fid: Int, source: Source, named: String? = nil) async throws -> [Note] {
        guard let url = Host.httpsURL(
            host: host,
            path: "/forum.php",
            query: [
                URLQueryItem(name: "mod", value: "forumdisplay"),
                URLQueryItem(name: "fid", value: String(fid)),
            ]
        ) else {
            throw DiscuzRequestError.invalidURL
        }
        return try await read(url, source: source, named: named, boardID: String(fid))
    }

    /// One subscribed board's thread list — what a reader who picked this board is reading.
    ///
    /// **The address is built from the board's number, and the number came off the index.** Three
    /// of the four installs measured do not write `forum.php?mod=forumdisplay&fid=N` on their own
    /// index at all — they write `forum-37-1.html`, or an SEO slug `37-1/news-feed.html` — and all
    /// four answer the canonical address regardless, because rewriting is a rule about the links a
    /// Discuz! *writes*, not about the addresses it *serves*. So the number is read out of
    /// whichever shape the page used and the address is built here, which keeps `DiscuzClient`'s
    /// standing rule: no address in this file came out of a stranger's markup.
    public func threads(board: DiscuzBoard, source: Source) async throws -> [Note] {
        try await self.board(board.fid, source: source, named: board.name)
    }

    /// The forum's index: every category a signed-out — or signed-in — reader may see, and the
    /// boards under it.
    ///
    /// **It takes no `Source`, and that is the point of it.** D28: a forum join pauses here. The
    /// reader has to be shown what there is before there is anything to subscribe to, and nothing
    /// is added to the store until they have picked — so this is the one read in this file that
    /// happens before a `Source` exists. See `DiscuzBoardJoin`.
    public func boards() async throws -> [DiscuzCategory] {
        guard let url = Host.httpsURL(host: host, path: "/forum.php") else {
            throw DiscuzRequestError.invalidURL
        }
        let html = try await page(url)
        let categories = DiscuzIndex.categories(in: html)
        // The same rule `read` states for an empty thread table, for the same reason and with the
        // same evidence behind it. `install-e.example` serves a signed-out reader a real, complete
        // Discuz! index page with **no forum list on it at all** — what it has instead is one
        // hand-written block whose id is `category_-99999`, holding a bus timetable, a calendar
        // and one board. A parser whose answer to that is `[]` would show the reader an empty
        // picker and no reason for it.
        guard !categories.isEmpty else { throw DiscuzRequestError.noBoards }
        return categories
    }

    /// One page fetched, decoded, and judged — everything the two readers below share.
    ///
    /// The order of the four judgements is the whole of this function and none of it is arbitrary.
    ///
    /// 1. **Decode before anything else**, because a page whose bytes are not UTF-8 is not a
    ///    broken page — it is an ordinary GBK Discuz!, and a reader that only tried UTF-8 would
    ///    call the whole forum unreadable. See `DiscuzHTML.text`.
    /// 2. **The challenge is judged before the status**, because a challenge arrives dressed as
    ///    anything: 403 on `challenge.example`, and 200 elsewhere. Reading the status first
    ///    would file the 200 case under "a page with no threads in it", which is exactly the
    ///    failure this ordering exists to prevent.
    /// 3. **Then the status**, so a plain refusal keeps its own number.
    /// 4. **Then Discuz!'s own notice page**, which is a 200 with real Discuz! markup in it and no
    ///    table — the forum telling this reader, in its own words, that they may not read this.
    ///    Every board on `install-e.example` answers a signed-out reader with one.
    ///
    /// Written once and called twice rather than restated at each door: this branch's second
    /// convention is that a rule enforced at each consumer is a rule consumer N+1 misses, and the
    /// index reader *is* consumer N+1 to the thread reader.
    private func page(_ url: URL) async throws -> String {
        let (data, response) = try await http.data(from: url)
        guard let html = DiscuzHTML.text(data, response) else {
            throw DiscuzRequestError.undecodable
        }
        if DiscuzPage.isChallenge(html) { throw DiscuzRequestError.challenged }
        try Self.check(response.statusCode)
        if DiscuzPage.isRestricted(html) { throw DiscuzRequestError.restricted }
        return html
    }

    /// One page fetched, judged by `page`, and turned into rows.
    private func read(
        _ url: URL,
        source: Source,
        named: String? = nil,
        boardID: String? = nil
    ) async throws -> [Note] {
        let html = try await page(url)

        let rows = DiscuzPage.threads(in: html)
        // **An empty list is the one answer this must never give.** A parser that meets markup it
        // cannot read and returns `[]` hands the reader a forum that draws nothing, forever, with
        // no error to explain it — and it cannot be told from a forum that really is empty,
        // because the markup for the two is the same markup. Of the two mistakes available, "we
        // could not read that" is the one the reader can act on, and the one a bug report can be
        // written about. This is also the backstop under judgement 2: a challenge page nobody has
        // taught `isChallenge` about still fails here rather than joining silently.
        // **A board a signed-out reader cannot read as a list is not an empty board either.**
        // Measured on `install-a.example`, board 37: the forum's own per-board display style is
        // Discuz!'s picture mode, so the thread table is served empty and the threads arrive as
        // `<ul id="waterfall">` cards instead — no date on any of them. `&forumdefstyle=no`, `=0`
        // and `=list` were each tried live and none of them turns it back into a table. Reading
        // those cards would put fifty rows in the store all dated `.distantPast`, which is a
        // worse answer than none: they would sort under everything the reader has forever. So
        // this stays `noThreads`, which is true, and the reader is told.
        guard !rows.isEmpty else { throw DiscuzRequestError.noThreads }

        let heading = DiscuzPage.boardHeading(in: html) ?? named
        // The number, where this read was a board's own page. A cross-board listing passes
        // nothing, because its rows name a section but carry no id — see `Note.boardID`.
        return rows.map { $0.asNote(source: source, host: host, board: heading, boardID: boardID) }
    }

    /// Turns a status code into the one distinction that changes what a reader should be told.
    ///
    /// Word for word the rule `DiscourseClient.check` states, and deliberately not shared with it:
    /// the two forums are different programs, and a status list that drifted apart later would be
    /// harder to find inside one helper than beside the client it belongs to. A filter in front of
    /// the forum answers 401, 403, 429 or 503; a host that has no `/forum.php` answers 404. The
    /// first is a door somebody closed, the second is a host that is not a Discuz!.
    static func check(_ status: Int) throws {
        guard !(200..<300).contains(status) else { return }
        switch status {
        case 401, 403, 429, 503: throw DiscuzRequestError.refused(status)
        default: throw DiscuzRequestError.http(status)
        }
    }
}

public enum DiscuzRequestError: Error, Equatable, Sendable {
    case invalidURL
    /// The bytes were not text in UTF-8, in whatever the server declared, or in GB18030.
    case undecodable
    /// A filter's interactive challenge page, whatever status it arrived with.
    case challenged
    /// The forum's own notice page: it answered, it is a Discuz!, and it says this reader may not
    /// read this. Apart from `challenged` because nothing is in front of the forum — the forum
    /// itself is the thing saying no, and an account is what would change the answer.
    case restricted
    /// The server answered with a status that says no, in the way a filter says it. See `check`.
    case refused(Int)
    case http(Int)
    /// It answered, it decoded, it was not a challenge and not a notice, and there was no thread
    /// in it. See the guard in `read`.
    case noThreads
    /// The same thing one page up: a forum index with no board on it that this reader may see.
    /// Its own case rather than `noThreads` because the two are answers to different questions —
    /// "this board has nothing in it" against "this forum has no boards for you" — and the second
    /// is the one where signing in is what would change the answer. See the guard in `boards`.
    case noBoards
}

// MARK: - The board index

/// One board on a forum's index: a number, a name, and what lets a reader choose it.
///
/// **`fid` is the identity and the name is not.** A forum renames a board whenever a moderator
/// feels like it, and the number it is served at never changes — so a subscription is a number,
/// and the name is what is drawn beside it.
///
/// **Nothing is not zero.** `threads`, `posts` and `lastPostAt` are what let a reader choose
/// between forty boards, and every one of them is absent on some template: `install-b.example`
/// writes a bare `...` where a board has never been posted in, and an abbreviated count —
/// `5万`, fifty thousand — is only a number at all because the same element carries the exact
/// figure in a `title`. Where the forum did not say a thing this device can read, this says
/// nothing, rather than a zero a reader would take for a fact about the board.
public struct DiscuzBoard: Identifiable, Hashable, Sendable {
    public var id: Int { fid }
    public let fid: Int
    public let name: String
    /// The category this board sits under, as the index's own heading spells it.
    public let category: String
    /// The category's number. Carried so that a flat list of forty boards can be grouped back
    /// the way the forum grouped them even where two categories share a name.
    public let gid: Int
    /// How many threads, where the page said a number this device could read.
    public let threads: Int?
    /// How many posts — every reply in every thread — on the same terms.
    public let posts: Int?
    /// When somebody last posted in it, where the page said. Read the way every other Discuz!
    /// date here is read, and UTC for the same reason: see `DiscuzDate`.
    public let lastPostAt: Date?

    public init(
        fid: Int,
        name: String,
        category: String,
        gid: Int,
        threads: Int? = nil,
        posts: Int? = nil,
        lastPostAt: Date? = nil
    ) {
        self.fid = fid
        self.name = name
        self.category = category
        self.gid = gid
        self.threads = threads
        self.posts = posts
        self.lastPostAt = lastPostAt
    }
}

/// A section of the index, and the boards the forum put under it.
public struct DiscuzCategory: Identifiable, Hashable, Sendable {
    public var id: Int { gid }
    public let gid: Int
    public let name: String
    public let boards: [DiscuzBoard]

    public init(gid: Int, name: String, boards: [DiscuzBoard]) {
        self.gid = gid
        self.name = name
        self.boards = boards
    }
}

extension BoardSubscription {
    /// What the reader picked, kept as the two things that outlive the page it was read off.
    public init(_ board: DiscuzBoard) {
        self.init(fid: board.fid, name: board.name)
    }
}

/// A Discuz! forum index, read as structure — `DiscuzPage`'s rule applied one page up.
///
/// **Four installs were in front of this while it was written, and the brief's markup was only
/// one of them.** `forum.php?mod=forumdisplay&fid=N` inside a `<dt>` is exactly what
/// `install-c.example` writes and it is what *no other measured install writes at all*:
///
/// | host | version | how a board is named | how it is addressed |
/// | --- | --- | --- | --- |
/// | `install-c.example` | X5.0 | `<dl><dt><a>` grid | `forum.php?mod=forumdisplay&fid=34` |
/// | `install-a.example` | X3.4 | `<dl><dt><a>` grid | `forum-37-1.html` |
/// | `install-b.example` | X3.5, English | `<dl><dt><a>` grid | `37-1/news-feed.html` |
/// | `install-d.example` | X3.4, GBK | `<td><h2><a>` wide list | `forum-297-1.html` |
///
/// Neither `install-a.example` nor `install-b.example` contains the four letters `fid=` **anywhere**
/// on its index. So the number is read out of all three address shapes Discuz!'s own rewrite
/// rules produce, and the two layouts are enumerated rather than assumed — see
/// `DiscuzBoardLayout`.
///
/// **What all four do share is a pair of numbers.** A category is an `<h2>` whose anchor carries
/// `gid=N`, and its boards are whatever is inside `<div id="category_N">` — *matched on N*, never
/// on which one is nearer in the file. Adjacency looked fine on three installs and is wrong on
/// the fourth: `install-d.example` writes each **board's** name in an `<h2>` too, so "the last heading
/// before the category" would have named every category after the first with a board's name.
/// Requiring both halves is also what rejects `install-e.example`'s hand-written
/// `id="category_-99999"` block of campus links, which has no `gid` heading and no boards in it.
enum DiscuzIndex {
    /// Every category on the page, in the order the page writes them, with the boards under it.
    ///
    /// A category the reader may see no board in is dropped rather than drawn: Discuz! hides a
    /// board by permission and still renders its heading, and a section header with nothing
    /// beneath it is not something to put in front of somebody choosing.
    static func categories(in html: String) -> [DiscuzCategory] {
        guard let patterns = Patterns() else { return [] }
        let full = NSRange(html.startIndex..., in: html)

        var names: [Int: String] = [:]
        for match in patterns.heading.matches(in: html, range: full) {
            guard let gidRange = Range(match.range(at: 1), in: html),
                  let gid = Int(html[gidRange]),
                  let nameRange = Range(match.range(at: 2), in: html)
            else { continue }
            let name = HTMLText.plain(String(html[nameRange]))
            // First heading wins: a page that names one gid twice named it first where the
            // section actually is, and again in a footer or a jump menu.
            if !name.isEmpty, names[gid] == nil { names[gid] = name }
        }

        var divs: [(gid: Int, tag: Range<String.Index>)] = []
        for match in patterns.section.matches(in: html, range: full) {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let gid = Int(html[idRange]),
                  let whole = Range(match.range, in: html)
            else { continue }
            divs.append((gid, whole))
        }

        return divs.enumerated().compactMap { index, div in
            guard let name = names[div.gid] else { return nil }
            // To the next section, or to the end of the page for the last one. A `<div>` cannot
            // be matched to its close by pattern — they nest — and it does not need to be: the
            // next section's own opening tag is where this one's boards stop.
            let end = index + 1 < divs.count ? divs[index + 1].tag.lowerBound : html.endIndex
            let boards = self.boards(
                in: String(html[div.tag.upperBound..<end]),
                gid: div.gid,
                category: name,
                patterns: patterns
            )
            return boards.isEmpty ? nil : DiscuzCategory(gid: div.gid, name: name, boards: boards)
        }
    }

    /// The boards inside one category's section, in the order the page writes them.
    ///
    /// Both layouts are asked, and the answers are merged **by where they were found** rather
    /// than layout by layout, so a template that mixed the two would still list its boards in
    /// reading order. A number seen twice keeps its first description, which is why `grid` is
    /// declared first: the grid carries counts and a date and the wide list beside it might not.
    private static func boards(
        in section: String,
        gid: Int,
        category: String,
        patterns: Patterns
    ) -> [DiscuzBoard] {
        var seen: Set<Int> = []
        return DiscuzBoardLayout.allCases
            .flatMap { $0.boards(in: section, gid: gid, category: category, patterns: patterns) }
            .sorted { $0.at < $1.at }
            .filter { seen.insert($0.board.fid).inserted }
            .map(\.board)
    }

    /// The patterns, compiled once per page. A value rather than a global, for the reason
    /// `DiscuzPage.Patterns` gives: `NSRegularExpression` is not `Sendable`.
    struct Patterns {
        /// `<h2><a href="…gid=N">Name</a>` — the category, and what it is called.
        let heading: NSRegularExpression
        /// `<div id="category_N"` — where that category's boards begin.
        let section: NSRegularExpression
        /// `<dl>…</dl>` — one board, on the grid layout.
        let definition: NSRegularExpression
        /// `<dt>…</dt>` — its name and its address.
        let term: NSRegularExpression
        /// `<dd>…</dd>` — its counts, then whatever was posted in it last.
        let detail: NSRegularExpression
        /// `<tr>…</tr>` — one board, on the wide layout.
        let row: NSRegularExpression
        /// `<h2>…</h2>` — its name, on the wide layout, where the grid uses a `<dt>`.
        let name: NSRegularExpression
        /// `<td class="fl_i">…</td>` — threads and posts, on the wide layout.
        let countCell: NSRegularExpression
        /// `<td class="fl_by">…</td>` — the last post, on the wide layout.
        let lastPostCell: NSRegularExpression
        /// `<a href="…">…</a>`, with the address kept. The one place in this file that reads a
        /// stranger's href at all — for the **number** in it, never to fetch it.
        let anchor: NSRegularExpression
        /// `<em>…</em>` and `<span>…</span>` — the two ways the two layouts wrap a number.
        let emphasis: NSRegularExpression
        let span: NSRegularExpression
        let cite: NSRegularExpression
        /// `title="…"`, which is where an abbreviated count keeps its exact figure.
        let titleAttribute: NSRegularExpression
        /// The three shapes Discuz!'s rewrite rules give a board's address, in the order they
        /// are tried: the canonical query, the classic rewrite, and the SEO rewrite.
        let addresses: [NSRegularExpression]
        let date: NSRegularExpression

        init?() {
            func attribute(_ name: String, _ value: String) -> String {
                "\(name)\\s*=\\s*[\"'][^\"']*\\b\(value)\\b[^\"']*[\"']"
            }
            func wrapped(_ tag: String) -> String { "<\(tag)[^>]*>(.*?)</\(tag)>" }
            let options: NSRegularExpression.Options = [
                .dotMatchesLineSeparators, .caseInsensitive,
            ]
            guard
                let heading = try? NSRegularExpression(
                    pattern:
                        "<h2[^>]*>\\s*<a[^>]*href\\s*=\\s*[\"'][^\"']*[?&;]gid=(\\d+)[^\"']*[\"'][^>]*>(.*?)</a>",
                    options: options
                ),
                let section = try? NSRegularExpression(
                    pattern: "<div[^>]*\\bid\\s*=\\s*[\"']category_(\\d+)[\"'][^>]*>",
                    options: options
                ),
                let definition = try? NSRegularExpression(pattern: wrapped("dl"), options: options),
                let term = try? NSRegularExpression(pattern: wrapped("dt"), options: options),
                let detail = try? NSRegularExpression(pattern: wrapped("dd"), options: options),
                let row = try? NSRegularExpression(pattern: wrapped("tr"), options: options),
                let name = try? NSRegularExpression(pattern: wrapped("h2"), options: options),
                let countCell = try? NSRegularExpression(
                    pattern: "<td[^>]*\(attribute("class", "fl_i"))[^>]*>(.*?)</td>",
                    options: options
                ),
                let lastPostCell = try? NSRegularExpression(
                    pattern: "<td[^>]*\(attribute("class", "fl_by"))[^>]*>(.*?)</td>",
                    options: options
                ),
                let anchor = try? NSRegularExpression(
                    pattern: "<a[^>]*href\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>",
                    options: options
                ),
                let emphasis = try? NSRegularExpression(pattern: wrapped("em"), options: options),
                let span = try? NSRegularExpression(pattern: wrapped("span"), options: options),
                let cite = try? NSRegularExpression(pattern: wrapped("cite"), options: options),
                let titleAttribute = try? NSRegularExpression(
                    pattern: "\\btitle\\s*=\\s*[\"']([^\"']*)[\"']",
                    options: options
                ),
                // `forum.php?mod=forumdisplay&fid=34`, `install-c.example`.
                let canonical = try? NSRegularExpression(pattern: "[?&;]fid=(\\d+)"),
                // `forum-37-1.html`, `install-a.example` and `install-d.example`.
                let classic = try? NSRegularExpression(
                    pattern: "(?:^|/)forum-(\\d+)-\\d+\\.html",
                    options: [.caseInsensitive]
                ),
                // `37-1/news-feed.html`, `install-b.example`. Anchored to the start of a path
                // segment so that a number inside a word can never be read as a board.
                let seo = try? NSRegularExpression(pattern: "(?:^|/)(\\d+)-\\d+/"),
                let date = try? NSRegularExpression(
                    pattern:
                        "(\\d{4})-(\\d{1,2})-(\\d{1,2})(?:[\\s\u{00A0}]+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?)?"
                )
            else { return nil }
            self.heading = heading
            self.section = section
            self.definition = definition
            self.term = term
            self.detail = detail
            self.row = row
            self.name = name
            self.countCell = countCell
            self.lastPostCell = lastPostCell
            self.anchor = anchor
            self.emphasis = emphasis
            self.span = span
            self.cite = cite
            self.titleAttribute = titleAttribute
            self.addresses = [canonical, classic, seo]
            self.date = date
        }
    }

    /// The board number out of whichever address shape this install writes, or nothing.
    ///
    /// **Read for its number and never fetched.** `DiscuzClient` builds every address it asks for
    /// out of a host this device parsed and an integer — see `DiscuzThread.asNote` — and this is
    /// the one place a stranger's href is looked at at all. An `Int` that does not parse, or a
    /// number that is not positive, is markup doing something rather than a board.
    static func fid(inHref raw: String, patterns: Patterns) -> Int? {
        let href = raw.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        for address in patterns.addresses {
            guard let found = address.capture(1, in: href), let fid = Int(found), fid > 0 else {
                continue
            }
            return fid
        }
        return nil
    }

    /// One number the index stated, or nothing where it stated something this device cannot read.
    ///
    /// **The `title` first, because an abbreviated count is not a number.** `install-c.example` and
    /// `install-d.example` both write `<span title="58779">5万</span>` once a figure passes ten
    /// thousand, and reading the text would report a board with fifty-eight thousand threads as
    /// having five. `install-b.example` abbreviates nothing and carries no `title` at all, so both
    /// are needed and neither is a fallback for the other.
    ///
    /// The text is taken after the last `:`, `：` or `/`, which is every separator the four
    /// installs put between a label and its figure — `主题: 5106`, `Threads: 5`, ` / 6414` — and
    /// what is left has to be nothing but digits. `5万` is therefore **nothing**, not five.
    static func number(in slot: String, patterns: Patterns) -> Int? {
        if let title = patterns.titleAttribute.capture(1, in: slot), let exact = digits(title) {
            return exact
        }
        return digits(tail(of: HTMLText.plain(slot)))
    }

    private static func tail(of text: String) -> String {
        guard let cut = text.lastIndex(where: { $0 == ":" || $0 == "：" || $0 == "/" }) else {
            return text
        }
        return String(text[text.index(after: cut)...])
    }

    private static func digits(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // ASCII as well as numeric: `５` is a digit to Unicode and is not one to `Int`, and a
        // page that writes its counts in fullwidth digits should say nothing rather than nil out
        // of a failed parse somewhere further down.
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int(trimmed)
    }

    /// When something was last posted in a board, out of the cell that says so.
    ///
    /// The `<cite>` where there is one, the whole cell otherwise — and that narrowing is what
    /// keeps a *thread title* out of the answer. `install-b.example` writes the last thread's name
    /// beside its date, so a cell scanned whole would read `2.0 released 2026-06-24 13:55` as
    /// whichever of the two numbers came first. Every date shape is then `DiscuzDate`'s, because
    /// an index writes them exactly as a thread table does: `<span title="2026-9-15 22:45">5
    /// 分钟前</span>` where it is recent, plain text where it is not.
    static func lastPost(in cell: String, patterns: Patterns) -> Date? {
        let narrowed = patterns.cite.capture(1, in: cell) ?? cell
        return DiscuzDate.parse(narrowed, date: patterns.date)
    }
}

/// The two ways a Discuz! index writes a board, both of them measured.
///
/// **No `default:`, and `allCases` rather than a hand-written list.** This branch has the lesson
/// written down twice over: a switch over a kind that falls through is a silent wrong answer, and
/// a test free to enumerate a subset describes a smaller world than the code. A third layout
/// would break the build here rather than quietly returning nothing.
enum DiscuzBoardLayout: CaseIterable, Sendable {
    /// `<td class="fl_g">` holding `<dl><dt><a>Name</a></dt><dd>counts</dd><dd>last post</dd>`.
    /// Three of the four installs, across X3.4, X3.5 and X5.0.
    case grid
    /// One board to a `<tr>`: `<td><h2><a>Name</a></h2></td><td class="fl_i">threads / posts</td>
    /// <td class="fl_by">last post</td>`. `install-d.example`, and the reason the grid alone is not
    /// enough.
    case list

    /// Every board this layout can find in one category's section, with where it was found.
    func boards(
        in section: String,
        gid: Int,
        category: String,
        patterns: DiscuzIndex.Patterns
    ) -> [(at: Int, board: DiscuzBoard)] {
        let range = NSRange(section.startIndex..., in: section)
        let container: NSRegularExpression
        switch self {
        case .grid: container = patterns.definition
        case .list: container = patterns.row
        }
        return container.matches(in: section, range: range).compactMap { match in
            guard let bodyRange = Range(match.range(at: 1), in: section) else { return nil }
            guard let board = self.board(
                in: String(section[bodyRange]),
                gid: gid,
                category: category,
                patterns: patterns
            ) else { return nil }
            return (match.range.location, board)
        }
    }

    private func board(
        in body: String,
        gid: Int,
        category: String,
        patterns: DiscuzIndex.Patterns
    ) -> DiscuzBoard? {
        // Where the name is. The grid's `<dt>` and the wide layout's `<h2>` are the *only* places
        // a board's own number is read from, which is what keeps a sub-board link — `子版块:
        // <a href="forum-300-1.html">…</a>`, a name with no counts and no date beside it — from
        // arriving in the list looking exactly like a board the reader can judge.
        let named: NSRegularExpression
        switch self {
        case .grid: named = patterns.term
        case .list: named = patterns.name
        }
        guard let heading = named.capture(1, in: body),
              let match = patterns.anchor.firstMatch(
                in: heading, range: NSRange(heading.startIndex..., in: heading)
              ),
              let hrefRange = Range(match.range(at: 1), in: heading),
              let labelRange = Range(match.range(at: 2), in: heading),
              let fid = DiscuzIndex.fid(inHref: String(heading[hrefRange]), patterns: patterns)
        else { return nil }
        let name = HTMLText.plain(String(heading[labelRange]))
        guard !name.isEmpty else { return nil }

        let counts: [String]
        let lastPostCell: String?
        switch self {
        case .grid:
            // The first `<dd>` is the counts and the last is the last post. Where there is only
            // one they are the same cell, and each rule then answers for itself: the counts want
            // labelled numbers and the last post wants a date, and neither finds the other's.
            let details = patterns.detail.captures(1, in: body)
            counts = details.first.map { patterns.emphasis.captures(1, in: $0) } ?? []
            lastPostCell = details.last
        case .list:
            counts = patterns.countCell.capture(1, in: body)
                .map { patterns.span.captures(1, in: $0) } ?? []
            lastPostCell = patterns.lastPostCell.capture(1, in: body)
        }

        // **Threads first, then posts, by position rather than by the word beside them.** The
        // four installs say 主题/帖数, Threads/Posts and nothing at all, in that one order; the
        // label is the half that is translated and the order is the half that is not. Reading
        // the words would be this file's only line of Chinese, and would stop working the day
        // somebody installs a language pack.
        return DiscuzBoard(
            fid: fid,
            name: name,
            category: category,
            gid: gid,
            threads: counts.first.flatMap { DiscuzIndex.number(in: $0, patterns: patterns) },
            posts: counts.dropFirst().first.flatMap {
                DiscuzIndex.number(in: $0, patterns: patterns)
            },
            lastPostAt: lastPostCell.flatMap { DiscuzIndex.lastPost(in: $0, patterns: patterns) }
        )
    }
}

/// Bytes off a Discuz! into a `String`, which is a real question here and is not one anywhere
/// else in this package.
///
/// Discuz! predates the UTF-8 default and a large share of running installs still serve **GBK**:
/// `install-d.example` answers `Content-Type: text/html; charset=gbk` today. GBK bytes are not valid
/// UTF-8, so `String(data:encoding:.utf8)` returns `nil` for the whole page — not a mangled
/// string that might be noticed, but nothing at all, which a caller reading only UTF-8 would
/// report as an unreadable host.
///
/// **The declaration is tried first, not UTF-8 first.** A server that says `gbk` and means it is
/// the common case, and trying UTF-8 ahead of it only wins where the server lied — while losing
/// wherever a GBK page's bytes happen to form valid UTF-8 by accident, which is a silently
/// mangled page rather than a refusal. The header is preferred over the `<meta>` because the
/// header is the one the server actually chose per response.
///
/// **A page that says UTF-8 and is not quite UTF-8 is a damaged UTF-8 page, not a page in some
/// other encoding** — and that case is real rather than defensive. `install-a.example` is a running
/// Discuz! X3.4 which declares UTF-8, is UTF-8 across all 80KB of its thread list, and carries ten
/// leftover GBK bytes in one JavaScript comment. Strict UTF-8 gives `nil` for the whole page;
/// GB18030 *also* fails on it, because the page really is UTF-8. So when UTF-8 is what was
/// declared, this decodes UTF-8 **lossily** rather than reaching for another encoding: the
/// declaration is the best evidence there is, every title and every name in the page is clean, and
/// the damage stays confined to the handful of bytes that were actually broken. Reaching for
/// GB18030 there would answer a damaged page with a wholly mojibake one.
///
/// **`isoLatin1` is not in the list, on purpose.** It decodes every byte sequence ever, so adding
/// it as a last resort would replace "this page could not be read" with "this page was read as
/// mojibake" — and mojibake parses: it would produce rows with unreadable titles and no error at
/// all. That is also why the lossy decode above is reached only on the strength of a declaration,
/// and never as a general fallback. Failing is the honest end of this function.
enum DiscuzHTML {
    static func text(_ data: Data, _ response: HTTPURLResponse) -> String? {
        let declared = declared(data, response)
        for encoding in declared {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        // It said UTF-8. Believe it, and take the loss on the bytes that contradict it.
        if declared.contains(.utf8) { return String(decoding: data, as: UTF8.self) }
        if let text = String(data: data, encoding: .utf8) { return text }
        // GB18030 rather than GBK: it is a strict superset, decodes every GBK page unchanged, and
        // additionally covers the installs that were migrated to it.
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        return String(data: data, encoding: gb18030)
    }

    /// What the response says it is: the header first, then the `<meta>` in the head.
    private static func declared(_ data: Data, _ response: HTTPURLResponse) -> [String.Encoding] {
        var names: [String] = []
        if let name = response.textEncodingName { names.append(name) }
        if let name = charsetMeta(data) { names.append(name) }
        return names.compactMap(encoding(named:))
    }

    /// The charset out of the first 2 KiB of head.
    ///
    /// Read lossily on purpose — the bytes being sniffed are, by assumption, in an encoding not
    /// yet known, and `charset=gbk` is ASCII in every one of them. Replacement characters
    /// elsewhere in the head cost nothing because nothing else here is looked at.
    private static func charsetMeta(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        guard let regex = try? NSRegularExpression(
            pattern: "charset\\s*=\\s*[\"']?([A-Za-z0-9_.:-]+)",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(head.startIndex..., in: head)
        guard let match = regex.firstMatch(in: head, range: range),
              let found = Range(match.range(at: 1), in: head)
        else { return nil }
        return String(head[found])
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

/// One thread as a Discuz! thread table states it.
struct DiscuzThread: Equatable, Sendable {
    let tid: Int
    let title: String
    /// The board this thread is in, where the row itself named one. A guide page names it per
    /// row; a single board's listing names it once in the heading instead.
    let board: String?
    /// Whoever started the thread. Never the last person to reply — see `DiscuzPage.threads`.
    let author: String
    let postedAt: Date?
    let replies: Int?

    func asNote(source: Source, host: String, board heading: String?, boardID: String? = nil) -> Note {
        Note(
            // Prefixed and host-qualified, as Discourse's are: a forum's thread numbers, another
            // forum's thread numbers and a microblog's status ids all share one store, and `82`
            // is a plausible id on every one of them.
            id: "discuz:\(host):\(tid)",
            source: source,
            author: author,
            // Discuz! shows the poster's name and links it by uid; the name is what the forum
            // calls them and is what a handle can be built from. Empty where the row named
            // nobody, rather than a bare `@@host`.
            handle: author.isEmpty ? "" : "@\(author)@\(host)",
            // **A forum row is a title, not a body.** Unlike Discourse's `/latest.json`, which at
            // least sometimes carries an excerpt, a Discuz! thread table carries no part of the
            // opening post at all — reading one would be a second request per row against a
            // stranger's server, which is not what the reader pressed a button for.
            body: "",
            title: title.isEmpty ? nil : title,
            // The row's own board where the page gave one, the page's heading otherwise. Never
            // the other way round: on a guide page the heading is 最新发表, which is the name of
            // a view and not of a section, and it would overwrite fifty correct answers.
            board: board ?? heading,
            boardID: boardID,
            // **When it was posted, not when it was last bumped.** The date taken is the one in
            // the row's *first* person-cell, which is the thread's author; the last cell's date
            // belongs to whoever answered most recently and would date somebody's question by a
            // stranger's reply.
            postedAt: postedAt ?? .distantPast,
            origins: [.publicTimeline],
            // Discuz! puts no avatar in a thread table. It can be *guessed* at
            // `uc_server/avatar.php?uid=…`, and that guess is wrong on any install that moved or
            // renamed UCenter — so nothing is drawn rather than a broken address fetched fifty
            // times per page.
            avatarURL: nil,
            // The row says a thread *has* an attachment — `<i class="fico-image">`, or an
            // `image_s.gif` on the older skins — and never says where it is. A flag with no file
            // behind it is not an `Attachment`; `Attachment.isEmpty` would be true of every one
            // of them.
            attachments: [],
            // **Built, not lifted.** `forum.php?mod=viewthread&tid=` is the address every Discuz!
            // answers, on all three installs measured, whether or not its rewrite rules are on —
            // and it is built here out of a host this device parsed and an integer, so it is the
            // one address in this file that did not come out of a stranger's markup. The
            // alternative was to resolve the row's own relative `href` against the page's `<base>`,
            // which is a value the same stranger writes: `Host.fetchableURL` would then be the
            // only thing between `javascript:` and a reader's tap. Not lifting it is a stronger
            // guarantee than checking it.
            url: Host.httpsURL(
                host: host,
                path: "/forum.php",
                query: [
                    URLQueryItem(name: "mod", value: "viewthread"),
                    URLQueryItem(name: "tid", value: String(tid)),
                ]
            ),
            counts: Counts(
                // **Already answers.** Discuz!'s own column is 回复 — the replies — and it does
                // not count the opening post, so unlike Discourse's `posts_count` there is
                // nothing to subtract. Subtracting anyway would show one answer fewer than the
                // thread has, on every row.
                replies: replies,
                reblogs: nil,
                favourites: nil
            )
        )
    }
}

/// A Discuz! page, read as structure.
///
/// Every pattern here is anchored on a **class and a shape**, never on a word of Chinese, a
/// template name or a version: the three installs this was measured against write their
/// addresses three different ways and their markup one way. `NSRegularExpression` and `String`
/// rather than a parser, because this package has no dependencies and gets none, and because
/// `HTMLKind` and `HTMLText` already read markup this way.
enum DiscuzPage {
    /// Every thread the page lists, in the order it lists them.
    ///
    /// **Which cell is who.** A row's person-cells and its board-cell are all `<td class="by">`,
    /// and they are told apart by a fact that holds on every skin: Discuz! wraps a *person* in
    /// `<cite>` and a board in a bare anchor. So the board is the by-cell with no `<cite>`, the
    /// **author is the first by-cell that has one**, and the last by-cell — which also has one —
    /// is the most recent replier and is never read. That single rule reads both page shapes:
    ///
    /// ```text
    ///   guide          icn  th(title)  by(board)  by(author)  num  by(last reply)
    ///   forumdisplay   icn  th(title)             by(author)  num  by(last reply)
    /// ```
    ///
    /// Getting this wrong is not a parse error, it is a **plausible wrong answer** — the row
    /// would carry a real person's name, spelled correctly, who did not write the thing.
    static func threads(in html: String) -> [DiscuzThread] {
        guard let patterns = Patterns() else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return patterns.row.matches(in: html, range: range).compactMap { match in
            guard let idRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html),
                  // A `tid` of four hundred digits is markup doing something, not a thread.
                  let tid = Int(html[idRange])
            else { return nil }
            return thread(tid: tid, row: String(html[bodyRange]), patterns: patterns)
        }
    }

    private static func thread(tid: Int, row: String, patterns: Patterns) -> DiscuzThread? {
        // The title's anchor is marked `xst` on every skin measured — sometimes alone,
        // sometimes as `class="s xst"` — and a row with no title is not a thread row.
        guard let title = patterns.title.capture(1, in: row).map(HTMLText.plain), !title.isEmpty
        else { return nil }

        let cells = patterns.byCell.captures(1, in: row)
        let people = cells.filter { $0.range(of: "<cite", options: .caseInsensitive) != nil }
        let board = cells.first { $0.range(of: "<cite", options: .caseInsensitive) == nil }

        let author = people.first.flatMap { patterns.cite.capture(1, in: $0) }
        let posted = people.first.flatMap { patterns.em.capture(1, in: $0) }

        return DiscuzThread(
            tid: tid,
            title: title,
            board: board.map(HTMLText.plain).flatMap { $0.isEmpty ? nil : $0 },
            author: author.map(HTMLText.plain) ?? "",
            postedAt: posted.flatMap { DiscuzDate.parse($0, using: patterns) },
            // `td.num` is `<a>replies</a><em>views</em>`. Only the first is stored, because
            // `Counts` has nowhere to put a view count and a number nobody draws is a number
            // nobody can check.
            replies: patterns.numCell.capture(1, in: row)
                .flatMap { patterns.anchor.capture(1, in: $0) }
                .flatMap { Int(HTMLText.plain($0).trimmingCharacters(in: .whitespaces)) }
        )
    }

    /// The board a single-board listing names in its heading, or nothing.
    ///
    /// **It must be an anchor**, and that is the whole of the rule. A board's heading links to the
    /// board; a guide page's heading is the name of a *view* — 最新发表, `Latest Posts` — and has
    /// no link in it. Taking the heading's plain text instead would file every row of every guide
    /// page under a board that does not exist.
    static func boardHeading(in html: String) -> String? {
        guard let patterns = Patterns(),
              let heading = patterns.h1.capture(1, in: html),
              let anchor = patterns.anchor.capture(1, in: heading)
        else { return nil }
        let name = HTMLText.plain(anchor)
        return name.isEmpty ? nil : name
    }

    /// Whether this is a filter's interactive challenge rather than a forum.
    ///
    /// Pinned against a live capture of `challenge.example`, which has bot-fighting
    /// deliberately switched on — its owner's decision about who may read it, and the reason it is
    /// a fair thing to capture rather than something to route around.
    ///
    /// Four markers, any one of which is enough, because a challenge page is rewritten often and
    /// a detector resting on all four at once would go quiet the first time one moved. Each is
    /// something no forum's thread list contains.
    static func isChallenge(_ html: String) -> Bool {
        let markers = [
            "Just a moment",
            "cdn-cgi/challenge-platform",
            "cf_chl_opt",
            "Enable JavaScript and cookies to continue",
        ]
        return markers.contains { html.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Whether this is Discuz!'s own notice page — the one it serves in place of a board.
    ///
    /// `id="messagetext"` is Discuz!'s, not a template's: it is the container every version puts
    /// its one-line answer in, and no thread list has one. It is what a signed-out reader gets
    /// from every board on `install-e.example`.
    static func isRestricted(_ html: String) -> Bool {
        html.range(of: "id=\"messagetext\"", options: .caseInsensitive) != nil
            || html.range(of: "id='messagetext'", options: .caseInsensitive) != nil
    }

    /// The patterns, compiled once per page rather than once per row.
    ///
    /// A value passed down instead of a global: `NSRegularExpression` is not `Sendable`, and a
    /// `static let` of one would be a shared mutable-looking global this package has no need of.
    /// Compiling per row instead would build eight of them fifty times for one page.
    struct Patterns {
        let row: NSRegularExpression
        let title: NSRegularExpression
        let byCell: NSRegularExpression
        let numCell: NSRegularExpression
        let cite: NSRegularExpression
        let em: NSRegularExpression
        let anchor: NSRegularExpression
        let h1: NSRegularExpression
        let date: NSRegularExpression

        init?() {
            // `stick` as well as `normal`: a board's listing puts its pinned threads in
            // `stickthread_` rows, and they are threads. Measured on `install-c.example`, six of the
            // thirty-three rows on one board.
            //
            // **They are kept, and not pinned.** A pinned thread carries a real number, title,
            // author and posting date, and it is what a reader sees at the top of that board on
            // the site — dropping it would silently hide a board's own rules and announcements.
            // Drawing it at the top is the thing that cannot be done: this device's store orders
            // every note in it by `postedAt`, across every source at once, and there is nowhere
            // for "above the others, but only within this one board" to live. So a sticky sorts
            // by when it was written, like everything else, and `Note.id` keys on the thread
            // number so one that repeats on every page of a board can never arrive twice.
            //
            // **One caveat, measured and not fixed here.** Discuz! pins a thread to one board
            // (`tpin1`) or to *every* board (`tpin3`), and a globally pinned one is written into
            // a listing it does not belong to: `install-c.example` thread 403684 reads under board 34
            // 杂谈区 and the thread itself is in 版务公开. Its number, title, author, date and
            // answer count are all correct — checked against the thread — and only the board it
            // is filed under is the board it was *read in* rather than the board it is in. The
            // marker that would tell the two apart was found on one skin out of four, which is
            // not enough to start dropping rows on.
            func attribute(_ name: String, _ value: String) -> String {
                "\(name)\\s*=\\s*[\"'][^\"']*\\b\(value)\\b[^\"']*[\"']"
            }
            guard
                let row = try? NSRegularExpression(
                    pattern: "<tbody[^>]*\\bid\\s*=\\s*[\"'](?:normal|stick)thread_(\\d+)[\"'][^>]*>(.*?)</tbody>",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]
                ),
                let title = try? NSRegularExpression(
                    pattern: "<a[^>]*\(attribute("class", "xst"))[^>]*>(.*?)</a>",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]
                ),
                let byCell = try? NSRegularExpression(
                    pattern: "<td[^>]*\(attribute("class", "by"))[^>]*>(.*?)</td>",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]
                ),
                let numCell = try? NSRegularExpression(
                    pattern: "<td[^>]*\(attribute("class", "num"))[^>]*>(.*?)</td>",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]
                ),
                let cite = try? NSRegularExpression(
                    pattern: "<cite[^>]*>(.*?)</cite>",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]
                ),
                let em = try? NSRegularExpression(
                    pattern: "<em[^>]*>(.*?)</em>",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]
                ),
                let anchor = try? NSRegularExpression(
                    pattern: "<a[^>]*>(.*?)</a>",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]
                ),
                let h1 = try? NSRegularExpression(
                    pattern: "<h1[^>]*>(.*?)</h1>",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]
                ),
                let date = try? NSRegularExpression(
                    pattern: "(\\d{4})-(\\d{1,2})-(\\d{1,2})(?:[\\s\u{00A0}]+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?)?"
                )
            else { return nil }
            self.row = row
            self.title = title
            self.byCell = byCell
            self.numCell = numCell
            self.cite = cite
            self.em = em
            self.anchor = anchor
            self.h1 = h1
            self.date = date
        }
    }
}

/// The date in a thread row, which Discuz! writes two ways in the same table.
///
/// A row posted recently reads `<span title="2026-9-15">5&nbsp;小时前</span>` — the words are
/// relative and untranslatable without a clock and a locale, and the **`title` carries the date**.
/// An older row reads `<span>2026-9-7</span>` with no title at all. So: try the attribute, then
/// the text, and take whichever yields a date.
///
/// **Parsed as UTC, and that is a known approximation.** Discuz! renders these in the forum's own
/// configured time zone and the page never says which — there is no offset in the markup, in a
/// header, or anywhere a client can reach unauthenticated. Reading them as UTC is therefore off by
/// that forum's offset, up to a day's boundary. It is chosen over guessing the device's zone for
/// two reasons: the device's zone has nothing to do with the forum's, so it would be wrong by a
/// different amount for every reader and untestable; and a forum row is drawn with a date, not a
/// clock time, so the error is invisible except at a midnight. Said out loud here rather than
/// discovered in a bug report.
enum DiscuzDate {
    static func parse(_ raw: String, using patterns: DiscuzPage.Patterns) -> Date? {
        parse(raw, date: patterns.date)
    }

    /// The same reading, taken by whichever page compiled the pattern. The index writes its dates
    /// exactly as a thread table does, and a second copy of this scanner would be a second place
    /// to get the calendar wrong.
    static func parse(_ raw: String, date: NSRegularExpression) -> Date? {
        if let attribute = titleAttribute(in: raw), let parsed = scan(attribute, date) {
            return parsed
        }
        return scan(HTMLText.plain(raw), date)
    }

    /// The `title="…"` on whatever is inside the `<em>`.
    private static func titleAttribute(in raw: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\btitle\\s*=\\s*[\"']([^\"']*)[\"']",
            options: [.caseInsensitive]
        ) else { return nil }
        return regex.capture(1, in: raw)
    }

    /// `2026-9-15`, `2026-06-08`, `2026-9-15 16:45`, `2009-12-27` — every shape the three
    /// installs produced, zero-padded or not.
    ///
    /// Scanned into `DateComponents` against a fixed Gregorian UTC calendar rather than handed to
    /// a `DateFormatter`: a formatter carries a locale and a calendar the device chooses, so the
    /// same page would parse differently for a reader whose phone is set to the Buddhist or
    /// Japanese calendar — both of which change what `2026` means. It is also the faster of the
    /// two by a wide margin at fifty rows a page.
    private static func scan(_ text: String, _ date: NSRegularExpression) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = date.firstMatch(in: text, range: range) else { return nil }
        func number(_ index: Int) -> Int? {
            guard let found = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[found])
        }
        guard let year = number(1), let month = number(2), let day = number(3) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = number(4) ?? 0
        components.minute = number(5) ?? 0
        components.second = number(6) ?? 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        // A rejected date — month 19, day 40 — is markup this file does not understand rather
        // than a thread posted on a day that does not exist.
        return calendar.date(from: components).flatMap { date in
            calendar.dateComponents([.year, .month, .day], from: date)
                == DateComponents(year: year, month: month, day: day) ? date : nil
        }
    }
}

extension NSRegularExpression {
    /// The first match's numbered group, or nothing.
    func capture(_ index: Int, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = firstMatch(in: text, range: range),
              match.numberOfRanges > index,
              let found = Range(match.range(at: index), in: text)
        else { return nil }
        return String(text[found])
    }

    /// Every match's numbered group, in order.
    func captures(_ index: Int, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > index,
                  let found = Range(match.range(at: index), in: text)
            else { return nil }
            return String(text[found])
        }
    }
}
