import Foundation
import Testing
@testable import FediqoCore

/// A rule can ask what only one kind of source says about a post (#287): the fields a kind
/// declares, what a note answers for one, and a rule on one combining as every rule does.
@Suite("A rule on what one kind of source says")
struct FieldRuleTests {
    private static let mastodon = Source(host: "social.example", kind: .mastodon)
    private static let other = Source(host: "second.example", kind: .mastodon)
    private static let forum = Source(
        host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "Board")]
    )
    private static let sources = [mastodon, other, forum]

    private static func note(
        _ id: String, _ source: Source = mastodon, audience: Audience? = .everyone, language: String? = nil,
        sensitive: Bool? = false, spoiler: String? = ""
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@\(source.host)", body: "words of \(id)",
            postedAt: Date(timeIntervalSince1970: 0), categories: [.public], audience: audience,
            sensitive: sensitive, spoiler: spoiler, language: language
        )
    }

    /// A forum's post: no audience, no language, and nothing said of a cover.
    private static func thread(_ id: String) -> Note {
        note(id, forum, audience: nil, language: nil, sensitive: nil, spoiler: nil)
    }

    private static let held: [Note] = [
        note("ja", language: "ja"),
        note("en", language: "en"),
        note("none", language: nil),
        note("ja-followers", other, audience: .followers, language: "ja"),
        note("covered", language: "en", sensitive: true),
        note("warned", language: "ja", sensitive: false, spoiler: "spiders"),
        thread("forum-1"),
        thread("forum-2"),
    ]

    private func timeline(_ rules: [Rule?], sources: [Source] = sources) throws -> CompiledTimeline {
        CompiledTimeline(TimelineDefinition(name: "t", rules: try rules.map { try #require($0) }), sources: sources)
    }

    private func shown(_ rules: [Rule?], sources: [Source] = sources) throws -> [String] {
        try timeline(rules, sources: sources).shown(Self.held, TextIndex(Self.held)).map(\.id)
    }

    // MARK: - What a kind declares, and what a note answers

    @Test("A Mastodon declares how far a post was sent, its language and whether it was covered, each with its type; no other kind declares any")
    func whatAKindDeclares() {
        #expect(ProtocolKind.mastodon.fields.map(\.name) == ["audience", "language", "covered", "reblog", "reblogOf"])
        #expect(ProtocolKind.mastodon.fields.map(\.about) == [.post, .post, .post, .item, .item], "each says what it is a fact about; whether an item is a reblog, and whose post it reblogs, are about the item")
        #expect(SourceField.reblog.type == .flag)
        #expect(SourceField.reblogOf.type == .text && SourceField.reblogOf.holdsHandle)
        #expect(ProtocolKind.mastodon.fields.filter(\.holdsHandle) == [.reblogOf])
        #expect(SourceField.audience.type == .options(fixed: ["everyone", "unlisted", "followers", "mentioned"], open: false))
        #expect(SourceField.language.type == .options(fixed: [], open: true), "any language there is")
        #expect(SourceField.covered.type == .flag)
        for kind in [ProtocolKind.discuz, .discourse, .pleroma, .unknown] {
            #expect(kind.fields.isEmpty)
            #expect(kind.field(named: "audience") == nil)
        }
        #expect(Set(ProtocolKind.mastodon.fields.map(\.name)).count == 5, "a name is one field")
    }

    @Test("A note answers for a field its source's kind declares; one the source said nothing of, or of another kind, answers nothing")
    func whatANoteAnswers() {
        let post = Self.note("1", audience: .followers, language: "JA", sensitive: false, spoiler: "")
        #expect(post.value(of: "audience") == .option("followers"))
        #expect(post.language == "ja" && post.value(of: "language") == .option("ja"), "folded as it is kept")
        #expect(post.value(of: "covered") == .flag(false))
        #expect(post.value(of: "no-such-field") == nil)

        // Covered is the row's own rule: marked sensitive, or given a line of warning.
        #expect(Self.note("2", sensitive: true).value(of: "covered") == .flag(true))
        #expect(Self.note("3", sensitive: false, spoiler: "mind").value(of: "covered") == .flag(true))
        #expect(Self.note("4", sensitive: nil, spoiler: "mind").value(of: "covered") == .flag(true))
        #expect(Self.note("5", sensitive: nil, spoiler: "").value(of: "covered") == .flag(false))

        // Nothing said is not a value.
        let silent = Self.note("6", audience: nil, language: nil, sensitive: nil, spoiler: nil)
        #expect(silent.value(of: "audience") == nil && silent.value(of: "language") == nil && silent.value(of: "covered") == nil)
        #expect(Self.note("7", language: "").language == nil)

        // A forum's post has no such fields, whatever else it happens to carry.
        let thread = Self.note("8", Self.forum, audience: .everyone, language: "ja", sensitive: true)
        #expect(thread.value(of: "audience") == nil && thread.value(of: "language") == nil && thread.value(of: "covered") == nil)
    }

    @Test("The language a status says it is in is read off it, and a status that says none has none")
    func theLanguageIsRead() throws {
        func note(_ language: String) throws -> Note {
            let json = """
            {"id":"9","uri":"https://social.example/users/ada/statuses/9","created_at":"2024-06-01T00:00:00.000Z",
             "content":"<p>x</p>","visibility":"public"\(language),
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
            return try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8)).asNote(source: Self.mastodon, category: .home, sent: .now())
        }
        #expect(try note(#","language":"ja""#).language == "ja")
        #expect(try note(#","language":"zh-TW""#).language == "zh-tw")
        #expect(try note(#","language":null"#).language == nil)
        #expect(try note("").language == nil)
        #expect(try note(#","language":7"#).language == nil, "a value of another shape cost the status")
        #expect(try note(#","language":"""#).language == nil)
    }

    @Test("Only what looks like a language tag is kept as a language: off the wire, on a note however it is made, and nothing else")
    func onlyALanguageTagIsALanguage() throws {
        #expect(SourceField.languageTag("ja") == "ja")
        #expect(SourceField.languageTag("zh-Hant-TW") == "zh-hant-tw")
        #expect(SourceField.languageTag("x-private-1") == "x-private-1")
        #expect(SourceField.languageTag(String(repeating: "a", count: 35)) != nil)
        for bad in [
            "", " ", "ja ", " ja", "ja\n", "ja\u{0}", "日本語", "ja_JP", "ja;drop", "<b>", "ja\u{202E}",
            String(repeating: "a", count: 36), String(repeating: "x", count: 1_000_000),
        ] {
            #expect(SourceField.languageTag(bad) == nil, "kept \(bad.prefix(12).debugDescription)")
            #expect(Self.note("1", language: bad).language == nil)
            #expect(Self.note("1", language: bad).value(of: "language") == nil)
        }
        #expect(SourceField.languageTag(nil) == nil)

        func note(_ language: String) throws -> Note {
            let json = """
            {"id":"9","uri":"https://social.example/users/ada/statuses/9","created_at":"2024-06-01T00:00:00.000Z",
             "content":"<p>x</p>","visibility":"public","language":"\(language)",
             "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
            """
            return try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(json.utf8)).asNote(source: Self.mastodon, category: .home, sent: .now())
        }
        #expect(try note(String(repeating: "j", count: 100_000)).language == nil, "a megabyte of language was kept on the row")
        #expect(try note("ja\\u0007").language == nil)
        #expect(try note("ja evil").language == nil)
        #expect(try note("pt-BR").language == "pt-br")
    }

    @Test("A post's language is what its source says of it now: taken with a change or a read of the post even where it states none, and left by an older or a partial copy")
    func theLanguageIsWhatItSaysNow() async throws {
        let store = ItemStore()
        await store.add(Self.mastodon)
        func copy(_ language: String?, edited: Double? = nil, id: String = "1") -> Note {
            Note(
                id: id, source: Self.mastodon, author: "Ada", handle: "@ada@social.example", body: "words",
                postedAt: Date(timeIntervalSince1970: 0), categories: [.public], spoiler: "", statusID: id,
                editedAt: edited.map { Date(timeIntervalSince1970: $0) }, language: language
            )
        }
        let key = copy("ja").key
        func language() async -> String? { await store.note(key)?.language }
        await store.ingest([copy("ja")], ifSourceHere: Self.mastodon.host)
        await store.setKept(true, for: key)

        // Changed at its source to state no language: it states none here, and matches no rule on one.
        await store.ingest([copy(nil, edited: 60)], ifSourceHere: Self.mastodon.host)
        #expect(await language() == nil, "it kept matching the language it used to state")
        // Changed again to another.
        await store.ingest([copy("en", edited: 120)], ifSourceHere: Self.mastodon.host)
        #expect(await language() == "en")
        // An older copy, still on its way, says nothing this row does not say more lately.
        await store.ingest([copy("ja", edited: 60)], ifSourceHere: Self.mastodon.host)
        await store.refresh([copy(nil, edited: 60)], ifSourceHere: Self.mastodon.host)
        #expect(await language() == "en")
        // A read of the post itself is the whole of what its source says now.
        await store.refresh([copy(nil, edited: 120)], ifSourceHere: Self.mastodon.host)
        #expect(await language() == nil)
        await store.refresh([copy("fr", edited: 120)], ifSourceHere: Self.mastodon.host)
        #expect(await language() == "fr")
        // A copy that is not the post read whole — a timeline's same-revision copy, a quoted
        // post carried inside another — fills what was never said and takes nothing away.
        await store.ingest([copy(nil, edited: 120)], ifSourceHere: Self.mastodon.host)
        #expect(await language() == "fr")
        await store.ingest([copy(nil, id: "2")], ifSourceHere: Self.mastodon.host)
        await store.ingest([copy("de", id: "2")], ifSourceHere: Self.mastodon.host)
        #expect(await store.note(copy(nil, id: "2").key)?.language == "de")
        #expect(await store.note(key)?.kept == true)
    }

    // MARK: - The rule

    @Test("A rule on a field is made for a value a rule can be asked of, folded as a note's is, and for no other")
    func theFactory() throws {
        let rule = try #require(Rule.field("language", is: .option("JA"), in: .every))
        #expect(rule.kind == .field(name: "language", is: .option("ja"), in: .every))
        #expect(rule.kind.tag == .field && rule.kind.group == .field("language"))
        #expect(Rule.field("covered", is: .flag(true), in: .source(host: "Social.Example"))?.kind
            == .field(name: "covered", is: .flag(true), in: .source(host: "social.example")))
        #expect(Rule.field("", is: .flag(true), in: .every) == nil)
        #expect(Rule.field("language", is: .option(""), in: .every) == nil)
        #expect(Rule.field("language", is: .option("ja"), in: .source(host: "")) == nil)
        // A value its field cannot hold is no rule: it could never match.
        #expect(Rule.field("covered", is: .option("yes"), in: .every) == nil)
        #expect(Rule.field("audience", is: .flag(true), in: .every) == nil)
        #expect(Rule.field("audience", is: .option("friends"), in: .every) == nil, "not one of its options")
        #expect(Rule.field("audience", is: .option("Followers"), in: .every)?.kind == .field(name: "audience", is: .option("followers"), in: .every))
        #expect(Rule.field("language", is: .flag(true), in: .every) == nil)
        for bad in ["ja jp", "日本語", String(repeating: "a", count: 36), "ja\n"] {
            #expect(Rule.field("language", is: .option(bad), in: .every) == nil, "\(bad.debugDescription) is no language")
        }
        #expect(SourceField.declared.keys.sorted() == ["audience", "covered", "language", "reblog", "reblogOf"])
        #expect(SourceField.audience.accepts(.option("followers")) && !SourceField.audience.accepts(.option("x")))
        #expect(SourceField.covered.accepts(.flag(false)) && !SourceField.covered.accepts(.option("no")))
        // A field no kind of source declares is not judged: a later build may declare it.
        #expect(Rule.field("mood", is: .option("glad"), in: .every) != nil)
        #expect(Rule.field("mood", is: .flag(true), in: .every) != nil)
        // Named so a stored rule's shape need not change; asked by nothing yet.
        for value in [FieldValue.number(3), .date(Date(timeIntervalSince1970: 0))] {
            #expect(!value.isAsked)
            #expect(Rule.field("later", is: value, in: .every) == nil)
        }
        // A text is asked of a field that holds a handle, and of no other: a name this build
        // does not declare has no way to compare one.
        #expect(Rule.field("later", is: .text("x"), in: .every) == nil)
        #expect(Rule.field("covered", is: .text("ada@m.example"), in: .every) == nil)
        // A handle is kept as an author rule keeps one, however it was typed; what is no handle is no rule.
        #expect(Rule.field("reblogOf", is: .text(" @Ada@M.Example "), in: .every)?.kind == .field(name: "reblogOf", is: .text("ada@m.example"), in: .every))
        #expect(Rule.field("reblogOf", is: .text("ada@m.example"), in: .every)?.kind == Rule.field("reblogOf", is: .text("@ADA@m.example"), in: .every)?.kind)
        for bad in ["", "ada", "@ada", "ada@", "@m.example", "a@b@c", "  "] {
            #expect(Rule.field("reblogOf", is: .text(bad), in: .every) == nil, "\(bad.debugDescription) is no handle")
            #expect(!SourceField.reblogOf.accepts(.text(bad)))
        }
        #expect(Rule.field("reblogOf", is: .option("ada@m.example"), in: .every) == nil)
        #expect(Rule.field("reblogOf", is: .flag(true), in: .every) == nil)
        #expect(SourceField.reblogOf.accepts(.text("ada@m.example")) && !SourceField.reblogOf.accepts(.text("@Ada@m.example")), "held as folded, and as nothing else")
        #expect(Rule.handle("@Ada@M.Example") == "ada@m.example" && Rule.handle("ada") == nil)
    }

    @Test("One rule “language is Japanese” shows only posts whose source says so; a post that says no language is not shown")
    func languageIsJapanese() throws {
        #expect(try shown([.field("language", is: .option("ja"), in: .every)]) == ["ja", "ja-followers", "warned"])
    }

    @Test("A timeline hiding covered posts shows everything else, and each hidden one names that rule")
    func hidingCoveredNamesItsRule() throws {
        let hide = try #require(Rule.field("covered", is: .flag(true), in: .every, effect: .exclude))
        let timeline = try timeline([hide])
        let index = TextIndex(Self.held)
        #expect(timeline.shown(Self.held, index).map(\.id) == ["ja", "en", "none", "ja-followers", "forum-1", "forum-2"])
        for note in Self.held {
            let covered = note.id == "covered" || note.id == "warned"
            #expect(timeline.verdict(note, index) == (covered ? .hidden(by: hide.id) : .shown), "\(note.id)")
        }
    }

    @Test("A rule on how far a post was sent, in a timeline that also reads a forum, shows no forum post through it and hides none by it")
    func aForumPostIsNeitherShownNorHidden() throws {
        let sent = Rule.field("audience", is: .option("everyone"), in: .every)
        let through = try shown([sent])
        #expect(!through.contains { $0.hasPrefix("forum") }, "a forum post has no “how far it was sent”")
        #expect(through == ["ja", "en", "none", "covered", "warned"])

        let hidden = try shown([.field("audience", is: .option("everyone"), in: .every, effect: .exclude)])
        #expect(hidden == ["ja-followers", "forum-1", "forum-2"], "a forum post was hidden by a rule that cannot be asked of it")
        // And the same for the other two: nothing said is not a no.
        #expect(try shown([.field("covered", is: .flag(false), in: .every)]).allSatisfy { !$0.hasPrefix("forum") })
        #expect(try shown([.field("covered", is: .flag(false), in: .every, effect: .exclude)]).contains("forum-1"))
        #expect(try shown([.field("language", is: .option("ja"), in: .every, effect: .exclude)]).contains("none"))

        // Even a forum's post that happens to carry such a value — a row from another reader of
        // the format — is not asked: its kind of source declares no such field.
        let odd = Self.note("forum-odd", Self.forum, audience: .everyone, language: "ja", sensitive: true)
        let notes = [odd, Self.note("ja", language: "ja", sensitive: true)]
        let index = TextIndex(notes)
        for (name, value) in [("audience", FieldValue.option("everyone")), ("language", .option("ja")), ("covered", .flag(true))] {
            let show = try timeline([.field(name, is: value, in: .every)])
            #expect(show.shown(notes, index).map(\.id) == ["ja"], "\(name) showed a forum post")
            let hide = try timeline([.field(name, is: value, in: .every, effect: .exclude)])
            #expect(hide.shown(notes, index).map(\.id) == ["forum-odd"], "\(name) hid a forum post")
        }
    }

    @Test("Rules on one field are any; rules on two fields are all; a hide wins; and each is for its scope")
    func theyCombineAsEveryRuleDoes() throws {
        let ja = Rule.field("language", is: .option("ja"), in: .every)
        let en = Rule.field("language", is: .option("en"), in: .every)
        #expect(try shown([ja, en]) == ["ja", "en", "ja-followers", "covered", "warned"])
        // Another field narrows it.
        let followers = Rule.field("audience", is: .option("followers"), in: .every)
        #expect(try shown([ja, en, followers]) == ["ja-followers"])
        // Another kind narrows it as it narrows any rule.
        #expect(try shown([ja, .source("second.example")]) == ["ja-followers"])
        #expect(try shown([ja, .keyword("words of warned", in: .every)]) == ["warned"])
        // A hide wins over what an include lets through, and names itself.
        let hide = try #require(Rule.field("covered", is: .flag(true), in: .every, effect: .exclude))
        #expect(try shown([ja, hide]) == ["ja", "ja-followers"])
        let warned = try #require(Self.held.first { $0.id == "warned" })
        #expect(try timeline([ja, hide]).verdict(warned, TextIndex(Self.held)) == .hidden(by: hide.id))
        // For one source only.
        #expect(try shown([.field("language", is: .option("ja"), in: .source(host: "second.example"))]) == ["ja-followers"])
        // The order they are tried in, and what a post left out is put down to: the kinds, then
        // each field as it first stands.
        let rules = try [followers, .keyword("x", in: .every), ja, en].map { try #require($0) }
        #expect(RuleKind.groups(of: rules) == [.kind(.keyword), .field("audience"), .field("language")])
    }

    // MARK: - A rule naming a field nobody here declares

    @Test("A rule on a field no remaining source declares stays, is marked missing, and still applies to posts held")
    func aFieldNoSourceDeclares() throws {
        let rule = try #require(Rule.field("language", is: .option("ja"), in: .every))
        #expect(try timeline([rule]).status(of: rule) == .present)
        #expect(try timeline([rule], sources: [Self.forum]).status(of: rule) == .missingField)
        #expect(try timeline([rule], sources: []).status(of: rule) == .missingField)
        // It still applies to what is held.
        #expect(try shown([rule], sources: [Self.forum]) == ["ja", "ja-followers", "warned"])

        // For one source: gone is gone, and one that declares no such field is a missing field.
        let onForum = try #require(Rule.field("language", is: .option("ja"), in: .source(host: "forum.example")))
        #expect(try timeline([onForum]).status(of: onForum) == .missingField)
        let onGone = try #require(Rule.field("language", is: .option("ja"), in: .source(host: "gone.example")))
        #expect(try timeline([onGone]).status(of: onGone) == .missingSource(host: "gone.example"))
        // A field this build has never heard of is a missing one too, and matches nothing.
        let unknown = try #require(Rule.field("mood", is: .option("glad"), in: .every))
        #expect(try timeline([unknown]).status(of: unknown) == .missingField)
        #expect(try shown([unknown]).isEmpty)
    }

    // MARK: - What a reload asks

    @Test("A timeline of field rules alone asks the sources that declare the field, for their usual reads, and no forum")
    func whatIsAsked() throws {
        let ja = Rule.field("language", is: .option("ja"), in: .every)
        let both = [FetchAsk(host: "social.example", categories: nil), FetchAsk(host: "second.example", categories: nil)]
        #expect(try timeline([ja]).sourcesToAsk() == both)
        #expect(try timeline([ja, .field("audience", is: .option("followers"), in: .every)]).sourcesToAsk() == both)
        // Its scope narrows what is asked; nothing else about it does.
        #expect(try timeline([.field("language", is: .option("ja"), in: .source(host: "second.example"))]).sourcesToAsk()
            == [FetchAsk(host: "second.example", categories: nil)])
        // A hide asks every source, since it lets every other post through.
        #expect(try timeline([.field("covered", is: .flag(true), in: .every, effect: .exclude)]).sourcesToAsk().map(\.host)
            == ["social.example", "second.example", "forum.example"])
        // With a category rule beside it, the category is what is asked for, where the field reaches.
        #expect(try timeline([ja, .category(.trends, in: .every, sources: Self.sources)]).sourcesToAsk()
            == [FetchAsk(host: "social.example", categories: [.trends]), FetchAsk(host: "second.example", categories: [.trends])])
        // Nobody declares it: nobody is asked.
        #expect(try timeline([ja], sources: [Self.forum]).sourcesToAsk().isEmpty)
    }
}
