import Foundation
import Testing
@testable import FediqoCore

/// The one rule a post's words are allowed to make this device follow, and what the words are cut
/// into so a screen can draw it.
///
/// **These are the tests that stand between a stranger's text and this app doing what it says.**
/// A post body is written by somebody nobody here has met; every case below is a thing that text
/// would otherwise be deciding.
@Suite("An address in somebody's post")
struct PostLinkTests {
    private static func link(_ text: String) -> PostLink? { PostLink(text) }

    // MARK: - The scheme, which is the whole of the security decision

    @Test("An https address with a host to reach is followed")
    func httpsIsFollowed() throws {
        let link = try #require(Self.link("https://example.test/a"))
        #expect(link.url.absoluteString == "https://example.test/a")
        #expect(link.host == "example.test")
        // What is drawn and where it goes are the same string. Nothing else is possible here.
        #expect(link.text == link.url.absoluteString)
    }

    @Test("Nothing but https is followed", arguments: [
        "http://example.test/a",
        "javascript:alert(1)",
        "javascript:void(0)",
        "data:text/html;base64,PHNjcmlwdD4=",
        "data:text/html,<script>alert(1)</script>",
        "file:///etc/passwd",
        "file://localhost/Users/somebody/.ssh/id_rsa",
        "mailto:somebody@example.test",
        "tel:+15550100",
        "itms-apps://apps.apple.com/app/id1",
        "fediqo://open/timeline",
        "ftp://example.test/a",
        "HTTP://example.test/a",
    ])
    func everyOtherSchemeIsRefused(_ raw: String) {
        #expect(PostLink.followable(raw) == nil)
        #expect(Self.link(raw) == nil)
    }

    @Test("An https address with no host to reach is refused", arguments: [
        "https://", "https:///a", "https://:8443/a", "https:",
    ])
    func aHostIsRequired(_ raw: String) {
        #expect(Self.link(raw) == nil)
    }

    /// `https://apple.com@evil.example/` reads, to a person, as Apple's. Its host is
    /// `evil.example`. Nothing honest can be done with it: stripping the userinfo opens a
    /// different address from the one on the screen, and keeping it hands a password to a web
    /// view. So it is not a link.
    @Test("Credentials in the address are refused, not stripped", arguments: [
        "https://user:secret@evil.example/a",
        "https://apple.com@evil.example/a",
        "https://apple.com@evil.example",
    ])
    func credentialsAreRefused(_ raw: String) {
        #expect(Self.link(raw) == nil)
        // And the scanner does not find one either, which is what the reader actually sees.
        #expect(PostLink.found(in: "look: \(raw) ").isEmpty)
    }

    @Test("An empty string is not an address")
    func emptyIsNotAnAddress() {
        #expect(PostLink.followable("") == nil)
    }

    @Test("The scheme's own spelling does not matter, because a URL's does not")
    func theSchemeIsReadCaseInsensitively() throws {
        let found = PostLink.found(in: "HTTPS://Example.Test/a")
        #expect(found.count == 1)
        #expect(try #require(found.first).host == "Example.Test")
    }

    // MARK: - Which letters an address may be written with

    /// A punycode host is unambiguous ASCII: the letters the reader sees and the name the wire
    /// uses are the same string.
    @Test("A punycode host is a host")
    func punycodeIsFollowed() throws {
        let link = try #require(Self.link("https://xn--80ak6aa92e.com/a"))
        #expect(link.host == "xn--80ak6aa92e.com")
    }

    /// The other half of the same decision, and the one that costs something. An address written
    /// with letters that are not ASCII is not drawn as a link at all — the punycode spelling of
    /// the same host is. What that buys is that no drawn address can be read one way and reached
    /// another: a Cyrillic а is not a Latin a on the wire and must not be one on the screen.
    @Test("An address written in letters an address is not written in is not a link", arguments: [
        "https://\u{0430}\u{0440}\u{0440}\u{04CF}\u{0435}.com/a",
        "https://台灣.tw/a",
        "https://example.test/ä",
    ])
    func nonASCIIStopsTheAddress(_ raw: String) {
        let found = PostLink.found(in: "see \(raw) ")
        // Either nothing, or the ASCII part before the letter that stopped it — never the whole
        // of what was typed.
        #expect(found.first?.text != raw)
        // **And the part that is left is an address with its host whole.** That is the shape the
        // cost takes, and it is why the cost is payable: `https://example.test/ä` draws an
        // underlined `https://example.test/` and then a plain `ä`, so a reader sees a shorter
        // address than the author typed and the press opens that shorter one — but the host sits
        // at the head of the underlined run and cannot be the half of a name, because a scan that
        // stops inside a host has already stopped before the path as well.
        if let link = found.first {
            #expect(raw.hasPrefix(link.text))
            #expect(link.text.hasPrefix("https://\(link.host)"))
        }
    }

    /// `U+202E` reverses everything drawn after it, which is how an address is made to read as a
    /// different one. It is not an address character, so it ends the address instead of joining
    /// it.
    ///
    /// **What this does not hold**, because the claim is easy to over-read: an override written
    /// *earlier* in the post sits in a `.text` run and still reaches the link, since the runs are
    /// concatenated into one `Text` and one paragraph. `PostLink.addressEnd` writes down why that
    /// is documented rather than stripped, and what is left of it.
    @Test("A bidirectional override cannot get into an address")
    func bidiOverrideStopsTheAddress() throws {
        let found = PostLink.found(in: "https://example.test/a\u{202E}gpj.exe ")
        #expect(found.count == 1)
        #expect(try #require(found.first).text == "https://example.test/a")
    }

    // MARK: - Finding one in a post's words

