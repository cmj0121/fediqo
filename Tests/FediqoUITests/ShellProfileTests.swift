import Foundation
import UniformTypeIdentifiers
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #312: the reader changes their own account at a source — where Change stands, what is asked
/// when the sheet opens and when Save is pressed, what the sheet says after an answer, a
/// refusal, a failure, a sign-in that ended and a part gone, and every place that draws the
/// reader's own account after each.
///
/// **No check here waits on the clock.** Each waits on an ask arriving at `PageServer` or on the
/// task that made it; a held ask is let go by the check, and by a guard when the run goes still.
@MainActor
@Suite("Your own account is changed from your own page", .serialized, .watched)
struct ShellProfileTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let reads = "read:statuses read:lists read:accounts read:search read:follows write:follows"
    private static let all = "\(reads) write:accounts"

    private static let who = "/api/v1/accounts/verify_credentials"
    private static let lookup = "/api/v1/accounts/lookup?acct=me"
    private static let instance = "/api/v2/instance"
    private static let change = "/api/v1/accounts/update_credentials"
    private static let statuses = "/api/v1/accounts/7/statuses"
    private static let pinned = "/api/v1/accounts/7/statuses?pinned=true"

    /// The account as its owner sees it, in the shape a real server's account check has.
    private static func own(name: String = "Me", locked: Bool = true, asking: Int = 3) -> String {
        #"""
        {"id":"7","acct":"me","username":"me","display_name":"\#(name)","locked":\#(locked),"discoverable":true,
         "note":"<p>I write about rivers.</p>","followers_count":2,"following_count":1,"statuses_count":4,
         "fields":[{"name":"Site","value":"<a href=\"https://me.example\">me.example</a>","verified_at":"2026-01-01T00:00:00.000Z"}],
         "source":{"note":"I write about rivers.","fields":[{"name":"Site","value":"https://me.example","verified_at":"2026-01-01T00:00:00.000Z"}],
          "discoverable":true,"hide_collections":null,"follow_requests_count":\#(asking)}}
        """#
    }

    private static let limits = #"{"configuration":{"accounts":{"max_display_name_length":30,"max_note_length":500,"max_profile_fields":4}}}"#

    private static func status(_ id: Int) -> String {
        #"""
        {"id":"\#(id)","uri":"https://m.example/users/me/statuses/\#(id)","created_at":"2026-10-0\#(id)T00:00:00.000Z",
         "content":"<p>post \#(id)</p>","visibility":"public","account":{"id":"7","acct":"me","display_name":"Me"}}
        """#
    }

    private static func served(_ more: [String: PageServer.Answer] = [:]) -> [String: PageServer.Answer] {
        [
            who: PageServer.Answer(body: own()),
            lookup: PageServer.Answer(body: own()),
            instance: PageServer.Answer(body: limits),
            change: PageServer.Answer(body: own(name: "River Me", locked: false, asking: 0)),
            statuses: PageServer.Answer(body: "[" + status(2) + "]"),
            pinned: PageServer.Answer(body: "[" + status(1) + "]"),
        ].merging(more) { $1 }
    }

    private func session(_ routes: [String: PageServer.Answer] = served()) async -> (ShellSession, PageServer) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        session.deadlinesUnturned()
        session.work = SourceWork()
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        return (session, server)
    }

    private func signIn(_ session: ShellSession, as access: String = "tok", holding scopes: String = ShellProfileTests.all) async throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: access, clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
    }

    /// The reader's own page, opened, and the pages it is one of.
    private func ownPage(_ session: ShellSession) async throws -> (ShellPersonPages, DummyPerson) {
        let pages = ShellPersonPages()
        let me = try #require(ShellPersonPages.own(at: Self.host, in: session))
        await pages.opened(me, in: session)
        return (pages, me)
    }

    /// The sheet up and read.
    private func opened(_ pages: ShellPersonPages, _ session: ShellSession) async throws -> ProfileSaid {
        await pages.profile.open(Self.host, in: session)?.value
        return try #require(pages.profile.said(in: session))
    }

    private func asked(_ server: PageServer) async -> [String] {
        await server.asked.filter { $0 != Self.who && $0 != Self.lookup }
    }

    /// What a change sent, as the pairs of its form.
    private func form(_ server: PageServer) async -> [String: String] {
        guard let body = await server.sent.last(where: { $0.ask == Self.change })?.body else { return [:] }
        var pairs: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            pairs[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return pairs
    }

    // MARK: - Where Change stands

    @Test("Change stands in the head of the reader's own page once the source has said who they are, and on nobody else's; where the sign-in does not hold the account part it is its lock — the press, and `l`, ask for the part and open no sheet; held, both open the sheet, and a second press while it is up does nothing")
    func changeStandsOnYourOwnPage() async throws {
        let (session, _) = await session()
        try await signIn(session)
        let pages = ShellPersonPages()
        let me = try #require(ShellPersonPages.own(at: Self.host, in: session))
        #expect(pages.head(of: me, in: session).change == nil, "not while asking who they are")
        await pages.opened(me, in: session)
        #expect(pages.head(of: me, in: session).change == OwnChangeEntry(host: Self.host, lock: nil))
        #expect(OwnChangeEntry(host: Self.host).spoken(language: .english) == "Change your profile at m.example")
        let ada = try #require(DummyPerson(handle: "@ada@m.example", host: Self.host))
        #expect(pages.changeEntry(of: ada, in: session) == nil, "somebody else's page has Follow")

        #expect(pages.followByKey(me, in: session), "`l` presses Change")
        #expect(pages.profile.open?.host == Self.host)
        await pages.profile.open(Self.host, in: session)?.value
        let first = pages.profile.open
        #expect(pages.changeOwn(me, in: session) && pages.profile.open == first, "one sheet: the press does nothing more")
        pages.profile.putDown()

        // The part not held: the lock, whose press asks for it.
        let (lacking, _) = await self.session()
        try await signIn(lacking, holding: Self.reads)
        let (others, mine) = try await ownPage(lacking)
        let entry = try #require(others.head(of: mine, in: lacking).change)
        #expect(entry.lock?.kind == .unasked && entry.lock?.asks == true)
        #expect(entry.lockWords(language: .english) == "This sign-in was not asked to change your profile. Update permission")
        #expect(others.changeOwn(mine, in: lacking))
        #expect(others.profile.open == nil, "no sheet")
        #expect(lacking.partAsks.open?.ticked == [.account], "the question for the part")
    }

    @Test("The root presents the sheet in one line beside the part's question, with no closure presenter in its body; the sheet's file names no kind of source, and the file that asks draws nothing")
    func presentedFromTheRoot() throws {
        let root = try String(contentsOf: ShellSource.root.appendingPathComponent("FediqoRootView.swift"), encoding: .utf8)
        #expect(root.contains(".modifier(PartQuestion(session: session))\n            .modifier(ProfileSheetPresenter(profile: people.profile, session: session))"))
        let sheet = try ShellSource.shell("ProfileSheet"), asks = try ShellSource.shell("ShellProfile")
        #expect(!sheet.contains("Mastodon") && !sheet.contains("session.mastodon"))
        #expect(!DrawsNotKnowingKindTests.draws(asks))
    }

    // MARK: - Opening

    @Test("The sheet reads the account afresh every time it opens, never from what the page holds — the owner's own words, not the drawn ones — and the limits the host states once a run; until the read lands nothing is drawn to edit and Save sends nothing")
    func theSheetReadsAfreshAndSaveWaits() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        let profile = pages.profile

        await server.hold(Self.who)
        let held = watching("the account check, held at its server") { await server.release(Self.who) }
        defer { held.cancel() }
        let checks = await server.arrivals(of: Self.who)
        let reading = try #require(profile.open(Self.host, in: session))
        await server.arrival(of: Self.who, times: checks + 1, by: reading)
        let asking = try #require(profile.said(in: session))
        #expect(asking.state == .asking && !asking.drawsRows && !asking.canSave && !asking.cancelAsks)
        #expect(asking.stateLine(language: .english) == "Asking m.example for your profile…")
        #expect(profile.save(in: session) == nil, "Save waits for the read")
        await server.release(Self.who)
        await reading.value

        let said = try #require(profile.said(in: session))
        let draft = try #require(said.draft)
        #expect(said.state == .read && said.drawsRows && said.editable && !said.canSave)
        #expect(said.stateLine(language: .english) == "As m.example holds it now.")
        #expect(draft.name == "Me" && draft.words == "I write about rivers.", "the owner's own words, never the HTML")
        #expect(draft.fields.map(\.content) == ["https://me.example"] && draft.fields[0].sealed)
        #expect(draft.follow == false && draft.found == true && draft.lists == nil, "an empty word is not said")
        #expect(draft.limits == OwnLimits(name: 30, words: 500, fields: 4))
        #expect(await asked(server) == [Self.instance])

        profile.putDown()
        #expect(profile.open == nil && profile.said(in: session) == nil)
        let again = await server.arrivals(of: Self.who)
        await profile.open(Self.host, in: session)?.value
        #expect(await server.arrivals(of: Self.who) == again + 1, "read again on the next opening")
        #expect(await asked(server) == [Self.instance], "the limits are not asked again this run")
        #expect(profile.draft?.limits.fields == 4)
    }

    @Test("A read that fails says so with the press that asks again, and draws nothing to edit; asked again and answered, the rows come")
    func aReadThatFails() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        await server.answer(Self.who, PageServer.Answer(body: "{}", status: 500))
        let failed = try await opened(pages, session)
        #expect(failed.state == .readFailed && !failed.drawsRows && !failed.canSave && !failed.cancelAsks && failed.lineWarns)
        #expect(failed.stateLine(language: .english) == "Could not ask m.example for your profile, so nothing can be changed yet.")
        await server.answer(Self.who, PageServer.Answer(body: Self.own()))
        await pages.profile.readAgain(in: session)?.value
        #expect(pages.profile.said(in: session)?.state == .read)
        #expect(pages.profile.readAgain(in: session) == nil, "nothing to ask again once read")
    }

    // MARK: - An answer

    @Test("Save sends only what changed, and the answer is drawn wherever the reader's own account is: the sheet closes and a listener hears it; the head and About take the answer's name and lock; the requests line takes the answer's count; Posts and Pinned forget what they read and the one in front asks again — and the handle every own-page place rests on, and what the source's page says of posting, draw the same")
    func anAnswerIsDrawnEverywhere() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let (pages, me) = try await ownPage(session)
        var lamp: String?
        _ = pages.turn(me, to: .posts, lamp: &lamp, in: session)
        await pages.fronted(me, in: session)
        #expect(await server.arrivals(of: Self.statuses) == 1)
        #expect(pages.requestsEntry(of: me, in: session)?.counted == 3)
        #expect(pages.head(of: me, in: session).marks.count == 1, "locked: the lock mark")
        let handle = session.mastodon.handles[Self.host]
        var heard: [String] = []
        pages.profile.announce = { heard.append($0) }

        _ = try await opened(pages, session)
        pages.profile.draft?.name = "River Me"
        pages.profile.draft?.follow = true
        let said = try #require(pages.profile.said(in: session))
        #expect(said.canSave && said.cancelAsks)
        #expect(said.waitingLine(language: .english) == "3 people ask to follow you; with this on, m.example lets them follow you at once.")
        let saving = try #require(pages.profile.save(in: session))
        #expect(pages.profile.said(in: session)?.state == .sending && pages.profile.said(in: session)?.held == true)
        pages.profile.putDown()
        #expect(pages.profile.open != nil, "nothing puts the sheet down while the change is out")
        await saving.value

        #expect(await form(server) == ["display_name": "River Me", "locked": "false"], "only what changed")
        #expect(await server.sent.last?.method == "PATCH")
        #expect(pages.profile.open == nil, "the sheet closes")
        #expect(heard == ["m.example saved your profile."])
        let head = pages.head(of: me, in: session)
        #expect(head.name == "River Me" && head.marks.isEmpty, "the head takes the answer")
        #expect(pages.about(of: me, in: session)?.person?.name == "River Me", "and About")
        #expect(session.mastodon.asking(host: Self.host) == 0 && pages.requestsEntry(of: me, in: session) == nil, "nobody waits now")
        #expect(await server.arrivals(of: Self.statuses) == 2, "Posts, in front, asked again")
        #expect(session.mastodon.handles[Self.host] == handle && ShellPersonPages.own(at: Self.host, in: session) == me)
        #expect(pages.you.said(at: Self.host, in: session)?.reading == .asking, "the source's page asked nothing")
    }

    @Test("Nothing changed sends nothing; a row with nothing in it is left out of what is sent; a field changed sends every field, and a moved one sends them in the new order")
    func whatIsSent() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        _ = try await opened(pages, session)
        pages.profile.draft?.add()
        #expect(pages.profile.said(in: session)?.canSave == false, "an empty field is no change")
        #expect(pages.profile.save(in: session) == nil)
        let added = pages.profile.draft?.add()
        let id = try #require(added)
        pages.profile.draft?.fields.removeAll { $0.blank && $0.id != id }
        pages.profile.draft?.fields[1].label = "Pronouns"
        pages.profile.draft?.fields[1].content = "they"
        pages.profile.draft?.move(id, by: -1)
        await pages.profile.save(in: session)?.value
        #expect(await form(server) == [
            "fields_attributes[0][name]": "Pronouns", "fields_attributes[0][value]": "they",
            "fields_attributes[1][name]": "Site", "fields_attributes[1][value]": "https://me.example",
        ])
    }

    // MARK: - Refused, failed, ended, gone

    @Test("A refusal says what was refused under each row it names, in the source's words, keeps every letter typed and changes nothing drawn; Save sends the same again and Cancel asks first")
    func aRefusal() async throws {
        let refused = PageServer.Answer(
            body: #"{"error":"Validation failed: Display name is too long","details":{"display_name":[{"error":"ERR_TOO_LONG","description":"is too long (maximum is 30 characters)"}]}}"#,
            status: 422
        )
        let (session, server) = await session(Self.served([Self.change: refused]))
        try await signIn(session)
        let (pages, me) = try await ownPage(session)
        _ = try await opened(pages, session)
        let long = String(repeating: "R", count: 31)
        pages.profile.draft?.name = long
        #expect(pages.profile.draft?.nameCount?.words(host: Self.host, language: .english) == "1 over the 30 m.example allows")
        await pages.profile.save(in: session)?.value

        let said = try #require(pages.profile.said(in: session))
        #expect(said.state == .refused(sentence: "Validation failed: Display name is too long", rows: [.name: "is too long (maximum is 30 characters)"]))
        #expect(said.stateLine(language: .english) == "m.example refused this. What you typed is kept.")
        #expect(said.refusalSaid(language: .english) == "m.example says: Validation failed: Display name is too long")
        #expect(said.refusal(of: .name) == "is too long (maximum is 30 characters)" && said.refusal(of: .words) == nil)
        #expect(said.draft?.name == long && said.canSave && said.cancelAsks && said.editable)
        #expect(pages.head(of: me, in: session).name == "Me", "nothing drawn changes")
        await pages.profile.save(in: session)?.value
        #expect(await server.arrivals(of: Self.change) == 2, "Save sends it again")
    }

    @Test("A source that forbids a sign-in holding the part says so and keeps what was typed; a 403 to a sign-in without it is the part gone — its lock, whose press asks for it, and Save dim until it is held again")
    func forbiddenAndThePartGone() async throws {
        let forbidden = PageServer.Answer(body: #"{"error":"This action is not allowed"}"#, status: 403)
        let (session, _) = await session(Self.served([Self.change: forbidden]))
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        _ = try await opened(pages, session)
        pages.profile.draft?.words = "Rivers, mostly."
        await pages.profile.save(in: session)?.value
        let said = try #require(pages.profile.said(in: session))
        #expect(said.state == .forbidden && said.draft?.words == "Rivers, mostly." && said.canSave)
        #expect(said.stateLine(language: .english) == "m.example would not let this sign-in change your profile. What you typed is kept.")

        let (lacking, wire) = await self.session(Self.served([Self.change: forbidden]))
        try await signIn(lacking, holding: Self.reads)
        let (others, _) = try await ownPage(lacking)
        _ = try await opened(others, lacking)
        others.profile.draft?.words = "Rivers, mostly."
        await others.profile.save(in: lacking)?.value
        let gone = try #require(others.profile.said(in: lacking))
        #expect(gone.state == .partGone && gone.lock?.asks == true && !gone.canSave && gone.cancelAsks)
        #expect(gone.stateLine(language: .english) == "This sign-in was not asked to change your profile. Update permission")
        #expect(gone.draft?.words == "Rivers, mostly.")
        others.profile.askForPart(in: lacking)
        #expect(lacking.partAsks.open?.ticked == [.account])
        lacking.partAsks.putDown()
        // Held again — as a yes on the source's page leaves it: a new token for the same
        // account — the sheet is as it was, and the next press keeps it and what was typed.
        try await signIn(lacking, as: "tok3")
        #expect(others.profile.said(in: lacking)?.state == .read && others.profile.said(in: lacking)?.canSave == true)
        await wire.answer(Self.change, PageServer.Answer(body: Self.own()))
        var heard: [String] = []
        others.profile.announce = { heard.append($0) }
        let saving = others.profile.save(in: lacking)
        #expect(saving != nil, "the same account: the press goes through")
        await saving?.value
        #expect(await wire.arrivals(of: Self.change) == 2)
        #expect(others.profile.open == nil)
        #expect(await form(wire) == ["note": "Rivers, mostly."])
        #expect(heard == ["m.example saved your profile."], "the answer landed on the sheet that sent it")
    }

    @Test("A change that gets no answer says whether it took is not known, keeps what was typed and changes nothing held — the page stays as last read — and Save sends the same again")
    func aFailure() async throws {
        let (session, server) = await session(Self.served([Self.change: PageServer.Answer(body: "", status: 502)]))
        try await signIn(session)
        let (pages, me) = try await ownPage(session)
        _ = try await opened(pages, session)
        pages.profile.draft?.name = "River Me"
        await pages.profile.save(in: session)?.value
        let said = try #require(pages.profile.said(in: session))
        #expect(said.state == .failed && said.canSave && said.draft?.name == "River Me")
        #expect(said.stateLine(language: .english) == "m.example did not answer, so whether it took the change is not known. What you typed is kept: Save sends it again.")
        #expect(pages.head(of: me, in: session).name == "Me" && session.mastodon.asking(host: Self.host) == 3)
        await server.answer(Self.change, PageServer.Answer(body: Self.own(name: "River Me", locked: true, asking: 3)))
        await pages.profile.save(in: session)?.value
        #expect(pages.profile.open == nil && pages.head(of: me, in: session).name == "River Me")
    }

    @Test("A sign-in that the source ended says so and keeps what was typed until the sheet is closed: Save is gone, and Cancel closes without asking")
    func theSignInEnded() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        _ = try await opened(pages, session)
        pages.profile.draft?.name = "River Me"
        await server.answer(Self.change, PageServer.Answer(body: #"{"error":"The access token was revoked"}"#, status: 401))
        await server.answer(Self.who, PageServer.Answer(body: #"{"error":"The access token was revoked"}"#, status: 401))
        await pages.profile.save(in: session)?.value
        let said = try #require(pages.profile.said(in: session))
        #expect(said.state == .ended && !said.offersSave && !said.canSave && !said.cancelAsks && said.draft?.name == "River Me")
        #expect(said.stateLine(language: .english) == "The sign-in at m.example has ended. What you typed is kept until you close this.")
        #expect(session.mastodon.ended.contains(Self.host), "the app's ending notice, as everywhere")
        pages.profile.putDown()
        #expect(pages.profile.open == nil)
    }

    @Test("A sheet whose reader became another account is put down at the next press and sends nothing")
    func becameAnother() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        _ = try await opened(pages, session)
        pages.profile.draft?.name = "River Me"
        await server.answer(Self.who, PageServer.Answer(body: #"{"id":"8","acct":"other","username":"other"}"#))
        try await signIn(session, as: "tok2")
        #expect(pages.profile.save(in: session) == nil)
        #expect(pages.profile.open == nil)
        #expect(await server.arrivals(of: Self.change) == 0)
    }

    // MARK: - What lands after the answer

    @Test("An ask of who the reader is that set out before the change and lands after its answer lands nowhere: the page goes on drawing the answer")
    func anOlderReadLandsNowhere() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let (pages, me) = try await ownPage(session)
        await server.hold(Self.lookup)
        let held = watching("the page's ask of who they are, held at its server") { await server.release(Self.lookup) }
        defer { held.cancel() }
        let before = await server.arrivals(of: Self.lookup)
        let asking = Task { await pages.again(me, in: session) }
        await server.arrival(of: Self.lookup, times: before + 1, by: asking)
        _ = try await opened(pages, session)
        pages.profile.draft?.name = "River Me"
        await pages.profile.save(in: session)?.value
        #expect(pages.head(of: me, in: session).name == "River Me")
        await server.release(Self.lookup)
        await asking.value
        #expect(pages.head(of: me, in: session).name == "River Me", "the older account is not drawn over the answer")
    }

    @Test("An account check that set out before a change's answer and lands after it leaves the answer's count of who asks to follow")
    func anOlderCheckKeepsTheAnsweredCount() async throws {
        let (session, server) = await session()
        try await signIn(session)
        #expect(session.mastodon.asking(host: Self.host) == 3)
        await server.hold(Self.who)
        let held = watching("the account check, held at its server") { await server.release(Self.who) }
        defer { held.cancel() }
        let before = await server.arrivals(of: Self.who)
        let checking = Task { await session.mastodon.learnWho(host: Self.host) }
        await server.arrival(of: Self.who, times: before + 1, by: checking)
        session.mastodon.askingAnswered(0, of: "8", host: Self.host)
        #expect(session.mastodon.asking(host: Self.host) == 3, "a figure about another account is not laid on this one")
        session.mastodon.askingAnswered(0, of: "7", host: Self.host)
        await server.release(Self.who)
        await checking.value
        #expect(session.mastodon.asking(host: Self.host) == 0)
        await session.mastodon.learnWho(host: Self.host)
        #expect(session.mastodon.asking(host: Self.host) == 3, "a check set out after says its own")
    }

    @Test("With Pinned in front, an answer has Pinned forget what it read and ask again, and Posts asks when it is next in front")
    func pinnedAsksAgain() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let (pages, me) = try await ownPage(session)
        var lamp: String?
        _ = pages.turn(me, to: .posts, lamp: &lamp, in: session)
        await pages.fronted(me, in: session)
        _ = pages.turn(me, to: .pinned, lamp: &lamp, in: session)
        await pages.fronted(me, in: session)
        #expect(await server.arrivals(of: Self.pinned) == 1)
        #expect(await server.arrivals(of: Self.statuses) == 1)
        _ = try await opened(pages, session)
        pages.profile.draft?.name = "River Me"
        await pages.profile.save(in: session)?.value
        #expect(await server.arrivals(of: Self.pinned) == 2, "Pinned, in front, asked again")
        #expect(await server.arrivals(of: Self.statuses) == 1, "Posts waits until it is in front")
        _ = pages.turn(me, to: .posts, lamp: &lamp, in: session)
        await pages.fronted(me, in: session)
        #expect(await server.arrivals(of: Self.statuses) == 2)
    }

    @Test("A change on the wire when the reader becomes another account lands for nobody: the sheet goes down, nothing is said to a listener, and the new account's own page and count of who asks to follow it are what its own source said")
    func anAnswerForAnotherAccountLandsNowhere() async throws {
        let other = #"{"id":"8","acct":"other","username":"other","display_name":"Other","locked":true,"source":{"note":"","fields":[],"follow_requests_count":5}}"#
        let (session, server) = await session(Self.served(["/api/v1/accounts/lookup?acct=other": PageServer.Answer(body: other)]))
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        var heard: [String] = []
        pages.profile.announce = { heard.append($0) }
        _ = try await opened(pages, session)
        pages.profile.draft?.name = "River Me"
        await server.hold(Self.change)
        let held = watching("the change, held at its server") { await server.release(Self.change) }
        defer { held.cancel() }
        let saving = try #require(pages.profile.save(in: session))
        await server.arrival(of: Self.change, by: saving)

        await server.answer(Self.who, PageServer.Answer(body: other))
        try await signIn(session, as: "tok2")
        let them = try #require(ShellPersonPages.own(at: Self.host, in: session))
        await pages.opened(them, in: session)
        #expect(pages.head(of: them, in: session).name == "Other" && session.mastodon.asking(host: Self.host) == 5)
        await server.release(Self.change)
        await saving.value

        #expect(pages.profile.open == nil && heard.isEmpty)
        #expect(pages.head(of: them, in: session).name == "Other", "the first account's answer is not drawn on theirs")
        #expect(session.mastodon.asking(host: Self.host) == 5, "nor counted for them")
    }

    // MARK: - The picture and the header

    private static let avatar = "/api/v1/profile/avatar"
    private static let header = "/api/v1/profile/header"

    /// The account check with a picture and a header held, as a real one draws them.
    private static func pictured(name: String = "Me", avatar: String = "https://m.example/system/a.png", header: String = "https://m.example/system/h.png") -> String {
        own(name: name).replacingOccurrences(of: #""locked":"#, with: #""avatar":"\#(avatar)","header":"\#(header)","locked":"#)
    }

    @Test("A picture chosen on the device goes with Save as one ask of several parts to the source's own change and nowhere else, as the file's own type and name; the sheet closes and the reader's page draws the picture the source answered with")
    func aChosenPictureIsSent() async throws {
        let (session, server) = await session(Self.served([
            Self.who: PageServer.Answer(body: Self.pictured()),
            Self.change: PageServer.Answer(body: Self.pictured(avatar: "https://m.example/system/new.png")),
        ]))
        try await signIn(session)
        let (pages, me) = try await ownPage(session)
        _ = try await opened(pages, session)
        let png = ProfileDraftTests.png()
        #expect(pages.profile.draft?.stage(.picture, data: png, type: .png, name: "me.png") == nil)
        #expect(pages.profile.said(in: session)?.canSave == true)
        let before = await server.asked.count
        await pages.profile.save(in: session)?.value

        let sent = try #require(await server.sent.last)
        #expect(sent.ask == Self.change && sent.method == "PATCH")
        #expect(sent.body.contains(#"name="avatar"; filename="me.png""#) && sent.body.contains("Content-Type: image/png"))
        #expect(!sent.body.contains("display_name"), "only what changed")
        let after = await server.asked.dropFirst(before).filter { $0 != Self.who && $0 != Self.lookup && !$0.hasPrefix(Self.statuses) }
        #expect(after == [Self.change], "one ask, to the change alone")
        #expect(pages.profile.open == nil)
        #expect(pages.head(of: me, in: session).face == URL(string: "https://m.example/system/new.png"), "the page draws the source's answer")
    }

    @Test("Remove sends the removal alone at Save, and nothing else is asked")
    func aRemovalIsSent() async throws {
        let (session, server) = await session(Self.served([
            Self.who: PageServer.Answer(body: Self.pictured()),
            Self.header: PageServer.Answer(body: Self.own()),
        ]))
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        _ = try await opened(pages, session)
        pages.profile.draft?.remove(.header)
        await pages.profile.save(in: session)?.value
        #expect(await server.arrivals(of: Self.header) == 1)
        #expect(await server.arrivals(of: Self.change) == 0)
        #expect(pages.profile.open == nil)
    }

    @Test("A change that lands while a removal fails: the page draws the answer, the sheet stays up on it with the removal still staged and says what was not taken off; Save sends the removal alone again")
    func savedInPart() async throws {
        let (session, server) = await session(Self.served([
            Self.who: PageServer.Answer(body: Self.pictured()),
            Self.change: PageServer.Answer(body: Self.pictured(name: "River Me")),
            Self.header: PageServer.Answer(body: "", status: 502),
        ]))
        try await signIn(session)
        let (pages, me) = try await ownPage(session)
        _ = try await opened(pages, session)
        pages.profile.draft?.name = "River Me"
        pages.profile.draft?.remove(.header)
        await pages.profile.save(in: session)?.value

        let said = try #require(pages.profile.said(in: session))
        #expect(said.state == .partly(failed: [.header]) && said.canSave && said.cancelAsks)
        #expect(said.stateLine(language: .english) == "m.example saved your profile but did not take off your header. Save asks it again.")
        #expect(said.draft?.name == "River Me" && said.draft?.stage(of: .header) == .removed)
        #expect(pages.head(of: me, in: session).name == "River Me", "the page took the answer")

        await server.answer(Self.header, PageServer.Answer(body: Self.pictured(name: "River Me")))
        await pages.profile.save(in: session)?.value
        #expect(await server.arrivals(of: Self.change) == 1, "the removal alone again")
        #expect(await server.arrivals(of: Self.header) == 2)
        #expect(pages.profile.open == nil)
    }

    @Test("A picture over the limit the host states is refused at the choice and never sent; a picture the source refuses at Save is said under its row in the source's words, the choice kept")
    func tooLargeAndRefused() async throws {
        let refused = PageServer.Answer(
            body: #"{"error":"Validation failed: Avatar must be less than 2 MB","details":{"avatar":[{"error":"ERR_INVALID","description":"must be less than 2 MB"}]}}"#,
            status: 422
        )
        let stating = #"{"configuration":{"media_attachments":{"image_size_limit":10}}}"#
        let (session, server) = await session(Self.served([Self.instance: PageServer.Answer(body: stating), Self.change: refused]))
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        _ = try await opened(pages, session)
        let png = ProfileDraftTests.png()
        #expect(pages.profile.draft?.stage(.picture, data: png, type: .png, name: "me.png") != nil)
        let said = try #require(pages.profile.said(in: session))
        #expect(said.pictureRefusal(of: .picture, language: .english)?.contains("m.example takes pictures up to 10 bytes") == true)
        #expect(!said.canSave && pages.profile.save(in: session) == nil)
        #expect(await server.arrivals(of: Self.change) == 0)

        let (other, wire) = await self.session(Self.served([Self.change: refused]))
        try await signIn(other)
        let (theirs, _) = try await ownPage(other)
        _ = try await opened(theirs, other)
        theirs.profile.draft?.stage(.picture, data: png, type: .png, name: "me.png")
        await theirs.profile.save(in: other)?.value
        let after = try #require(theirs.profile.said(in: other))
        #expect(after.refusal(of: .picture) == "must be less than 2 MB" && after.canSave)
        if case .chosen = after.draft?.stage(of: .picture) {} else { Issue.record("the choice is kept") }
        #expect(await wire.arrivals(of: Self.change) == 1)
    }

    @Test("Save waits while a picked file is read; a read that lands after Cancel, or in a later opening, changes nothing, and one that lands while a change is out is not laid on what is sent")
    func aLateReadLandsNowhere() async throws {
        let (session, server) = await session()
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        let profile = pages.profile
        let first = try await opened(pages, session).opening
        let png = ProfileDraftTests.png()
        profile.draft?.name = "River Me"
        profile.reading(.picture, opening: first)
        #expect(profile.said(in: session)?.canSave == false && profile.save(in: session) == nil, "Save waits for the read")
        profile.putDown()
        profile.picked(.picture, .read(png, type: .png, name: "me.png"), opening: first)
        #expect(profile.open == nil && profile.draft == nil, "after Cancel: no sheet, no draft")

        let second = try await opened(pages, session).opening
        #expect(second != first && profile.said(in: session)?.reading.isEmpty == true)
        profile.picked(.picture, .read(png, type: .png, name: "me.png"), opening: first)
        #expect(profile.draft?.stage(of: .picture) == .held(nil), "a read of an earlier opening is not this one's")

        profile.draft?.name = "River Me"
        await server.hold(Self.change)
        let held = watching("the change, held at its server") { await server.release(Self.change) }
        defer { held.cancel() }
        let saving = try #require(profile.save(in: session))
        await server.arrival(of: Self.change, by: saving)
        profile.reading(.picture, opening: second)
        profile.picked(.picture, .read(png, type: .png, name: "me.png"), opening: second)
        #expect(profile.draft?.stage(of: .picture) == .held(nil) && profile.said(in: session)?.reading.isEmpty == true, "nothing laid on what is out")
        await server.release(Self.change)
        await saving.value
        #expect(profile.open == nil)
        #expect(await !server.sent.contains { $0.body.contains("avatar") })
    }

    @Test("A change saved in part whose answer lands after the reader became another account lands for nobody: the sheet goes down and the new account's page is its own")
    func aPartlyAnswerForAnotherAccountLandsNowhere() async throws {
        let other = #"{"id":"8","acct":"other","username":"other","display_name":"Other","locked":true,"source":{"note":"","fields":[],"follow_requests_count":5}}"#
        let (session, server) = await session(Self.served([
            Self.who: PageServer.Answer(body: Self.pictured()),
            Self.change: PageServer.Answer(body: Self.pictured(name: "River Me")),
            Self.header: PageServer.Answer(body: "", status: 502),
            "/api/v1/accounts/lookup?acct=other": PageServer.Answer(body: other),
        ]))
        try await signIn(session)
        let (pages, _) = try await ownPage(session)
        var heard: [String] = []
        pages.profile.announce = { heard.append($0) }
        _ = try await opened(pages, session)
        pages.profile.draft?.name = "River Me"
        pages.profile.draft?.remove(.header)
        await server.hold(Self.header)
        let held = watching("the removal, held at its server") { await server.release(Self.header) }
        defer { held.cancel() }
        let saving = try #require(pages.profile.save(in: session))
        await server.arrival(of: Self.header, by: saving)

        await server.answer(Self.who, PageServer.Answer(body: other))
        try await signIn(session, as: "tok2")
        let them = try #require(ShellPersonPages.own(at: Self.host, in: session))
        await pages.opened(them, in: session)
        await server.release(Self.header)
        await saving.value

        #expect(pages.profile.open == nil && heard.isEmpty)
        #expect(pages.head(of: them, in: session).name == "Other", "the first account's answer is not drawn on theirs")
        #expect(session.mastodon.asking(host: Self.host) == 5)
    }

    @Test("Where the source has named neither reader, a sign-in replaced by another's while the sheet is up is not taken for the reader: Save sends nothing and the sheet goes down")
    func anUnnamedReaderIsTheSignInItself() async throws {
        let (session, server) = await session()
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: Self.all, asked: Self.all
        ))
        session.mastodon.refresh()
        let profile = ShellPersonPages().profile
        await profile.open(Self.host, in: session)?.value
        #expect(session.mastodon.reader(host: Self.host) == nil, "nobody named")
        profile.draft?.name = "River Me"
        #expect(profile.said(in: session)?.canSave == true)
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "theirs", clientID: "c", clientSecret: "s", scopes: Self.all, asked: Self.all
        ))
        session.mastodon.refresh()
        #expect(profile.save(in: session) == nil)
        #expect(profile.open == nil)
        #expect(await server.arrivals(of: Self.change) == 0)
    }
}
