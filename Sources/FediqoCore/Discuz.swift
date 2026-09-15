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
    /// Not used by the join — a reader adding a forum has no idea what number a board is — but it
    /// is the same page with one column fewer, and the parser handles both, so the capability is
    /// here rather than waiting to be rediscovered. A board listing names its board **once**, in
    /// the heading, because every row on it is in the same board; the guide page names it per row.
    public func board(_ fid: Int, source: Source) async throws -> [Note] {
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
        return try await read(url, source: source)
    }

    /// One page fetched, decoded, judged, and turned into rows.
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
    private func read(_ url: URL, source: Source) async throws -> [Note] {
        let (data, response) = try await http.data(from: url)
        guard let html = DiscuzHTML.text(data, response) else {
            throw DiscuzRequestError.undecodable
        }
        if DiscuzPage.isChallenge(html) { throw DiscuzRequestError.challenged }
        try Self.check(response.statusCode)
        if DiscuzPage.isRestricted(html) { throw DiscuzRequestError.restricted }

        let rows = DiscuzPage.threads(in: html)
        // **An empty list is the one answer this must never give.** A parser that meets markup it
        // cannot read and returns `[]` hands the reader a forum that draws nothing, forever, with
        // no error to explain it — and it cannot be told from a forum that really is empty,
        // because the markup for the two is the same markup. Of the two mistakes available, "we
        // could not read that" is the one the reader can act on, and the one a bug report can be
        // written about. This is also the backstop under judgement 2: a challenge page nobody has
        // taught `isChallenge` about still fails here rather than joining silently.
        guard !rows.isEmpty else { throw DiscuzRequestError.noThreads }

        let heading = DiscuzPage.boardHeading(in: html)
        return rows.map { $0.asNote(source: source, host: host, board: heading) }
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

    func asNote(source: Source, host: String, board heading: String?) -> Note {
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
        if let attribute = titleAttribute(in: raw), let date = scan(attribute, patterns) {
            return date
        }
        return scan(HTMLText.plain(raw), patterns)
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
    private static func scan(_ text: String, _ patterns: DiscuzPage.Patterns) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = patterns.date.firstMatch(in: text, range: range) else { return nil }
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
