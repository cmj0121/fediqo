#if DEBUG
import FediqoCore
import FediqoUI
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A launch made for a picture: the app with posts in it that came from nowhere, standing on the
/// screen it was asked for (#301).
///
/// **Debug builds only, and only when asked.** `scripts/shots.sh --phone` launches the app with
/// `FEDIQO_STAGED=1`; a launch without it reads nothing here, and a release build does not hold
/// this file at all.
///
/// **Nothing of the person's is opened and nothing is asked of any server.** The store is made in
/// memory from the posts below and is never written; the sign-in is a token that exists only in
/// this process; every question the app would put to a server is answered here, by
/// `StagedHTTP`. `Launch.shared` — the index on disk, the Keychain, the forum browser's store —
/// is never made.
///
/// What a picture is of is said by three more variables:
///
///     FEDIQO_STAGED_SCREEN   timeline | post | compose | preferences | notice | link | signin
///                            | swiped | ended | fresh — what a swipe to the next timeline leaves
///                            | named | lost | list — a timeline of the person's own in front, and the list of them
///     FEDIQO_STAGED_TIMELINES 1 — the person has written three timelines of their own
///                            | cut | returned | emptied — the list scrolled and switched, with what it reports written over it
///     FEDIQO_STAGED_KEYBOARD 1 — stands as a device with a keyboard attached; without it, as one with none
///     FEDIQO_STAGED_WIDTH    320 — the window made that many points wide, where the screen is wider
///
/// and the text size and language by the app's own preferences, handed over as launch arguments
/// (`-fediqo.dummy.fontSize largest`), which the defaults read before anything written down.
@MainActor
enum Staged {
    static let isOn = ProcessInfo.processInfo.environment["FEDIQO_STAGED"] == "1"

    /// A name no server answers to: `.example` is reserved for exactly this.
    static let host = "fixture.example"
    private static let source = Source(host: host, kind: .mastodon)

    static var root: some View {
        let tokens = MemoryMastodonTokens()
        try? tokens.save(MastodonToken(
            host: host, accessToken: "staged", clientID: "staged", clientSecret: "staged",
            scopes: MastodonOAuth.reading + " " + MastodonOAuth.writing
        ))
        return FediqoRootView(
            http: StagedHTTP(),
            store: ItemStore(sources: [source], notes: notes + (screenName == "returned" || screenName == "fresh" ? rising : [])),
            forums: ForumSessions(),
            mastodon: MastodonSessions(tokens: tokens, sender: StagedHTTP()),
            deviceName: "Staged",
            staged: staged
        )
        .modifier(StagedWindow(width: width))
    }

    private static var staged: ShellStaged {
        var staged = screen
        // A phone has no keyboard, and a simulator reports its Mac's: without this the picture
        // is of a phone with one attached. `FEDIQO_STAGED_KEYBOARD=1` keeps the one reported.
        staged.noKeyboard = ProcessInfo.processInfo.environment["FEDIQO_STAGED_KEYBOARD"] != "1"
        staged.scroll = { down in StagedScroll.scroll(down) }
        // Timelines of the person's own, for a phone's pictures (#304). Asked for, and not in
        // every picture: the iPad's are laid beside ones taken before there were any.
        if ProcessInfo.processInfo.environment["FEDIQO_STAGED_TIMELINES"] == "1" {
            // Written, and then the first of them all in front again: writing one puts it in front.
            staged.steps.insert(contentsOf: [.timelines, .go(0), .unvisited], at: 0)
        }
        return staged
    }

    private static var screenName: String? { ProcessInfo.processInfo.environment["FEDIQO_STAGED_SCREEN"] }

    private static var screen: ShellStaged {
        switch screenName {
        // The three a picture is evidence of (#303): the top row a third off the screen; a
        // timeline left a few rows down for another with posts and come back to; and the same
        // through a timeline with none.
        // The timeline's own head (#304): one of the person's own in front, with a long name;
        // one that lost its source; and the list of them all, up.
        case "named": ShellStaged(place: .timeline, steps: [.go(2)])
        case "lost": ShellStaged(place: .timeline, steps: [.go(3)])
        case "list": ShellStaged(place: .timeline, steps: [.go(2), .list])
        // What a swipe leaves (#305), by the step a swipe takes: two timelines on; at the last
        // one, a step on that goes nowhere; and a timeline never visited, come to from a list
        // scrolled down to a row the two share, which opens at its own first post.
        case "swiped": ShellStaged(place: .timeline, steps: [.next, .next], reports: true)
        case "ended": ShellStaged(place: .timeline, steps: [.go(4), .next], reports: true)
        // Rising posts are the last of All and all of Trends: All is scrolled to its end, among
        // them, and Trends — never visited, and long enough to scroll — is come to.
        case "fresh": ShellStaged(place: .timeline, steps: [.scroll(100_000), .trends], reports: true)
        case "menu": ShellStaged(place: .timeline, menus: true)
        case "cut": ShellStaged(place: .timeline, steps: [.scroll(90)], reports: true)
        case "returned": ShellStaged(place: .timeline, steps: [.scroll(700), .trends, .all], reports: true)
        case "emptied": ShellStaged(place: .timeline, steps: [.scroll(700), .empty, .all], reports: true)
        case "post": ShellStaged(place: .timeline, opens: NoteKey(host: host, id: opened).rowID)
        case "compose": ShellStaged(place: .timeline, composing: true)
        case "preferences": ShellStaged(place: .preferences)
        case "notice": ShellStaged(place: .timeline, says: notice)
        // Both are somebody's page, and there is nobody: the name is one no server answers to,
        // so the picture is of this app's own frame around a page that did not arrive.
        case "link": ShellStaged(place: .timeline, reads: URL(string: "https://\(host)/a/page/read/out/of/a/post"))
        case "signin": ShellStaged(place: .timeline, signsIn: "forum.\(host)")
        default: ShellStaged(place: .timeline)
        }
    }