    @Test("An address at the start, in the middle and at the end of a line")
    func whereverItSits() {
        #expect(PostLink.found(in: "https://example.test/a").map(\.text) == ["https://example.test/a"])
        #expect(PostLink.found(in: "see https://example.test/a now").map(\.text)
            == ["https://example.test/a"])
        #expect(PostLink.found(in: "see https://example.test/a").map(\.text)
            == ["https://example.test/a"])
    }

    @Test("Two addresses are two links, in the order they were written")
    func twoOfThem() {
        #expect(PostLink.found(in: "https://a.test/1 and https://b.test/2").map(\.host)
            == ["a.test", "b.test"])
    }

    /// The whole reason `opensAWord` reads ASCII alphanumerics and not `Character.isLetter`: 看 is
    /// a letter, and a great many posts in this app's second language put an address straight
    /// after one.
    @Test("An address written straight after a CJK character is still an address")
    func afterCJK() {
        #expect(PostLink.found(in: "請看https://example.test/a這個").map(\.text)
            == ["https://example.test/a"])
    }

    @Test("Something that merely ends in https:// is not an address")
    func notInsideAWord() {
        #expect(PostLink.found(in: "nothttps://example.test/a").isEmpty)
        #expect(PostLink.found(in: "9https://example.test/a").isEmpty)
    }

    @Test("An address inside another address is not a second link")
    func nestedIsNotASecondLink() {
        let found = PostLink.found(in: "https://a.test/r?to=https://b.test/2")
        #expect(found.map(\.host) == ["a.test"])
    }

    @Test("A sentence's punctuation stays with the sentence", arguments: [
        ("Read https://example.test/a.", "https://example.test/a"),
        ("Read https://example.test/a, then go.", "https://example.test/a"),
        ("Read https://example.test/a!", "https://example.test/a"),
        ("Read https://example.test/a?", "https://example.test/a"),
        ("Read https://example.test/a;", "https://example.test/a"),
        ("(https://example.test/a)", "https://example.test/a"),
    ])
    func trailingPunctuation(_ line: String, _ expected: String) {
        #expect(PostLink.found(in: line).map(\.text) == [expected])
    }

    /// A bracket the address opened belongs to the address. Wikipedia writes them.
    @Test("A closing bracket the address opened is kept")
    func balancedBrackets() {
        #expect(PostLink.found(in: "https://example.test/a_(b) and on").map(\.text)
            == ["https://example.test/a_(b)"])
    }

    @Test("A query, a fragment, a port and an escape are all part of the address")
    func theWholeAddress() {
        let raw = "https://example.test:8443/a/b%20c?q=1&r=2#frag"
        #expect(PostLink.found(in: "see \(raw) now").map(\.text) == [raw])
    }

    @Test("An address that stops at a newline stops there")
    func stopsAtALine() {
        #expect(PostLink.found(in: "https://example.test/a\nand more").map(\.text)
            == ["https://example.test/a"])
    }

    @Test("A bare host is not made into a link")
    func noGuessing() {
        #expect(PostLink.found(in: "example.test and www.example.test").isEmpty)
    }

    /// A post is five hundred characters of somebody else's choosing. Past the bound the
    /// addresses stay as the letters they were typed as, which is what a reader would have seen
    /// anyway.
    @Test("However many addresses a post carries, only so many become links")
    func thereIsACeiling() {
        let many = (0 ..< (PostLink.maxLinks + 20))
            .map { "https://n\($0).test/a" }
            .joined(separator: " ")
        #expect(PostLink.found(in: many).count == PostLink.maxLinks)
    }

    // MARK: - The cut a screen draws

    private static let blobcat = CustomEmoji(
        shortcode: "blobcat", url: URL(string: "https://first.example/blobcat.png")!
    )

    @Test("Prose is cut into words, pictures and addresses")
    func proseCut() throws {
        let link = try #require(Self.link("https://example.test/a"))
        #expect(EmojiRun.prose(in: "hi :blobcat: see https://example.test/a now",
                               emojis: [Self.blobcat]) == [
            .text("hi "), .emoji(Self.blobcat), .text(" see "), .link(link), .text(" now"),
        ])
    }

    @Test("An address with nothing either side is one run")
    func onlyAnAddress() throws {
        let link = try #require(Self.link("https://example.test/a"))
        #expect(EmojiRun.prose(in: "https://example.test/a", emojis: []) == [.link(link)])
    }

    @Test("Words with no colon in them are neither a picture nor an address")
    func noColonNoScan() {
        #expect(EmojiRun.prose(in: "just some words", emojis: [Self.blobcat]) == [.text("just some words")])
        #expect(EmojiRun.prose(in: "", emojis: []) == [])
    }

    @Test("A colon that opens nothing leaves the words exactly as they were typed")
    func aColonThatOpensNothing() {
        #expect(EmojiRun.prose(in: "at 12:30, not before", emojis: [Self.blobcat])
            == [.text("at 12:30, not before")])
    }

    /// The cut a **label** gets cannot produce a link, whatever a stranger called themselves.
    /// `EmojiText`'s two initialisers are the other half of this, and this is the half a test can
    /// hold.
    @Test("The label cut has no link in it, however the label is spelled")
    func labelsAreNotProse() {
        let runs = CustomEmoji.runs(in: "https://example.test/a", from: [])
        #expect(runs == [.text("https://example.test/a")])
    }

    @Test("A picture inside an address is not a picture")
    func aShortcodeInsideAnAddress() throws {
        // `:blobcat:` is legal in a path, and the address swallows it: what the author wrote is
        // one address, not an address with a picture standing in the middle of it.
        let link = try #require(Self.link("https://example.test/:blobcat:/a"))
        #expect(EmojiRun.prose(in: "https://example.test/:blobcat:/a", emojis: [Self.blobcat])
            == [.link(link)])
    }
}
