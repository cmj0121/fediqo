import Foundation

// MARK: - A ranked blog, read off its own page — #209

/// One blog (日誌) as its own page carries it: who wrote it, when, what it is called, and **their
/// words and nobody else's** — `DiscuzPost.body`'s rule, read by the same hands.
///
/// A blog is one post by one person, so it is read as a topic's opening post is: its words are
/// taken out of their container with the forum's furniture removed (`DiscuzPostLayout.words`), a
/// picture leaves nothing behind in them, and what it quoted is kept apart. What the ranking list
/// already said of it — its title, author and date — is read again here because the page says it
/// with more care: a date to the minute where the list gave one, and the author's picture.
public struct DiscuzBlog: Hashable, Sendable {
    public let id: Int
    /// Its author, by number — half the address it is served at.
    public let uid: Int
    /// What the page calls it. Empty where the page's heading could not be read, which the row's
    /// own title — the ranking list's — stands in for.
    public let title: String
    /// Whoever the page names as its author. Empty where it names nobody this device can read.
    public let author: String
    public let postedAt: Date?
    public let body: String
    public let quoted: [DiscuzQuotation]
    /// The author's picture, where the page drew one — read, checked and never built, for the
    /// reason `DiscuzPost.avatarURL` gives.
    public let avatarURL: URL?

    public init(
        id: Int, uid: Int, title: String, author: String, postedAt: Date?, body: String,
        quoted: [DiscuzQuotation] = [], avatarURL: URL? = nil
    ) {
        self.id = id
        self.uid = uid
        self.title = title
        self.author = author
        self.postedAt = postedAt
        self.body = body
        self.quoted = quoted
        self.avatarURL = avatarURL
    }

    /// What is kept with the blog's row once it is read — the words, what they quoted, the
    /// author's picture and the page's own date. **The row's shape and no new one**: a blog's row
    /// already is a `Note`, and a read blog is that row with an opening, as a read thread is.
    public var opening: ForumOpening {
        ForumOpening(words: body, quoted: quoted, avatarURL: avatarURL, postedAt: postedAt)
    }
}

/// A Discuz! blog page, read as structure — `DiscuzThreadPage`'s rule applied to the page a blog
/// lives on: `home.php?mod=space&uid=…&do=blog&id=…`.
///
/// **What X3.x's own template writes, and what this reads of it.**
///
/// ```text
///   div#pt       breadcrumb: … › <a …mod=space&uid=N>author</a> › <a …do=blog…>日誌</a> › …
///   div.vw       h1.ph(title)  p.xg2(span.xg1(date) …)
///                div#blog_article(the words)
///   div#pcd      <a …mod=space&uid=N class="avtm"><img avatar></a>  h2(<a …uid=N>author</a>)
/// ```
///
/// **Anchored on an id, a tag and a number, never on a label** — `DiscuzRanklist`'s rule. The
/// words are the one element Discuz! gives the id `blog_article`, which no other page has; the
/// title is the page's heading; the date is the first one written between the heading and the
/// words; and the author is found by the number the row already holds — the first link to *that*
/// person's space with a name on it — so a reader's own name in the page's header, a visitor in
/// the sidebar or a commenter under the words cannot be taken for them.
///
/// **Measured on no install.** The ranking list's markup was measured on `install-g.example`;
/// this page's is Discuz! X3.x's shipped template (`home/space_blog_view`), and no capture of a
/// live blog page stood behind it. So nothing here is more than the template promises, and every
/// part but the words is optional: a page whose heading, date or author this does not find still
/// reads, with the row's own title, author and date in their place. A page with no
/// `blog_article` is not a blog this device can read, and says so.
enum DiscuzBlogPage {
    static func blog(in html: String, id: Int, uid: Int, host: String) -> DiscuzBlog? {
        guard let patterns = Patterns.shared, let post = DiscuzThreadPage.Patterns.shared,
              let opened = patterns.article.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let start = Range(opened.range, in: html),
              let article = DiscuzMarkup.balanced(in: html, nesting: post.divs, from: start.upperBound)
        else { return nil }
        let words = DiscuzPostLayout.words(in: String(html[article.range]), patterns: post)
        // Everything above the words: the heading, then the line under it with the date.
        let above = String(html[..<start.lowerBound])
        let heading = patterns.heading.matches(in: above, range: NSRange(above.startIndex..., in: above)).last
        let title = heading
            .flatMap { Range($0.range(at: 1), in: above) }
            .map { HTMLText.plain(String(above[$0])) } ?? ""
        let byline = heading
            .flatMap { Range($0.range, in: above) }
            .map { String(above[$0.upperBound...]) } ?? ""
        let line = patterns.dateLine.capture(1, in: byline) ?? byline
        let posted = line.isEmpty ? nil : DiscuzDate.parse(line, date: post.date)
        let person = Self.person(uid, in: html, patterns: patterns)
        return DiscuzBlog(
            id: id,
            uid: uid,
            title: title,
            author: person.name,
            postedAt: posted,
            body: words.body,
            quoted: words.quoted,
            avatarURL: person.picture.flatMap { DiscuzPostLayout.address(in: $0, host: host, patterns: post) }
        )
    }