    /// How wide the window is made, or nothing where the variable is absent or is not a width.
    private static var width: CGFloat? {
        Double(ProcessInfo.processInfo.environment["FEDIQO_STAGED_WIDTH"] ?? "").flatMap { $0 > 0 ? CGFloat($0) : nil }
    }

    /// A sentence longer than one line of a phone, to see where a long notice goes.
    private static let notice =
        "\(host) and a-rather-long-subdomain.\(host) did not answer, so this timeline shows what this device already holds; it will ask again in a minute."

    // MARK: - The posts

    private static func name(_ status: String) -> String { "https://\(host)/users/staged/statuses/\(status)" }

    /// The post `FEDIQO_STAGED_SCREEN=post` opens: the one with answers under it.
    private static let opened = name("108")

    private static func note(
        _ status: String, _ author: String, _ handle: String, _ body: String, minutesAgo: Double,
        boostedBy: String? = nil, audience: Audience? = .everyone, spoiler: String? = nil,
        counts: Counts = Counts(replies: 0, reblogs: 0, favourites: 0), edited: Bool = false,
        favourited: Bool = false, answers: String? = nil, answering: String? = nil
    ) -> Note {
        let posted = Date().addingTimeInterval(-minutesAgo * 60)
        return Note(
            id: name(status), source: source, author: author, handle: handle, body: body,
            postedAt: posted, categories: [.public],
            boostedBy: boostedBy, boosterHandle: boostedBy.map { _ in "@booster@\(host)" },
            boosted: false, favourited: favourited, bookmarked: false, audience: audience,
            sensitive: spoiler != nil, spoiler: spoiler,
            url: URL(string: "https://\(host)/@staged/\(status)"), counts: counts, statusID: status,
            editedAt: edited ? posted.addingTimeInterval(120) : nil,
            refs: answers.map { [Reference(kind: .answers, id: name($0), statusID: $0, handle: answering)] } ?? []
        )
    }

    /// Posts that are rising, for the one picture that needs a second timeline with posts in
    /// it. Older than every other, so they stand at the end of the timeline of everything.
    private static let rising: [Note] = (1 ... (screenName == "fresh" ? 12 : 4)).map { number in
        Note(
            id: name("9\(number)"), source: source, author: "Rising \(number)", handle: "@rising@\(host)",
            body: "A post that is rising, number \(number).", postedAt: Date().addingTimeInterval(-Double(5000 + number) * 60),
            categories: [.trends], audience: .everyone, statusID: "9\(number)"
        )
    }

