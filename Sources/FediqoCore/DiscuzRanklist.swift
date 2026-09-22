import Foundation

// MARK: - A forum's ranking lists, read as its Trends

/// What a Discuz! forum's ranking lists — `misc.php?mod=ranklist` — say is being read this week:
/// its threads ranked by replies, and its blogs (日誌) ranked by how often they are read. These
/// are a forum's **Trends**, the one thing on it that means what a microblog's trending read
/// means: what everybody else is reading, not what the reader subscribed to.
///
/// **Measured on `install-g.example`**, both pages, as a signed-in reader saves them:
///
/// ```text
///   thread   <tr> td.icn(rank) th(<a …tid=N>title</a>) td.frm(<a …fid=N>board</a>)
///                 td.by(<cite><a>author</a></cite> <em>date</em>) td(<a>replies</a>)
///   blog     <dl class="bbda"> dd.ranknum(rank) dd.m(avatar) dt(share-link, <a …do=blog&id=N>title</a>)
///                 dd(<a>author</a> <span class="xg1">date</span>) dd.cl(excerpt) dd.xg1(heat)
/// ```
///
/// The first three ranks are an `<img alt="N">` and the rest are the number as text; the table's
/// own heading is a `<tr class="th">` with no link in it; and an author may be an empty anchor,
/// which is how the forum writes a thread posted anonymously.
///
/// **Structure, never words.** Every rule below is anchored on a class, a tag or a number in an
/// address — `tid=`, `fid=`, `do=blog&id=` — and never on a label: the heat is written after a
/// word this file does not read, and nothing is lost by not reading it, since `Counts` has
/// nowhere to put a number no other source has.
///
/// **An address is read for its number and never followed** — `DiscuzIndex.fid(inHref:)`'s rule.
/// A thread's address is built by `DiscuzThread.asNote`, and a blog's by `DiscuzRankedBlog.url`,
/// out of the host this device parsed and integers.
enum DiscuzRanklist {
    /// Every ranked thread on the page, in the order the page ranks them. Nothing where the page
    /// has no ranking on it — switched off, empty, or not a ranking page at all.
    static func threads(in html: String) -> [DiscuzRankedThread] {
        guard let patterns = Patterns(), let index = DiscuzIndex.Patterns() else { return [] }
        return patterns.row.matches(in: html, range: NSRange(html.startIndex..., in: html))
            .compactMap { match -> DiscuzRankedThread? in
                guard let attributes = Range(match.range(at: 1), in: html),
                      let body = Range(match.range(at: 2), in: html)
                else { return nil }
                // The table's heading row: the column names, and no thread.
                if patterns.headingRow.firstMatch(
                    in: String(html[attributes]),
                    range: NSRange(html[attributes].startIndex..., in: html[attributes])
                ) != nil { return nil }
                return thread(in: String(html[body]), patterns: patterns, index: index)
            }
    }

    private static func thread(
        in row: String, patterns: Patterns, index: DiscuzIndex.Patterns
    ) -> DiscuzRankedThread? {
        // **The board cell is what makes a row a ranked thread.** A thread anchor alone is in
        // every navigation menu on the page; one beside a `td.frm` is only in this table.
        guard let board = patterns.boardCell.capture(1, in: row),
              let heading = patterns.heading.capture(1, in: row),
              let link = patterns.link.firstMatch(
                  in: heading, range: NSRange(heading.startIndex..., in: heading)
              ),
              let href = Range(link.range(at: 1), in: heading).map({ String(heading[$0]) }),
              let words = Range(link.range(at: 2), in: heading).map({ String(heading[$0]) }),
              let tid = number(in: href, patterns.tid),
              case let title = HTMLText.plain(words), !title.isEmpty
        else { return nil }

        let boardName = HTMLText.plain(board)
        let fid = patterns.link.capture(1, in: board).flatMap { DiscuzIndex.fid(inHref: $0, patterns: index) }
        let by = patterns.byCell.capture(1, in: row) ?? ""
        let author = patterns.cite.capture(1, in: by).map(HTMLText.plain) ?? ""
        let posted = patterns.em.capture(1, in: by).flatMap { DiscuzDate.parse($0, date: patterns.date) }
        // The last cell is the figure the page ranks by — replies, on the view this app asks for.
        let replies = patterns.cell.captures(1, in: row).last
            .map(HTMLText.plain)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        return DiscuzRankedThread(
            rank: patterns.rankCell.capture(1, in: row).flatMap { rank(in: $0, patterns) },
            thread: DiscuzThread(
                tid: tid,
                title: title,
                board: boardName.isEmpty ? nil : boardName,
                author: author,
                postedAt: posted,
                replies: replies
            ),
            fid: fid
        )
    }

