import Foundation
import Testing
@testable import FediqoCore

/// #161: a board's sub-boards, where the forum writes them only on the board's own page.
///
/// **The shape is `install-g.example`'s, trimmed and with every name replaced.** Its front page
/// names a parent and none of its children; the parent's own page writes them in a
/// `<div id="subforum_N">` block above the thread list, one `fl_tb` row each — a real board with
/// its figures, and a board that is only a link elsewhere, with none. Nothing below was copied
/// from the forum: the names, the descriptions, the people and the thread are placeholders, and
/// only the markup's structure is the forum's.
@Suite("Sub-boards on a board's own page")
struct DiscuzSubBoardTests {
    private static let host = "install-g.example"
    private static let source = Source(host: host, kind: .discuz)

    /// The parent's page: its trail, its heading, the sub-board block, and one thread.
    ///
    /// Subject of the tests below rather than scenery for them — each is about a different
    /// property of this one shape.
    private static let parentPage = #"""
    <html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"></head><body>
    <div id="pt" class="bm cl">
    <div class="z">
    <a href="https://install-g.example/" class="nvhm" title="首頁">論壇</a><em>»</em><a href="https://install-g.example/forum.php">首頁</a> <em>›</em> <a href="https://install-g.example/forum.php?gid=1">分類甲</a><em>›</em> <a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=38">版塊甲</a></div>
    </div>
    <h1 class="xs2"><a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=38">版塊甲</a></h1>
    <div class="bm bmw fl">
    <div class="bm_h cl">
    <span class="o"><img id="subforum_38_img" src="collapsed_no.gif" title="收起/展開" alt="收起/展開" onclick="toggle_collapse('subforum_38');"></span>
    <h2>子版塊</h2>
    </div>
    <div id="subforum_38" class="bm_c" style="">
    <table cellspacing="0" cellpadding="0" class="fl_tb">
    <tbody><tr><td class="fl_icn" style="width: 103px;">
    <a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=434"><img src="icon_434.jpg" align="left" alt=""></a></td>
    <td>
    <h2><a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=434" style="color: #993300;">版塊乙</a><em class="xw0 xi1" title="今日"> (2)</em></h2>
    <p class="xg2">一段說明</p><p>版主: <a href="https://install-g.example/home.php?mod=space&amp;username=someone" class="notabs">someone</a></p></td>
    <td class="fl_i">
    <span class="xi2"><span title="15595">1萬</span></span><span class="xg1"> / <span title="48036">4萬</span></span></td>
    <td class="fl_by">
    <div>
    <a href="https://install-g.example/forum.php?mod=redirect&amp;tid=900&amp;goto=lastpost#lastpost" class="xi2">一個主題 ...</a> <cite><span title="2026-9-22 13:18">3&nbsp;分鐘前</span> <a href="https://install-g.example/home.php?mod=space&amp;username=someone">someone</a></cite>
    </div>
    </td>
    </tr>
    <tr class="fl_row">
    <td class="fl_icn" style="width: 103px;">
    <a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=805"><img src="icon_805.jpg" align="left" alt=""></a></td>
    <td>
    <h2><a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=805" target="_blank" style="color: #993300;">版塊丙</a></h2>
    <p class="xg2">另一段說明</p></td>
    <td class="fl_i">
    </td>
    <td class="fl_by">
    <div>
    <a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=805" class="xi2">鏈接到外部地址</a>
    </div>
    </td>
    </tr>
    <tr class="fl_row">
    </tr>
    </tbody></table>
    </div>
    </div>
    <table><tbody id="normalthread_900"><tr><th><a href="#" class="xst">一個主題</a></th>
    <td class="by"><cite>someone</cite><em>2026-9-22</em></td>
    <td class="num"><a href="#">3</a></td></tr></tbody></table>
    </body></html>
    """#

    /// The same block, in GBK — assembled a byte at a time for `DiscuzTests.gbkIndexPage`'s
    /// reason: bytes the decoder did not produce itself. Simplified names, because a GBK
    /// install is a Simplified one; the structure is the one above.
    private static func gbkParentPage() -> Data {
        var page = Data()
        func ascii(_ text: String) { page.append(contentsOf: Array(text.utf8)) }
        ascii(#"""
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=gbk" /></head><body>
        <div id="subforum_38" class="bm_c"><table cellspacing="0" cellpadding="0" class="fl_tb"><tbody>
        <tr><td class="fl_icn"><a href="forum.php?mod=forumdisplay&amp;fid=434"><img src="i.jpg" /></a></td>
        <td><h2><a href="forum.php?mod=forumdisplay&amp;fid=434">
        """#)
        page.append(contentsOf: [0xB0, 0xE6, 0xBF, 0xE9, 0xD2, 0xD2])  // 版块乙
        ascii(#"""
        </a></h2></td>
        <td class="fl_i"><span class="xi2"><span title="15595">1</span></span><span class="xg1"> / <span title="48036">4</span></span></td>
        <td class="fl_by"><div><a href="forum.php?mod=redirect&amp;tid=900&amp;goto=lastpost" class="xi2">t</a> <cite><span title="2026-9-22 13:18">x</span></cite></div></td></tr>
        <tr class="fl_row"><td class="fl_icn"><a href="forum.php?mod=forumdisplay&amp;fid=805"><img src="i.jpg" /></a></td>
        <td><h2><a href="forum.php?mod=forumdisplay&amp;fid=805" target="_blank">
        """#)
        page.append(contentsOf: [0xB0, 0xE6, 0xBF, 0xE9, 0xB1, 0xFB])  // 版块丙
        ascii(#"""
        </a></h2></td><td class="fl_i"> </td>
        <td class="fl_by"><div><a href="forum.php?mod=forumdisplay&amp;fid=805" class="xi2">
        """#)
        // 链接到外部地址
        page.append(contentsOf: [
            0xC1, 0xB4, 0xBD, 0xD3, 0xB5, 0xBD, 0xCD, 0xE2, 0xB2, 0xBF, 0xB5, 0xD8, 0xD6, 0xB7,
        ])
        ascii(#"""
        </a></div></td></tr>
        <tr class="fl_row"> </tr></tbody></table></div></body></html>
        """#)
        return page
    }

    /// The parent as the front page offers it, with no child beside it.
    private static let parent = DiscuzBoard(
        fid: 38, name: "版塊甲", category: "分類甲", gid: 1, threads: 16081
    )

    private static func client(_ routes: [String: FixtureHTTP.Outcome]) -> DiscuzClient {
        DiscuzClient(http: FixtureHTTP(routes), host: host)
    }

    private static let lookAddress = "https://\(host)/forum.php?mod=forumdisplay&fid=38"
    private static let boardAddress =
        "https://\(host)/forum.php?mod=forumdisplay&fid=38&filter=author&orderby=dateline"

    // MARK: - Reading the block

    @Test("A sub-board written only on its parent's page is found, under that parent")
    func aSubBoardOnTheParentsPageIsFound() async throws {
        let found = try await Self.client([Self.lookAddress: .text(Self.parentPage)])
            .subBoards(of: Self.parent)

        #expect(found.map(\.fid) == [434])
        let child = try #require(found.first)
        #expect(child.name == "版塊乙")
        #expect(child.parent == 38)
        #expect(child.depth == 1)
        // Filed in the parent's section: the page does not say which section it is in.
        #expect(child.category == "分類甲")
        #expect(child.gid == 1)
        // Picked on the same terms as any other board: a number and a name.
        #expect(BoardSubscription(child) == BoardSubscription(fid: 434, name: "版塊乙"))
    }

    @Test("What the parent's page states about a sub-board is kept, exact where abbreviated")
    func aSubBoardsFiguresAreKept() async throws {
        let found = DiscuzIndex.subBoards(in: Self.parentPage, under: 38)
        let child = try #require(found.first)
        // `1萬` and `4萬` are the words; the `title` beside each is the figure.
        #expect(child.threads == 15595)
        #expect(child.posts == 48036)
        #expect(child.lastPostAt != nil)
    }

    @Test("A board that only links elsewhere is not offered, whatever its label says")
    func aLinkOnlyBoardIsNotOffered() throws {
        // No figures, and a last-post cell that links to the board itself. The label is not read:
        // the same row with its label in another language is refused the same way.
        #expect(!DiscuzIndex.subBoards(in: Self.parentPage, under: 38).contains { $0.fid == 805 })
        let relabelled = Self.parentPage.replacingOccurrences(of: "鏈接到外部地址", with: "External link")
        #expect(DiscuzIndex.subBoards(in: relabelled, under: 38).map(\.fid) == [434])
    }

    @Test("A board with no figures and no link to itself is still a board")
    func aQuietBoardIsNotALink() throws {
        // A board nobody has posted in states no figures either; its last-post cell says so in
        // words (`install-b.example` writes `...`), not with a link to itself.
        let quiet = #"""
        <div id="subforum_38"><table class="fl_tb"><tr>
        <td><h2><a href="forum.php?mod=forumdisplay&fid=500">Quiet</a></h2></td>
        <td class="fl_i"></td><td class="fl_by"><div>...</div></td>
        </tr></table></div>
        """#
        let found = DiscuzIndex.subBoards(in: quiet, under: 38)
        #expect(found.map(\.fid) == [500])
        // Nothing stated, so nothing — never a zero.
        #expect(found.first?.threads == nil)
        #expect(found.first?.posts == nil)
        #expect(found.first?.lastPostAt == nil)
    }

    @Test("A link-only board on the front page is not offered either")
    func aLinkOnlyBoardOnTheIndexIsNotOffered() throws {
        let index = #"""
        <h2><a href="forum.php?gid=1">Section</a></h2>
        <div id="category_1"><table class="fl_tb">
        <tr><td><h2><a href="forum.php?mod=forumdisplay&fid=38">Parent</a></h2></td>
        <td class="fl_i"><span class="xi2">5</span><span class="xg1"> / 9</span></td>
        <td class="fl_by"><div><cite>2026-9-1 10:00</cite></div></td></tr>
        <tr><td><h2><a href="forum.php?mod=forumdisplay&fid=805">Elsewhere</a></h2></td>
        <td class="fl_i"></td>
        <td class="fl_by"><div><a href="forum.php?mod=forumdisplay&fid=805">Link</a></div></td></tr>
        </table></div>
        """#
        #expect(DiscuzIndex.categories(in: index).flatMap(\.boards).map(\.fid) == [38])
    }

    @Test("Only this board's block is read, and nothing past its table")
    func onlyThisBoardsBlockIsRead() {
        // Another board's block on the same page is that board's children, not this one's.
        #expect(DiscuzIndex.subBoards(in: Self.parentPage, under: 39).isEmpty)
        // A page with no block has no sub-boards — the thread list is never read as boards.
        let noBlock = Self.parentPage.replacingOccurrences(of: "subforum_38\"", with: "elsewhere\"")
        #expect(DiscuzIndex.subBoards(in: noBlock, under: 38).isEmpty)
    }

    @Test("The block is read out of a GBK page too")
    func theBlockIsReadInGBK() async throws {
        let page = Self.gbkParentPage()
        #expect(String(data: page, encoding: .utf8) == nil, "the bytes must not be valid UTF-8")
        let found = try await Self.client([Self.lookAddress: .body(page)]).subBoards(of: Self.parent)
        #expect(found.map(\.name) == ["版块乙"])
        #expect(found.first?.threads == 15595)
        #expect(found.first?.parent == 38)
    }

    @Test("A parent whose page lists no thread still gives its sub-boards")
    func aParentWithNoThreadsStillGivesItsSubBoards() async throws {
        let bare = Self.parentPage.replacingOccurrences(of: "normalthread_900", with: "x")
        let found = try await Self.client([Self.lookAddress: .text(bare)]).subBoards(of: Self.parent)
        #expect(found.map(\.fid) == [434])
    }

    // MARK: - The page a reload reads anyway

    @Test("A board's thread list also says what is under it and what it is under")
    func aBoardPageSaysWhatIsAround() async throws {
        let page = try await Self.client([Self.boardAddress: .text(Self.parentPage)])
            .boardPage(38, source: Self.source, named: "版塊甲")
        #expect(page.notes.map(\.id) == ["discuz:\(Self.host):900"])
        #expect(page.subBoards.map(\.fid) == [434])
        // A board at the top: the trail's step before it is a section, which is not a board.
        #expect(page.parent == nil)
    }

    @Test("A sub-board's own page names its parent in its trail")
    func aSubBoardsTrailNamesItsParent() {
        let trail = #"""
        <div id="pt" class="bm cl"><div class="z"><a href="https://install-g.example/">x</a><em>»</em>
        <a href="https://install-g.example/forum.php">y</a> <em>›</em>
        <a href="https://install-g.example/forum.php?gid=1">s</a><em>›</em>
        <a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=38">p</a><em>›</em>
        <a href="https://install-g.example/forum.php?mod=forumdisplay&amp;fid=434">c</a></div></div>
        """#
        #expect(DiscuzIndex.parent(of: 434, in: trail) == 38)
        #expect(DiscuzIndex.parent(of: 38, in: trail) == nil)
        #expect(DiscuzIndex.parent(of: 38, in: Self.parentPage) == nil)
    }

    // MARK: - Onto the picker's list

    private static let offer = JoinOffer(host: host, kind: .discuz, categories: [
        DiscuzCategory(gid: 1, name: "分類甲", boards: [
            parent,
            DiscuzBoard(fid: 40, name: "版塊丁", category: "分類甲", gid: 1),
        ]),
    ])

    @Test("Found sub-boards are drawn right under their parent, and nothing is ticked")
    func foundSubBoardsGoUnderTheirParent() {
        let found = DiscuzIndex.subBoards(in: Self.parentPage, under: 38)
        let grown = Self.offer.adding(found, under: 38)
        #expect(grown.boards.map(\.fid) == [38, 434, 40])
        #expect(grown.boards.map(\.depth) == [0, 1, 0])
        #expect(grown.boards.first { $0.fid == 434 }?.category == "分類甲")
    }

    @Test("A sub-board already on the list is not listed twice")
    func aSubBoardIsListedOnce() {
        // The front page named 434 already, bare; the parent's page names it again with figures.
        let named = JoinOffer(host: Self.host, kind: .discuz, categories: [
            DiscuzCategory(gid: 1, name: "分類甲", boards: [
                Self.parent,
                DiscuzBoard(fid: 434, name: "版塊乙", category: "分類甲", gid: 1, parent: 38),
            ]),
        ])
        let found = DiscuzIndex.subBoards(in: Self.parentPage, under: 38)
        let grown = named.adding(found, under: 38)
        #expect(grown.boards.map(\.fid) == [38, 434])
        // And a second read of the same page adds nothing either.
        let twice = Self.offer.adding(found, under: 38).adding(found, under: 38)
        #expect(twice.boards.map(\.fid) == [38, 434, 40])
    }

    @Test("Nothing is drawn under a board that is not on the list, or under a sub-board")
    func nothingUnderABoardNotListedOrUnderASubBoard() {
        let found = DiscuzIndex.subBoards(in: Self.parentPage, under: 38)
        #expect(Self.offer.adding(found, under: 999) == Self.offer)
        let grown = Self.offer.adding(found, under: 38)
        let deeper = [DiscuzBoard(fid: 900, name: "x", category: "", gid: 0, parent: 434)]
        #expect(grown.adding(deeper, under: 434) == grown)
    }

    @Test("What a reload read is offered on the next restate, and a picked sub-board stays")
    func whatAReloadReadIsOffered() async throws {
        var learned = DiscuzSubBoards()
        let page = try await Self.client([Self.boardAddress: .text(Self.parentPage)])
            .boardPage(38, source: Self.source, named: "版塊甲")
        learned.learn(page, of: BoardSubscription(fid: 38, name: "版塊甲"))
        #expect(learned.applied(to: Self.offer).boards.map(\.fid) == [38, 434, 40])

        // A reader who picked the sub-board and not its parent: the parent's page is never read,
        // and the sub-board's own trail is what files it.
        var orphan = DiscuzSubBoards()
        orphan.learn(
            DiscuzBoardPage(notes: [], subBoards: [], parent: 38),
            of: BoardSubscription(fid: 434, name: "版塊乙")
        )
        let offered = orphan.applied(to: Self.offer)
        #expect(offered.boards.map(\.fid) == [38, 434, 40])
        // Its own page states no figures about it, so it carries none.
        #expect(offered.boards.first { $0.fid == 434 }?.threads == nil)
    }
}