    /// What a narrow screen has trouble with, one post each: a long name beside a long handle,
    /// a word that will not break, the two scripts the app is written in, a warning over a post,
    /// a post changed after it was sent, large counts, and a conversation to open.
    private static let notes: [Note] = [
        note("110", "Ada", "@ada@\(host)", "Short one. Nothing to wrap, nothing to cut.", minutesAgo: 2,
             counts: Counts(replies: 1, reblogs: 2, favourites: 3)),
        note("109", "Grace Brewster Murray Hopper, Rear Admiral (retired)",
             "@grace.brewster.murray.hopper@a-rather-long-subdomain.\(host)",
             "A name and a handle that are each longer than the screen is wide, over a post of ordinary length that has to wrap twice or three times at the narrowest width a phone has.",
             minutesAgo: 9, counts: Counts(replies: 12, reblogs: 340, favourites: 1289), edited: true, favourited: true),
        note("108", "Lin", "@lin@\(host)",
             "The post that is opened. It has answers under it, so the opened page has something to draw below the post itself.\n\n#fediqo #phones",
             minutesAgo: 21, counts: Counts(replies: 3, reblogs: 4, favourites: 15)),
        note("107", "林小明", "@xiaoming@\(host)",
             "一則用繁體中文寫的貼文，夠長到在最窄的手機上必須換行兩三次，而且中間沒有任何空白可以斷行，看看每一行的結尾是不是都還在畫面裡。",
             minutesAgo: 34, counts: Counts(replies: 0, reblogs: 7, favourites: 21)),
        note("106", "Tim", "@tim@\(host)",
             "A hyperlink with no place to break it: https://\(host)/a/very/long/path/with-no-spaces-in-it/that-goes-on-and-on-and-on/index.html?and=a&query=besides and then the sentence carries on.",
             minutesAgo: 48, audience: .unlisted, counts: Counts(replies: 2, reblogs: 0, favourites: 1)),
        note("105", "Katherine", "@katherine@\(host)", "What the warning was about.", minutesAgo: 65,
             spoiler: "A warning written at some length, to see where a long warning goes on a narrow screen",
             counts: Counts(replies: 0, reblogs: 1, favourites: 9)),
        note("104", "Margaret", "@margaret@\(host)",
             "Somebody else passed this one on, so the row says who did above what was written.",
             minutesAgo: 90, boostedBy: "A person with a long display name who passes things on",
             counts: Counts(replies: 5, reblogs: 88, favourites: 412)),
        note("103", "Ada", "@ada@\(host)", "For followers only.", minutesAgo: 130, audience: .followers,
             counts: Counts(replies: 0, reblogs: 0, favourites: 2)),
        note("102", "Radia", "@radia@\(host)",
             "Three paragraphs.\n\nThe second of them is the long one, and is here so that a single row can be taller than a small phone's whole screen once the text is at its largest.\n\nThe third.",
             minutesAgo: 200, counts: Counts(replies: 1, reblogs: 3, favourites: 30)),
        note("101", "Barbara", "@barbara@\(host)", "The oldest of them.", minutesAgo: 1500,
             counts: Counts(replies: 0, reblogs: 0, favourites: 0)),
        // Under 108, and drawn where it is opened.
        note("111", "Ada", "@ada@\(host)", "An answer, the first.", minutesAgo: 18, answers: "108", answering: "@lin@\(host)"),
        note("112", "Grace Brewster Murray Hopper, Rear Admiral (retired)",
             "@grace.brewster.murray.hopper@a-rather-long-subdomain.\(host)",
             "A second answer, long enough to wrap under the post it answers on the narrowest phone there is.",
             minutesAgo: 15, answers: "108", answering: "@lin@\(host)"),
        note("113", "Lin", "@lin@\(host)", "And the author answering the first answer.", minutesAgo: 11,
             answers: "111", answering: "@ada@\(host)"),
    ]
}

/// Every question the app would put to a server, answered here with nothing in it.
///
/// **Nothing new, rather than nothing there.** A timeline asked for is an empty list and a
/// conversation is an empty one, so a reload finds nothing to add and says nothing went wrong;
/// everything else — what the server is, who the reader is — is a 404, which the app reads as a
/// server that did not say. No request leaves the process.
private struct StagedHTTP: HTTPClient, HTTPSender {
    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        let path = url.path
        if path.hasSuffix("/context") { return answer(url, #"{"ancestors":[],"descendants":[]}"#) }
        if path.contains("/timelines/") || path.contains("/trends/") || path.hasSuffix("/notifications") {
            return answer(url, "[]")
        }
        return answer(url, "{}", status: 404)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        return try await data(from: url)
    }

    private func answer(_ url: URL, _ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        let headers = ["Content-Type": "application/json"]
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

/// The list scrolled as a finger would have scrolled it, for a picture of a list that is not
/// at its start: the tallest scroll view on screen is put that many points down.
@MainActor
private enum StagedScroll {
    static func scroll(_ down: CGFloat) {
        #if os(iOS)
        var found: UIScrollView?
        func look(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height,
               scroll.bounds.height > (found?.bounds.height ?? 0) {
                found = scroll
            }
            view.subviews.forEach(look)
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach(look)
        }
        guard let found else { return }
        let end = max(0, found.contentSize.height - found.bounds.height + found.adjustedContentInset.bottom)
        found.setContentOffset(CGPoint(x: 0, y: min(down, end) - found.adjustedContentInset.top), animated: false)
        #endif
    }
}

/// The window made a given width, so a phone narrower than any simulator there is can be
/// photographed on one that exists.
///
/// **The window and not a frame around the page**, because a sheet is laid out in its window: a
/// frame would narrow the timeline and leave the composer over it as wide as the screen. The
/// window stays in the middle of the screen and keeps its height, so what is over and under it
/// — the status bar, the home indicator — is still there; what is beside it is nothing, and
/// `scripts/shots.sh` cuts the picture to the window.
private struct StagedWindow: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        #if os(iOS)
        content.onAppear {
            guard let width else { return }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                let screen = scene.screen.bounds
                guard width < screen.width else { continue }
                for window in scene.windows {
                    window.frame = CGRect(x: (screen.width - width) / 2, y: 0, width: width, height: screen.height)
                }
            }
        }
        #else
        content
        #endif
    }
}
#endif
