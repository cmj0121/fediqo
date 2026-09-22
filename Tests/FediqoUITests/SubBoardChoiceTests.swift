import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #161, as the shell drives it: a forum whose front page names a board and none of the boards
/// under it, and whose board page names them instead.
///
/// The markup is `install-g.example`'s shape, trimmed and renamed — see `DiscuzSubBoardTests`,
/// which pins the parsing. What is pinned here is **when** that page is read and what the reader
/// is left holding: a tick reads it, a reload reads it anyway, and a restate reads the pages of
/// the boards the reader already reads — and nothing reads a board the reader has not chosen.
@MainActor
@Suite("Choosing sub-boards", .serialized)
struct SubBoardChoiceTests {
    static let host = "install-g.example"

    init() {
        L10n.language = .english
    }

    /// The front page: one section, board 38 and board 40, and not a word about 434.
    static let index = #"""
    <html><head><meta name="generator" content="Discuz! X3.2" /></head><body>
    <h2><a href="forum.php?gid=1">Section</a></h2>
    <div id="category_1"><table class="fl_tb">
    <tr><td><h2><a href="forum.php?mod=forumdisplay&fid=38">Parent</a></h2></td>
    <td class="fl_i"><span class="xi2">16081</span><span class="xg1"> / 90000</span></td></tr>
    <tr><td><h2><a href="forum.php?mod=forumdisplay&fid=40">Neighbour</a></h2></td>
    <td class="fl_i"><span class="xi2">12</span><span class="xg1"> / 30</span></td></tr>
    </table></div></body></html>
    """#

    /// A board's page: its trail, its sub-board block where it has one, and one thread.
    static func boardPage(_ fid: Int, parent: Int? = nil, children: Bool = false) -> String {
        let trail = [
            #"<a href="forum.php?gid=1">Section</a>"#,
            parent.map { #"<a href="forum.php?mod=forumdisplay&amp;fid=\#($0)">Parent</a>"# },
            #"<a href="forum.php?mod=forumdisplay&amp;fid=\#(fid)">Board</a>"#,
        ].compactMap { $0 }.joined(separator: "<em>›</em>")
        let block = children ? #"""
            <div id="subforum_\#(fid)" class="bm_c"><table class="fl_tb"><tbody>
            <tr><td><h2><a href="forum.php?mod=forumdisplay&amp;fid=434">Child</a></h2></td>
            <td class="fl_i"><span class="xi2"><span title="15595">1萬</span></span><span class="xg1"> / <span title="48036">4萬</span></span></td>
            <td class="fl_by"><div><a href="forum.php?mod=redirect&amp;tid=1&amp;goto=lastpost" class="xi2">t</a> <cite><span title="2026-9-22 13:18">now</span></cite></div></td></tr>
            <tr class="fl_row"><td><h2><a href="forum.php?mod=forumdisplay&amp;fid=805" target="_blank">Elsewhere</a></h2></td>
            <td class="fl_i"> </td>
            <td class="fl_by"><div><a href="forum.php?mod=forumdisplay&amp;fid=805" class="xi2">link</a></div></td></tr>
            </tbody></table></div>
            """# : ""
        return #"""
        <div id="pt" class="bm cl"><div class="z">\#(trail)</div></div>
        <h1 class="xs2"><a href="forum.php?mod=forumdisplay&amp;fid=\#(fid)">Board \#(fid)</a></h1>
        \#(block)
        <table><tbody id="normalthread_9\#(fid)"><tr>
        <th class="common"><a href="forum.php?mod=viewthread&tid=9\#(fid)" class="s xst">thread</a></th>
        <td class="by"><cite><a href="home.php?mod=space&uid=8">someone</a></cite><em>2026-9-15 13:12</em></td>
        </tr></tbody></table>
        """#
    }

    static func look(_ fid: Int) -> String {
        "https://\(host)/forum.php?mod=forumdisplay&fid=\(fid)"
    }

    static func read(_ fid: Int) -> String {
        "https://\(host)/forum.php?mod=forumdisplay&fid=\(fid)&filter=author&orderby=dateline"
    }

    static var routes: [String: FixtureHTTP.Outcome] {
        [
            "/": .text(#"<html><head><meta name="generator" content="Discuz! X3.2" /></head></html>"#),
            "https://\(host)/forum.php": .text(index),
            look(38): .text(boardPage(38, children: true)),
            look(40): .text(boardPage(40)),
            look(434): .text(boardPage(434, parent: 38)),
            read(38): .text(boardPage(38, children: true)),
            read(40): .text(boardPage(40)),
            read(434): .text(boardPage(434, parent: 38)),
        ]
    }

    private static func offer(_ session: ShellSession) -> JoinOffer? {
        guard case .choosingBoards(let offer, _) = session.stage else { return nil }
        return offer
    }

    @Test("Ticking a board reads its page once, and draws its sub-boards under it, unticked")
    func tickingABoardDrawsItsSubBoards() async throws {
        let http = FixtureHTTP(Self.routes)
        let session = ShellSession(http: http, store: ItemStore())
        session.hostname = Self.host
        await session.add()
        await session.confirm()
        #expect(Self.offer(session)?.boards.map(\.fid) == [38, 40], "the premise: 434 is not on the front page")
        // Opening the picker read no board's page.
        #expect(await !http.requested.contains { $0.absoluteString.contains("forumdisplay") })

        session.tick([38])
        await session.looking?.value

        let offer = try #require(Self.offer(session))
        // Under its parent, and the link-only board not at all.
        #expect(offer.boards.map(\.fid) == [38, 434, 40])
        #expect(offer.boards.map(\.depth) == [0, 1, 0])
        // Its figures, as the parent's page stated them.
        #expect(offer.boards.first { $0.fid == 434 }?.threads == 15595)
        // Picking the parent did not pick the child.
        #expect(session.stage?.ticked == [38])

        // Unticked and ticked again: the page is not read a second time.
        session.tick([])
        session.tick([38])
        await session.looking?.value
        let looks = await http.requested.filter { $0.absoluteString == Self.look(38) }
        #expect(looks.count == 1)
        #expect(Self.offer(session)?.boards.map(\.fid) == [38, 434, 40])
    }

    @Test("A picked sub-board reads its own threads, and its parent's timeline does not grow them")
    func aPickedSubBoardReadsItsOwnThreads() async throws {
        let http = FixtureHTTP(Self.routes)
        let session = ShellSession(http: http, store: ItemStore())
        session.hostname = Self.host
        await session.add()
        await session.confirm()
        session.tick([38])
        await session.looking?.value
        session.tick([38, 434])
        await session.looking?.value

        let offer = try #require(Self.offer(session))
        await session.subscribe(offer.boards.filter { [38, 434].contains($0.fid) })

        #expect(session.sources.first?.boards.map(\.fid) == [38, 434])
        let byBoard = Dictionary(grouping: session.notes, by: \.categories)
        #expect(byBoard[[.board(id: "434")]]?.map(\.id) == ["discuz:\(Self.host):9434"])
        #expect(byBoard[[.board(id: "38")]]?.map(\.id) == ["discuz:\(Self.host):938"])
        // A sub-board is not a board under a board: ticking it read nothing more.
        #expect(await !http.requested.contains { $0.absoluteString == Self.look(434) })
    }

    @Test("A reload learns a subscribed board's sub-boards, and a restate offers them ticked")
    func aReloadLearnsAndARestateKeeps() async throws {
        // A reader who picked the sub-board and not its parent, and one who picked the parent:
        // both read on a reload, neither asks for a page the reload was not reading anyway.
        let http = FixtureHTTP(Self.routes)
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .discuz, boards: [
            BoardSubscription(fid: 434, name: "Child"),
            BoardSubscription(fid: 40, name: "Neighbour"),
        ]))
        let session = ShellSession(http: http, store: store)
        await session.reloadFromStore()
        await session.reload.timeline(.all, in: session)
        #expect(await !http.requested.contains { $0.absoluteString == Self.look(38) })

        await session.changeBoards(host: Self.host)
        guard case .choosingBoards(let offer, let origin) = session.stage else {
            Issue.record("the boards control did not open the picker")
            return
        }
        // Filed under its parent by its own page's trail — and still ticked, so the next press
        // does not drop a board the reader never touched.
        #expect(offer.boards.map(\.fid) == [38, 434, 40])
        #expect(origin.ticked == [434, 40])
    }

    /// A session reading `boards`, joined weeks ago, with **no refresh yet** this run.
    private static func unrefreshed(
        _ boards: [BoardSubscription], routes: [String: FixtureHTTP.Outcome] = routes
    ) async -> (ShellSession, FixtureHTTP) {
        let http = FixtureHTTP(routes)
        let store = ItemStore()
        await store.add(Source(host: host, kind: .discuz, boards: boards))
        let session = ShellSession(http: http, store: store)
        await session.reloadFromStore()
        return (session, http)
    }

    @Test("A sub-board read alone, before any refresh, is listed under its parent, ticked, and kept")
    func aSubBoardAloneBeforeARefreshIsKept() async throws {
        let (session, http) = await Self.unrefreshed([BoardSubscription(fid: 434, name: "Child")])

        await session.changeBoards(host: Self.host)
        await session.looking?.value

        guard case .choosingBoards(let offer, let origin) = session.stage else {
            Issue.record("the boards control did not open the picker")
            return
        }
        // Its own page's trail filed it under 38; the parent's page was not read.
        #expect(offer.boards.map(\.fid) == [38, 434, 40])
        #expect(offer.boards.first { $0.fid == 434 }?.parent == 38)
        #expect(origin.ticked == [434])
        #expect(await !http.requested.contains { $0.absoluteString == Self.look(38) })

        // A new board ticked and pressed: the one the reader already read stays.
        await session.subscribe(offer.boards.filter { [434, 40].contains($0.fid) })
        #expect(Set(session.sources.first?.boards.map(\.fid) ?? []) == [434, 40])
    }

    @Test("A subscribed board whose page cannot be read is still listed, ticked, and kept")
    func aSubscribedBoardWhosePageFailsIsKept() async throws {
        var routes = Self.routes
        routes[Self.look(434)] = .fail
        let (session, _) = await Self.unrefreshed(
            [BoardSubscription(fid: 434, name: "Child")], routes: routes
        )

        await session.changeBoards(host: Self.host)
        await session.looking?.value

        guard case .choosingBoards(let offer, let origin) = session.stage else {
            Issue.record("the boards control did not open the picker")
            return
        }
        // At the top level, under the name it was subscribed by — not left out.
        let kept = try #require(offer.boards.first { $0.fid == 434 })
        #expect(kept.name == "Child")
        #expect(kept.parent == nil)
        #expect(kept.gid == JoinOffer.keptSection)
        #expect(origin.ticked == [434])
        #expect(session.rowRefusal == nil)

        await session.subscribe(offer.boards.filter { [434, 40].contains($0.fid) })
        #expect(Set(session.sources.first?.boards.map(\.fid) ?? []) == [434, 40])
    }

    @Test("A subscribed parent shows its sub-boards when the picker opens, with no tick")
    func aSubscribedParentShowsItsSubBoardsOnOpen() async throws {
        let (session, _) = await Self.unrefreshed([BoardSubscription(fid: 38, name: "Parent")])

        await session.changeBoards(host: Self.host)
        await session.looking?.value

        guard case .choosingBoards(let offer, let origin) = session.stage else {
            Issue.record("the boards control did not open the picker")
            return
        }
        #expect(offer.boards.map(\.fid) == [38, 434, 40])
        #expect(offer.boards.first { $0.fid == 434 }?.threads == 15595)
        // Listed, not picked.
        #expect(origin.ticked == [38])
    }

    @Test("A look that fails leaves the picker as it was, and a second tick asks again")
    func aFailedLookIsQuiet() async throws {
        var routes = Self.routes
        routes[Self.look(38)] = .fail
        let http = FixtureHTTP(routes)
        let session = ShellSession(http: http, store: ItemStore())
        session.hostname = Self.host
        await session.add()
        await session.confirm()

        session.tick([38])
        await session.looking?.value
        #expect(Self.offer(session)?.boards.map(\.fid) == [38, 40])
        #expect(session.stage?.ticked == [38])
        #expect(session.refuse == nil)

        session.tick([])
        session.tick([38])
        await session.looking?.value
        let looks = await http.requested.filter { $0.absoluteString == Self.look(38) }
        #expect(looks.count == 2)
    }
}
