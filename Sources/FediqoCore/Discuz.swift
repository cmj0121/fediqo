import Foundation

// MARK: - The installs these measurements were taken on
//
// Almost every rule in this file is here because a running forum did something a reasonable
// person would not have guessed, and the comments say which forum and what it did. Those forums
// are **not named**: the reader asked that no real server be left anywhere in this repository,
// and a measurement does not need an identity to be worth reading — it needs a *property*.
//
// So each install is named by what it is. This is the one place the table lives; everything in
// `Sources` and `Tests` uses these names and nothing anywhere maps them back, which is the whole
// object of the exercise.
//
// | codename | what it stands for |
// | --- | --- |
// | `install-a.example` | X3.4. Grid index; classic rewrite `forum-N-1.html`; **declares UTF-8 and carries stray non-UTF-8 bytes**; a third-party mobile template that is not Discuz!'s markup; replies withheld from a signed-out reader; a picture replaced by a `javascript:` link |
// | `install-b.example` | X3.5/X5.0 **English**. Grid index; SEO slug addresses; counts with no `title` behind them; a board that has never been posted in and says so with `...`; a `[quote]` around something that is not a person; a Copy Code button |
// | `install-c.example` | X5.0. Grid index; canonical `forum.php?mod=forumdisplay&fid=N`; abbreviated counts (`5万`) keeping the exact figure in a `title`; a touch template that **lazy-loads** its avatars into `data-src`; a desktop template whose avatar box is `favatar` and is filled in by script, so there is no `<img>` to read; pinned threads |
// | `install-d.example` | X3.4 served **GBK** — and UTF-8 on its own mobile page, so one forum is two encodings. The **wide list** index layout: a board's name is an `<h2>`, which is what makes "the heading nearest this section" the wrong rule; sub-boards written as bare links inside a parent's cell; avatars on two hosts, neither of them the forum; a favourite button in the same list as the author's name |
// | `install-e.example` | X3.4 with **nothing a signed-out reader may see**: a hand-written `id="category_-99999"` block in place of a forum list, Discuz!'s own `messagetext` notice on every board, an empty guide table, and the sign-in page |
// | `install-f.example` | Discourse |
// | `challenge.example` | a forum behind a managed challenge |
// | `avatars-d.example` | `install-d`'s avatar host on the touch template |
// | `files-d.example` | `install-d`'s avatar host on the desktop template — a *second* host that is not the forum |
//
// **The numbers are kept and the identities are not.** A count, a byte size, a ratio or a claim
// about markup is the evidence an argument here rests on; the name of the server it came off is
// not part of the argument.

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
/// address a thread the same way — `thread-410728-1-1.html`, `forum.php?mod=viewthread&tid=…`,
/// and on `install-b.example` an SEO slug, `-english-language-pack-4201-1-1.html`.
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

    /// One thread's **opening post** — the words the row is missing.
    ///
    /// D30: a Discuz! thread table carries a title and nothing else, so the body a reader sees on
    /// a row has to be fetched from the thread itself. This is that fetch, and it is deliberately
    /// **not** the same call as `replies`: the row wants one post and the reader asks for the
    /// rest only sometimes, so the second read is paid only when it is asked for.
    ///
    /// **Which post is the opening one.** The floor — `1#` — where the page stated one, and the
    /// first post in the order the page wrote them where it did not. Floor first because a forum
    /// can be configured to list a thread newest-first, and "the first one on the page" would
    /// then be the most recent reply wearing the opening post's place: a plausible wrong answer,
    /// which is the family of mistake this file's thread-table rules exist to avoid. Document
    /// order is the fallback rather than the rule because one of the four measured templates —
    /// the third-party one on `install-a.example` — numbers every reply and leaves the opening post
    /// unnumbered.
    public func post(tid: Int) async throws -> DiscuzPost {
        let posts = try await self.posts(tid: tid)
        guard let opening = posts.first(where: { $0.floor == 1 }) ?? posts.first else {
            throw DiscuzRequestError.noPosts
        }
        return opening
    }

    /// The rest of the same topic — D31, and nothing else.
    ///
    /// **"Load other threads" meant the replies of this topic**, confirmed by the reader. Not the
    /// board's next page, and not a long topic's later pages: a Discuz! thread paginates at the
    /// forum's own configured size and this reads the first page only, which is what `post` read
    /// and what the site opens on. Later pages are their own question and neither was asked for.
    ///
    /// Everything the page listed except the opening post, in the order it listed them.
    public func replies(tid: Int) async throws -> [DiscuzPost] {
        let posts = try await self.posts(tid: tid)
        guard let opening = posts.first(where: { $0.floor == 1 }) ?? posts.first else {
            throw DiscuzRequestError.noPosts
        }
        return posts.filter { $0.pid != opening.pid }
    }

    /// One thread page fetched, judged by `page`, and turned into posts.
    ///
    /// **`&mobile=2`, and what it is really worth.** Measured on 2026-09-16, the busiest thread
    /// each install's guide page named:
    ///
    /// | host | version | what `&mobile=2` answers with | full | mobile |
    /// | --- | --- | --- | --- | --- |
    /// | `install-c.example` | X5.0 | Discuz!'s own touch template | 186,836 | 60,319 |
    /// | `install-b.example` | X3.5/X5.0 EN | Discuz!'s own touch template | 58,067 | 17,436 |
    /// | `install-d.example` | X3.4 GBK | Discuz!'s own touch template, **served UTF-8** | 33,189 | 8,344 |
    /// | `install-a.example` | X3.4 | **Comiis**, a third-party mobile template | 274,457 | 238,791 |
    ///
    /// So it is worth roughly a quarter to a third of the bytes on three installs out of four —
    /// and on the fourth it is worth **nothing**: `install-a.example` has a third-party mobile
    /// template installed, which answers `&mobile=2` with markup that is not Discuz!'s and, on a
    /// short thread, is *larger* than the desktop page (55,351 against 47,746). `&mobile=2` is
    /// therefore a **hint, not a contract**, and the one thing that cannot be built on it is that
    /// the answer will be any particular markup.
    ///
    /// **So the request is made once and the answer is read for whatever it is.** Three shapes
    /// are enumerated in `DiscuzPostLayout` — Discuz!'s touch template, the third-party one, and
    /// the ordinary desktop page an install with its mobile template switched off would return —
    /// rather than fetching the mobile page, judging it, and fetching the desktop page after it,
    /// which is two requests into a stranger's forum to save bytes on one.
    ///
    /// `archiver/tid-N.html`, which would have been cheaper still, is not usable: **404 on
    /// `install-c.example`**, and it is a setting like the mobile JSON API and RSS before it. It does
    /// answer on `install-b.example` and `install-d.example`, which is exactly what makes it unusable —
    /// a source that is there on some installs and absent on others cannot be the one that is
    /// asked first without asking twice everywhere it is missing.
    private func posts(tid: Int) async throws -> [DiscuzPost] {
        guard tid > 0, let url = Host.httpsURL(
            host: host,
            path: "/forum.php",
            query: [
                URLQueryItem(name: "mod", value: "viewthread"),
                URLQueryItem(name: "tid", value: String(tid)),
                URLQueryItem(name: "mobile", value: "2"),
            ]
        ) else {
            throw DiscuzRequestError.invalidURL
        }
        let html = try await page(url)
        let posts = DiscuzThreadPage.posts(in: html, tid: tid, host: host)
        // The rule `read` states for an empty thread table, one page down and for the same
        // reason: a parser that meets markup it cannot read and answers `[]` gives the reader a
        // blank row forever with nothing to explain it. It is also the backstop under a case
        // measured live — `install-a.example` answers a signed-out reader's request for a thread in
        // a members-only board with **its login page, at status 200**, which is neither a
        // challenge nor Discuz!'s own `messagetext` notice, so nothing above catches it and this
        // does.
        guard !posts.isEmpty else { throw DiscuzRequestError.noPosts }
        return posts
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
        // **Asked for a thread, handed the sign-in page.** Measured on `install-a.example`: a thread
        // in a members-only board answers `&mobile=2` with a 302 to
        // `member.php?mod=logging&action=login`, which then answers **200** with a real login form
        // and no `id="messagetext"` anywhere — so the notice-page rule above does not see it, and
        // what reached the reader was "we could not read that" where "you need an account" is the
        // truer answer and the one their sign-in can do something about.
        //
        // Judged on **where the answer came from** rather than on anything in it. The address is
        // the server's own statement about what it served, it survives translation and every
        // template, and it cannot be confused with the quick-login box that sits in the header of
        // an ordinary forum page. Nothing in this client ever asks for `member.php`, so a response
        // that arrives from one is a redirect and nothing else.
        if DiscuzPage.isSignInPage(response.url) { throw DiscuzRequestError.restricted }
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
        // nothing: its rows name a section but did not arrive through one, so they carry no
        // category — a source rule still reaches them (#31).
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
    /// A thread page that answered, decoded, and had no post in it that this device could read.
    /// Its own case for the same reason `noBoards` is: "we could not read that thread" and "that
    /// board is empty" are answers to different questions. See the guard in `posts(tid:)`.
    case noPosts
}

