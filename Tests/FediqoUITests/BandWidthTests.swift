import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// The row's header at the widths it is actually read at (#127).
///
/// **The arrangement itself is verified by photograph and not here**, and that is not a gap: what
/// `ViewThatFits` picks at 440 points and 1.6× is a fact about layout, and the assertion that
/// would catch it is a picture of a row. `make -C Apps shots-widths` takes it, and the failure it
/// caught — `ced…ample` — was invisible to every test in this suite for three releases.
///
/// What is asserted here is the half a picture cannot check: that dropping the server's name from
/// the narrowest band does not drop it from what a reader is *told*.
@Suite("What the header says when it cannot say everything")
struct BandWidthTests {
    /// **A width is a reason to draw less, not a reason to say less.** With the pill gone, the
    /// label naming every server has to survive — a reader using a screen reader had no width
    /// problem to begin with, and the narrowest arrangement must not invent one for them.
    @Test("The words for naming every server exist in both languages")
    func thelabelExists() {
        #expect(TemplateWordsTests.written("post.sources"))
    }

    /// The count needs no words at all — `+1` is drawn verbatim, and a number is a number in
    /// both languages — which is exactly why it survives where a name cannot. What it needs is
    /// somewhere to say what it is a count *of*, and that is the label above.
    @Test("The count is a number and not a phrase")
    func thecountNeedsNoWords() {
        // Asserted as the absence it is: nothing in the catalogue is spent on it, and nothing
        // should be. A key here would be a translation of "+1".
        #expect(!TemplateWordsTests.written("timeline.carriedBy"))
    }

    /// A hostname is recognised from its middle, which is why cutting the middle out leaves
    /// something that is neither a hostname nor anything else. Kept as an assertion about the
    /// *value* rather than the drawing: `cedar.example` and `ced…ample` are not the same string,
    /// and nothing in this app may turn the first into the second.
    @Test("A host is only ever itself")
    func ahostIsItself() {
        let host = "cedar.example"
        #expect(Server.normalise("HTTPS://Cedar.Example/") == host)
        // Nothing here shortens. The one transformation a host goes through is normalising, and
        // it is reversible in the only sense that matters: what comes out is still a hostname.
        #expect(Server.normalise(host) == host)
    }
}
