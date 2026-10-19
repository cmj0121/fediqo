import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// F10, a hashtag: a page of its own in the frame every opened page stands in — Posts · About
/// where a signed-in source keeps hashtags followed, and one list with no strip, no mark and
/// no Follow for a forum's reader and for nobody signed in.
///
/// Every wait here is on a press the check holds the task of, or on nothing at all: a check
/// asks a value, or hosts a view and lays it out.
/// What a check heard announced.
@MainActor
private final class Heard {
    var words: [String] = []
}

@MainActor
@Suite("A hashtag's page", .watched)
struct TagPageTests {
    private static let host = "m.example"
    private static let other = "two.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let reads = "read:statuses read:lists read:accounts read:search"
    private static let follows = "\(reads) read:follows write:follows"
    private static let asked = "/api/v1/tags/swift"
    private static let follow = "/api/v1/tags/swift/follow"
    private static let unfollow = "/api/v1/tags/swift/unfollow"
    private static let swift = PostTag("#swift")!

    private static func answer(_ following: Bool) -> PageServer.Answer {
        PageServer.Answer(body: #"{"id":"2","name":"swift","url":"https://m.example/tags/swift","history":[],"following":\#(following),"featuring":false}"#)
    }

    private func session(_ routes: [String: PageServer.Answer], sources: [Source] = [source, forum]) async -> (ShellSession, PageServer) {
        let server = PageServer(routes)
        let session = ShellSession(
            http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server)
        )
        for source in sources { await session.store.add(source) }
        session.sources = await session.store.sources()
        return (session, server)
    }

    private func signIn(_ session: ShellSession, holding scopes: String = TagPageTests.follows) throws {
        try signOut(session)
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
    }

    private func signOut(_ session: ShellSession) throws {
        if let held = try session.mastodon.tokens.token(host: Self.host) { _ = try session.mastodon.tokens.forget(held) }
        session.mastodon.refresh()
    }

    private static func line(_ standing: TagFollowLine.Standing, at host: String = host) -> TagFollowLine {
        TagFollowLine(host: host, tag: swift, standing: standing)
    }

