import Testing
@testable import FediqoCore

@Suite("HTML is reduced to the words")
struct HTMLTextTests {
    @Test("Tags become newlines or disappear, and entities decode")
    func stripsTagsAndEntities() {
        #expect(HTMLText.plain("<p>first</p><p>second</p>") == "first\nsecond")
        #expect(HTMLText.plain("<p>one<br>two<br/>three<br />four</p>") == "one\ntwo\nthree\nfour")
        #expect(HTMLText.plain("<div>block</div><p>after</p>") == "block\nafter")
        #expect(
            HTMLText.plain(#"<p>see <a href="https://example.org">example</a></p>"#) == "see example"
        )
        #expect(HTMLText.plain("<p>a &amp; b &lt;c&gt; &quot;q&#39; &nbsp;x</p>") == "a & b <c> \"q' \u{00A0}x")
        #expect(HTMLText.plain("<p>&#8230; &#x2014;</p>") == "… —")
        #expect(HTMLText.plain("  <p>trim me</p>\n") == "trim me")
    }
}