    /// Every ranked blog on the page, in the order the page ranks them. Nothing where there is
    /// no ranking on it.
    static func blogs(in html: String) -> [DiscuzRankedBlog] {
        guard let patterns = Patterns() else { return [] }
        return patterns.entry.captures(1, in: html).compactMap { entry -> DiscuzRankedBlog? in
            // The title is the `dt`'s link **to a blog** — the other link in it is the forum's
            // share button, whose address names the same blog through a different door.
            guard let term = patterns.term.capture(1, in: entry) else { return nil }
            let links = patterns.link.matches(in: term, range: NSRange(term.startIndex..., in: term))
            let blog = links.lazy.compactMap { link -> (id: Int, uid: Int, title: String)? in
                guard let href = Range(link.range(at: 1), in: term).map({ String(term[$0]) }),
                      let words = Range(link.range(at: 2), in: term).map({ String(term[$0]) }),
                      let address = blogAddress(href, patterns),
                      case let title = HTMLText.plain(words), !title.isEmpty
                else { return nil }
                return (address.id, address.uid, title)
            }.first
            guard let blog else { return nil }

            let byline = patterns.plainDetail.capture(1, in: entry) ?? ""
            let author = patterns.link.capture(2, in: byline).map(HTMLText.plain) ?? ""
            let posted = patterns.dimSpan.capture(1, in: byline)
                .flatMap { DiscuzDate.parse($0, date: patterns.date) }
            let excerpt = patterns.excerpt.capture(1, in: entry).map(Self.excerpt) ?? ""

            return DiscuzRankedBlog(
                rank: patterns.rankDetail.capture(1, in: entry).flatMap { rank(in: $0, patterns) },
                id: blog.id,
                uid: blog.uid,
                title: blog.title,
                author: author,
                postedAt: posted,
                excerpt: excerpt
            )
        }
    }