    /// The author's name, and the `<img>` tag of their picture, out of the links the page makes
    /// to their space.
    ///
    /// **Their space, by number, and nothing else of it.** `mod=space&uid=N` with no `do=` is a
    /// person's own page; the same address with `do=blog` is the blog list the breadcrumb names
    /// next, and `mod=spacecp` is a control. The first such link with words in it is the name —
    /// the breadcrumb's, on the template — and the first whose words are only a picture is the
    /// face. A link whose words are an address (`https://…/?21`, the space's own short link) is
    /// not a name.
    private static func person(
        _ uid: Int, in html: String, patterns: Patterns
    ) -> (name: String, picture: String?) {
        var name = ""
        var picture: String?
        let range = NSRange(html.startIndex..., in: html)
        for match in patterns.link.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let labelRange = Range(match.range(at: 2), in: html)
            else { continue }
            let href = html[hrefRange].replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            guard Self.isSpace(of: uid, href) else { continue }
            let label = String(html[labelRange])
            let plain = HTMLText.plain(label)
            if name.isEmpty, !plain.isEmpty, !plain.lowercased().hasPrefix("http"), !plain.hasPrefix("?") {
                name = plain
            }
            if picture == nil, plain.isEmpty, let tag = patterns.image.capture(0, in: label) {
                picture = tag
            }
            if !name.isEmpty, picture != nil { break }
        }
        return (name, picture)
    }

    /// Whether an address is person `uid`'s own space: `mod=space`, `uid=` exactly this number,
    /// and no `do=` — or the rewrite `space-uid-N.html`.
    private static func isSpace(of uid: Int, _ href: String) -> Bool {
        if href.range(of: #"(?:^|/)space-uid-\#(uid)\.html"#, options: .regularExpression) != nil {
            return true
        }
        return href.range(of: #"[?&;]mod=space(?:[&;]|$)"#, options: .regularExpression) != nil
            && href.range(of: #"[?&;]uid=\#(uid)(?![0-9])"#, options: .regularExpression) != nil
            && href.range(of: #"[?&;]do="#, options: .regularExpression) == nil
    }

    /// The patterns, compiled once for the life of the process — `DiscuzPage.Patterns`' reason.
    struct Patterns: @unchecked Sendable {
        /// Compiled on first use and shared by every page read after it.
        static let shared = Patterns()

        /// `<div id="blog_article">`, the words.
        let article: NSRegularExpression
        /// Every `<h1>`, the last of which above the words is the blog's own heading.
        let heading: NSRegularExpression
        /// `<p class="xg2">` under the heading, where the template writes the date first.
        let dateLine: NSRegularExpression
        let link: NSRegularExpression
        let image: NSRegularExpression

        init?() {
            let options: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
            func compile(_ pattern: String) -> NSRegularExpression? {
                try? NSRegularExpression(pattern: pattern, options: options)
            }
            guard
                let article = compile("<div[^>]*\(DiscuzMarkup.attribute("id", "blog_article"))[^>]*>"),
                let heading = compile("<h1\\b[^>]*>(.*?)</h1>"),
                let dateLine = compile("<p[^>]*\(DiscuzMarkup.classed("xg2"))[^>]*>(.*?)</p>"),
                let link = compile("<a\\b[^>]*\\bhref\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>"),
                let image = compile("<img\\b[^>]*>")
            else { return nil }
            self.article = article
            self.heading = heading
            self.dateLine = dateLine
            self.link = link
            self.image = image
        }
    }
}
