import Foundation
import Testing
@testable import FediqoCore

/// #310: somebody a post's words name is whoever the source said the post mentions, found where
/// the words spell them — and nobody the source did not list.
@Suite("Somebody mentioned in a post's words")
struct PostMentionTests {
    private static let source = Source(host: "one.example", kind: .mastodon)
    private static let ada = "@ada@one.example"
    private static let cyd = "@cyd@two.example"

    private static func mention(_ text: String, _ handle: String) -> PostMention {
        PostMention(text: text, handle: handle)
    }

    private static func status(_ content: String, mentions: String?) -> String {
        """
        {"id":"7","uri":"https://one.example/users/bob/statuses/7","created_at":"2026-10-01T00:00:00.000Z",
         "content":"\(content)","account":{"username":"bob","acct":"bob","display_name":"Bob"}\
        \(mentions.map { ",\"mentions\":\($0)" } ?? "")}
        """
    }

    private static func note(_ json: String) throws -> Note {
        try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8))
            .asNote(source: source, category: .public, sent: .now())
    }

    // MARK: - What the source lists

    @Test("A status keeps whom it says it mentions, each as an author's handle is spelled: its own people by its host, a stranger by theirs")
    func theListIsKept() throws {
        let listed = #"[{"id":"1","username":"ada","acct":"ada","url":"https://one.example/@ada"},"#
            + #"{"id":"2","username":"cyd","acct":"cyd@two.example","url":"https://two.example/@cyd"}]"#
        let content = #"<p><span class=\"h-card\"><a href=\"https://one.example/@ada\" class=\"u-url mention\">@<span>ada</span></a></span> and "#
            + #"<span class=\"h-card\"><a href=\"https://two.example/@cyd\" class=\"u-url mention\">@<span>cyd</span></a></span> hello</p>"#
        let note = try Self.note(Self.status(content, mentions: listed))
        #expect(note.mentions == [Self.ada, Self.cyd])
        #expect(note.body == "@ada and @cyd hello")
        #expect(PostMention.found(in: note.body, among: note.mentions)
            == [Self.mention("@ada", Self.ada), Self.mention("@cyd", Self.cyd)])
    }

    @Test("A status that lists nobody, or sends no list, mentions nobody whatever its words say")
    func nothingListedNothingMentioned() throws {
        for mentions in [nil, "[]"] {
            let note = try Self.note(Self.status("<p>@ada hello</p>", mentions: mentions))
            #expect(note.mentions.isEmpty)
            #expect(EmojiRun.prose(in: note.body, emojis: [], mentions: note.mentions) == [.text("@ada hello")])
        }
    }

    @Test("What is kept is whole handles only, each once, and no more than a post may mention")
    func theListIsBounded() {
        #expect(PostMention.bounded([Self.ada, "@ADA@one.example", "ada@one.example", "@ada", "@@one.example",
                                     "@ada@", "@a da@one.example", "@ada@one\u{202E}.example", "", Self.cyd])
            == [Self.ada, Self.cyd])
        // A server's name, and a port where it has one — never where an address goes on.
        let hosts = ["@ada@h/", "@ada@h+x", "@ada@h?x#y", "@ada@h:", "@ada@h:80:1", "@ada@h:x", "@ada@:80", "@ada@h h",
                     "@ada@例え.jp", "@ada@h.example:3000"]
        #expect(PostMention.bounded(hosts) == ["@ada@例え.jp", "@ada@h.example:3000"])
        let many = (0 ..< 100).map { "@p\($0)@one.example" }
        #expect(PostMention.bounded(many) == Array(many.prefix(PostMention.maxMentions)))
        let note = Note(id: "1", source: Self.source, author: "Bob", handle: "@bob@one.example", body: "",
                        postedAt: Date(timeIntervalSince1970: 0), categories: [], mentions: many + ["@ada"])
        #expect(note.mentions.count == PostMention.maxMentions)
    }

    @Test("A reblog mentions nobody of its own, and a quoted post keeps whom it mentions")
    func reblogsAndQuotes() {
        let at = Date(timeIntervalSince1970: 0)
        let reblog = Note(id: "r", source: Self.source, author: "Bob", handle: "@bob@one.example", body: "@ada",
                          postedAt: at, categories: [], mentions: [Self.ada], refs: [Reference(kind: .reblogs, id: "1")])
        #expect(reblog.mentions.isEmpty)
        let post = Note(id: "1", source: Self.source, author: "Bob", handle: "@bob@one.example", body: "@ada",
                        postedAt: at, categories: [], mentions: [Self.ada])
        #expect(QuotedPost(post).mentions == [Self.ada])
        #expect(QuotedPost(post).note(through: Self.source).mentions == [Self.ada])
    }

    @Test("A row kept before mentions were takes them from the next copy that says; one that has its own keeps them")
    func aLaterCopyFillsIn() {
        let at = Date(timeIntervalSince1970: 0)
        func copy(_ mentions: [String]) -> Note {
            Note(id: "1", source: Self.source, author: "Bob", handle: "@bob@one.example", body: "@ada",
                 postedAt: at, categories: [.public], mentions: mentions)
        }
        #expect(copy([]).filled(from: copy([Self.ada])).mentions == [Self.ada])
        #expect(copy([Self.ada]).filled(from: copy([Self.cyd])).mentions == [Self.ada])
        #expect(copy([Self.ada]).refreshed(over: copy([Self.cyd])).mentions == [Self.ada])
    }

    @Test("A post changed to mention nobody is not given back the list of a copy read before the change")
    func anEarlierCopyGivesNothingBack() {
        let at = Date(timeIntervalSince1970: 0)
        func copy(_ mentions: [String], edited: Date?) -> Note {
            Note(id: "1", source: Self.source, author: "Bob", handle: "@bob@one.example", body: "hello",
                 postedAt: at, categories: [.public], mentions: mentions, editedAt: edited)
        }
        let changed = copy([], edited: at.addingTimeInterval(600))
        #expect(changed.filled(from: copy([Self.ada], edited: nil)).mentions.isEmpty)
        #expect(changed.filled(from: copy([Self.ada], edited: at.addingTimeInterval(60))).mentions.isEmpty)
        // A copy as late, or later, is the source's word still.
        #expect(changed.filled(from: copy([Self.ada], edited: at.addingTimeInterval(600))).mentions == [Self.ada])
        #expect(copy([], edited: nil).filled(from: copy([Self.ada], edited: at.addingTimeInterval(60))).mentions == [Self.ada])
    }

    // MARK: - Where the words spell them

    @Test("Only somebody listed is a mention: an @word the source did not list stays letters")
    func nothingIsGuessed() {
        #expect(PostMention.found(in: "@ada and @eve", among: [Self.ada]) == [Self.mention("@ada", Self.ada)])
        #expect(EmojiRun.prose(in: "@ada and @eve", emojis: [], mentions: [Self.ada])
            == [.mention(Self.mention("@ada", Self.ada)), .text(" and @eve")])
        #expect(PostMention.found(in: "@eve", among: [Self.ada]).isEmpty)
        #expect(PostMention.found(in: "@ada", among: []).isEmpty)
    }

    @Test("Written whole, a mention is whoever was listed by exactly that handle — never the same name of another server")
    func writtenWhole() {
        #expect(PostMention.found(in: "hi @cyd@two.example.", among: [Self.cyd])
            == [Self.mention("@cyd@two.example", Self.cyd)])
        #expect(PostMention.found(in: "hi @cyd@three.example", among: [Self.cyd]).isEmpty)
        #expect(PostMention.found(in: "hi @CYD@Two.Example", among: [Self.cyd])
            == [Self.mention("@CYD@Two.Example", Self.cyd)])
    }

    @Test("Two people listed under one name are both written @ada, and neither is guessed")
    func oneNameTwoPeople() {
        let other = "@ada@two.example"
        #expect(PostMention.found(in: "@ada and @ada", among: [Self.ada, other]).isEmpty)
        #expect(PostMention.found(in: "@ada@two.example and @ada", among: [Self.ada, other])
            == [Self.mention("@ada@two.example", other)])
    }

    @Test(
        "A mention opens at an @ that starts a word, and ends where the name does",
        arguments: [
            ("@ada", ["@ada"]), ("(@ada)", ["@ada"]), ("@ada.", ["@ada"]), ("@ada, hi", ["@ada"]),
            ("請看@ada這個", ["@ada"]), ("@Ada", ["@Ada"]), ("@ada @ada", ["@ada", "@ada"]),
            ("mail bob@ada", []), ("x_@ada", []), ("@@ada", []), ("a/@ada", []), ("@adam", []), ("@ada_b", []),
            ("@ada.b", []), ("@", []), ("@ ada", []),
        ] as [(String, [String])]
    )
    func whereItOpensAndEnds(text: String, written: [String]) {
        #expect(PostMention.found(in: text, among: [Self.ada]).map(\.text) == written)
    }

    @Test("Words spell no more mentions than a post may draw")
    func theWordsAreBounded() {
        let text = String(repeating: "@ada ", count: 200)
        #expect(PostMention.found(in: text, among: [Self.ada]).count == PostMention.maxMentions)
    }

    // MARK: - In the cut

    @Test("A mention inside an address is the address, and one beside a tag and a picture is cut with them")
    func besideTheOtherMarks() throws {
        let blobcat = CustomEmoji(shortcode: "blobcat", url: URL(string: "https://e.test/b.png")!)
        let link = try #require(PostLink("https://one.example/@ada"))
        #expect(EmojiRun.prose(in: "see https://one.example/@ada", emojis: [], mentions: [Self.ada])
            == [.text("see "), .link(link)])
        // An `@` that would open a mention by the mention's rule alone, inside an address.
        for address in ["https://one.example/x,@ada", "https://x.example/(@ada)"] {
            let whole = try #require(PostLink(address))
            #expect(PostMention.found(in: address, among: [Self.ada]).map(\.text) == ["@ada"], "the premise")
            #expect(EmojiRun.prose(in: address, emojis: [], mentions: [Self.ada]) == [.link(whole)])
        }
        let tag = try #require(PostTag("#swift"))
        #expect(EmojiRun.prose(in: "@ada :blobcat: #swift", emojis: [blobcat], mentions: [Self.ada])
            == [.mention(Self.mention("@ada", Self.ada)), .text(" "), .emoji(blobcat), .text(" "), .tag(tag)])
    }

    @Test("A forum post's words are cut as they were: it lists nobody, so nothing in them is a mention")
    func aForumPostIsUnchanged() {
        let post = Note(id: "t1", source: Source(host: "forum.example", kind: .discuz), author: "ada", handle: "",
                        body: "@ada 你好 #swift https://e.test/a", postedAt: Date(timeIntervalSince1970: 0), categories: [])
        #expect(post.mentions.isEmpty)
        #expect(EmojiRun.prose(in: post.body, emojis: [], mentions: post.mentions)
            == EmojiRun.prose(in: post.body, emojis: []))
        #expect(!EmojiRun.prose(in: post.body, emojis: [], mentions: post.mentions)
            .contains { if case .mention = $0 { true } else { false } })
    }
}
