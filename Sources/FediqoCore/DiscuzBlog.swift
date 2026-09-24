import Foundation

// MARK: - A ranked blog, read off its own page — #209

/// One blog (日誌) as its own page carries it: when it was written, the author's picture, and
/// **their words and nobody else's** — `DiscuzPost.body`'s rule, read by the same hands.
///
/// A blog is one post by one person, so it is read as a topic's opening post is: its words are
/// taken out of their container with the forum's furniture removed (`DiscuzPostLayout.words`), a
/// picture leaves nothing behind in them, and what it quoted is kept apart.
///
/// **No title and no author**, which the ranking list already gave its row and which stay the
/// row's: what a reader saw in Trends is what the opened blog is called and who it is by. The
/// page is read for what the list could not say — a date to the minute where the list gave one,
/// and the author's picture.
public struct DiscuzBlog: Hashable, Sendable {
    public let id: Int
    /// Its author, by number — half the address it is served at.
    public let uid: Int
    public let postedAt: Date?
    public let body: String
    public let quoted: [DiscuzQuotation]
    /// The author's picture, where the page drew one — read, checked and never built, for the
    /// reason `DiscuzPost.avatarURL` gives.
    public let avatarURL: URL?

    public init(
        id: Int, uid: Int, postedAt: Date?, body: String,
        quoted: [DiscuzQuotation] = [], avatarURL: URL? = nil
    ) {
        self.id = id
        self.uid = uid
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
/// **What the page writes, and what this reads of it** — measured on a real X5.0.2 install, the
/// local one in `servers/`:
///
/// ```text
///   div#pt       breadcrumb: … › <a …mod=space&uid=N>author</a> › <a …do=blog…>日志</a>
///   div#uhd      div.avt(<a …mod=space&uid=N><img data-src=avatar></a>)  h2.mt(author)
///   div.vw       h1.ph(title)  p.xg2(span.xg1(read count) span.xg1(date))
///                div#blog_article(the words)
///                div#click_div(buttons)  …  comments
/// ```
///
/// **Anchored on an id, a tag and a number, never on a label** — `DiscuzRanklist`'s rule. The
/// words are the one element Discuz! gives the id `blog_article`, which no other page has; the
/// date is the first one written between the page's heading and the words; and the picture is
/// found by the number the row already holds — a link to *that* person's space whose words are
/// only a picture.
///
/// **The picture is looked for above the words, and in X3.x's author card, and nowhere else.**
/// Under the words are the comments, and a commenter is somebody else; the author's own blog
/// can link their own space too, but what it links is their writing, not their face. X5.0 draws
/// the face in `#uhd`, above the words; X3.x's template has it in a sidebar card `#pcd`, which
/// may come after them in the page, so that card is read by name.
///
/// The date line leads with the read count, so the date is the first one *in* it rather than its
/// first words; the avatar is lazy-loaded into `data-src`, which `DiscuzPostLayout.address` reads
/// first, and an author with none is the template's `noavatar`, which is no picture. Discuz!'s
/// own notice answers every refusal measured — a blog only its author may read, one behind a
/// password and a number with no blog, each to a signed-out reader, and a forum with blogs
/// switched off, which is how X5.0 installs — so `DiscuzClient.page` refuses them all.
///
/// **Measured on X5.0 and not on the reader's X3.2.** The ranking list was measured on
/// `install-g.example`; its blog pages were not, and X3.2's template is the same
/// `home/space_blog_view` lineage. So every part but the words is optional: a page whose date or
/// picture this does not find still reads, with the row's own date in its place. A page with no
/// `blog_article` is not a blog this device can read, and says so.
enum DiscuzBlogPage {
    static func blog(in html: String, id: Int, uid: Int, host: String) -> DiscuzBlog? {
        guard let patterns = Patterns.shared, let post = DiscuzThreadPage.Patterns.shared,
              let article = Self.article(in: html, patterns: patterns, divs: post.divs)
        else { return nil }
        let words = DiscuzPostLayout.words(in: String(html[article.words]), patterns: post)
        // Everything above the words: the heading, then the line under it with the date.
        let above = String(html[..<article.whole.lowerBound])
        let heading = patterns.heading.matches(in: above, range: NSRange(above.startIndex..., in: above)).last
        let byline = heading
            .flatMap { Range($0.range, in: above) }
            .map { String(above[$0.upperBound...]) } ?? ""
        let line = patterns.dateLine.capture(1, in: byline) ?? byline
        let posted = line.isEmpty ? nil : DiscuzDate.parse(line, date: post.date)
        let card = DiscuzMarkup.content(patterns.card, nesting: post.divs, in: html) ?? ""
        let picture = Self.picture(of: uid, in: above + card, patterns: patterns)
        return DiscuzBlog(
            id: id,
            uid: uid,
            postedAt: posted,
            body: words.body,
            quoted: words.quoted,
            avatarURL: picture.flatMap { DiscuzPostLayout.address(in: $0, host: host, patterns: post) }
        )
    }

    /// The page with the blog's own words taken out — what `DiscuzClient.page` looks for a
    /// challenge or the forum's notice in. Somebody's blog may say `Just a moment` or write
    /// `id="messagetext"` in its words; the forum's own markup around them never does. A page
    /// with no words on it is judged whole.
    static func withoutWords(_ html: String) -> String {
        guard let patterns = Patterns.shared, let divs = DiscuzThreadPage.Patterns.shared?.divs,
              let article = Self.article(in: html, patterns: patterns, divs: divs)
        else { return html }
        return String(html[..<article.whole.lowerBound]) + String(html[article.whole.upperBound...])
    }

    /// Where `div#blog_article` is: the element whole, and its words inside it.
    private static func article(
        in html: String, patterns: Patterns, divs: NSRegularExpression
    ) -> (whole: Range<String.Index>, words: Range<String.Index>)? {
        guard let opened = patterns.article.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let start = Range(opened.range, in: html),
              let inside = DiscuzMarkup.balanced(in: html, nesting: divs, from: start.upperBound)
        else { return nil }
        return (start.lowerBound..<inside.after, inside.range)
    }

    /// The `<img>` tag of the author's picture, out of the links `markup` makes to their space.
    ///
    /// **Their space, by number, and nothing else of it.** `mod=space&uid=N` with no `do=` is a
    /// person's own page; the same address with `do=blog` is the blog list the breadcrumb names
    /// next, and `mod=spacecp` is a control. The first such link whose words are only a picture is
    /// the face; the breadcrumb's, which names them, is passed over.
    private static func picture(of uid: Int, in markup: String, patterns: Patterns) -> String? {
        let range = NSRange(markup.startIndex..., in: markup)
        for match in patterns.link.matches(in: markup, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: markup),
                  let labelRange = Range(match.range(at: 2), in: markup)
            else { continue }
            let href = markup[hrefRange].replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            guard Self.isSpace(of: uid, href) else { continue }
            let label = String(markup[labelRange])
            if HTMLText.plain(label).isEmpty, let tag = patterns.image.capture(0, in: label) {
                return tag
            }
        }
        return nil
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
        /// `<div id="pcd">`, X3.x's author card.
        let card: NSRegularExpression
        /// Every `<h1>`, the last of which above the words is the blog's own heading.
        let heading: NSRegularExpression
        /// `<p class="xg2">` under the heading, where the template writes the date.
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
                let card = compile("<div[^>]*\(DiscuzMarkup.attribute("id", "pcd"))[^>]*>"),
                let heading = compile("<h1\\b[^>]*>(.*?)</h1>"),
                let dateLine = compile("<p[^>]*\(DiscuzMarkup.classed("xg2"))[^>]*>(.*?)</p>"),
                let link = compile("<a\\b[^>]*\\bhref\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>"),
                let image = compile("<img\\b[^>]*>")
            else { return nil }
            self.article = article
            self.card = card
            self.heading = heading
            self.dateLine = dateLine
            self.link = link
            self.image = image
        }
    }
}
