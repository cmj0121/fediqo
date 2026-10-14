import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #347 — signing in again, by the read-or-act question, over whatever is held: reading and
/// acting keeps everything the sign-in held was asked for where it stood, reading alone keeps
/// what reads and gives up what acts, and the question says first what either answer's page
/// asks, what it gives up, and what it ends. And the same question raised with a part ticked,
/// where nothing is held.
///
/// Every word a page is held against, and every sentence, is written out here.
@MainActor
@Suite("Signing in again over what a sign-in holds", .watched)
struct SignInAgainTests {
    private typealias S = PartServer
    private let host = "social.example"
    private static let r = "read:statuses read:lists read:accounts"
    private static let s = "read:search"
    private static let w = "write:statuses write:favourites"
    private static let b = "write:bookmarks"
    private static let n = "read:notifications"
    private static let d = "write:notifications"
    private static let f = "read:follows write:follows"
    private static let reads = "\(r) \(s)"
    private static let acts = "\(r) \(s) \(w) \(b)"
    private static let all = "\(r) \(s) \(w) \(b) \(n) \(d)"

    private static let alsoRead = "Sign in to read also asks for "
    private static let alsoWrite = "Sign in to read and write also asks for "
    private static let another = "Signing in as another account ends the sign-in this device has at social.example. Any other device carrying this sign-in is signed out too."
    private static let reading = "Sign in to read ends the sign-in this device has at social.example, and so does signing in as another account. Any other device carrying this sign-in is signed out too."
    private static let either = "Either answer ends the sign-in this device has at social.example. Any other device carrying this sign-in is signed out too."

    /// One thing held, and what the question about it must say and each answer's page ask.
    struct Held: Sendable {
        var scopes: String?
        /// What this device asked that sign-in for; what it holds, where nothing is said.
        var asked: String?
        /// Whether the source has said whose the sign-in is, this run.
        var named = true
        /// Whose it is, as an earlier run wrote down with it.
        var written: String?
        /// The parts the question is raised with ticked.
        var ticked: Set<MastodonPart> = []
        let read: String
        let act: String
        /// The sentences the question says beyond its own, in order — the last of them which
        /// answer ends the sign-in held, where one is.
        let says: [String]
    }

    static let states: [Held] = [
        // 0–3: nothing asked where the sign-in stood. Each choice is the page it always was.
        Held(scopes: reads, read: reads, act: acts, says: [another]),
        Held(scopes: acts, read: reads, act: acts, says: [reading]),
        Held(scopes: "\(reads) \(n)", read: "\(reads) \(n)", act: all, says: [another]),
        // Bookmarks and notices allowed where the sign-in stood, or with it: the same words.
        Held(scopes: all, read: "\(reads) \(n)", act: all, says: [reading]),
        // 4–5: follows, whole.
        Held(
            scopes: "\(reads) \(f)", read: "\(reads) read:follows", act: "\(acts) \(f)",
            says: [
                alsoRead + "seeing who you follow.", alsoWrite + "who you follow.",
                "Sign in to read gives up changing who you follow.", reading,
            ]
        ),
        Held(
            scopes: "\(all) \(f)", read: "\(reads) \(n) read:follows", act: "\(all) \(f)",
            says: [
                alsoRead + "seeing who you follow.", alsoWrite + "who you follow.",
                "Sign in to read gives up writing as you, bookmarks, dismissing your notices, changing who you follow.", reading,
            ]
        ),
        // 6–7: follows held in part, either half.
        Held(
            scopes: "\(reads) read:follows", read: "\(reads) read:follows", act: "\(acts) read:follows",
            says: [alsoRead + "seeing who you follow.", alsoWrite + "seeing who you follow.", another]
        ),
        Held(
            scopes: "\(acts) write:follows", read: reads, act: "\(acts) write:follows",
            says: [
                alsoWrite + "changing who you follow.",
                "Sign in to read gives up writing as you, bookmarks, changing who you follow.", reading,
            ]
        ),
        // 8–9: a word this build does not use, and a sign-in that reads by the source's one
        // word for every read: on no page, said to be given up, and ended by either answer.
        Held(
            scopes: "\(acts) push", read: reads, act: acts,
            says: ["This sign-in has push, which this version of Fediqo does not ask for, so either answer gives it up.", either]
        ),
        Held(
            scopes: "read write follow", read: reads, act: acts,
            says: ["This sign-in has read, write, follow, which this version of Fediqo does not ask for, so either answer gives it up.", either]
        ),
        // 10: follows this device never asked that sign-in for, as a package brings one: on
        // no page, and said to be given up.
        Held(
            scopes: "\(reads) \(f)", asked: reads, read: reads, act: acts,
            says: ["Either answer gives up who you follow.", either]
        ),
        // 11: nobody has said whose the sign-in is, so no answer is shown to leave it live.
        Held(
            scopes: "\(reads) \(f)", named: false, read: "\(reads) read:follows", act: "\(acts) \(f)",
            says: [
                alsoRead + "seeing who you follow.", alsoWrite + "who you follow.",
                "Sign in to read gives up changing who you follow.", either,
            ]
        ),
        // 12–13: nothing held — and the same, raised from the lock on following.
        Held(scopes: nil, read: reads, act: acts, says: []),
        Held(
            scopes: nil, ticked: [.follows], read: "\(reads) read:follows", act: "\(acts) \(f)",
            says: [
                alsoRead + "seeing who you follow.", alsoWrite + "who you follow.",
                "With Sign in to read, Fediqo can see who you follow but cannot follow or unfollow.",
            ]
        ),
        // 14: whose it is was written down with the sign-in, and no source has said so this
        // run — a launch with no network. The same account's is left live, and said to be.
        Held(
            scopes: "\(reads) \(f)", named: false, written: "1", read: "\(reads) read:follows", act: "\(acts) \(f)",
            says: [
                alsoRead + "seeing who you follow.", alsoWrite + "who you follow.",
                "Sign in to read gives up changing who you follow.", reading,
            ]
        ),
    ]