/// How somebody is addressed, spelled once.
///
/// A forum gives a poster a name and links it by uid; the name is what the forum calls them and
/// is what a handle can be built from. It is built in one place rather than at each of the two
/// sites that need it — a thread row and a post — because this branch's second convention is
/// that a rule restated at each consumer is a rule consumer N+1 misses, and the post reader *is*
/// consumer N+1 to the thread table.
enum DiscuzHandle {
    /// `@name@host`, or nothing at all where the page named nobody — never a bare `@@host`.
    static func of(_ author: String, host: String) -> String {
        author.isEmpty ? "" : "@\(author)@\(host)"
    }
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
    /// The board this one sits under, where the index wrote it under one. **D29.**
    ///
    /// A sub-board is a separate `fid` in Discuz! and it is a separate pick here, because a
    /// parent's `forumdisplay` does *not* include its children's threads: a checkbox that quietly
    /// meant nine boards would be either a lie or nine boards' worth of traffic nobody asked for.
    /// Verified live — `install-d.example` board 300 (a child of 297) answers
    /// `forum.php?mod=forumdisplay&fid=300` with its own heading and sixty-three threads of its
    /// own, none of which appear under 297.
    ///
    /// **A sub-board is emptier than a board, and that is the honest cost.** On the index it is a
    /// bare name: no thread count, no post count, no last-post time. Those stay `nil` rather than
    /// becoming zeroes, which is this file's standing rule about a figure the forum did not state.
    public let parent: Int?
    /// How far to indent it: `0` for a board, `1` for a board under one.
    ///
    /// Derived from `parent` rather than stored beside it, so the two can never disagree — and it
    /// stops at one because one level is all a Discuz! index states. A forum may nest deeper in
    /// its own database; its index page writes a board's *direct* children and no further, so a
    /// deeper number here would be a claim this device cannot support.
    public var depth: Int { parent == nil ? 0 : 1 }

    public init(
        fid: Int,
        name: String,
        category: String,
        gid: Int,
        threads: Int? = nil,
        posts: Int? = nil,
        lastPostAt: Date? = nil,
        parent: Int? = nil
    ) {
        self.fid = fid
        self.name = name
        self.category = category
        self.gid = gid
        self.threads = threads
        self.posts = posts
        self.lastPostAt = lastPostAt
        self.parent = parent
    }
}