    /// What the list wrote of a blog, as words.
    ///
    /// **Read twice, because the forum wrote some of it twice.** Measured on `install-g.example`:
    /// a blog written in the forum's rich editor is cut for the list *with its markup still in
    /// it*, and the cut is then escaped — `&lt;font …&gt;` — so one reading leaves the reader a
    /// line of tags. The second reading takes out what is now markup, and the cut's last tag,
    /// which the forum stopped halfway through, goes with it.
    static func excerpt(_ raw: String) -> String {
        let once = HTMLText.plain(raw)
        let twice = HTMLText.plain(once)
        return twice
            .replacingOccurrences(of: "<[A-Za-z/][^>]*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A rank, as an image's `alt` for the first three and as text for the rest.
    private static func rank(in cell: String, _ patterns: Patterns) -> Int? {
        if let alt = patterns.alt.capture(1, in: cell), let rank = Int(alt) { return rank }
        return Int(HTMLText.plain(cell).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A positive number out of an address, by the first of `shapes` that finds one.
    private static func number(in raw: String, _ shapes: [NSRegularExpression]) -> Int? {
        let href = raw.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        for shape in shapes {
            if let found = shape.capture(1, in: href), let number = Int(found), number > 0 {
                return number
            }
        }
        return nil
    }

    /// Whose blog and which, out of an address to one, or nothing where it is not one.
    ///
    /// **Both numbers, because the forum needs both.** A blog is served from its author's space,
    /// and an address naming the blog but no author opens the *reader's* space and says there is
    /// no such blog.
    private static func blogAddress(_ raw: String, _ patterns: Patterns) -> (uid: Int, id: Int)? {
        let href = raw.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        if patterns.blogQuery.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)) != nil,
           let uid = number(in: href, [patterns.uid]),
           let id = number(in: href, [patterns.blogID]) {
            return (uid, id)
        }
        // `blog-21-500.html`, the rewrite Discuz! offers for a blog.
        let range = NSRange(href.startIndex..., in: href)
        guard let match = patterns.blogRewrite.firstMatch(in: href, range: range),
              let uid = Range(match.range(at: 1), in: href).flatMap({ Int(href[$0]) }),
              let id = Range(match.range(at: 2), in: href).flatMap({ Int(href[$0]) }),
              uid > 0, id > 0
        else { return nil }
        return (uid, id)
    }

    /// The patterns, compiled once per page — `DiscuzPage.Patterns`' reason.
    struct Patterns {
        let row: NSRegularExpression
        let headingRow: NSRegularExpression
        let rankCell: NSRegularExpression
        let heading: NSRegularExpression
        let boardCell: NSRegularExpression
        let byCell: NSRegularExpression
        let cell: NSRegularExpression
        let cite: NSRegularExpression
        let em: NSRegularExpression
        let link: NSRegularExpression
        let alt: NSRegularExpression
        let tid: [NSRegularExpression]
        let entry: NSRegularExpression
        let rankDetail: NSRegularExpression
        let term: NSRegularExpression
        let plainDetail: NSRegularExpression
        let dimSpan: NSRegularExpression
        let excerpt: NSRegularExpression
        let blogQuery: NSRegularExpression
        let uid: NSRegularExpression
        let blogID: NSRegularExpression
        let blogRewrite: NSRegularExpression
        let date: NSRegularExpression

        init?() {
            let options: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
            func compile(_ pattern: String, _ options: NSRegularExpression.Options = options)
                -> NSRegularExpression? {
                try? NSRegularExpression(pattern: pattern, options: options)
            }
            func classed(_ value: String) -> String {
                "class\\s*=\\s*[\"'][^\"']*\\b\(value)\\b[^\"']*[\"']"
            }
            guard
                let row = compile("<tr\\b([^>]*)>(.*?)</tr>"),
                let headingRow = compile(classed("th")),
                let rankCell = compile("<td[^>]*\(classed("icn"))[^>]*>(.*?)</td>"),
                let heading = compile("<th\\b[^>]*>(.*?)</th>"),
                let boardCell = compile("<td[^>]*\(classed("frm"))[^>]*>(.*?)</td>"),
                let byCell = compile("<td[^>]*\(classed("by"))[^>]*>(.*?)</td>"),
                let cell = compile("<td\\b[^>]*>(.*?)</td>"),
                let cite = compile("<cite[^>]*>(.*?)</cite>"),
                let em = compile("<em[^>]*>(.*?)</em>"),
                let link = compile("<a\\b[^>]*\\bhref\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>"),
                let alt = compile("<img\\b[^>]*\\balt\\s*=\\s*[\"'](\\d+)[\"']"),
                // `forum.php?mod=viewthread&tid=N`, and the classic rewrite `thread-N-1-1.html`.
                let tidQuery = compile("[?&;]tid=(\\d+)"),
                let tidRewrite = compile("(?:^|/)thread-(\\d+)-\\d+-\\d+\\.html"),
                // A `dl` cannot hold another `dl` in this markup, so the first close is its own.
                let entry = compile("<dl[^>]*\(classed("bbda"))[^>]*>(.*?)</dl>"),
                let rankDetail = compile("<dd[^>]*\(classed("ranknum"))[^>]*>(.*?)</dd>"),
                let term = compile("<dt\\b[^>]*>(.*?)</dt>"),
                // The byline is the one `dd` with no class of its own.
                let plainDetail = compile("<dd(?![^>]*\\bclass\\s*=)[^>]*>(.*?)</dd>"),
                let dimSpan = compile("<span[^>]*\(classed("xg1"))[^>]*>(.*?)</span>"),
                let excerpt = compile("<dd[^>]*class\\s*=\\s*[\"']cl[\"'][^>]*>(.*?)</dd>"),
                let blogQuery = compile("[?&;]do=blog(?:&|$)"),
                let uid = compile("[?&;]uid=(\\d+)"),
                let blogID = compile("[?&;]id=(\\d+)"),
                let blogRewrite = compile("(?:^|/)blog-(\\d+)-(\\d+)\\.html"),
                let date = compile(
                    "(\\d{4})-(\\d{1,2})-(\\d{1,2})(?:[\\s\u{00A0}]+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?)?", []
                )
            else { return nil }
            self.row = row
            self.headingRow = headingRow
            self.rankCell = rankCell
            self.heading = heading
            self.boardCell = boardCell
            self.byCell = byCell
            self.cell = cell
            self.cite = cite
            self.em = em
            self.link = link
            self.alt = alt
            self.tid = [tidQuery, tidRewrite]
            self.entry = entry
            self.rankDetail = rankDetail
            self.term = term
            self.plainDetail = plainDetail
            self.dimSpan = dimSpan
            self.excerpt = excerpt
            self.blogQuery = blogQuery
            self.uid = uid
            self.blogID = blogID
            self.blogRewrite = blogRewrite
            self.date = date
        }
    }
}

/// One thread as a forum's ranking lists it: the thread, where it stood, and its board's number.
struct DiscuzRankedThread: Equatable, Sendable {
    /// Where the page placed it, or nothing where it wrote no rank this device can read. Kept for
    /// the order it proves and nothing else: the page's order is the rank.
    let rank: Int?
    let thread: DiscuzThread
    /// The board it is in, by number, out of the row's own board cell.
    let fid: Int?

    /// **The same row as the board's own**, and only more of it: `DiscuzThread.asNote` spells
    /// the id, so a thread ranked and also read through its board is one row in the store,
    /// which gains `.trends` beside the board it is in.
    func asNote(source: Source, host: String) -> Note {
        var note = thread.asNote(source: source, host: host, board: nil, boardID: fid.map(String.init))
        note.categories.insert(.trends)
        return note
    }
}

/// One blog (日誌) as a forum's ranking lists it.
///
/// **A row of its own kind, and never a thread.** A blog lives in its author's space, not in a
/// board; it has no floors, no replies this app reads and no thread number, and its number is
/// counted apart from threads' — `500` is a plausible thread too. So its id is
/// `discuz:<host>:blog:<id>`, which `ForumThreadRef` will not take for a thread, and it is read
/// from the ranking list alone: its words are the excerpt the list wrote, and opening it opens
/// its page.
struct DiscuzRankedBlog: Equatable, Sendable {
    let rank: Int?
    let id: Int
    /// Its author, by number — part of the address a blog is served at.
    let uid: Int
    let title: String
    let author: String
    let postedAt: Date?
    /// What the list wrote of it. The forum's own cut, ellipsis and all.
    let excerpt: String

    func asNote(source: Source, host: String) -> Note {
        Note(
            id: DiscuzRankedBlog.noteID(host: host, id: id),
            source: source,
            author: author,
            handle: DiscuzHandle.of(author, host: host),
            // **The excerpt is the body, because it is what the page states.** Unlike a thread's
            // opening post, which is fetched when reached and kept apart (#154), nothing more of
            // a blog is ever read into its row — so what the list said is its words, and a
            // keyword rule or the search reads them as it reads any post's.
            body: excerpt,
            title: title,
            board: nil,
            postedAt: postedAt ?? .distantPast,
            categories: [.trends],
            url: Host.httpsURL(
                host: host,
                path: "/home.php",
                query: [
                    URLQueryItem(name: "mod", value: "space"),
                    URLQueryItem(name: "uid", value: String(uid)),
                    URLQueryItem(name: "do", value: "blog"),
                    URLQueryItem(name: "id", value: String(id)),
                ]
            )
        )
    }

    /// The one spelling of a blog row's id. See the type.
    static func noteID(host: String, id: Int) -> String { DiscuzBlogRow.id(host: host, blog: id) }
}

/// A forum blog's row id, spelled and read back in one place.
///
/// **`discuz:<host>:blog:<id>`**, four parts where a thread's has three, so nothing that reads a
/// thread number out of a row id (`ForumThreadRef`) can take a blog for a thread, and a blog and a
/// thread that share a number are two rows.
public enum DiscuzBlogRow {
    public static func id(host: String, blog: Int) -> String { "discuz:\(host):blog:\(blog)" }

    /// Whether a row id is a forum blog's.
    public static func isBlog(_ noteID: String) -> Bool {
        let parts = noteID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "discuz", !parts[1].isEmpty, parts[2] == "blog",
              let id = Int(parts[3])
        else { return false }
        return id > 0
    }
}
