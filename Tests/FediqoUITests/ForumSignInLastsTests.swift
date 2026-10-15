import Foundation
import Testing
import WebKit

@testable import FediqoCore
@testable import FediqoUI

/// A forum signed in to stays signed in across a relaunch, and a kept password is really kept —
/// #153. Everything here is through `MemoryCredentials` or a store that fails on purpose, and a
/// non-persistent cookie store: no test touches the real Keychain or the real WebKit store.
@MainActor
@Suite("A forum's sign-in lasts", .watched)
struct ForumSignInLastsTests {
    static let host = "bbs.example.org"

    // MARK: - Keeping what was typed

    @Test("What the reader submitted is what is kept, once the sign-in is confirmed")
    func theSubmittedPairIsKept() async throws {
        let credentials = MemoryCredentials()
        let forums = ForumSessions(credentials: credentials)
        // What the forum's page hands over at the moment of submitting — see
        // `ForumSignInPageTests` for the page itself doing it.
        forums.holdTyped(ForumCredential(host: Self.host, username: "reader", password: "right"))

        #expect(await forums.saveTyped(host: "BBS.Example.ORG") == .kept)
        #expect(try credentials.credential(host: Self.host)
                == ForumCredential(host: Self.host, username: "reader", password: "right"))
        #expect(forums.hasPassword(host: Self.host))
        #expect(!forums.holdsTyped(host: Self.host), "the pair outlived its keeping in memory")
        #expect(forums.notice(host: Self.host) == nil)
    }

    @Test("A Keychain that will not keep it is said, with its status, in both languages")
    func aRefusedKeepIsSaid() async {
        let forums = ForumSessions(credentials: RefusingCredentials(status: -25_308))
        forums.holdTyped(ForumCredential(host: Self.host, username: "reader", password: "right"))

        let answer = await forums.saveTyped(host: Self.host)
        #expect(answer == .failed(.store(.keychain(-25_308))))
        #expect(forums.notice(host: Self.host) == .unkept(.store(.keychain(-25_308))),
                "the row would not say it after the sheet is gone")
        #expect(!forums.hasPassword(host: Self.host))

        let english = ForumKeepFailure.store(.keychain(-25_308)).sentence(language: .english)
        #expect(english.contains("-25308"), "the status was not said: \(english)")
        #expect(english.localizedCaseInsensitiveContains("locked"), "\(english)")
        #expect(!english.contains("right"), "the password reached a sentence")
        let chinese = ForumKeepFailure.store(.keychain(-25_308)).sentence(language: .taiwanese)
        #expect(chinese.contains("-25308") && chinese.contains("鑰匙圈"), "\(chinese)")
    }

    @Test("Nothing typed is a failure that says so, and stands no browser up to find out")
    func nothingTypedIsSaid() async {
        let forums = ForumSessions(credentials: MemoryCredentials())
        #expect(await forums.saveTyped(host: Self.host) == .failed(.nothingTyped))
        #expect(!forums.hasEngine(host: Self.host))
        #expect(forums.notice(host: Self.host) == .unkept(.nothingTyped))
        #expect(ForumRowNotice.unkept(.nothingTyped).sentence(language: .english)
            .localizedCaseInsensitiveContains("not kept"))
    }

    @Test("Turning the switch off drops what was held")
    func switchingOffDropsTheHeldPair() {
        let forums = ForumSessions(credentials: MemoryCredentials())
        forums.holdTyped(ForumCredential(host: Self.host, username: "reader", password: "right"))
        forums.watchTyped(host: Self.host, on: false)
        #expect(!forums.holdsTyped(host: Self.host))
        #expect(!forums.hasEngine(host: Self.host), "turning it off stood a browser up")
    }

    @Test("A kept password that cannot be read back is said, and the forum's page still offered")
    func anUnreadableKeepIsSaid() async {
        let forums = ForumSessions(credentials: RefusingCredentials(status: -25_293, reading: true))
        #expect(await forums.signIn(host: Self.host) == .handOver(.keychain(.keychain(-25_293))))
        let said = ForumSignInStop.keychain(.keychain(-25_293)).explanation(language: .english)
        #expect(said.contains("-25293") && said.localizedCaseInsensitiveContains("refused"), "\(said)")
    }

    @Test("A password that could not be deleted is said on the row")
    func anUndeletablePasswordIsSaid() {
        let forums = ForumSessions(credentials: RefusingCredentials(status: -25_308))
        forums.forgetPassword(host: Self.host)
        #expect(forums.notice(host: Self.host) == .unforgotten(.keychain(-25_308)))
        #expect(forums.notice(host: Self.host)?.sentence(language: .english).contains("-25308") == true)
    }

    // MARK: - Signing in again at launch

    @Test("At launch a lapsed forum with something kept signs in again, and one without is left alone")
    func launchSignsInAgain() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: Self.host, username: "reader", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        let attempts = Attempts(.signedIn)

        forums.signInAgain(hosts: ["BBS.Example.ORG", "nothing.example"], attempt: attempts.attempt)
        #expect(forums.isSigningInAgain(host: Self.host), "not registered before returning")
        #expect(!forums.isSigningInAgain(host: "nothing.example"), "a forum with nothing kept was held")
        await forums.signInEnds(host: Self.host)

        #expect(attempts.hosts == [Self.host])
        #expect(forums.reachedSignIn(host: Self.host))
        #expect(!forums.reachedSignIn(host: "nothing.example"))
        #expect(!forums.hasEngine(host: "nothing.example"), "a forum with nothing kept got a browser")
        #expect(forums.notice(host: Self.host) == nil)
    }

    @Test("A forum whose sign-in survived the relaunch is asked nothing")
    func aSurvivingSignInIsLeftAlone() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: Self.host, username: "reader", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        await forums.dataStore.httpCookieStore.setCookie(
            ForumDeviceStoreTests.cookie("x7Kq_2132_auth", domain: ".\(Self.host)")
        )
        let attempts = Attempts(.signedIn)

        forums.signInAgain(hosts: [Self.host], attempt: attempts.attempt)
        await forums.signInEnds(host: Self.host)
        #expect(attempts.hosts.isEmpty, "a forum still signed in spent a sign-in attempt")
    }

    @Test("Where the launch cannot sign a forum in, the row says why and still offers Sign in")
    func aLapsedLaunchIsSaid() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: Self.host, username: "reader", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        let attempts = Attempts(.handOver(.refused(nil)))

        forums.signInAgain(hosts: [Self.host], attempt: attempts.attempt)
        await forums.signInEnds(host: Self.host)

        #expect(forums.notice(host: Self.host) == .lapsed(.refused(nil)))
        #expect(!session.isSignedIn(host: Self.host), "the row would offer Sign out, not Sign in")
        let said = forums.notice(host: Self.host)?.sentence(language: .english) ?? ""
        #expect(said.localizedCaseInsensitiveContains("at launch") && said.localizedCaseInsensitiveContains("sign in"))

        // Signing in by hand takes the sentence away.
        forums.recordSignIn(host: Self.host)
        #expect(forums.notice(host: Self.host) == nil)
    }

    @Test("Each way a launch can fail to sign in has its own row sentence, in both languages")
    func everyLapseHasASentence() {
        let keys = ForumSignInStop.allKinds.map(\.lapsedKey)
        #expect(Set(keys).count == keys.count, "two lapses share one sentence")
        for stop in ForumSignInStop.allKinds {
            for language in [DummyLanguage.english, .taiwanese] {
                let said = ForumRowNotice.lapsed(stop).sentence(language: language)
                #expect(said != stop.lapsedKey && !said.isEmpty, "\(stop.lapsedKey) in \(language)")
                #expect(!said.contains("%@"), "\(stop.lapsedKey) was not filled in")
            }
        }
        for status: Int32 in [-25_308, -34_018, -25_293, -128, -25_291, -25_294, -50] {
            for language in [DummyLanguage.english, .taiwanese] {
                let said = ForumKeychainReason.of(.keychain(status), language: language)
                #expect(said.contains("\(status)"), "\(status) in \(language): \(said)")
            }
        }
        for error in [ForumCredentialError.incomplete, .unreadable] {
            let key = ForumKeychainReason.of(error, language: .taiwanese)
            #expect(!key.hasPrefix("forum.keychain."), "\(error) has no 繁體中文 sentence")
        }
    }

    // MARK: - Posts read before the sign-in came back

    @Test("A forum's posts wait for its launch sign-in before they are read")
    func postsWaitForTheLaunch() async throws {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: Self.host, username: "reader", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        let http = FixtureHTTP([Self.thread: .text(Self.words)])
        let posts = ForumPosts(http: http, through: forums)
        forums.limitSleep = TurnedClock().sleep
        let gate = Gate()
        let attempts = Attempts(.handOver(.unreachable), gate: gate)

        forums.signInAgain(hosts: [Self.host], attempt: attempts.attempt)
        let fetching = Task { await posts.fetch(Self.ref) }
        // No `by:`: the launch sign-in is a task the sessions start for themselves.
        await met("the launch sign-in has started") { attempts.hosts == [Self.host] }
        await met("the post's read has begun", by: fetching) { posts.isFetching(Self.ref) }
        // Counted turns, behind the two waits: the read is parked on the sign-in inside the
        // posts' own task, and nothing says it has reached that wait.
        for _ in 0..<50 { await Task.yield() }
        #expect(await http.requested.isEmpty, "a post was read before its forum's sign-in settled")

        await gate.open()
        await fetching.value
        #expect(await http.requested.count == 1)
        #expect(posts.reading(Self.ref) == .words("旧插座该换了。"))
    }

    @Test("A post read as a guest is asked again once the sign-in lands, not left withheld")
    func withheldIsForgottenOnSignIn() async {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let posts = ForumPosts(http: FixtureHTTP([Self.thread: .text(Self.locked)]), through: forums)
        await posts.fetch(Self.ref)
        #expect(posts.reading(Self.ref) == .withheld, "the premise: a guest is withheld the post")
        let other = ForumThreadRef(host: "other.example", tid: 1)
        posts.keep([Self.lockedPost(host: "other.example")], for: .init(other, .opening), startedAt: 0)
        let generation = posts.generation

        forums.recordSignIn(host: Self.host)

        #expect(posts.reading(Self.ref) == .coming, "the withheld answer outlived the sign-in")
        #expect(posts.generation > generation, "the band on screen would not ask again")
        #expect(posts.reading(other) == .withheld, "a sign-in reached a forum it was not for")
    }

    @Test("A guest's answer still in the air when the sign-in lands is not kept")
    func aGuestAnswerInFlightIsDropped() async {
        let forums = ForumSessions(credentials: MemoryCredentials())
        let http = GateHTTP(Data(Self.locked.utf8))
        let posts = ForumPosts(http: http, through: forums)
        let fetching = Task { await posts.fetch(Self.ref) }
        await http.waitForRequest()
        let generation = posts.generation

        forums.recordSignIn(host: Self.host)
        await http.open()
        await fetching.value

        #expect(posts.reading(Self.ref) == .coming, "a guest's answer landed under a signed-in forum")
        #expect(posts.generation > generation)
    }

    // MARK: - A launch sign-in held past the hold

    /// A forum with a kept password and a launch sign-in held at `gate`, its hold on `clock`, and
    /// what a member reads afterwards answered by `member` — never a browser.
    private static func heldLaunch(
        gate: Gate, clock: TurnedClock, member: FixtureHTTP, outcome: ForumSignInOutcome = .signedIn
    ) throws -> (ForumSessions, Attempts) {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: host, username: "reader", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        forums.limitSleep = clock.sleep
        forums.memberRead = { _ in member }
        let attempts = Attempts(outcome, gate: gate)
        forums.signInAgain(hosts: [host], attempt: attempts.attempt)
        return (forums, attempts)
    }

    @Test("Past the hold the wait for a launch sign-in ends, and the sign-in goes on")
    func theHoldEndsTheWait() async throws {
        let gate = Gate()
        let guardTask = watching(gate, "the launch sign-in, held past the hold")
        defer { guardTask.cancel() }
        let clock = TurnedClock()
        let (forums, attempts) = try Self.heldLaunch(gate: gate, clock: clock, member: FixtureHTTP())

        let returned = Returned()
        let settling = Task { await forums.settled(host: Self.host); returned.yes = true }
        await met("the hold is asleep", by: settling) { clock.sleeping == 1 }
        #expect(clock.asked == [ForumSessions.launchHold])
        clock.turn()
        // No `by:`: the wait under check is the very work that would not end.
        await met("the wait has returned at the hold") { returned.yes }

        #expect(forums.isSigningInAgain(host: Self.host), "the sign-in was ended with the wait")
        await gate.open()
        await met("the sign-in has ended by itself") { !forums.isSigningInAgain(host: Self.host) }
        #expect(attempts.hosts == [Self.host])
        #expect(forums.reachedSignIn(host: Self.host), "the sign-in did not land")
    }

    @Test("The hold is counted once, from the launch's sign-in: a wait begun after it has passed is not held again")
    func theHoldIsCountedOnce() async throws {
        let gate = Gate()
        let guardTask = watching(gate, "the launch sign-in, held past the hold")
        defer { guardTask.cancel() }
        let clock = TurnedClock()
        let (forums, _) = try Self.heldLaunch(gate: gate, clock: clock, member: FixtureHTTP())

        let first = Returned()
        let firstWait = Task { await forums.settled(host: Self.host); first.yes = true }
        await met("the hold is asleep", by: firstWait) { clock.sleeping == 1 }
        clock.turn()
        await met("the first wait has returned at the hold", by: firstWait) { first.yes }

        let later = Returned()
        let laterWait = Task { await forums.settled(host: Self.host); later.yes = true }
        // No `by:`: the wait under check is the very work that would not end.
        await met("a wait begun after the hold has returned at once") { later.yes }
        await laterWait.value
        #expect(clock.asked == [ForumSessions.launchHold], "a wait begun after the hold was held a hold of its own")
        #expect(forums.isSigningInAgain(host: Self.host), "the sign-in was ended with the wait")
    }

    @Test("Past the hold a post kept is drawn, not the guest's withheld one, and is read again as the sign-in lands")
    func keptWordsOutlastTheHold() async throws {
        let gate = Gate()
        let guardTask = watching(gate, "the launch sign-in, held past the hold")
        defer { guardTask.cancel() }
        let clock = TurnedClock()
        let member = FixtureHTTP([Self.thread: .text(Self.words)])
        let (forums, _) = try Self.heldLaunch(gate: gate, clock: clock, member: member)
        let guest = FixtureHTTP([Self.thread: .text(Self.locked)])
        let posts = ForumPosts(http: guest, through: forums)
        posts.deadlineSleep = TurnedClock().sleep
        let kept = ForumThreadRef(host: Self.host, tid: 88012, kept: ForumOpening(words: "先前讀過的字。"))

        let fetching = Task { await posts.fetch(kept) }
        await met("the launch's hold is asleep", by: fetching) { clock.sleeping == 1 }
        clock.turn()
        await met("the guest's answer waits for the sign-in", by: fetching) { forums.waitingOnSignIn == 1 }
        #expect(await guest.requested.count == 1)
        #expect(posts.reading(kept) == .words("先前讀過的字。"), "the guest's answer took the kept words' place")
        #expect(forums.isSigningInAgain(host: Self.host), "the sign-in was cancelled")
        let generation = posts.generation

        await gate.open()
        await fetching.value
        #expect(posts.reading(kept) == .words("先前讀過的字。"))
        #expect(posts.generation > generation, "the band on screen would not ask again")
        // What the band asks once the generation moves.
        await posts.fetch(kept)
        #expect(await member.requested.count == 1, "the post was not read again as a member")
        #expect(posts.reading(kept) == .words("旧插座该换了。"))
    }

    @Test("Past the hold a topic's kept replies stay drawn, and its page is read again as the sign-in lands")
    func keptRepliesOutlastTheHold() async throws {
        let gate = Gate()
        let guardTask = watching(gate, "the launch sign-in, held past the hold")
        defer { guardTask.cancel() }
        let clock = TurnedClock()
        let member = FixtureHTTP([Self.thread: .text(Self.words + Self.reply(locked: false))])
        let (forums, _) = try Self.heldLaunch(gate: gate, clock: clock, member: member)
        let guest = FixtureHTTP([Self.thread: .text(Self.words + Self.reply(locked: true))])
        let posts = ForumPosts(http: guest, through: forums)
        posts.deadlineSleep = TurnedClock().sleep
        let stored = DiscuzPost(
            pid: 19102, tid: 88012, floor: 2, author: "老王", handle: "@老王@\(Self.host)", body: "先前讀過的回覆。"
        )
        posts.reading = { _, _ in [stored] }
        await posts.open(Self.ref)
        #expect(Self.bodies(posts) == ["先前讀過的回覆。"], "the premise: the kept reply is drawn")

        let renewing = Task { await posts.renew(Self.ref) }
        await met("the launch's hold is asleep", by: renewing) { clock.sleeping == 1 }
        clock.turn()
        await met("the guest's page waits for the sign-in", by: renewing) { forums.waitingOnSignIn == 1 }
        #expect(await guest.requested.count == 1)
        #expect(Self.bodies(posts) == ["先前讀過的回覆。"], "the guest's withheld reply took the kept one's place")
        #expect(posts.further(of: Self.ref) == .coming, "the foot said something the sign-in takes back")

        await gate.open()
        await renewing.value
        #expect(await member.requested.count == 1, "the page was not read again as a member")
        #expect(Self.bodies(posts) == ["换了，三孔的。"])
    }

    @Test("Past the hold a blog the guest is refused is still on its way, and reads as the sign-in lands")
    func aRefusedBlogWaitsForTheSignIn() async throws {
        let gate = Gate()
        let guardTask = watching(gate, "the launch sign-in, held past the hold")
        defer { guardTask.cancel() }
        let clock = TurnedClock()
        let member = FixtureHTTP([Self.blog: .text(Self.blogPage)])
        let (forums, _) = try Self.heldLaunch(gate: gate, clock: clock, member: member)
        let guest = FixtureHTTP([Self.blog: .text(#"<html><body><div id="messagetext"><p>只有好友才能查看。</p></div></body></html>"#)])
        let blogs = ForumBlogs(http: guest, through: forums)
        blogs.work = SourceWork()
        let row = DummyItem(Note(
            id: DiscuzBlogRow.id(host: Self.host, blog: 500), source: Source(host: Self.host, kind: .discuz),
            author: "某人", handle: "@某人@\(Self.host)", body: "摘要……", title: "一篇日誌",
            postedAt: Date(timeIntervalSince1970: 0), categories: [.trends], url: URL(string: Self.blog)
        ))

        let opening = Task { await blogs.open(row) }
        await met("the launch's hold is asleep", by: opening) { clock.sleeping == 1 }
        clock.turn()
        await met("the guest's refusal waits for the sign-in", by: opening) { forums.waitingOnSignIn == 1 }
        #expect(await guest.requested.count == 1)
        #expect(blogs.reading(of: row) == .coming, "a refusal the sign-in takes back was drawn")

        await gate.open()
        await opening.value
        #expect(await member.requested.count == 1, "the blog was not read again as a member")
        #expect(blogs.reading(of: row) == .read)
    }

    @Test("Past the hold, a launch sign-in that fails leaves the guest's answer drawn")
    func aFailedSignInLeavesTheGuestAnswer() async throws {
        let gate = Gate()
        let guardTask = watching(gate, "the launch sign-in, held past the hold")
        defer { guardTask.cancel() }
        let clock = TurnedClock()
        let member = FixtureHTTP()
        let (forums, _) = try Self.heldLaunch(gate: gate, clock: clock, member: member, outcome: .handOver(.unreachable))
        let guest = FixtureHTTP([Self.thread: .text(Self.locked)])
        let posts = ForumPosts(http: guest, through: forums)
        posts.deadlineSleep = TurnedClock().sleep

        let fetching = Task { await posts.fetch(Self.ref) }
        await met("the launch's hold is asleep", by: fetching) { clock.sleeping == 1 }
        clock.turn()
        await met("the guest's answer waits for the sign-in", by: fetching) { forums.waitingOnSignIn == 1 }
        #expect(await guest.requested.count == 1)
        #expect(posts.reading(Self.ref) == .coming, "a withheld answer the sign-in may take back was drawn")

        await gate.open()
        await fetching.value
        #expect(posts.reading(Self.ref) == .withheld, "with no sign-in, the guest's answer is the answer")
        #expect(await member.requested.isEmpty)
    }

    private static func bodies(_ posts: ForumPosts) -> [String] {
        guard case .loaded(let replies) = posts.standing(of: ref) else { return [] }
        return replies.map { $0.isWithheld ? "withheld" : $0.body }
    }

    static func reply(locked: Bool) -> String {
        let words = locked
            ? #"<div class="locked">游客请<a href="member.php?mod=logging&action=login">登录</a>后查看回复内容</div>"#
            : "换了，三孔的。"
        return """
        <div class="comiis_postli" id="pid19102">
        <div class="comiis_postli_top"><h2><a href="home.php?mod=space&uid=72">老王</a></h2></div>
        <div class="comiis_postli_time"><span>20&nbsp;分钟前</span></div>
        <div class="comiis_a comiis_message_table cl">\(words)</div>
        </div>
        """
    }

    static let blog = "https://\(host)/home.php?mod=space&uid=21&do=blog&id=500"

    static let blogPage = #"""
    <html><body>
    <div id="pt" class="bm cl"><div class="z"><a href="./">論壇</a> <em>&rsaquo;</em>
    <a href="home.php?mod=space&amp;uid=21">某人</a> <em>&rsaquo;</em>
    <a href="home.php?mod=space&amp;uid=21&amp;do=blog&amp;view=me">日誌</a></div></div>
    <div class="vw mbm"><div class="h pbm">
    <h1 class="ph">一篇日誌</h1>
    <p class="xg2"><span class="xg1">2026-9-10 21:30</span></p>
    </div>
    <div id="blog_article" class="d cl">整篇日誌的字。</div>
    </div>
    </body></html>
    """#

    // MARK: - Clear, Remove and Sign out still take everything

    @Test("Sign out, Clear and Remove take the kept password, the held pair and the row's sentence")
    func forgettingTakesEverything() async throws {
        let credentials = MemoryCredentials()
        let forums = ForumSessions(credentials: credentials)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        session.sources = [Source(host: "one.example", kind: .discuz), Source(host: "two.example", kind: .discuz)]
        for host in ["one.example", "two.example", "three.example"] {
            try credentials.save(ForumCredential(host: host, username: "u", password: "p"))
            await forums.plantSession(host: host)
            forums.holdTyped(ForumCredential(host: host, username: "u", password: "p2"))
        }
        forums.refreshSavedHosts()
        _ = await forums.saveTyped(host: "nowhere.example")

        await session.signOut(host: "one.example")
        await session.clear(host: "two.example")
        await session.remove(host: "three.example")
        await forums.forget(host: "nowhere.example")

        for host in ["one.example", "two.example", "three.example"] {
            #expect(try credentials.credential(host: host) == nil, "\(host) kept its password")
            #expect(!forums.hasPassword(host: host))
            #expect(!forums.holdsTyped(host: host), "\(host) kept what was typed")
            #expect(!forums.reachedSignIn(host: host), "\(host) kept its sign-in")
        }
        #expect(forums.notice(host: "nowhere.example") == nil)
    }

    // MARK: - Fixtures

    static let ref = ForumThreadRef(host: host, tid: 88012)
    static let thread = "https://\(host)/forum.php?mod=viewthread&tid=88012&mobile=2"

    static let words = #"""
    <div class="comiis_postli" id="pid19101">
    <div class="comiis_postli_top"><h2><a href="home.php?mod=space&uid=71">小北</a></h2></div>
    <div class="comiis_postli_time"><span>22&nbsp;分钟前</span></div>
    <div class="comiis_a comiis_message_table cl">旧插座该换了。</div>
    </div>
    """#

    static let locked = #"""
    <div class="comiis_postli" id="pid19101">
    <div class="comiis_postli_top"><h2><a href="home.php?mod=space&uid=71">小北</a></h2></div>
    <div class="comiis_postli_time"><span>22&nbsp;分钟前</span></div>
    <div class="comiis_a comiis_message_table cl">
    <div class="locked">游客请<a href="member.php?mod=logging&action=login">登录</a>后查看回复内容</div>
    </div></div>
    """#

    static func lockedPost(host: String) -> DiscuzPost {
        DiscuzPost(pid: 1, tid: 1, floor: 1, author: "a", handle: "@a@\(host)", body: "", isWithheld: true)
    }
}

/// Whether a wait under check has returned.
@MainActor
final class Returned {
    var yes = false
}

/// A launch's sign-in, answered as the test says and counted, optionally held at a gate.
@MainActor
final class Attempts {
    private let outcome: ForumSignInOutcome
    private let gate: Gate?
    private(set) var hosts: [String] = []

    init(_ outcome: ForumSignInOutcome, gate: Gate? = nil) {
        self.outcome = outcome
        self.gate = gate
    }

    func attempt(_ host: String) async -> ForumSignInOutcome {
        hosts.append(host)
        if let gate { await gate.wait() }
        return outcome
    }
}

/// A Keychain that refuses, with the status it is given. Never the real one.
final class RefusingCredentials: ForumCredentialStore, @unchecked Sendable {
    let status: Int32
    let reading: Bool

    init(status: Int32, reading: Bool = false) {
        self.status = status
        self.reading = reading
    }

    func credential(host: String) throws -> ForumCredential? {
        if reading { throw ForumCredentialError.keychain(status) }
        return nil
    }

    func save(_ credential: ForumCredential) throws { throw ForumCredentialError.keychain(status) }
    func forget(host: String) throws { throw ForumCredentialError.keychain(status) }
    func savedHosts() throws -> Set<String> { [] }
}
