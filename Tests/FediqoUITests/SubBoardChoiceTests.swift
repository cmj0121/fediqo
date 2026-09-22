import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #161, as the shell drives it: a forum whose front page names a board and none of the boards
/// under it, and whose board page names them instead.
///
/// The markup is `install-g.example`'s shape, trimmed and renamed — see `DiscuzSubBoardTests`,
/// which pins the parsing. What is pinned here is **when** that page is read and what the reader
/// is left holding: a tick reads it, a reload reads it anyway, and nothing else does.
@MainActor
@Suite("Choosing sub-boards", .serialized)
struct SubBoardChoiceTests {
    private static let host = "install-g.example"

    init() {
        L10n.language = .english
    }

    /// The front page: one section, board 38 and board 40, and not a word about 434.
    private static let index = #"""
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
    private static func boardPage(_ fid: Int, parent: Int? = nil, children: Bool = false) -> String {
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

    private static func look(_ fid: Int) -> String {
        "https://\(host)/forum.php?mod=forumdisplay&fid=\(fid)"
    }

    private static func read(_ fid: Int) -> String {
        "https://\(host)/forum.php?mod=forumdisplay&fid=\(fid)&filter=author&orderby=dateline"
    }

    private static var routes: [String: FixtureHTTP.Outcome] {
        [
            "/": .text(#"<html><head><meta name="generator" content="Discuz! X3.2" /></head></html>"#),
            "https://\(host)/forum.php": .text(index),
            look(38): .text(boardPage(38, children: true)),
            look(40): .text(boardPage(40)),
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
