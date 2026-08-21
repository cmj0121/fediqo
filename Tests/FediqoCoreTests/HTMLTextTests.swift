import Testing
@testable import FediqoCore

@Suite("HTML is reduced to what a person wrote")
struct HTMLTextTests {
    @Test("Paragraphs become blank lines and tags go")
    func paragraphs() {
        let html = "<p>first</p><p>second</p>"
        #expect(HTMLText.plain(html) == "first\n\nsecond")
    }

    @Test("Line breaks survive")
    func breaks() {
        #expect(HTMLText.plain("<p>one<br>two</p>") == "one\ntwo")
    }

    @Test("Links keep their text and lose their markup")
    func links() {
        let html = #"<p>see <a href="https://example.org" class="mention">example</a></p>"#
        #expect(HTMLText.plain(html) == "see example")
    }

    @Test("Named and numeric entities are decoded")
    func entities() {
        #expect(HTMLText.plain("<p>a &amp; b &lt;c&gt; &#8230; &#x2014;</p>") == "a & b <c> … —")
    }

    @Test("Runs of empty blocks collapse")
    func collapse() {
        #expect(HTMLText.plain("<p>a</p><p></p><p></p><p>b</p>") == "a\n\nb")
    }
}