/// A section of the index, and the boards the forum put under it.
///
/// **In reading order, with a board's children directly after it.** `boards` is flat rather than
/// a tree because that is the shape a picker draws — one row each, indented by `DiscuzBoard.depth`
/// — and it is what `JoinOffer.boards` flattens to without having to know about nesting at all.
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

        let found: [DiscuzCategory] = divs.enumerated().compactMap { index, div in
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

        // **A board the index named in its own right is nobody's sub-board**, and this is the
        // half of the sub-board rule that cannot be decided inside one category. A board's own
        // cell may link to a board that is listed, with its counts and its date, somewhere else
        // on the page — a moderator's pointer in a description, or a section that repeats — and
        // taking that link for a child would draw the same board twice: once as itself and once,
        // countless and dateless, indented under something it is not under. The reader would
        // then be able to pick it twice.
        //
        // It is also the half that the four live indexes prove is needed together with the
        // other: with both, the rule finds **all 39** of `install-d.example`'s sub-boards and invents
        // **none** on the three installs that have none.
        let named = Set(found.flatMap(\.boards).filter { $0.parent == nil }.map(\.fid))
        return found.compactMap { category in
            let kept = category.boards.filter { $0.parent == nil || !named.contains($0.fid) }
            return kept.isEmpty
                ? nil
                : DiscuzCategory(gid: category.gid, name: category.name, boards: kept)
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
    /// `install-d.example` both write `<span title="31842">3万</span>` once a figure passes ten
    /// thousand, and reading the text would report a board with thirty-one thousand threads as
    /// having three. `install-b.example` abbreviates nothing and carries no `title` at all, so both
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
        return container.matches(in: section, range: range).flatMap { match -> [(at: Int, board: DiscuzBoard)] in
            guard let bodyRange = Range(match.range(at: 1), in: section) else { return [] }
            return self.boards(
                in: String(section[bodyRange]),
                // Every board is placed by where its own anchor is on the page, in the section's
                // own coordinates — not by where its container is. That is what makes a single
                // sort put a parent, then its children, then the next parent, in the order a
                // reader would choose from them, without anybody arranging it.
                at: match.range(at: 1).location,
                gid: gid,
                category: category,
                patterns: patterns
            )
        }
    }

    /// One board's cell: the board it names, and the boards it names underneath it.
    private func boards(
        in body: String,
        at origin: Int,
        gid: Int,
        category: String,
        patterns: DiscuzIndex.Patterns
    ) -> [(at: Int, board: DiscuzBoard)] {
        // Where the name is. The grid's `<dt>` and the wide layout's `<h2>` are the only places a
        // board's *own* number is read from, and everything else in the cell that yields a number
        // is a board underneath it.
        let named: NSRegularExpression
        switch self {
        case .grid: named = patterns.term
        case .list: named = patterns.name
        }
        let whole = NSRange(body.startIndex..., in: body)
        guard let headingMatch = named.firstMatch(in: body, range: whole),
              let headingRange = Range(headingMatch.range(at: 1), in: body)
        else { return [] }
        let heading = String(body[headingRange])
        guard let match = patterns.anchor.firstMatch(
                in: heading, range: NSRange(heading.startIndex..., in: heading)
              ),
              let hrefRange = Range(match.range(at: 1), in: heading),
              let labelRange = Range(match.range(at: 2), in: heading),
              let fid = DiscuzIndex.fid(inHref: String(heading[hrefRange]), patterns: patterns)
        else { return [] }
        let name = HTMLText.plain(String(heading[labelRange]))
        guard !name.isEmpty else { return [] }

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
        let board = DiscuzBoard(
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
        return [(origin + headingMatch.range(at: 1).location, board)]
            + self.children(
                in: body, at: origin, of: board, naming: headingMatch.range(at: 1),
                patterns: patterns
            )
    }

    /// The boards this board's own cell names underneath it — **D29**.
    ///
    /// **One structural rule, and not one word of any language.** A sub-board is an anchor inside
    /// a board's own cell that yields a board number, is not that board's own number, and is not
    /// the anchor that names it. `install-d.example` labels the row `子版块:` and an English install
    /// would label it something else; the label is the half that is translated, the same way the
    /// count labels are, so neither is read.
    ///
    /// **An anchor with nothing to read is not a board a reader can pick.** That is not tidiness:
    /// it is what keeps a board's own icon out of the answer. The wide layout puts the parent's
    /// picture in a cell of its own — `<td class="fl_icn"><a href="forum-297-1.html"><img/></a>`
    /// — whose address yields a number and whose text is an image. Requiring a name is what
    /// refuses it, and the number test alone would not have.
    ///
    /// **Measured on all four indexes on 2026-09-16**, which is the whole of the evidence for it:
    ///
    /// | host | layout | boards named | sub-boards found |
    /// | --- | --- | --- | --- |
    /// | `install-d.example` | `list` | 23 | **39** — `<p>子版块: <a>…</a>, <a>…</a></p>` beside the name |
    /// | `install-c.example` | `grid` | 32 | 0 — the install has none; `forum.php?forumlist=1` names the same 32 |
    /// | `install-a.example` | `grid` | 33 | 0 — likewise, the same 33 |
    /// | `install-b.example` | `grid` | 14 | 0 |
    ///
    /// So the `grid` layout's sub-boards are **unmeasured, because no install measured has any**,
    /// and this is deliberately not answered by guessing at what its markup would be. The rule is
    /// the same rule on both layouts and it finds whatever is written the way a sub-board is
    /// written; where an install writes them some other way it finds **nothing**, which is the
    /// answer to give — a sub-board attached to the wrong parent is a wrong answer a reader
    /// cannot see is wrong, and a missing one is merely a board they will not be offered.
    ///
    /// The one thing it will take for a sub-board that is not one: a link to *another* board
    /// written inside a board's description. That board is real and picking it works; it is only
    /// drawn in the wrong place. Preferred to the alternative, which is reading the label.
    private func children(
        in body: String,
        at origin: Int,
        of parent: DiscuzBoard,
        naming heading: NSRange,
        patterns: DiscuzIndex.Patterns
    ) -> [(at: Int, board: DiscuzBoard)] {
        let whole = NSRange(body.startIndex..., in: body)
        return patterns.anchor.matches(in: body, range: whole).compactMap { match in
            // Inside the element that names the board: that is the board itself.
            guard !NSLocationInRange(match.range.location, heading) else { return nil }
            guard let hrefRange = Range(match.range(at: 1), in: body),
                  let labelRange = Range(match.range(at: 2), in: body),
                  let fid = DiscuzIndex.fid(inHref: String(body[hrefRange]), patterns: patterns),
                  fid != parent.fid
            else { return nil }
            let name = HTMLText.plain(String(body[labelRange]))
            guard !name.isEmpty else { return nil }
            // **Nothing, not zero.** F3 measured that on the index a sub-board is a name and
            // nothing else — no thread count, no post count, no last-post time — so it carries
            // none, rather than three zeroes a reader would take for facts about the board.
            return (
                origin + match.range.location,
                DiscuzBoard(
                    fid: fid,
                    name: name,
                    category: parent.category,
                    gid: parent.gid,
                    parent: parent.fid
                )
            )
        }
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
            handle: DiscuzHandle.of(author, host: host),
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
            categories: boardID.map { [.board(id: $0)] } ?? [],
            // Discuz! puts no avatar in a thread table. It can be *guessed* at
            // `uc_server/avatar.php?uid=…`, and that guess is wrong on any install that moved or
            // renamed UCenter — so nothing is drawn rather than a broken address fetched fifty
            // times per page.
            //
            // **Still nothing here, and the row now fills it in from somewhere else.** The thread
            // *page* does carry the author's picture, and D30 already fetches that page when the
            // row is scrolled to — so the avatar arrives with the opening post rather than
            // costing a request of its own. `DiscuzPost.avatarURL` is where it comes from and
            // `DummyItemRow.avatar` is where the two are put together. Reading it here instead
            // would mean forty thread pages for one board listing, which is the traffic D30
            // exists to refuse.
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
    /// Whether an answer arrived from Discuz!'s sign-in page rather than from what was asked for.
    ///
    /// Both halves are required. `member.php` alone is a reader's profile, their messages and
    /// half a dozen other pages; `mod=logging` alone appears in the header of an ordinary page as
    /// the quick-login box's action. Together, and as the address the response actually came
    /// **from**, they are a redirect to sign in and nothing else.
    ///
    /// A `nil` url is not a sign-in page. A transport that does not report where it ended up is
    /// answering "I do not know", and turning that into "you need an account" would put a sign-in
    /// prompt in front of a reader whose forum is simply open.
    static func isSignInPage(_ url: URL?) -> Bool {
        guard let url, url.path.hasSuffix("member.php") else { return false }
        let query = url.query ?? ""
        return query.contains("mod=logging") && query.contains("action=login")
    }

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
            // a listing it does not belong to: `install-c.example`'s globally pinned thread reads
            // under a board it is not in. Its number, title, author, date and
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

// MARK: - One thread's posts

/// One post in a thread: who wrote it, when, and **their words and nobody else's**.
///
/// The last clause is the whole of the difficulty. A Discuz! post's container holds the author's
/// words together with a quotation of somebody else's, the forum's own edit notice, an
/// attachment's filename and download count, a reply-reward badge, a "Copy Code" button, and —
/// where the reader may not see the post at all — a line inviting them to sign in. Every one of
/// those reads as a sentence once the markup is stripped, and a row drawn from the lot of them
/// would put a stranger's words, or the forum's, under this person's name. So `body` is what is
/// left after the furniture is taken out, and each thing taken out is either kept somewhere it
/// can be told apart (`quoted`, `isWithheld`) or is not somebody's words at all.
public struct DiscuzPost: Identifiable, Hashable, Sendable {
    public var id: Int { pid }
    /// Discuz!'s own post number, unique on the forum. The key, because a post is what repeats
    /// on a page and a floor is not: a thread's later page starts again at its own count.
    public let pid: Int
    /// The thread it was read in.
    public let tid: Int
    /// The floor: `1#`, `2#`, `1楼`, `#1`. Nothing where the template did not number it — the
    /// third-party mobile template on `install-a.example` numbers every reply and leaves the opening
    /// post unnumbered. See `DiscuzClient.post(tid:)` for what it is used for.
    public let floor: Int?
    /// Whoever wrote it, as the forum spells their name.
    public let author: String
    /// `@name@host`, built the way a thread row's is. Empty where the page named nobody.
    public let handle: String
    /// When it was written, where the page said so in a way this device can read.
    ///
    /// **A mobile template often does not.** Measured: a recent post reads `昨天 22:48` or
    /// `2 小时前` with no `title` beside it, where the desktop page writes
    /// `<span title="2026-9-15 22:48:55">` for the same post. So this is `nil` far more often
    /// here than on a thread row, and a `nil` is the honest answer rather than a clock reading
    /// invented from words. A row's own date is unaffected: it comes off the thread table, which
    /// does carry the attribute.
    public let postedAt: Date?
    /// The author's words. Empty where the post was a picture, or where it was withheld.
    public let body: String
    /// What this post reproduced of somebody else's, where it quoted one.
    ///
    /// Kept out of `body` and kept rather than dropped. Out of `body` because a reply that opens
    /// by quoting the whole post above it would fill a line-limited row with a stranger's
    /// sentence and never show its own; kept because a deletion nobody can see is the kind of
    /// thing that looks right on a fixture, and because the quotation is real content a reader
    /// may want drawn as a quotation.
    public let quoted: String?
    /// The forum answered with a notice where the words should have been — `游客请登录后查看回复内容`,
    /// Discuz!'s `<div class="locked">`. Measured on `install-a.example`, where 19 of 20 replies on
    /// one thread are withheld from a signed-out reader.
    ///
    /// The notice is **not** put in `body`: it is the forum's sentence, not the author's, and a
    /// row drawing it would attribute it to them. This says the same thing in a way a caller can
    /// act on, and `body` is empty — which is the difference between "they wrote nothing" and
    /// "you were not allowed to read it", and a reader deserves to be told which.
    public let isWithheld: Bool
    /// The author's picture, where the thread **page** carried one.
    ///
    /// **The page has them and the thread table does not**, which is the whole of why this field
    /// is here and `DiscuzThread` has no equivalent. `asNote` says it: a Discuz! thread table
    /// carries no avatar, it can be *guessed* at `uc_server/avatar.php?uid=…`, and that guess is
    /// wrong on any install that moved UCenter. `install-d.example` is that install — it serves its
    /// avatars from `avatars-d.example` on the touch template and `files-d.example` on the desktop one, so
    /// the guess would have been wrong twice on one forum. This is read off the page instead, and
    /// therefore read rather than built. See `DiscuzPostLayout.avatarURL`.
    ///
    /// **Lifted, and so checked.** `Note.url` is built out of a parsed host and an integer and
    /// needs no check; this is an address a stranger wrote, so it goes through `Host.fetchableURL`
    /// — `https` only, and a host to reach — at the point it stops being ours. Nothing where the
    /// template drew no picture, where it drew the forum's own `noavatar` placeholder, or where
    /// the address is one this device will not fetch.
    public let avatarURL: URL?

    public init(
        pid: Int,
        tid: Int,
        floor: Int? = nil,
        author: String,
        handle: String,
        postedAt: Date? = nil,
        body: String,
        quoted: String? = nil,
        isWithheld: Bool = false,
        avatarURL: URL? = nil
    ) {
        self.pid = pid
        self.tid = tid
        self.floor = floor
        self.author = author
        self.handle = handle
        self.postedAt = postedAt
        self.body = body
        self.quoted = quoted
        self.isWithheld = isWithheld
        self.avatarURL = avatarURL
    }

    /// Where this one post lives on the forum it was read from, for a reader who wants to go and
    /// read it there.
    ///
    /// **Built, not lifted — the same guarantee `asNote` makes about a thread's address, and for
    /// the same reason.** A host this device parsed and two integers this device parsed; nothing
    /// here came out of a stranger's markup, so `javascript:` in somebody's `href` has nothing to
    /// reach. Not lifting an address is a stronger guarantee than checking one, and the check is
    /// applied anyway: `host` arrives as a `String` from a caller, and an empty one builds
    /// `https:///forum.php`, which parses, has no host to reach, and would open nowhere.
    ///
    /// **The form is measured, not guessed.** Discuz!'s own floor permalink, as captured on the
    /// desktop template, is `forum.php?mod=viewthread&tid=<tid>#pid<pid>` — the thread address
    /// this file already builds, with the post's own anchor on the end. The forum writes that
    /// link itself, beside every floor number, which is why this is the spelling rather than one
    /// of the several others Discuz! also answers.
    ///
    /// ## Why the anchor is honest here, and the one thing that would make it dishonest
    ///
    /// An anchor only reaches a post that is **on the page the address opens**, and that address
    /// opens a thread's first page. Every `DiscuzPost` this package hands out is a first-page
    /// post: `replies(tid:)` states it in as many words — "a Discuz! thread paginates at the
    /// forum's own configured size and this reads the first page only" — and `post(tid:)` reads
    /// the same page. So the anchor resolves for every post that can reach a caller, and it is
    /// not luck that it does; it is that invariant.
    ///
    /// **If later pages are ever fetched, this becomes wrong and silently so** — a reply from
    /// page four would open page one and land the reader at the top of it, which is worse than
    /// offering them nothing. Whoever adds pagination adds `&page=` here, or removes this. There
    /// is no compiler stop for it, so this paragraph is the whole of the warning.
    public func url(onHost host: String) -> URL? {
        guard let base = Host.httpsURL(
            host: host,
            path: "/forum.php",
            query: [
                URLQueryItem(name: "mod", value: "viewthread"),
                URLQueryItem(name: "tid", value: String(tid)),
            ]
        ) else { return nil }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.fragment = "pid\(pid)"
        guard let url = parts?.url, Host.isFetchable(url) else { return nil }
        return url
    }
}

/// A Discuz! thread page, read as structure — `DiscuzPage`'s rule applied to the page a thread
/// actually lives on.
enum DiscuzThreadPage {
    /// Every post the page carries, in the order it wrote them.
    ///
    /// All three layouts are asked and their answers merged **by where they were found**, the way
    /// `DiscuzIndex` merges its two: a page is read for whatever markup it turned out to be
    /// written in, and a post seen twice keeps its first description. A `pid` is the key because
    /// it is the number Discuz! itself gives a post, and it is the same number in all three
    /// templates — `id="pid58035493"` and `id="post_58035493"` are the same post.
    static func posts(in html: String, tid: Int, host: String) -> [DiscuzPost] {
        guard let patterns = Patterns() else { return [] }
        var seen: Set<Int> = []
        return DiscuzPostLayout.allCases
            .flatMap { $0.posts(in: html, tid: tid, host: host, patterns: patterns) }
            .sorted { $0.at < $1.at }
            .filter { seen.insert($0.post.pid).inserted }
            .map(\.post)
    }

    /// The patterns, compiled once per page. A value rather than a global, for the reason
    /// `DiscuzPage.Patterns` gives: `NSRegularExpression` is not `Sendable`.
    struct Patterns {
        /// Where one post begins, on each of the three layouts. Each captures the `pid`.
        let touchPost: NSRegularExpression
        let comiisPost: NSRegularExpression
        let desktopPost: NSRegularExpression
        /// Where its words begin, on each.
        let touchBody: NSRegularExpression
        let comiisBody: NSRegularExpression
        let desktopBody: NSRegularExpression
        /// `<ul class="authi">` — who and when, on Discuz!'s own mobile template.
        let touchWho: NSRegularExpression
        /// `<div class="comiis_postli_top">` and `<div class="comiis_postli_time">` — the same
        /// two facts on the third-party one, which keeps them in two places rather than one.
        let comiisWho: NSRegularExpression
        let comiisWhen: NSRegularExpression
        /// `<div class="authi">` and `<em id="authorposton…">` — the same two on the desktop page.
        let desktopWho: NSRegularExpression
        let desktopWhen: NSRegularExpression
        /// `<a id="postnum…">` — the floor, on the desktop page.
        let desktopFloor: NSRegularExpression
        /// `<li>…</li>` and `<h2>…</h2>` — where the other two keep the floor.
        let item: NSRegularExpression
        let subheading: NSRegularExpression
        /// An anchor, with its address and its label.
        let anchor: NSRegularExpression
        /// The box a template puts the author's picture in — `<div class="avatar">` on
        /// `install-c.example` and `install-b.example`, `<span class="avatar">` on `install-d.example`. The
        /// tag is captured and back-referenced because it is **not** the same tag on the four
        /// installs measured, and a rule written for `div` alone would have silently drawn no
        /// avatar on one whole forum.
        ///
        /// `\bavatar\b` and not a substring: `install-c.example`'s desktop page writes
        /// `class="pls cl favatar"` round a box its own JavaScript fills in later
        /// (`fixed_avatar([…])`), and there is no `<img>` in it to read. The word boundary is
        /// what keeps that box from being matched and then quietly answering nothing.
        let avatarBox: NSRegularExpression
        /// One `<img>` tag, whole.
        let image: NSRegularExpression
        /// Where the address is: `data-src` where the template lazy-loads, `src` otherwise.
        /// Both, and in that order, because the four installs do not agree — see
        /// `DiscuzPostLayout.address`.
        let imageDeferred: NSRegularExpression
        let imageSource: NSRegularExpression
        /// Whether that address is a person's page rather than a button. `mod=spacecp` is a
        /// *control* — Discuz!'s own favourite button sits in the same list as the author's name
        /// on `install-d.example` — so the boundary after `space` is load-bearing.
        let person: NSRegularExpression
        /// The furniture, each taken out of the words before they are read. See `words`.
        let quote: NSRegularExpression
        let locked: NSRegularExpression
        let editNotice: NSRegularExpression
        let attachmentList: NSRegularExpression
        let signature: NSRegularExpression
        let control: NSRegularExpression
        let scripted: NSRegularExpression
        let anchors: NSRegularExpression
        /// One open-or-close tag of each kind that has to be counted to find an element's end.
        let divs: NSRegularExpression
        let cells: NSRegularExpression
        let lists: NSRegularExpression
        let italics: NSRegularExpression
        let emphasis: NSRegularExpression
        let date: NSRegularExpression

        init?() {
            let options: NSRegularExpression.Options = [
                .dotMatchesLineSeparators, .caseInsensitive,
            ]
            func attribute(_ name: String, _ value: String) -> String {
                "\(name)\\s*=\\s*[\"'][^\"']*\\b\(value)\\b[^\"']*[\"']"
            }
            func opening(_ tag: String, _ value: String) -> String {
                "<\(tag)[^>]*\(attribute("class", value))[^>]*>"
            }
            func nesting(_ tag: String) -> String { "<\(tag)\\b[^>]*>|</\(tag)\\s*>" }
            func wrapped(_ tag: String) -> String { "<\(tag)[^>]*>(.*?)</\(tag)>" }
            func compile(_ pattern: String) -> NSRegularExpression? {
                try? NSRegularExpression(pattern: pattern, options: options)
            }
            guard
                let touchPost = compile(
                    "<div[^>]*\(attribute("class", "plc"))[^>]*\\bid\\s*=\\s*[\"']pid(\\d+)[\"'][^>]*>"
                ),
                let comiisPost = compile(
                    "<div[^>]*\(attribute("class", "comiis_postli"))[^>]*\\bid\\s*=\\s*[\"']pid(\\d+)[\"'][^>]*>"
                ),
                let desktopPost = compile("<div[^>]*\\bid\\s*=\\s*[\"']post_(\\d+)[\"'][^>]*>"),
                let touchBody = compile(opening("div", "message")),
                let comiisBody = compile(opening("div", "comiis_message_table")),
                let desktopBody = compile(
                    "<td[^>]*\\bid\\s*=\\s*[\"']postmessage_\\d+[\"'][^>]*>"
                ),
                let touchWho = compile(opening("ul", "authi")),
                let comiisWho = compile(opening("div", "comiis_postli_top")),
                let comiisWhen = compile(opening("div", "comiis_postli_time")),
                let desktopWho = compile(opening("div", "authi")),
                let desktopWhen = compile(
                    "<em[^>]*\\bid\\s*=\\s*[\"']authorposton\\d+[\"'][^>]*>(.*?)</em>"
                ),
                let desktopFloor = compile(
                    "<a[^>]*\\bid\\s*=\\s*[\"']postnum\\d+[\"'][^>]*>(.*?)</a>"
                ),
                let item = compile(wrapped("li")),
                let subheading = compile(wrapped("h2")),
                let anchor = compile(
                    "<a[^>]*href\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>"
                ),
                let avatarBox = compile(
                    "<(div|span)[^>]*\(attribute("class", "avatar"))[^>]*>(.*?)</\\1\\s*>"
                ),
                let image = compile("<img\\b[^>]*>"),
                let imageDeferred = compile(
                    "\\bdata-src\\s*=\\s*[\"']([^\"']*)[\"']"
                ),
                let imageSource = compile(
                    "(?<![-\\w])src\\s*=\\s*[\"']([^\"']*)[\"']"
                ),
                let person = compile(
                    "[?&;]mod=space(?:[&;]|$)|(?:^|/)space-(?:uid|username)-"
                ),
                let quote = compile(opening("div", "quote")),
                let locked = compile(opening("div", "locked")),
                let editNotice = compile(opening("i", "pstatus")),
                let attachmentList = compile(opening("ul", "post_attlist")),
                let signature = compile(opening("div", "sign")),
                let control = compile("<em[^>]*\\bonclick\\b[^>]*>"),
                let scripted = compile(
                    "<a[^>]*href\\s*=\\s*[\"']\\s*javascript:[^\"']*[\"'][^>]*>"
                ),
                let anchors = compile(nesting("a")),
                let divs = compile(nesting("div")),
                let cells = compile(nesting("td")),
                let lists = compile(nesting("ul")),
                let italics = compile(nesting("i")),
                let emphasis = compile(nesting("em")),
                let date = try? NSRegularExpression(
                    pattern:
                        "(\\d{4})-(\\d{1,2})-(\\d{1,2})(?:[\\s\u{00A0}]+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?)?"
                )
            else { return nil }
            self.touchPost = touchPost
            self.comiisPost = comiisPost
            self.desktopPost = desktopPost
            self.touchBody = touchBody
            self.comiisBody = comiisBody
            self.desktopBody = desktopBody
            self.touchWho = touchWho
            self.comiisWho = comiisWho
            self.comiisWhen = comiisWhen
            self.desktopWho = desktopWho
            self.desktopWhen = desktopWhen
            self.desktopFloor = desktopFloor
            self.item = item
            self.subheading = subheading
            self.anchor = anchor
            self.avatarBox = avatarBox
            self.image = image
            self.imageDeferred = imageDeferred
            self.imageSource = imageSource
            self.person = person
            self.quote = quote
            self.locked = locked
            self.editNotice = editNotice
            self.attachmentList = attachmentList
            self.signature = signature
            self.control = control
            self.scripted = scripted
            self.anchors = anchors
            self.divs = divs
            self.cells = cells
            self.lists = lists
            self.italics = italics
            self.emphasis = emphasis
            self.date = date
        }
    }
}

/// The three ways the page behind `&mobile=2` turned out to be written, all three measured.
///
/// **No `default:`, and `allCases` rather than a hand-written list**, for the reason
/// `DiscuzBoardLayout` states: a switch over a kind that falls through is a silent wrong answer,
/// and a fourth template should break the build rather than quietly return nothing.
///
/// `&mobile=2` is asked for because it is worth about three quarters of the bytes where Discuz!'s
/// own mobile template answers it — see `DiscuzClient.posts(tid:)` for the figures — but **what
/// comes back is not a contract**, and these are the three answers measured on 2026-09-16.
enum DiscuzPostLayout: CaseIterable, Sendable {
    /// Discuz!'s own touch template: `<div class="plc" id="pidN">` around a `<ul class="authi">`
    /// and a `<div class="message">`. `install-c.example` X5.0, `install-b.example` X5.0 English, and
    /// `install-d.example` X3.4 — which serves it as **UTF-8 while its desktop page is GBK**, so the
    /// same forum is two encodings depending on which page is asked for. `DiscuzHTML.text` reads
    /// the header per response, so it already handles that; it is written down because a reader
    /// that had decided a host's encoding once would be wrong here.
    case touch
    /// Comiis, a third-party mobile template: `<div class="comiis_postli" id="pidN">` around a
    /// `<div class="comiis_message_table">`. `install-a.example` X3.4. Not Discuz!'s markup, not
    /// smaller than the desktop page, and the reason `&mobile=2` cannot be assumed.
    case comiis
    /// The ordinary desktop page: `<div id="post_N">` around a `<div class="authi">` and a
    /// `<td id="postmessage_N">`. It is what all four installs serve without `&mobile=2`, and it
    /// is here as the answer for an install whose mobile template is switched off — which is a
    /// setting, exactly as the mobile JSON API and RSS were, and would otherwise be a page this
    /// device could not read at all.
    ///
    /// **The markup is measured on all four installs; the route to it is not.** Every one of them
    /// has a mobile template installed, so no install was found that answers `&mobile=2` with
    /// this page. The parser is verified against the four desktop captures directly.
    case desktop

    /// Every post this layout can find on the page, with where it was found.
    func posts(
        in html: String,
        tid: Int,
        host: String,
        patterns: DiscuzThreadPage.Patterns
    ) -> [(at: Int, post: DiscuzPost)] {
        let container: NSRegularExpression
        switch self {
        case .touch: container = patterns.touchPost
        case .comiis: container = patterns.comiisPost
        case .desktop: container = patterns.desktopPost
        }
        let marks = container.matches(in: html, range: NSRange(html.startIndex..., in: html))
        return marks.enumerated().compactMap { index, mark in
            guard let pidRange = Range(mark.range(at: 1), in: html),
                  let pid = Int(html[pidRange]),
                  let opened = Range(mark.range, in: html)
            else { return nil }
            // The element, counted to its own close. Where the markup does not close it — which
            // is a thing a real page does — the next post's opening tag is where this one stops,
            // which is the same rule `DiscuzIndex` uses for a category and cannot run away.
            let end = index + 1 < marks.count
                ? Range(marks[index + 1].range, in: html)?.lowerBound ?? html.endIndex
                : html.endIndex
            let body = DiscuzMarkup.balanced(
                in: html, nesting: patterns.divs, from: opened.upperBound
            )?.range ?? opened.upperBound..<end
            return (
                mark.range.location,
                post(pid: pid, tid: tid, host: host, in: String(html[body]), patterns: patterns)
            )
        }
    }

    private func post(
        pid: Int,
        tid: Int,
        host: String,
        in body: String,
        patterns: DiscuzThreadPage.Patterns
    ) -> DiscuzPost {
        let who: String?
        let when: String?
        let floor: Int?
        switch self {
        case .touch:
            // One list holds all three, and it is written three different ways inside: `mtit` and
            // `mtime` on X5.0, bare `<li class="grey">` on `install-d.example`. So none of those class
            // names is read — the **first** item carries the floor, the list as a whole carries
            // the date, and the author is the first person the list links to.
            let list = DiscuzMarkup.content(patterns.touchWho, nesting: patterns.lists, in: body)
            who = list
            when = list
            floor = list.flatMap { patterns.item.capture(1, in: $0) }
                .flatMap { DiscuzPostLayout.number(in: $0, patterns: patterns) }
        case .comiis:
            let top = DiscuzMarkup.content(patterns.comiisWho, nesting: patterns.divs, in: body)
            who = top
            when = DiscuzMarkup.content(patterns.comiisWhen, nesting: patterns.divs, in: body)
            floor = top.flatMap { patterns.subheading.capture(1, in: $0) }
                .flatMap { DiscuzPostLayout.number(in: $0, patterns: patterns) }
        case .desktop:
            who = DiscuzMarkup.content(patterns.desktopWho, nesting: patterns.divs, in: body)
            when = patterns.desktopWhen.capture(1, in: body)
            floor = patterns.desktopFloor.capture(1, in: body)
                .flatMap { DiscuzPostLayout.number(in: $0, patterns: patterns) }
        }

        let author = who.flatMap { DiscuzPostLayout.author(in: $0, patterns: patterns) } ?? ""
        let words = DiscuzPostLayout.words(
            in: DiscuzMarkup.content(self.message(patterns), nesting: self.nesting(patterns), in: body) ?? "",
            patterns: patterns
        )
        let avatar = avatarURL(in: body, heading: who, host: host, patterns: patterns)
        return DiscuzPost(
            pid: pid,
            tid: tid,
            floor: floor,
            author: author,
            handle: DiscuzHandle.of(author, host: host),
            // The anchors come out first, because a name is not a date and a button is not one
            // either: `install-d.example` puts its favourite button in the same list as the author.
            postedAt: when
                .map { DiscuzMarkup.extract(patterns.anchor, in: $0).remainder }
                .flatMap { DiscuzDate.parse($0, date: patterns.date) },
            body: words.body,
            quoted: words.quoted,
            isWithheld: words.isWithheld,
            avatarURL: avatar
        )
    }

    /// The author's picture, where this layout's template put one on the page.
    ///
    /// **Measured on all four installs, on 2026-09-16, and no two of them agree.** The table is
    /// the reason this is a per-layout question rather than one pattern:
    ///
    /// | install | layout | box | attribute | address |
    /// | --- | --- | --- | --- | --- |
    /// | `install-c.example` | touch | `<div class="avatar">` | `data-src` | `./data/avatar/…` |
    /// | `install-b.example` | touch | `<div class="avatar">` | `src` | `./data/avatar/…` |
    /// | `install-b.example` | desktop | `<div class="avatar">` | `src` | `./data/avatar/…` |
    /// | `install-d.example` | touch | `<span class="avatar">` | `src` | `https://avatars-d.example/avatar.php?uid=…` |
    /// | `install-d.example` | desktop | `<div class="avatar">` | `src` | `https://files-d.example/…_avatar_small.jpg` |
    /// | `install-a.example` | comiis | *none* | `src` | `https://…/uc_server/avatar.php?uid=…` |
    /// | `install-c.example` | desktop | `class="…favatar"` | *none* | written in by JavaScript |
    ///
    /// Three things follow from it, and each one is a rule a single-install reading would have got
    /// wrong. The attribute is `data-src` where the template lazy-loads and `src` where it does
    /// not, so both are read and the deferred one wins. The box is a `div` on three installs and a
    /// `span` on the fourth, so the tag is captured rather than assumed. And the address is
    /// relative on two installs and absolute on two — pointing at a **different host** on
    /// `install-d.example`, which is precisely the install whose UCenter has moved and precisely why
    /// `uc_server/avatar.php?uid=…` is not constructed here.
    ///
    /// The two answers of nothing are both correct and both measured. `install-c.example`'s desktop
    /// page has no `<img>` to read at all — its own script fills the box in afterwards — and
    /// `install-d.example` writes `<div class="avatar">頭像被屏蔽</div>` for three posts in ten, which is
    /// the forum saying there is no picture. Nothing is drawn rather than an address guessed.
    ///
    /// **No `default:`.** A fourth template has to say where its avatar lives, and the build is
    /// where that should be noticed.
    private func avatarURL(
        in body: String,
        heading: String?,
        host: String,
        patterns: DiscuzThreadPage.Patterns
    ) -> URL? {
        let box: String?
        switch self {
        case .touch, .desktop:
            box = patterns.avatarBox.capture(2, in: body)
        case .comiis:
            // Comiis has no box named for the job. It keeps the picture in the heading it also
            // keeps the name in — `<div class="comiis_postli_top">`, which `who` above already
            // isolated — inside the first of the two anchors it links the author by. That is the
            // same fact `author(in:)` works around from the other side: the template links one
            // person twice, the picture first and the name second.
            box = heading
        }
        guard let box, let tag = patterns.image.capture(0, in: box) else { return nil }
        return DiscuzPostLayout.address(in: tag, host: host, patterns: patterns)
    }

    /// One `<img>` tag's address, resolved against the forum and admitted under decision 9's rule.
    ///
    /// `data-src` before `src`, because a template that lazy-loads keeps the real picture in the
    /// first and a blank or a spinner in the second; where there is no `data-src` the `src` *is*
    /// the picture. `(?<![-\w])src` rather than `\bsrc`, so reading `src` cannot accidentally read
    /// the tail of `data-src`.
    ///
    /// **`noavatar` is not a picture.** `./data/avatar/noavatar.svg` is Discuz!'s own placeholder
    /// for somebody who uploaded nothing — measured three times on one `install-c.example` page — and
    /// fetching it would draw *the forum's* grey silhouette over the plate this app already draws
    /// for an author with no picture. The whole last path component is tested by prefix, which
    /// also covers the `noavatar_small.gif` and `noavatar_middle.gif` older skins ship.
    ///
    /// Resolution is against `https://<host>/` rather than against the page's own `<base href>`:
    /// the base is a value the same stranger writes, and the host is one this device parsed. An
    /// absolute address survives resolution unchanged, which is how `install-d.example`'s separate
    /// avatar host keeps working, and `Host.isFetchable` is what stops `javascript:`, `data:` and
    /// plain `http:` surviving it.
    static func address(
        in tag: String,
        host: String,
        patterns: DiscuzThreadPage.Patterns
    ) -> URL? {
        let raw = patterns.imageDeferred.capture(1, in: tag)
            ?? patterns.imageSource.capture(1, in: tag)
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard let base = Host.httpsURL(host: host, path: "/"),
              let resolved = URL(string: cleaned, relativeTo: base)?.absoluteURL,
              Host.isFetchable(resolved)
        else { return nil }
        guard !resolved.lastPathComponent.lowercased().hasPrefix("noavatar") else { return nil }
        return resolved
    }

    /// Where this layout keeps the words, and what has to be counted to find the end of them.
    private func message(_ patterns: DiscuzThreadPage.Patterns) -> NSRegularExpression {
        switch self {
        case .touch: return patterns.touchBody
        case .comiis: return patterns.comiisBody
        case .desktop: return patterns.desktopBody
        }
    }

    private func nesting(_ patterns: DiscuzThreadPage.Patterns) -> NSRegularExpression {
        switch self {
        case .touch, .comiis: return patterns.divs
        case .desktop: return patterns.cells
        }
    }

    /// Whoever this post's heading names, out of the first person it links to who has a name.
    ///
    /// **A person, and a name.** Both halves are load-bearing and each was put there by a
    /// different install. The person test — the address is somebody's page, not `mod=spacecp` —
    /// is what keeps `install-d.example`'s 收藏 button from being read as the author. The name test is
    /// what keeps the third-party template's avatar from being: it links the same person twice,
    /// once around their picture and once around their name, and the picture comes first.
    ///
    /// Where the heading links nobody at all, its own text is the answer: `install-d.example` writes
    /// an author who has no profile page as bare text.
    private static func author(
        in heading: String,
        patterns: DiscuzThreadPage.Patterns
    ) -> String {
        let whole = NSRange(heading.startIndex..., in: heading)
        for match in patterns.anchor.matches(in: heading, range: whole) {
            guard let hrefRange = Range(match.range(at: 1), in: heading),
                  let labelRange = Range(match.range(at: 2), in: heading)
            else { continue }
            let href = String(heading[hrefRange])
                .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            guard patterns.person.firstMatch(
                in: href, range: NSRange(href.startIndex..., in: href)
            ) != nil else { continue }
            let name = HTMLText.plain(String(heading[labelRange]))
            if !name.isEmpty { return name }
        }
        return HTMLText.plain(DiscuzMarkup.extract(patterns.anchor, in: heading).remainder)
    }

    /// The floor, out of whichever of `1<sup>#</sup>`, `<sup>#1</sup>` and `<em>1楼</em>` this
    /// template writes.
    ///
    /// The anchors come out first and the digits are taken from what is left, so that a member
    /// called `abc123` can never be read as the hundred and twenty-third floor. Nothing where the
    /// template numbered nothing, which is the opening post on the third-party one.
    private static func number(
        in slot: String,
        patterns: DiscuzThreadPage.Patterns
    ) -> Int? {
        let text = HTMLText.plain(DiscuzMarkup.extract(patterns.anchor, in: slot).remainder)
        let digits = text.prefix { !$0.isNumber }.count
        let rest = text.dropFirst(digits).prefix { $0.isASCII && $0.isNumber }
        return rest.isEmpty ? nil : Int(rest)
    }

    /// The author's words, and nothing that merely sits beside them.
    ///
    /// **Each of these was measured inside a real post's own message element**, which is what
    /// makes it a decision rather than a precaution:
    ///
    /// - **A quotation** (`<div class="quote">`) is somebody else's sentence. Taken out of the
    ///   words and kept in `quoted`. `install-b.example`.
    /// - **A withheld post** (`<div class="locked">`) is the forum saying this reader may not
    ///   read it. Taken out, and said in `isWithheld` instead. `install-a.example`, 19 replies of 20.
    /// - **An edit notice** (`<i class="pstatus">本帖最后由 … 编辑`) is the forum's sentence about
    ///   the post, written in the forum's language, not the author's. Taken out. `install-c.example`.
    /// - **An attachment list** (`<ul class="post_attlist">`) is a filename, a size, a download
    ///   count and a price. Taken out: it is a *file*, and a file's name drawn as a sentence is
    ///   the thing that looks right on a fixture and is wrong on every real post. `install-c.example`.
    /// - **A "Copy Code" button** (`<em onclick=…>` in a code block) is a control. Taken out —
    ///   structurally, on having an `onclick`, rather than on the words in it, which are
    ///   translated. `install-b.example`.
    /// - **A `javascript:` link is a button somebody drew as a link**, and the same rule reaches
    ///   it. This one was found live rather than reasoned about: `install-a.example` replaces a
    ///   picture a signed-out reader may not see with `<a href="javascript:;">登录/注册后可看大图</a>`,
    ///   and the first run of this reader put **"log in or register to see the full image" into
    ///   the body of somebody's post, three times**. An address that goes nowhere is not a link
    ///   and the words in it are the forum's, exactly as with a withheld post — the difference is
    ///   only that a picture was withheld rather than a post, and a picture is not words either.
    /// - **A signature** (`<div class="sign">`) is the same sentence under every post its author
    ///   ever wrote. Taken out — and on the desktop template it is a *sibling* of the message
    ///   element rather than a child, so reading only the message excludes it by construction and
    ///   this is belt to that braces. **Unverified live**: not one post on the four open installs
    ///   rendered a signature to a signed-out reader, which is itself a Discuz! setting.
    ///
    /// **A picture is not words.** An `<img>` in a post leaves nothing behind, because
    /// `HTMLText.plain` takes the tag and there is no text in it — so a post that is only a
    /// photograph has an empty `body`, which is true. Carrying its filename instead would put
    /// `Screenshot_20260916_094759.jpeg` on the row as though somebody had written it.
    private static func words(
        in message: String,
        patterns: DiscuzThreadPage.Patterns
    ) -> (body: String, quoted: String?, isWithheld: Bool) {
        let quotes = DiscuzMarkup.extract(patterns.quote, nesting: patterns.divs, in: message)
        let locked = DiscuzMarkup.extract(patterns.locked, nesting: patterns.divs, in: quotes.remainder)
        var text = locked.remainder
        text = DiscuzMarkup.extract(patterns.editNotice, nesting: patterns.italics, in: text).remainder
        text = DiscuzMarkup.extract(patterns.attachmentList, nesting: patterns.lists, in: text).remainder
        text = DiscuzMarkup.extract(patterns.signature, nesting: patterns.divs, in: text).remainder
        text = DiscuzMarkup.extract(patterns.control, nesting: patterns.emphasis, in: text).remainder
        text = DiscuzMarkup.extract(patterns.scripted, nesting: patterns.anchors, in: text).remainder
        let quoted = quotes.removed
            .map { tidy(HTMLText.plain($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return (tidy(HTMLText.plain(text)), quoted.isEmpty ? nil : quoted, !locked.removed.isEmpty)
    }

    /// The blank the removals left behind, closed up.
    ///
    /// **This is litter of this reader's own making, not a view's problem to solve.** Discuz!
    /// writes a post one `<br />` at a time, so taking a quotation or a row of withheld pictures
    /// out of the middle of one leaves the blank lines that were around it — six of them, in the
    /// live post that prompted this. A row draws a fixed number of lines and must not become
    /// taller than a row whose post has not arrived, so six blank lines is six lines of somebody's
    /// post the reader does not get. A paragraph break is kept, because the author wrote it;
    /// anything more than one is closed up.
    /// `\r` is in the class because these pages are served with CRLF — measured, after a first
    /// version without it closed up nothing at all on three installs of the four.
    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(
            of: "[ \\t\\r\u{00A0}\u{3000}]*\\n(?:[ \\t\\r\u{00A0}\u{3000}]*\\n)+[ \\t\\r\u{00A0}\u{3000}]*",
            with: "\n\n",
            options: .regularExpression
        )
    }
}

/// Finding where an element ends, which a pattern on its own cannot do.
///
/// `<div[^>]*>(.*?)</div>` stops at the **first** close, so an element holding one nested `<div>`
/// — which is every post body on every template measured — is cut in half. Everywhere this file
/// reads an element that can nest, it counts opens against closes instead. The one place it does
/// not is a category on the index, where the *next* section's opening tag is a boundary that
/// cannot be got wrong; a post body has no such neighbour.
enum DiscuzMarkup {
    /// What lies between an opening tag that ends at `start` and its matching close.
    static func balanced(
        in text: String,
        nesting: NSRegularExpression,
        from start: String.Index
    ) -> (range: Range<String.Index>, after: String.Index)? {
        var depth = 1
        let tail = NSRange(start..<text.endIndex, in: text)
        for match in nesting.matches(in: text, range: tail) {
            guard let range = Range(match.range, in: text) else { continue }
            depth += text[range].hasPrefix("</") ? -1 : 1
            if depth == 0 { return (start..<range.lowerBound, range.upperBound) }
        }
        // Unclosed. Nothing rather than the rest of the page, which is the same choice this file
        // makes everywhere: a wrong answer that parses is worse than no answer.
        return nil
    }

    /// The contents of the first element whose opening tag matches `opening`.
    static func content(
        _ opening: NSRegularExpression,
        nesting: NSRegularExpression,
        in text: String
    ) -> String? {
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = opening.firstMatch(in: text, range: whole),
              let opened = Range(match.range, in: text),
              let found = balanced(in: text, nesting: nesting, from: opened.upperBound)
        else { return nil }
        return String(text[found.range])
    }

    /// Every element whose opening tag matches `opening`, taken out, with what was in each.
    static func extract(
        _ opening: NSRegularExpression,
        nesting: NSRegularExpression,
        in text: String
    ) -> (remainder: String, removed: [String]) {
        var remainder = text
        var removed: [String] = []
        while true {
            let whole = NSRange(remainder.startIndex..., in: remainder)
            guard let match = opening.firstMatch(in: remainder, range: whole),
                  let opened = Range(match.range, in: remainder)
            else { break }
            guard let found = balanced(
                in: remainder, nesting: nesting, from: opened.upperBound
            ) else {
                // Unclosed: take the opening tag off and leave what followed it as words. The
                // loop has to shorten the string on every pass or it does not end.
                remainder.removeSubrange(opened)
                continue
            }
            removed.append(String(remainder[found.range]))
            remainder.removeSubrange(opened.lowerBound..<found.after)
        }
        return (remainder, removed)
    }

    /// Every match of `opening` taken out, with nothing counted — for a tag that cannot nest.
    static func extract(
        _ opening: NSRegularExpression,
        in text: String
    ) -> (remainder: String, removed: [String]) {
        var removed: [String] = []
        let whole = NSRange(text.startIndex..., in: text)
        for match in opening.matches(in: text, range: whole) {
            guard match.numberOfRanges > 1, let found = Range(match.range(at: 1), in: text)
            else { continue }
            removed.append(String(text[found]))
        }
        return (opening.stringByReplacingMatches(in: text, range: whole, withTemplate: ""), removed)
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