    private func shell(_ state: Held) async throws -> (ShellSession, PartServer, MemoryMastodonTokens) {
        let tokens = MemoryMastodonTokens()
        if let scopes = state.scopes {
            let token = MastodonToken(
                host: host, accessToken: "held-1", clientID: "cid-old", clientSecret: "csecret-old", scopes: scopes,
                asked: state.asked ?? scopes
            )
            try tokens.save(state.written.map { token.named(accountID: $0, handle: nil) } ?? token)
        }
        let server = PartServer(tokens: tokens)
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(), mastodon: MastodonSessions(tokens: tokens, sender: server)
        )
        // A door's deadline, on a clock nobody turns: a sign-in held at its page is not ended by
        // one, and no check here waits for one to pass.
        session.mastodon.deadlineSleep = TurnedClock().sleep
        await session.store.add(Source(host: host, kind: .mastodon))
        session.sources = await session.store.sources()
        if state.named, state.scopes != nil { await session.mastodon.learnWho(host: host) }
        await server.forget()
        return (session, server, tokens)
    }

    /// The question raised as its place raises it, and what it was drawn from.
    private func raise(_ session: ShellSession, ticking ticked: Set<MastodonPart> = []) -> SignInDrawn {
        if ticked.isEmpty {
            session.askSignIn(host: host)
        } else {
            #expect(session.askSignIn(host: host, ticking: ticked))
        }
        return session.signInDrawn(host: host)
    }

    /// The answer to the question, as its card hands it over.
    private func answer(_ session: ShellSession, _ drawn: SignInDrawn, writing: Bool, through page: PartPage) async {
        session.putDownSignInChoice()
        await session.signIn(host: host, through: page, writing: writing, noticesSaid: drawn.notices, answering: drawn)
    }

    private static func split(_ scopes: String) -> Set<String> {
        Set(scopes.split(separator: " ").map(String.init))
    }

    private static func text(_ question: ShellConfirmation) -> String {
        question.line + " " + (question.help ?? "")
    }

    /// The words of each thing a question names beside its own, written out: a half of a
    /// part is its one word.
    private static let namedWords: [String: Set<String>] = [
        "who you follow": ["read:follows", "write:follows"],
        "seeing who you follow": ["read:follows"],
        "changing who you follow": ["write:follows"],
        "your notices": ["read:notifications"],
        "dismissing your notices": ["write:notifications"],
    ]

    /// Every word the question, as drawn, says one answer's page asks: what that answer
    /// always asked, notices where it names them, and each thing it says the page also asks.
    private static func wordsNamed(by question: ShellConfirmation, writing: Bool) -> Set<String> {
        let said = text(question)
        var words = split(writing ? acts : reads)
        if said.contains("your notices among it") { words.formUnion(split(writing ? "\(n) \(d)" : n)) }
        guard let lead = said.range(of: writing ? alsoWrite : alsoRead) else { return words }
        let list = String(said[lead.upperBound...].prefix { $0 != "." })
        for name in list.components(separatedBy: ", ") {
            #expect(namedWords[name] != nil, "the question names something no word is written for")
            words.formUnion(namedWords[name] ?? [])
        }
        return words
    }

    // MARK: - The page is its question's

    @Test("Whatever the sign-in holds and whichever answer is given, the page asks exactly what that answer keeps of it and no word the question did not name; the question says what each page also asks, what is given up, and which answer ends the sign-in held; and the sign-in held is ended where the question said that answer ends it, and left live where it did not", arguments: 0..<15, [false, true])
    func thePageIsItsQuestions(_ index: Int, _ writing: Bool) async throws {
        let state = Self.states[index]
        let (session, server, tokens) = try await shell(state)
        let drawn = raise(session, ticking: state.ticked)
        let question = session.signInQuestion(host: host, language: .english)
        let said = Self.text(question)

        // What it says beyond its own words: these sentences, and no other of their kind.
        for sentence in state.says { #expect(said.contains(sentence), "the question does not say: \(sentence)") }
        let kinds = [
            Self.alsoRead, Self.alsoWrite, "gives up", "gives it up", "does not ask for", "ends the sign-in", "With Sign in to read",
        ]
        for kind in kinds {
            let expected: Bool = state.says.contains { $0.contains(kind) }
            #expect(said.contains(kind) == expected, "the question says, or leaves unsaid, something of the kind: \(kind)")
        }
        #expect(await server.requests.isEmpty, "putting the question sent something")

        let page = PartPage()
        await answer(session, drawn, writing: writing, through: page)
        await session.mastodon.leftSettled()

        let wanted = writing ? state.act : state.read
        #expect(page.scopes == [wanted])
        let named = Self.wordsNamed(by: question, writing: writing)
        #expect(Self.split(page.scopes.joined(separator: " ")).isSubset(of: named), "a page carried a word its question did not name")
        let now = try #require(try tokens.token(host: host))
        #expect(now.accessToken == "new-1")
        #expect(now.scopes == wanted)

        // Ended where the question said so, and only there.
        let ends = state.says.last ?? ""
        let saidEnded: Bool = ends == Self.either || (ends == Self.reading && !writing)
        let ended: [String] = saidEnded ? ["held-1"] : []
        #expect(await server.revoked == ended)
        let left: [MastodonLeft.State] = state.scopes != nil && !saidEnded ? [.left] : []
        #expect(try tokens.left(host: host).map(\.state) == left)
    }

    // MARK: - Shown first

    enum Meanwhile: String, CaseIterable, Sendable { case signOut, remove, replaced, replacedAlike, readBack, allowed }

    @Test("A question drawn over one sign-in opens no page over another: signed out of, removed, replaced, read back from a package or allowed more while the question stood open, its yes ends nothing and asks nothing — and the question is put again, drawn from what is held then and saying why it is back", arguments: Meanwhile.allCases, [false, true])
    func theYesIsHeldToWhatWasDrawn(_ meanwhile: Meanwhile, _ writing: Bool) async throws {
        let (session, server, tokens) = try await shell(Self.states[4])
        let drawn = raise(session)
        let other = MastodonToken(
            host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.reads, asked: Self.reads
        )
        switch meanwhile {
        case .signOut: await session.signOut(host: host)
        case .remove: await session.mastodon.signOut(host: host, forgettingApp: true)
        case .replaced:
            try tokens.save(other)
            session.mastodon.refresh()
        // Another sign-in holding the very same words, whose source has said whose it is:
        // everything the question was drawn from but the sign-in itself.
        case .replacedAlike:
            try tokens.save(MastodonToken(
                host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret",
                scopes: Self.states[4].scopes, asked: Self.states[4].scopes
            ))
            session.mastodon.refresh()
            await session.mastodon.learnWho(host: host)
        // Filed from outside the session, which has not looked since.
        case .readBack: try tokens.save(other)
        case .allowed:
            let wider = MastodonToken(
                host: host, accessToken: "held-1", clientID: "cid-old", clientSecret: "csecret-old",
                scopes: "\(Self.reads) \(Self.n) \(Self.f)", asked: "\(Self.reads) \(Self.n) \(Self.f)"
            )
            #expect(try tokens.update(wider))
        }
        await session.mastodon.leftSettled()
        let before = try tokens.token(host: host)
        let endedBefore = await server.revoked
        await server.forget()

        let page = PartPage()
        await answer(session, drawn, writing: writing, through: page)

        #expect(page.opened == 0, "a page opened on a question about another sign-in")
        #expect(await server.requests.isEmpty)
        #expect(try tokens.token(host: host) == before)
        let gone: Bool = meanwhile == .signOut || meanwhile == .remove
        #expect(endedBefore == (gone ? ["held-1"] : []))
        // Put again, from what is held now.
        #expect(session.signInChoice == host)
        let again = session.signInQuestion(host: host, language: .english)
        #expect(Self.text(again).contains("This sign-in turned out to hold something other than what you were asked about, so here is the question again."))
        let follows: Bool = Self.text(again).contains("who you follow")
        #expect(follows == (meanwhile == .allowed || meanwhile == .replacedAlike))
        let now = session.signInDrawn(host: host)
        #expect(now != drawn)

        // And the yes to that one opens the page it was drawn for.
        await answer(session, now, writing: writing, through: page)
        #expect(page.scopes == [now.page(writing: writing)])
        #expect(Self.split(now.page(writing: writing)).isSubset(of: Self.wordsNamed(by: again, writing: writing)))
    }

    @Test("A sign-in filed where none was held while the question stood open — a package read back, which the session has not looked at — is not signed in over: the yes opens no page, and the question put again is drawn from the sign-in now held, says what its answers end, and its yes opens the page")
    func filedWhereNoneWasHeld() async throws {
        let (session, server, tokens) = try await shell(Self.states[12])
        let drawn = raise(session)
        #expect(drawn.ends == nil)
        try tokens.save(MastodonToken(
            host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.acts, asked: Self.acts
        ))
        let page = PartPage()
        await answer(session, drawn, writing: false, through: page)
        #expect(page.opened == 0)
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.token(host: host)?.accessToken == "other-1")

        #expect(session.signInChoice == host)
        let again = session.signInDrawn(host: host)
        #expect(again.ends == .either && again.scopes == Self.acts)
        #expect(Self.text(session.signInQuestion(host: host, language: .english)).contains(Self.either))
        await answer(session, again, writing: false, through: page)
        await session.mastodon.leftSettled()
        #expect(page.scopes == [Self.reads])
        #expect(await server.revoked == ["other-1"])
    }

    @Test("A page closed, and a page refused, leave the sign-in held exactly as it was: nothing is ended, nothing is written beside it, and the part it holds is still held", arguments: [false, true], [PartPage.Answer.close, .refuse])
    func closedOrRefusedChangesNothing(_ writing: Bool, _ how: PartPage.Answer) async throws {
        let (session, server, tokens) = try await shell(Self.states[5])
        let before = try #require(try tokens.token(host: host))
        let drawn = raise(session)
        let page = PartPage(how)
        await answer(session, drawn, writing: writing, through: page)
        await session.mastodon.leftSettled()
        #expect(page.opened == 1)
        #expect(try tokens.token(host: host) == before)
        #expect(await server.revoked.isEmpty)
        #expect(try tokens.left(host: host).isEmpty)
        #expect(session.mastodon.standing(.follows, host: host) == .held)
    }

    @Test("A source that answers reading and acting with less than the sign-in held has — without the follows its page asked for — is not kept: the sign-in held stays, and the one that came back is ended")
    func lessThanHeldIsNotKept() async throws {
        let (session, server, tokens) = try await shell(Self.states[4])
        await server.grant(Self.acts)
        let drawn = raise(session)
        let page = PartPage()
        await answer(session, drawn, writing: true, through: page)
        await session.mastodon.leftSettled()
        #expect(page.scopes == ["\(Self.acts) \(Self.f)"])
        #expect(try tokens.token(host: host)?.accessToken == "held-1")
        #expect(await server.revoked == ["new-1"])
        #expect(session.mastodon.standing(.follows, host: host) == .held)
    }

    @Test("Signed out of while the page is up: what comes back is not kept and is ended, and nothing is held — the sign-in the question said an answer would end was ended by the sign-out, once")
    func signedOutWhileThePageIsUp() async throws {
        let (session, server, tokens) = try await shell(Self.states[4])
        let gate = Gate()
        defer { Task { await gate.open() } }
        let guardTask = watching(gate, "the sign-in's page, up")
        defer { guardTask.cancel() }
        let page = PartPage(gate: gate)
        let drawn = raise(session)
        let answered = Task { await self.answer(session, drawn, writing: true, through: page) }
        await met("the sign-in has reached its page", by: answered) { page.opened == 1 }
        await session.signOut(host: host)
        await gate.open()
        await answered.value
        await session.mastodon.leftSettled()
        #expect(try tokens.token(host: host) == nil)
        #expect(await server.revoked.sorted() == ["held-1", "new-1"])
        #expect(try tokens.left(host: host).isEmpty)
    }

    // MARK: - A sign-in that cannot be read

    @Test("A Keychain that cannot be read answers the yes with the one sentence a sign-in it could not keep has: no page opens, nothing is sent, and the question is not put again", arguments: [false, true])
    func anUnreadableKeychainIsSaidOnce(_ writing: Bool) async throws {
        let (session, server, tokens) = try await shell(Self.states[4])
        let drawn = raise(session)
        tokens.refuse(.reading, times: 100)
        defer { tokens.refuse(.reading, times: 0) }
        let page = PartPage()
        await answer(session, drawn, writing: writing, through: page)
        #expect(page.opened == 0)
        #expect(await server.requests.isEmpty)
        #expect(session.signInChoice == nil, "the question was put again over a Keychain that cannot be read")
        #expect(session.rowRefusal?.key == "account.mastodon.failed.keychain")
    }

    @Test("A sign-in whose value cannot be read as one, while what rides beside it still says signed in, is repaired by signing in again: the yes opens the page a sign-in holding nothing would get, the new sign-in is kept, and the question is not put again", arguments: [false, true])
    func anUndecodableValueIsSignedInOver(_ writing: Bool) async throws {
        let (session, _, tokens) = try await shell(Self.states[4])
        tokens.garble(host: host)
        session.mastodon.refresh()
        #expect(session.mastodon.isSignedIn(host: host))
        let drawn = raise(session)
        let page = PartPage()
        await answer(session, drawn, writing: writing, through: page)
        await session.mastodon.leftSettled()
        #expect(session.signInChoice == nil, "the question was put again over a sign-in that cannot be read")
        #expect(page.scopes == [writing ? Self.acts : Self.reads])
        #expect(try tokens.token(host: host)?.accessToken == "new-1")
        #expect(session.rowRefusal == nil)
    }

    @Test("A sign-in filed while the page is up — a package read back from off the main actor — is not signed in over: what comes back is not kept and is ended, the sign-in filed is neither replaced nor ended, and the row says nothing was changed", arguments: [4, 12], [false, true])
    func filedWhileThePageIsUp(_ index: Int, _ writing: Bool) async throws {
        let (session, server, tokens) = try await shell(Self.states[index])
        let gate = Gate()
        defer { Task { await gate.open() } }
        let guardTask = watching(gate, "the sign-in's page, up")
        defer { guardTask.cancel() }
        let page = PartPage(gate: gate)
        let drawn = raise(session)
        let answered = Task { await self.answer(session, drawn, writing: writing, through: page) }
        await met("the sign-in has reached its page", by: answered) { page.opened == 1 }
        let other = MastodonToken(
            host: host, accessToken: "other-1", clientID: "cid", clientSecret: "csecret", scopes: Self.reads, asked: Self.reads
        )
        try await Task.detached { try tokens.save(other) }.value
        await gate.open()
        await answered.value
        await session.mastodon.leftSettled()
        #expect(try tokens.token(host: host)?.accessToken == "other-1")
        #expect(await server.revoked == ["new-1"])
        #expect(try tokens.left(host: host).isEmpty)
        #expect(session.signInChoice == nil)
        #expect(session.rowRefusal?.key == "account.signin.replaced")
        let said = String(format: L10n.t("account.signin.replaced", language: .english), host)
        #expect(said == "The sign-in this device has at social.example became another while the page was open. Nothing was changed.")
    }

    // MARK: - A first sign-in raised from a part's lock

    @Test("The lock on a part where no sign-in is held raises the read-or-act question with that part ticked, and sends nothing; where a sign-in is held it raises none — that one is asked where it stands; and a question put down takes its tick with it")
    func raisedFromALock() async throws {
        let (session, server, _) = try await shell(Self.states[12])
        #expect(session.askSignIn(host: "Social.Example", ticking: [.follows]))
        #expect(session.signInChoice == "Social.Example")
        #expect(session.signInDrawn(host: host).ticked == [.follows])
        let question = session.signInQuestion(host: host, language: .english)
        #expect(question.title == "Sign in to social.example?")
        #expect(question.choices.map(\.id) == [ShellQuestion.signInRead, ShellQuestion.signInWrite])
        #expect(await server.requests.isEmpty)

        // Put down, and raised again as the row's own key raises it: nothing is ticked.
        session.putDownSignInChoice()
        session.signInChoice = host
        #expect(session.signInDrawn(host: host).ticked.isEmpty)
        #expect(session.signInQuestion(host: host, language: .english) == ShellQuestion.signIn(host: host, language: .english))
        session.putDownSignInChoice()

        let (held, _, _) = try await shell(Self.states[0])
        #expect(!held.askSignIn(host: host, ticking: [.follows]))
        #expect(held.signInChoice == nil)
        #expect(held.askFor([.follows], host: host))
    }

    @Test("The parts ticked are one record, about one source: a question raised or put down about any other source takes them with it, so they ride no later question")
    func theTicksAreOneRecord() async throws {
        let (session, _, _) = try await shell(Self.states[12])
        let other = "other.example"
        // Put down while a question about another source is the one open.
        #expect(session.askSignIn(host: host, ticking: [.follows]))
        session.signInChoice = other
        #expect(session.signInDrawn(host: other).ticked.isEmpty)
        session.putDownSignInChoice()
        session.signInChoice = host
        #expect(session.signInDrawn(host: host).ticked.isEmpty, "a tick outlived the question it was raised with")
        session.putDownSignInChoice()
        // Raised about another source from its row, over the one open.
        #expect(session.askSignIn(host: host, ticking: [.follows]))
        session.askSignIn(host: other)
        #expect(session.signInChoice == other)
        session.signInChoice = host
        #expect(session.signInDrawn(host: host).ticked.isEmpty, "a tick outlived a question raised over its own")
        session.putDownSignInChoice()
    }

    // MARK: - The words

    @Test("Every sentence the question gained is written in English and in Traditional Chinese with the same arguments, and the third table is the second byte for byte")
    func theWords() throws {
        let english = [
            "account.signin.ask.also.read": "Sign in to read also asks for %@.",
            "account.signin.ask.also.write": "Sign in to read and write also asks for %@.",
            "account.signin.ask.givesUp.either": "Either answer gives up %@.",
            "account.signin.ask.givesUp.read": "Sign in to read gives up %@.",
            "account.signin.ask.givesUp.changing": "changing %@",
            "account.signin.ask.seeing": "seeing %@",
            "account.signin.ask.givesUp.other": "This sign-in has %@, which this version of Fediqo does not ask for, so either answer gives it up.",
            "part.follows.readOnly": "With Sign in to read, Fediqo can see who you follow but cannot follow or unfollow.",
            "account.signin.replaced": "The sign-in this device has at %@ became another while the page was open. Nothing was changed.",
        ]
        let chinese = [
            "account.signin.ask.also.read": "「登入來讀」還會問：%@。",
            "account.signin.ask.also.write": "「登入來讀與寫」還會問：%@。",
            "account.signin.ask.givesUp.either": "兩種選擇都會放棄：%@。",
            "account.signin.ask.givesUp.read": "選「登入來讀」會放棄：%@。",
            "account.signin.ask.givesUp.changing": "更改%@",
            "account.signin.ask.seeing": "查看%@",
            "account.signin.ask.givesUp.other": "這個登入有 %@，是這個版本的 Fediqo 不會問的，所以兩種選擇都會放棄它。",
            "part.follows.readOnly": "選「登入來讀」，Fediqo 只能查看你追蹤的對象，不能追蹤或取消追蹤。",
            "account.signin.replaced": "頁面開著的時候，這台裝置在 %@ 的登入已經變成另一個。什麼都沒有改變。",
        ]
        for (key, words) in english {
            #expect(L10n.t(key, language: .english) == words)
            #expect(L10n.t(key, language: .taiwanese) == chinese[key])
        }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        let taiwan = try Data(contentsOf: resources.appendingPathComponent("zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"))
        #expect(taiwan == hant)
    }
}