    private static func ui() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI")
    }

    // MARK: - Which tabs, and what the head says

    @Test("Signed in to a source that keeps hashtags followed the page has Posts · About with Posts in front, the figure of posts held a press that opens Posts, and a mark for the source that said it is followed there; About, brought in front, asks its source nothing more than the page did")
    func withASourceThatKeepsFollows() async throws {
        let (session, server) = await session([Self.asked: Self.answer(true)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        // Before the source has answered: the tabs are there, and nothing is guessed of it.
        let before = tags.said(of: Self.swift, held: 41, in: session)
        #expect(before.tabs == [.posts, .about] && before.front == .posts && before.stripped)
        #expect(before.followed.isEmpty && before.follow == nil, "no mark and no press over a read that is out")

        await tags.opened(Self.swift, in: session)
        let said = tags.said(of: Self.swift, held: 41, in: session)
        #expect(said.tabs == [.posts, .about] && said.front == .posts)
        #expect(said.figure == PageFigure(symbol: "text.bubble", figure: "41", spoken: L10n.count("person.held", 41), opens: true, lit: true))
        #expect(said.followed == [TagPageSaid.Followed(host: Self.host, spoken: String(format: L10n.t("tag.stands.followed"), Self.host))])
        #expect(said.follow == nil, "followed already: the head offers no Follow, and never an Unfollow")
        #expect(said.about?.follows == [Self.line(.said(true))])
        #expect(said.reach == nil, "which sources were asked is About's to say")

        // About in front: the page's one ask of the source stands, and nothing is added to it.
        var lamp: String? = "post-1"
        #expect(tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        #expect(tags.front(of: Self.swift, in: session) == .about && lamp == nil)
        let about = tags.said(of: Self.swift, held: 41, in: session)
        #expect(about.front == .about && about.figure.opens && !about.figure.lit, "the figure is lit only while its tab is in front")
        #expect(await server.asked == [Self.asked], "one ask, the page's own")
    }

    @Test("Where the source said it is not followed there is no mark — there is none for 'not followed' — and the head offers Follow, at that one source; a sign-in that holds less than follows has an About with its lock and neither mark nor Follow")
    func notFollowedAndSignedInForLess() async throws {
        let (session, server) = await session([Self.asked: Self.answer(false), Self.follow: Self.answer(true)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        let said = tags.said(of: Self.swift, held: 0, in: session)
        #expect(said.followed.isEmpty)
        let offered = try #require(said.follow)
        #expect(offered == Self.line(.said(false)) && offered.offers == .follow)
        // The head's press follows, as the row's own does: sent once, and the mark is then there.
        let sent = try #require(tags.pressed(offered, only: true, in: session))
        await sent.value
        #expect(await server.asked == [Self.asked, Self.follow])
        let after = tags.said(of: Self.swift, held: 0, in: session)
        #expect(after.followed.map(\.host) == [Self.host] && after.follow == nil)
        // **The head's Follow never unfollows**: a line gone stale under the finger sends nothing.
        #expect(tags.pressed(offered, only: true, in: session) != nil)
        await tags.pressed(offered, only: true, in: session)?.value
        #expect(await server.asked == [Self.asked, Self.follow], "followed by now: nothing more is sent")

        let (less, quiet) = await self.session([Self.asked: Self.answer(true)])
        try signIn(less, holding: Self.reads)
        let locked = ShellPersonPages().tags
        await locked.opened(Self.swift, in: less)
        let lockedSaid = locked.said(of: Self.swift, held: 3, in: less)
        #expect(lockedSaid.tabs == [.posts, .about] && lockedSaid.followed.isEmpty && lockedSaid.follow == nil)
        #expect(lockedSaid.about?.follows.first?.isLocked == true)
        #expect(await quiet.asked.isEmpty, "nothing is asked of a sign-in that does not hold follows")
    }

    @Test("For a forum's reader, and with nobody signed in, the page is one list: its posts alone, no strip, no mark, no Follow and no About — absent, and nobody is asked; its figure opens nothing, and which sources were asked is said in the page's line")
    func aForumOrSignedOut() async throws {
        let (session, server) = await session([Self.asked: Self.answer(true)])
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        let signedOut = tags.said(of: Self.swift, held: 41, in: session)
        let (forumOnly, unasked) = await self.session([:], sources: [Self.forum])
        let forum = ShellPersonPages().tags.said(of: Self.swift, held: 41, in: forumOnly)
        for (name, said) in [("signed out", signedOut), ("a forum", forum)] {
            #expect(said.tabs == [.posts] && said.front == .posts && !said.stripped, "\(name)")
            #expect(said.followed.isEmpty && said.follow == nil && said.about == nil, "\(name)")
            #expect(said.figure == PageFigure(symbol: "text.bubble", figure: "41", spoken: L10n.count("person.held", 41), opens: false), "\(name)")
            #expect(!said.figure.lit, "\(name): a figure that opens nothing is never lit")
        }
        #expect(await server.asked.isEmpty)
        #expect(await unasked.asked.isEmpty)
        // A tab the page has not is not turned to, by a press, the key or a swipe.
        var lamp: String? = "post-1"
        #expect(!tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        #expect(tags.rotate(Self.swift, by: 1, covered: false, lamp: &lamp, in: session), "the key is taken, and turns nothing")
        #expect(lamp == "post-1" && tags.front(of: Self.swift, in: session) == .posts)
        #expect(tags.walkedAbout(of: Self.swift, in: session) == nil && !tags.pressAbout(TagAboutSaid.reachID, of: Self.swift, in: session))
        // The sign-in ended while About was in front: the page is its posts again.
        try signIn(session)
        #expect(tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        try signOut(session)
        #expect(tags.said(of: Self.swift, held: 41, in: session).front == .posts)
        #expect(TagPageSaid.made(of: Self.swift, held: 41, reach: "Asked m.example.").reach == "Asked m.example.")
    }

    @Test("The head is worked out from what each source said and nothing else: a mark only for a source that said followed, Follow only where exactly one source offers it, the figure whole and of this device's own count; the page's line says which were asked once they have answered, failed or not — the asking and the failure are the toast's")
    func whatTheHeadSays() throws {
        let en = DummyLanguage.english
        let followed = Self.line(.said(true)), not = Self.line(.said(false), at: Self.other)
        let both = TagPageSaid.made(of: Self.swift, held: 1204, follows: [followed, not], language: en)
        #expect(both.followed == [TagPageSaid.Followed(host: Self.host, spoken: "Followed at m.example")])
        #expect(both.follow == not, "one source offers it")
        #expect(both.figure.figure == "1,204" && both.figure.spoken == L10n.count("person.held", 1204, language: en))
        let two = TagPageSaid.made(of: Self.swift, held: 1, follows: [Self.line(.said(false)), not], language: en)
        #expect(two.follow == nil && two.followed.isEmpty, "two offer it: which is About's to choose")
        #expect(two.figure.spoken == "1 post here")
        for standing in [TagFollowLine.Standing.asking, .doing(true), .doing(false), .unknown, .absent] {
            let said = TagPageSaid.made(of: Self.swift, held: 0, follows: [Self.line(standing)], language: en)
            #expect(said.followed.isEmpty && said.follow == nil, "\(standing)")
            #expect(said.tabs == [.posts, .about], "\(standing): the source has a line, so the page has an About")
        }
        #expect(TagPageSaid.made(of: Self.swift, held: 0, follows: [followed], language: .taiwanese).followed.first?.spoken == "已在 m.example 追蹤")

        // What this device holds is its own count: nought is said as nought, with the sentence
        // of a page with no posts — but not under an ask still out, which would read as an answer.
        let empty = TagPageSaid.made(of: Self.swift, held: 0, language: en)
        #expect(empty.figure.figure == "0" && empty.none == "Nothing under #swift has reached this device.")
        #expect(TagPageSaid.made(of: Self.swift, held: 0, asking: [Self.host], language: en).none == nil)
        #expect(TagPageSaid.made(of: Self.swift, held: 2, language: en).none == nil)

        // The page's line: which sources were asked, once the toast no longer names them.
        let reach = "Asked m.example."
        let asking = TagPageSaid.made(of: Self.swift, held: 0, asking: [Self.host], reach: reach, language: en)
        #expect(asking.reach == nil, "while they are asked, the toast names them")
        let landed = TagPageSaid.made(of: Self.swift, held: 0, reach: reach, language: en)
        #expect(landed.reach == reach)
        // With an About the reach is its last block, and the line says only how the ask stands.
        let withAbout = TagPageSaid.made(of: Self.swift, held: 0, reach: reach, follows: [followed], language: en)
        #expect(withAbout.reach == nil && withAbout.about == TagAboutSaid(follows: [followed], reach: reach))
        #expect(TagTab.posts.symbol == "text.bubble" && TagTab.about.symbol == "info.circle")

        // The mark is its glyph with the host as its word, and its sentence is what a pointer
        // and a listener are told; the figure is one value in two forms, which the frame draws.
        let mark = try #require(both.followed.first)
        #expect(mark.host == Self.host && mark.spoken == "Followed at m.example" && TagPageSaid.Followed.symbol == "checkmark.circle")
        let pressed = TagPageSaid.made(of: Self.swift, held: 41, follows: [followed], language: en).figure
        let still = TagPageSaid.made(of: Self.swift, held: 41, language: en).figure
        #expect(pressed == PageFigure(symbol: "text.bubble", figure: "41", spoken: "41 posts here", opens: true, lit: true))
        #expect(still == PageFigure(symbol: "text.bubble", figure: "41", spoken: "41 posts here", opens: false, lit: false))
        #expect(pressed.spoken == still.spoken, "the sentence is the same on a well and on none")
        // A post's key acts on the rows of Posts, and on none of About's blocks.
        #expect(TagTab.posts.listsPosts && !TagTab.about.listsPosts)
    }

    @Test("What a source failed at is said once, whichever tab is in front — under the head on Posts, by its source's own row on About — and aloud as it lands: a follow that did not arrive, by name; a source that could not say whether it is followed, with a press that says what it asks again and where; a source with no such hashtag says nothing")
    func aFailureIsSaidUnderTheHead() async throws {
        let en = DummyLanguage.english
        let down = PageServer.Answer(body: "<html>", status: 500)
        // A follow that did not arrive: pressed from the head, on Posts.
        let (session, server) = await session([Self.asked: Self.answer(false), Self.follow: down])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        let offered = try #require(tags.said(of: Self.swift, held: 3, in: session).follow)
        #expect(tags.said(of: Self.swift, held: 3, in: session).troubles.isEmpty)
        let heard = Heard()
        session.said.announce = { heard.words.append($0) }
        await tags.pressed(offered, only: true, in: session)?.value
        #expect(await server.asked == [Self.asked, Self.follow])
        let missed = TagPageSaid.Trouble(id: "missed:m.example", words: String(format: L10n.t("tag.follow.failed.follow"), "#swift", Self.host))
        #expect(heard.words == [missed.words] && session.said.lines.isEmpty, "said aloud once as it lands, and no line on the foot strip")
        let onPosts = tags.said(of: Self.swift, held: 3, in: session)
        #expect(onPosts.front == .posts && onPosts.troubles == [missed] && onPosts.follow?.offers == .follow, "said, and Follow is offered again")
        var lamp: String?
        #expect(tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        let onAbout = tags.said(of: Self.swift, held: 3, in: session)
        #expect(onAbout.troubles.isEmpty && onAbout.about?.follows.first?.missedWords() == missed.words, "on About its row says it, once")
        // `l` is the same press, and says the same.
        let (keyed, _) = await self.session([Self.asked: Self.answer(false), Self.follow: down])
        try signIn(keyed)
        let byKey = ShellPersonPages().tags
        await byKey.opened(Self.swift, in: keyed)
        await byKey.followByKey(Self.swift, in: keyed)?.value
        #expect(byKey.said(of: Self.swift, held: 0, in: keyed).troubles == [missed])

        // A source that could not be asked whether it is followed: said, with its Try again.
        let (failing, asks) = await self.session([Self.asked: down])
        try signIn(failing)
        let unknown = ShellPersonPages().tags
        await unknown.opened(Self.swift, in: failing)
        let trouble = try #require(unknown.said(of: Self.swift, held: 0, in: failing).troubles.first)
        #expect(trouble == TagPageSaid.Trouble(
            id: "unknown:m.example", words: Self.line(.unknown).words(), again: Self.line(.unknown), spoken: Self.line(.unknown).pressSpoken()
        ))
        #expect(trouble.again?.pressWords(language: en) == "Try again")
        var lit: String?
        #expect(unknown.turn(Self.swift, to: .about, lamp: &lit, in: failing))
        let aboutUnknown = unknown.said(of: Self.swift, held: 0, in: failing)
        #expect(aboutUnknown.troubles.isEmpty && aboutUnknown.about?.follows == [Self.line(.unknown)], "on About the row says it, with its own Try again")
        #expect(unknown.turn(Self.swift, to: .posts, lamp: &lit, in: failing))
        await asks.answer(Self.asked, Self.answer(true))
        await unknown.pressed(try #require(trouble.again), in: failing)?.value
        #expect(await asks.asked == [Self.asked, Self.asked])
        let after = unknown.said(of: Self.swift, held: 0, in: failing)
        #expect(after.troubles.isEmpty && after.followed.map(\.host) == [Self.host])

        // By value, in the sources' order; a source with no such hashtag has nothing to say.
        var late = Self.line(.said(true), at: Self.other)
        late.missed = false
        let said = TagPageSaid.made(of: Self.swift, held: 0, follows: [Self.line(.unknown), late, Self.line(.absent, at: "three.example")], language: en)
        #expect(said.troubles == [
            TagPageSaid.Trouble(
                id: "unknown:m.example", words: "At m.example: could not find out whether you follow it.", again: Self.line(.unknown),
                spoken: "Ask m.example again whether you follow #swift"
            ),
            TagPageSaid.Trouble(id: "missed:two.example", words: "Could not unfollow #swift at two.example."),
        ])
        // Each press that asks again says what it asks and where: two that failed are two names.
        let twice = TagPageSaid.troubles(of: [Self.line(.unknown), Self.line(.unknown, at: Self.other)], language: en).compactMap(\.spoken)
        #expect(twice == ["Ask m.example again whether you follow #swift", "Ask two.example again whether you follow #swift"])
        #expect(Self.line(.unknown).pressSpoken(language: .taiwanese) == "再問 m.example 一次你是否追蹤 #swift")
        // The bar's mark that asks the sources again says whom it asks, and for what.
        #expect(TagPane.reloadName(Self.swift, asking: [Self.host, Self.other], canReload: true, language: en) == "Ask m.example, two.example again for #swift")
        #expect(TagPane.reloadName(Self.swift, asking: [Self.host], canReload: true, language: .taiwanese) == "再向 m.example 詢問 #swift")
        #expect(TagPageSaid.made(of: Self.swift, held: 0, follows: [Self.line(.unknown), late], front: .about, language: en).troubles.isEmpty)
        #expect(TagPageSaid.troubles(of: [Self.line(.absent), Self.line(.asking), Self.line(.said(false)), Self.line(.doing(true))]).isEmpty)
    }

    // MARK: - About

    @Test("About's blocks are a row for each source and the sentence of which were asked, each one the lamp stops on; Return on a row makes its press — follow, ask again — and does nothing on words, on a row with no press, or on a followed row, whose Unfollow is only in its `…`")
    func aboutAndItsPresses() async throws {
        let (session, server) = await session([Self.asked: Self.answer(true), Self.unfollow: Self.answer(false), Self.follow: Self.answer(true)])
        try signIn(session)
        let tags = ShellPersonPages().tags
        await tags.opened(Self.swift, in: session)
        let row = TagAboutSaid.lamp(on: Self.line(.said(true)))
        let about = TagAboutSaid(follows: [Self.line(.said(true)), Self.line(.asking, at: Self.other)], reach: "Asked m.example.")
        #expect(about.walked == [row, "tag.about.follow:two.example", TagAboutSaid.reachID])
        #expect(about.press(on: row) == nil, "a followed row's Unfollow is in its `…`, which no key reaches")
        #expect(TagAboutSaid(follows: [Self.line(.said(false))]).press(on: row)?.offers == .follow)
        #expect(about.press(on: "tag.about.follow:two.example") == nil && about.press(on: TagAboutSaid.reachID) == nil)
        #expect(TagAboutSaid(follows: [Self.line(.unknown)]).walked == ["tag.about.follow:m.example"])

        // On Posts the lamp walks posts, and Return is not About's.
        #expect(tags.walkedAbout(of: Self.swift, in: session) == nil && !tags.pressAbout(row, of: Self.swift, in: session))
        var lamp: String?
        #expect(tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        // Under the row, the source's feature row (#318): a block of its own.
        #expect(tags.walkedAbout(of: Self.swift, in: session) == [row, "tag.about.feature:m.example"])
        #expect(!tags.pressAbout("tag.about.follow:two.example", of: Self.swift, in: session))
        // Return on the followed row does nothing; the item of its `…` unfollows, and the
        // source's word is the row's.
        #expect(!tags.pressAbout(row, of: Self.swift, in: session))
        let line = try #require(tags.about(of: Self.swift, in: session)?.follows.first)
        #expect(line.offers == .unfollow && line.pressWords() == nil)
        var sent: Task<Void, Never>?
        let item = try #require(line.more { sent = tags.unfollowed(line, in: session) }?.items.first)
        // Red, and it asks first: chosen, it puts its question and sends nothing.
        #expect(item.isDanger && item.question == ShellQuestion.unfollow(Self.swift, at: Self.host))
        var put: ShellMoreAsk?
        item.press { put = $0 }
        let ask = try #require(put)
        #expect(sent == nil)
        // No sends nothing; yes unfollows, once.
        ask.answered("not the yes")
        #expect(sent == nil)
        ask.answered(ShellQuestion.yes)
        await sent?.value
        #expect(await server.asked == [Self.asked, Self.unfollow])
        #expect(tags.lines(of: Self.swift, in: session) == [Self.line(.said(false))])
        // The same question, put while the line was followed and answered yes again now that it
        // is not: it only ever unfollows, so nothing is sent — never a follow.
        sent = nil
        ask.answered(ShellQuestion.yes)
        await sent?.value
        #expect(await server.asked == [Self.asked, Self.unfollow], "a stale Unfollow sends no follow")
        #expect(tags.lines(of: Self.swift, in: session) == [Self.line(.said(false))])
        #expect(tags.said(of: Self.swift, held: 0, in: session).followed.isEmpty, "and its mark is gone from the head")
        #expect(tags.pressAbout(row, of: Self.swift, in: session), "Return on the row is that press")
        #expect(await met("the follow Return sent has landed") { tags.lines(of: Self.swift, in: session) == [Self.line(.said(true))] })
        // A row with nothing to press, and a press that only raises a question, send nothing.
        #expect(tags.pressed(Self.line(.asking), in: session) == nil && tags.pressed(Self.line(.absent), in: session) == nil)
        let lock = Self.line(.locked(PartWords.Place(kind: .unasked, key: "part.ask.partly")))
        #expect(await server.asked == [Self.asked, Self.unfollow, Self.follow])
        let (less, quiet) = await self.session([:])
        try signIn(less, holding: Self.reads)
        #expect(lock.offers == .ask && less.partAsks.open == nil)
        #expect(ShellPersonPages().tags.pressed(lock, in: less) == nil)
        #expect(less.partAsks.open?.ticked == [.follows] && less.partAsks.open?.host == Self.host)
        #expect(await quiet.asked.isEmpty, "the question sends nothing")
    }

    // MARK: - The tab in front

    @Test("A hashtag's page still a step of the other stream place's walk keeps its tab when this side leaves it, or ends in one go; once neither side holds it, it is forgotten")
    func theTabStaysWhileEitherSideHoldsIt() async throws {
        let (session, _) = await session([Self.asked: Self.answer(true)])
        try signIn(session)
        let people = ShellPersonPages()
        let tags = people.tags
        var lamp: String?
        #expect(tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        var here = ShellWalk(), there = ShellWalk()
        _ = here.walk(to: .tag(Self.swift), from: "row")
        _ = there.walk(to: .tag(Self.swift), from: "rising-row")
        let left = here.back()
        people.left(try #require(left).step, of: here, besides: there)
        #expect(tags.front(of: Self.swift, in: session) == .about, "the other side still holds the page")
        people.leftAll(besides: there)
        #expect(tags.front(of: Self.swift, in: session) == .about, "ended in one go, the other side's page keeps its tab")
        people.left(try #require(left).step, of: here, besides: ShellWalk())
        #expect(tags.front(of: Self.swift, in: session) == .posts, "neither side holds it: forgotten")
        #expect(tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        people.leftAll(keeping: nil, besides: ShellWalk())
        #expect(tags.front(of: Self.swift, in: session) == .posts)
        #expect(tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        people.leftAll(keeping: Self.swift, besides: ShellWalk())
        #expect(tags.front(of: Self.swift, in: session) == .about, "the page left standing keeps it")
    }

    @Test("The tab in front is kept with the page, by the hashtag whatever case it was written in, each tab with its own lamp; Tab goes round the two; the walk leaving the page's last step forgets it, and a page opened afresh opens on Posts")
    func theTabInFrontIsKeptWithThePage() async throws {
        let (session, _) = await session([Self.asked: Self.answer(true)])
        try signIn(session)
        let people = ShellPersonPages()
        let tags = people.tags
        let shouted = try #require(PostTag("#SWIFT"))
        var lamp: String? = "post-7"
        #expect(tags.rotate(Self.swift, by: 1, covered: false, lamp: &lamp, in: session))
        #expect(tags.front(of: shouted, in: session) == .about && lamp == nil)
        lamp = "tag.about.follow:m.example"
        #expect(!tags.turn(Self.swift, to: .about, lamp: &lamp, in: session), "already in front")
        #expect(tags.rotate(shouted, by: 1, covered: false, lamp: &lamp, in: session), "round the ring")
        #expect(tags.front(of: Self.swift, in: session) == .posts && lamp == "post-7")
        #expect(tags.rotate(Self.swift, by: -1, covered: false, lamp: &lamp, in: session))
        #expect(tags.front(of: Self.swift, in: session) == .about && lamp == "tag.about.follow:m.example")

        // The timeline changed under the page (#197): About's lamp stays lit, a post the new
        // timeline no longer shows is put out, and the lamp Posts was left with goes the same way.
        let block = "tag.about.follow:m.example"
        #expect(FediqoRootView.lampOverSwitch(block, aboutInFront: true, held: ["post-1"]) == block)
        #expect(FediqoRootView.lampOverSwitch("post-7", aboutInFront: false, held: ["post-1"]) == nil)
        #expect(FediqoRootView.lampOverSwitch("post-7", aboutInFront: false, held: ["post-7"]) == "post-7")
        #expect(FediqoRootView.lampOverSwitch(nil, aboutInFront: false, held: ["post-7"]) == nil)
        tags.timelineSwitched(under: shouted, held: ["post-7", "post-8"])
        var kept = lamp
        #expect(tags.turn(Self.swift, to: .posts, lamp: &kept, in: session) && kept == "post-7", "still shown: kept")
        #expect(tags.turn(Self.swift, to: .about, lamp: &kept, in: session))
        tags.timelineSwitched(under: Self.swift, held: ["post-8"])
        #expect(tags.turn(Self.swift, to: .posts, lamp: &kept, in: session) && kept == nil, "no longer shown: no row is lit")
        #expect(tags.turn(Self.swift, to: .about, lamp: &kept, in: session))

        // Come back to, a hashtag's page takes only a lamp that is a row of the tab in front:
        // the same hashtag met twice in one walk is one page, on the tab it was left on.
        let tagStep = ShellStep.tag(Self.swift)
        #expect(FediqoRootView.lampBack("post-7", onto: tagStep, rows: [block]) == nil, "a post's id is not carried onto About")
        #expect(FediqoRootView.lampBack(block, onto: tagStep, rows: ["post-7"]) == nil, "nor a block's onto the posts")
        #expect(FediqoRootView.lampBack("post-7", onto: tagStep, rows: ["post-7"]) == "post-7")
        #expect(FediqoRootView.lampBack("post-7", onto: tagStep, rows: nil) == nil)
        #expect(FediqoRootView.lampBack("row-1", onto: .thread("post-7"), rows: nil) == "row-1" && FediqoRootView.lampBack("row-1", onto: nil, rows: []) == "row-1", "every other page takes the lamp the walk kept")

        // A tab is not a step: a conversation opened from the page and left comes back to it.
        var walk = ShellWalk()
        _ = walk.walk(to: .tag(Self.swift), from: "row-3")
        _ = walk.walk(to: .thread("post-7"), from: "post-7")
        _ = walk.walk(to: .tag(shouted), from: "post-9")
        #expect(walk.depth == 3 && walk.holdsTag(Self.swift))
        let inner = walk.back()
        people.left(try #require(inner).step, of: walk)
        #expect(tags.front(of: Self.swift, in: session) == .about, "its page is still a step of the walk")
        _ = walk.back()
        let last = walk.back()
        #expect(last?.step == .tag(Self.swift) && last?.lamp == "row-3" && walk.isEmpty, "one step back, to the row it was taken from")
        people.left(try #require(last).step, of: walk)
        #expect(tags.front(of: Self.swift, in: session) == .posts)
        #expect(tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        #expect(lamp == nil, "and its tabs' lamps went with it")
        // A walk ended with one hashtag's page left standing forgets every other hashtag's tab.
        let birds = try #require(PostTag("#birds"))
        #expect(tags.turn(birds, to: .about, lamp: &lamp, in: session))
        tags.leftAll(but: Self.swift)
        #expect(tags.front(of: Self.swift, in: session) == .about && tags.front(of: birds, in: session) == .posts)
        tags.leftAll()
        #expect(tags.front(of: Self.swift, in: session) == .posts)

        // The page loses About under the reader — the sign-in ended: the kept tab is forgotten
        // and the lamp goes out, so the page is its posts with no lamp on a block that is gone.
        #expect(TagTab.fallen(.about, among: [.posts], lamp: "tag.about.follow:m.example").map { $0.kept == nil && $0.lamp == nil } == true)
        #expect(TagTab.fallen(.about, among: [.posts, .about], lamp: "tag.about.follow:m.example") == nil, "still there: nothing changes")
        #expect(TagTab.fallen(nil, among: [.posts], lamp: "post-7") == nil, "Posts in front: its lamp is a post's, and stays")
        #expect(tags.turn(Self.swift, to: .about, lamp: &lamp, in: session))
        lamp = "tag.about.follow:m.example"
        tags.tabsChanged(Self.swift, lamp: &lamp, in: session)
        #expect(lamp == "tag.about.follow:m.example" && tags.front(of: Self.swift, in: session) == .about, "nothing lost: nothing changes")
        try signOut(session)
        tags.tabsChanged(Self.swift, lamp: &lamp, in: session)
        #expect(lamp == nil && tags.front(of: Self.swift, in: session) == .posts)
        try signIn(session)
        #expect(tags.front(of: Self.swift, in: session) == .posts, "and signed in again it opens on Posts, not where it was")
    }

    // MARK: - Where it stands

    private func laidOut(
        _ said: TagPageSaid, width: CGFloat, layout: ShellLayout, scheme: ColorScheme, size: DynamicTypeSize
    ) -> [OpenedPageProbe.Part: CGRect] {
        let probe = OpenedPageProbe()
        let pane = TagPane(
            said: said, items: [], catalogues: EmojiCatalogueStore(), posts: ForumPosts(http: FixtureHTTP([:])),
            selectedID: .constant(nil), decks: .constant(ShellDecks()), playback: ShellPlayback(),
            onPlayRow: { _ in }, onViewRow: { _ in }, onTurnRow: { _ in }, onOpenThread: { _ in }, jumpToTop: 0
        )
        let view = NSHostingView(
            rootView: pane.frame(width: width, height: 700)
                .environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size).environment(\.openedPageProbe, probe)
        )
        view.layoutSubtreeIfNeeded()
        return probe.frames
    }

    @Test("The page takes the pane's whole height through the frame, in both its forms: the bar at the top and as wide as the page, the strip only where the page has two tabs, the head between them and scrolling away at an accessibility text size — at 720, 390 and 320, at the largest text, in light and in dark")
    func thePageTakesTheWholeHeight() throws {
        let en = DummyLanguage.english
        let lines = [Self.line(.said(true)), Self.line(.said(false), at: Self.other)]
        let forms: [(String, TagPageSaid)] = [
            ("posts in front", TagPageSaid.made(of: Self.swift, held: 1_204_000, asking: [Self.host], follows: lines, language: en)),
            ("about in front", TagPageSaid.made(of: Self.swift, held: 41, reach: "Asked m.example.", follows: lines, front: .about, language: en)),
            ("a follow that could not be found out", TagPageSaid.made(of: Self.swift, held: 41, follows: [Self.line(.unknown)], language: en)),
            ("one list", TagPageSaid.made(of: Self.swift, held: 41, reach: "Asked m.example.", language: en)),
            ("one list, its reach", TagPageSaid.made(of: Self.swift, held: 0, reach: "Asked m.example. Not asked, as they keep no tags: forum.example.", language: en)),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width, size) in [
                (ShellLayout.wide, CGFloat(720), DynamicTypeSize.large), (.narrow, 390, .large), (.narrow, 320, .large),
                (.narrow, 320, .xxxLarge), (.narrow, 320, .accessibility5),
            ] {
                for (name, said) in forms {
                    let at = "\(name) at \(width), \(scheme), \(size)"
                    let parts = laidOut(said, width: width, layout: layout, scheme: scheme, size: size)
                    let bar = try #require(parts[.bar]), room = try #require(parts[.front])
                    #expect(bar.minX == 0 && bar.minY == 0 && bar.width == width, "\(at): \(bar)")
                    #expect(room.minX == 0 && room.width == width && room.maxY == 700 && room.height > 0, "\(at): \(room)")
                    let scrolls = PageFrame.headScrolls(at: size)
                    if said.stripped {
                        let strip = try #require(parts[.strip], "\(at): two tabs, a strip")
                        #expect(strip.minX == 0 && strip.width == width && room.minY >= strip.maxY, "\(at): \(strip), \(room)")
                        // The head stands between the bar and the strip, and at an accessibility size scrolls away.
                        #expect(scrolls ? strip.minY - bar.maxY <= 1.5 : strip.minY - bar.maxY > 20, "\(at): \(bar), \(strip)")
                    } else {
                        #expect(parts[.strip] == nil, "\(at): one list, no strip")
                        #expect(scrolls ? room.minY - bar.maxY <= 1.5 : room.minY - bar.maxY > 20, "\(at): \(bar), \(room)")
                    }
                }
            }
        }
    }

    @Test("With a hashtag in front the timelines' head is not drawn and the sideways swipe is the page's own: with two tabs it goes to the tab beside and on the first leaves, and with its posts alone it leaves; its bar asks again where a source of the timeline keeps tags")
    func theTimelinesHeadIsNotDrawn() throws {
        let step = ShellStep.tag(Self.swift)
        #expect(!TimelinePane.headDrawn(over: step) && TimelinePane.drawn(step, of: nil, in: ShellSession(http: FixtureHTTP([:]), store: ItemStore())).drawn, "a hashtag's page can always be drawn")
        #expect(TimelinePane.page(step) == .tabbed)
        #expect(TimelineSwipe.means(touch: true, page: TimelinePane.page(step), searching: false, listShown: false, editing: false) == nil, "the timeline's swipe is not heard on it")
        let lines = [Self.line(.said(true))]
        let two = TagPageSaid.made(of: Self.swift, held: 0, follows: lines), one = TagPageSaid.made(of: Self.swift, held: 0)
        for said in [two, one] {
            #expect(TimelineSwipe.means(touch: true, detail: false, tabs: said.tabs.count, leaves: true) == .beside)
            #expect(TimelineSwipe.tabStep(from: said.tabs.firstIndex(of: .posts), count: said.tabs.count, step: -1, leaves: true) == .leave)
        }
        #expect(TimelineSwipe.tabStep(from: 0, count: two.tabs.count, step: 1, leaves: true) == .tab(1))
        #expect(TimelineSwipe.tabStep(from: 1, count: two.tabs.count, step: -1, leaves: true) == .tab(0), "from About the swipe goes to Posts, and only then leaves")
        #expect(TimelineSwipe.tabStep(from: 1, count: two.tabs.count, step: 1, leaves: true) == nil)
        #expect(TimelineSwipe.tabStep(from: 0, count: one.tabs.count, step: 1, leaves: true) == nil)
        // `r`, the bar's mark and a pull ask its sources again (decision 11) — where the timeline
        // in front has one that keeps tags, and on Trends as on the timeline.
        for place in [ShellPlace.timeline, .trends] {
            #expect(FediqoRootView.canReload(place: place, editing: false, hasSources: true, open: [.tag, .selection], tagAsked: true))
            #expect(!FediqoRootView.canReload(place: place, editing: false, hasSources: true, open: [.tag, .selection]), "nobody keeps tags: no mark")
        }
        #expect(!FediqoRootView.canReload(place: .timeline, editing: true, hasSources: true, open: [.tag], tagAsked: true))

        let ui = try Self.ui()
        // The page keeps no bar of its own, and the files that draw it learn no kind of source.
        let page = try String(contentsOf: ui.appending(path: "Shell/TagPane.swift"), encoding: .utf8)
        #expect(!page.contains("ShellBackButton") && !page.contains("ShellKeyHint"))
        for file in ["TagPane.swift", "TagHead.swift", "TagAbout.swift"] {
            let text = try String(contentsOf: ui.appending(path: "Shell/\(file)"), encoding: .utf8)
            #expect(DrawsNotKnowingKindTests.draws(text) && DrawsNotKnowingKindTests.kindsNamed(in: text).isEmpty, "\(file) names a kind of source")
        }
        let decided = try String(contentsOf: ui.appending(path: "Shell/TagTab.swift"), encoding: .utf8)
        #expect(!DrawsNotKnowingKindTests.draws(decided), "which tabs a page has is decided by a file that draws nothing")
    }

    @Test("Tab on a hashtag's page is the page's own while the page is what is in front — its two tabs, or taken and turning nothing where it has one — and nothing while something covers it; it changes neither the timeline nor the walk")
    func tabIsThePagesOwn() async throws {
        var walk = ShellWalk()
        _ = walk.walk(to: .thread("post-9"), from: "row-7")
        _ = walk.walk(to: .tag(Self.swift), from: "post-9")
        #expect(walk.tabKey == .tag(Self.swift))
        let before = walk
        #expect(FediqoRootView.pageInFront(.tag, open: [.tag, .selection]) && FediqoRootView.pageInFront(.tag, open: [.tag, .search]))
        for covered in [[DummyLayer.viewer, .tag], [.shortcuts, .tag]] as [Set<DummyLayer>] {
            #expect(!FediqoRootView.pageInFront(.tag, open: covered), "\(covered)")
        }
        // What the key does is decided once, from the page's tabs, the one in front and whether it is covered.
        let two: [TagTab] = [.posts, .about], one: [TagTab] = [.posts]
        #expect(TagTab.keyed(two, front: .posts, by: 1, covered: false) == .turn(.about))
        #expect(TagTab.keyed(two, front: .about, by: 1, covered: false) == .turn(.posts), "round the ring")
        #expect(TagTab.keyed(two, front: .posts, by: -1, covered: false) == .turn(.about))
        #expect(TagTab.keyed(one, front: .posts, by: 1, covered: false) == .taken && TagTab.keyed(one, front: .posts, by: -1, covered: false) == .taken)
        #expect(TagTab.keyed(two, front: .posts, by: 1, covered: true) == .unheard && TagTab.keyed(one, front: .posts, by: 1, covered: true) == .unheard)
        // And the pages answer the root by it: taken with one tab and nothing turned, turned with two, not heard when covered.
        let (session, _) = await session([Self.asked: Self.answer(true)])
        let tags = ShellPersonPages().tags
        var lamp: String? = "post-1"
        #expect(tags.rotate(Self.swift, by: 1, covered: false, lamp: &lamp, in: session) && lamp == "post-1", "one tab: taken, nothing to turn")
        #expect(tags.front(of: Self.swift, in: session) == .posts)
        try signIn(session)
        #expect(!tags.rotate(Self.swift, by: 1, covered: true, lamp: &lamp, in: session) && tags.front(of: Self.swift, in: session) == .posts)
        #expect(lamp == "post-1", "covered: the lamp is where it was")
        #expect(tags.rotate(Self.swift, by: 1, covered: false, lamp: &lamp, in: session) && tags.front(of: Self.swift, in: session) == .about)
        #expect(walk == before && walk.depth == 2)
        let left = walk.back()
        #expect(left?.step == .tag(Self.swift) && left?.lamp == "post-9" && walk.depth == 1)
    }

    @Test("The page's own words are in the three tables, and the two Chinese tables say the same bytes")
    func theTables() throws {
        func ours(_ language: String) throws -> [String] {
            let table = try String(contentsOf: Self.ui().appending(path: "Resources/\(language).lproj/Localizable.strings"), encoding: .utf8)
            return table.components(separatedBy: "\n").filter { $0.hasPrefix("\"tag.tab.") || $0.hasPrefix("\"tag.stands.") }
        }
        let english = try ours("en"), taiwanese = try ours("zh-TW"), hant = try ours("zh-Hant")
        #expect(english == ["\"tag.tab.posts\" = \"Posts\";", "\"tag.tab.about\" = \"About\";", "\"tag.stands.followed\" = \"Followed at %@\";"])
        #expect(taiwanese == ["\"tag.tab.posts\" = \"貼文\";", "\"tag.tab.about\" = \"關於\";", "\"tag.stands.followed\" = \"已在 %@ 追蹤\";"])
        #expect(taiwanese == hant)
        func spoken(_ language: String) throws -> [String] {
            let table = try String(contentsOf: Self.ui().appending(path: "Resources/\(language).lproj/Localizable.strings"), encoding: .utf8)
            return table.components(separatedBy: "\n").filter { $0.hasPrefix("\"tag.retry.spoken\"") || $0.hasPrefix("\"tag.again.spoken\"") }
        }
        #expect(try spoken("en").count == 2 && spoken("zh-TW").count == 2)
        #expect(try spoken("zh-TW") == spoken("zh-Hant"))
        for tab in TagTab.allCases {
            #expect(L10n.t(tab.titleKey, language: .english) != tab.titleKey && L10n.t(tab.titleKey, language: .taiwanese) != tab.titleKey)
        }
    }
}
