import Foundation
import Testing

@testable import FediqoCore

/// Looking at a source without taking it, and then taking it.
///
/// **What every test here is really pinning is that nothing was added.** The whole point of the
/// stage is that a reader sees what a server says about itself *before* anything of theirs
/// changes, so an empty store after a look is not a detail of these tests — it is the promise.
///
/// The servers are the ones the join tests already use, so that what is proved here is the new
/// door and not a new fixture: `JoinTests.joinHTTP()` is a whole Mastodon, and the forums are
/// written out at the smallest shape that detects.
@Suite("Looking before taking")
struct PreviewTests {
    private static func joiner(_ http: FixtureHTTP, _ store: ItemStore) -> SourceJoin {
        SourceJoin(http: http, store: store, catalogues: EmojiCatalogueStore())
    }

    /// A Discuz! front page, at the smallest shape that detects as one.
    private static let discuzFront = #"""
    <html><head><meta name="generator" content="Discuz! X3.4" /></head><body></body></html>
    """#

    /// One category with one board — enough for an offer to be an offer.
    private static let discuzIndex = #"""
    <h2><a href="forum.php?gid=56">Tools</a></h2>
    <div id="category_56" class="bm_c">
    <table class="fl_tb"><tr><td class="fl_g"><dl>
    <dt><a href="forum.php?mod=forumdisplay&fid=33">Boot disks</a></dt>
    <dd><em>主题: 4207</em></dd>
    </dl></td></tr></table>
    </div>
    """#

    private static func discuzHTTP() -> FixtureHTTP {
        FixtureHTTP([
            "/": .text(discuzFront),
            "https://install-c.example/forum.php": .text(discuzIndex),
        ])
    }

    /// A Mastodon whose front page names it, so detection never reaches the probe — which leaves
    /// `/api/v2/instance` free to be the *profile*'s answer and nothing else. That separation is
    /// what lets a look fail at the profile while the server is still perfectly joinable.
    private static let mastodonFront = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="application-name" content="Mastodon">
      <link rel="help" href="https://joinmastodon.org/">
      <title>Mastodon</title>
    </head>
    <body><div id="mastodon"></div></body>
    </html>
    """

    private static let onePost = """
    [
      {
        "id": "100",
        "uri": "https://old.example/users/ada/statuses/only",
        "created_at": "2024-01-01T00:00:00.000Z",
        "content": "<p>The only one</p>",
        "visibility": "public",
        "account": { "username": "ada", "acct": "ada", "display_name": "Ada" }
      }
    ]
    """

    private static func mastodonHTTP(instance: FixtureHTTP.Outcome) -> FixtureHTTP {
        FixtureHTTP([
            "/": .text(mastodonFront),
            "/api/v2/instance": instance,
            "/api/v1/timelines/public": .text(onePost),
            "/api/v1/trends/statuses": .text("[]"),
        ])
    }

    // MARK: - What a look answers

    @Test("A look at a Mastodon says what it says about itself, and adds nothing")
    func aMastodonIsLookedAt() async throws {
        let store = ItemStore()
        let http = JoinTests.joinHTTP()
        let preview = try await Self.joiner(http, store).look(host: "first.example")

        #expect(preview.id == "first.example")
        #expect(preview.host == "first.example")
        #expect(preview.kind == .mastodon)
        guard case .stated(let profile) = preview.profile else {
            Issue.record("a Mastodon serving /api/v2/instance should have stated itself")
            return
        }
        #expect(profile.title == "The first server")
        #expect(profile.summary == "A server this test wrote")

        // **The promise.** Not the source, not a note, not a catalogue — a reader who looked has
        // agreed to nothing, and nothing of theirs has changed.
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
        // And neither timeline was asked for. Those are what the press buys.
        #expect(await http.paths.allSatisfy { !$0.hasPrefix("/api/v1/timelines") })
        #expect(await http.paths.allSatisfy { !$0.hasPrefix("/api/v1/trends") })
    }

    /// **The preview is every protocol's, not only the one with something to show.**
    ///
    /// A stage that appeared for a Mastodon and was skipped for a Discuz! would be the frame
    /// failing at its one job. What a Discuz! is *asked* is not what a Mastodon is asked — see
    /// the forum tests below — but it is asked, and it is previewed.
    @Test("A Discuz! is previewed like everything else, and adds nothing")
    func aDiscuzIsLookedAt() async throws {
        let store = ItemStore()
        let preview = try await Self.joiner(Self.discuzHTTP(), store).look(host: "install-c.example")

        #expect(preview.kind == .discuz)
        #expect(preview.host == "install-c.example")
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    /// **A profile that could not be read is not a host that could not be joined.**
    ///
    /// A Mastodon older than 4.0 serves no `/api/v2/instance` at all and reads its timeline
    /// perfectly. So this is a preview the reader may still subscribe from, and the second half
    /// of the test is the half that matters: the press works.
    @Test("A server with no profile to serve still previews, and still subscribes")
    func anUnreadProfileStillSubscribes() async throws {
        let store = ItemStore()
        let http = Self.mastodonHTTP(instance: .text("<html>not here</html>", status: 404))
        let join = Self.joiner(http, store)
        let preview = try await join.look(host: "old.example")

        #expect(preview.kind == .mastodon)
        #expect(preview.profile == .unread(host: "old.example", kind: .mastodon, .unreadable))
        #expect(await store.sources().isEmpty)

        #expect(try await join.begin(preview) == .joined)
        #expect(await store.sources().map(\.host) == ["old.example"])
        #expect(await store.all().count == 1)
    }

    // MARK: - The forum's index is its self-description

    /// **Ruling A.** Discuz! publishes no document about itself, so what the look asks it is not
    /// what it *says* but whether it will show a signed-out reader anything at all — the one fact
    /// about it the reader needs and the only one it can give. A forum that answers with boards
    /// reads without an account, and says so through the field Discourse's `login_required`
    /// already means.
    @Test("A forum that shows its boards to a stranger says so in the preview")
    func anOpenForumStatesThatItReads() async throws {
        let store = ItemStore()
        let http = Self.discuzHTTP()
        let preview = try await Self.joiner(http, store).look(host: "install-c.example")

        #expect(preview.kind == .discuz)
        #expect(preview.profile == .stated(SourceProfile(
            host: "install-c.example", kind: .discuz, readsWithoutAccount: true
        )))
        // The index is carried, so the press has nothing left to ask.
        #expect(preview.boards.flatMap(\.boards).map(\.fid) == [33])
        #expect(await http.paths == ["/", "/forum.php"])
        #expect(await store.sources().isEmpty, "a look still adds nothing")
    }

    /// **The affordance this ruling exists to make reachable.** A forum that turns a signed-out
    /// reader away is the normal case for Discuz!, and it was the one protocol for which the
    /// "reading this needs an account" warning could never fire — the preview was `.silent`, and
    /// nothing but a `.stated` profile can carry the field the warning reads.
    ///
    /// **It does not throw.** Throwing would put the reader exactly where they were before this
    /// ruling: told no, after a press. The press is still allowed, and still offers the sign-in.
    @Test("A forum that turns a stranger away is previewed with the warning, not refused")
    func aClosedForumIsPreviewedAndWarnedAbout() async throws {
        let store = ItemStore()
        // `install-e.example`'s shape: a complete, unchallenged index with no board on it.
        let http = FixtureHTTP([
            "/": .text(Self.discuzFront),
            "https://install-c.example/forum.php": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
            <div class="bm bmw cl"><div id="category_-99999" class="bm_c">
            <table class="fl_tb"><tr><td class="fl_g"><a href="/calendar">学年日历</a></td></tr></table>
            </div></div></body></html>
            """#),
        ])
        let join = Self.joiner(http, store)
        let preview = try await join.look(host: "install-c.example")

        #expect(preview.profile == .stated(SourceProfile(
            host: "install-c.example", kind: .discuz, readsWithoutAccount: false
        )))
        #expect(preview.boards.isEmpty)
        #expect(await store.sources().isEmpty)

        // And the press is still theirs to make, and still fails with the one error that offers
        // them a sign-in — a prediction before it, a refusal after it.
        await #expect(throws: JoinError.refused(403)) { _ = try await join.begin(preview) }
    }

    /// **Who said no decides which sentence it is.** A challenge page is a bot filter standing in
    /// front of the forum, and the forum itself said nothing at all — so recording it as
    /// `.stated(readsWithoutAccount: false)` would break `SourceProfile`'s own invariant
    /// ("never because a request failed") and assert a policy about a forum that may well read
    /// perfectly to a signed-out human. Unit 5 caches and draws that claim, so the lie would
    /// outlive the press.
    ///
    /// It is still a *warning before the press*, which is what the ruling asked for — just a
    /// different one, said in the preview's own words. See `aTurnedAwayForumWarnsDifferently`.
    @Test("A filter in front of a forum is not the forum stating its policy")
    func aChallengeIsNotAPolicy() async throws {
        let store = ItemStore()
        let http = FixtureHTTP([
            "/": .text(Self.discuzFront),
            // A challenge page reaching the index, after a front page that named the software.
            "https://install-c.example/forum.php": .text(#"""
            <!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title></head>
            <body><p>Enable JavaScript and cookies to continue</p></body></html>
            """#),
        ])
        let preview = try await Self.joiner(http, store).look(host: "install-c.example")

        #expect(preview.profile == .unread(host: "install-c.example", kind: .discuz, .refused(403)))
        #expect(preview.boards.isEmpty)
        if case .stated = preview.profile {
            Issue.record("a doorman was recorded as the forum's own claim about itself")
        }
        #expect(await store.sources().isEmpty)
    }

    /// The other half of the same split, kept beside it: the forum's **own** notice page and an
    /// index with no board this reader may see are the forum answering about itself, and an
    /// account is what would change either. Those stay `.stated`.
    @Test("The forum's own answer about its own boards is a policy, and stays stated")
    func theForumsOwnAnswerIsAPolicy() async throws {
        let notice = FixtureHTTP([
            "/": .text(Self.discuzFront),
            "https://install-c.example/forum.php": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
            <div id="ct"><div id="messagetext" class="alert_info">
            <p>抱歉，您的权限不足，无法访问本版块。</p>
            </div></div></body></html>
            """#),
        ])
        let preview = try await Self.joiner(notice, ItemStore()).look(host: "install-c.example")
        #expect(preview.profile == .stated(SourceProfile(
            host: "install-c.example", kind: .discuz, readsWithoutAccount: false
        )))
    }

    /// A status that says no "in the way a filter says it" — `DiscuzRequestError.refused`'s own
    /// words — is a doorman too, and keeps its own number rather than being flattened to 403.
    @Test("A refusing status is a doorman, and keeps the number it arrived with")
    func aRefusingStatusKeepsItsNumber() async throws {
        let http = FixtureHTTP([
            "/": .text(Self.discuzFront),
            "https://install-c.example/forum.php": .text("no", status: 429),
        ])
        let preview = try await Self.joiner(http, ItemStore()).look(host: "install-c.example")
        #expect(preview.profile == .unread(host: "install-c.example", kind: .discuz, .refused(429)))
    }

    /// **The forum is asked once per errand.** Reading the index at the look and again at the
    /// press would double this app's traffic into a stranger's forum for one button — the spend
    /// `SourceJoin` refuses in as many words.
    @Test("The press reuses the index the look read, and asks the forum nothing")
    func thePressReusesTheIndex() async throws {
        let store = ItemStore()
        let http = Self.discuzHTTP()
        let join = Self.joiner(http, store)
        let preview = try await join.look(host: "install-c.example")
        #expect(await http.paths.filter { $0 == "/forum.php" }.count == 1, "the premise")

        guard case .chooseBoards(let offer) = try await join.begin(preview) else {
            Issue.record("a Discuz! should pause for the reader to choose")
            return
        }
        #expect(offer.boards.map(\.fid) == [33])
        #expect(await http.paths.filter { $0 == "/forum.php" }.count == 1, """
            The press asked the forum for its index a second time. The look already read it and \
            `SourcePreview.boards` carries it.
            """)
    }

    /// Where the look got no index there is nothing to reuse, so the press reads it — and that
    /// read is what produces the reader's sentence and the sign-in it offers.
    @Test("A press with no carried index reads one, rather than inventing a failure")
    func thePressWithoutAnIndexReadsOne() async throws {
        let store = ItemStore()
        let http = FixtureHTTP([
            "/": .text(Self.discuzFront),
            "https://install-c.example/forum.php": .fail,
        ])
        let join = Self.joiner(http, store)
        let preview = try await join.look(host: "install-c.example")
        // A forum that did not answer is not a fact about who may read it.
        #expect(preview.profile == .unread(host: "install-c.example", kind: .discuz, .unreachable))
        #expect(preview.boards.isEmpty)

        await #expect(throws: JoinError.unreachable) { _ = try await join.begin(preview) }
    }

    /// **The difference this ruling leaves behind, pinned so it is a recorded fact.**
    /// `SourceProfiles` asks "what do you publish about yourself", which a Discuz! still answers
    /// with nothing and still costs no request. The preview asks "will you let me in", which is a
    /// different question with a different answer. They are not two opinions about one question.
    @Test("A Discuz! asked in isolation is still silent, and still costs nothing")
    func aDiscuzAnsweredInIsolationIsStillSilent() async throws {
        let http = FixtureHTTP([:])
        let answer = try await SourceProfiles(http: http)
            .answer(host: "install-c.example", kind: .discuz)
        #expect(answer == .silent(host: "install-c.example", kind: .discuz))
        #expect(await http.paths.isEmpty)
    }

    // MARK: - The two switches, held together

    /// **`reads` and the dispatcher must agree, and the compiler cannot make them.**
    ///
    /// Neither switch has a `default:`, so a protocol *added* to `ProtocolKind` breaks the build
    /// in both. That is the whole of the compiler's help. A protocol **moved between the groups**
    /// — `.lemmy` promoted in `reads` while the dispatcher still refuses it — compiles clean and
    /// leaves every other test green, and ships exactly the screen the ban on `default:` exists
    /// to prevent: a rendered preview, an outcome sentence, and a Subscribe that can only throw.
    ///
    /// Moving cases between those groups is precisely what unlocking the Mastodon family is, five
    /// times over. So the agreement is asserted rather than assumed, over `allCases` so a
    /// thirteenth protocol is covered the day it is written.
    @Test("Every protocol agrees with itself about whether it can be read")
    func everyProtocolAgreesAboutWhetherItCanBeRead() async throws {
        // Nothing is routed, so an accepted protocol fails at the wire and a refused one fails
        // before reaching it. Which of the two happened is the whole question.
        let http = FixtureHTTP([:])
        let join = Self.joiner(http, ItemStore())

        for kind in ProtocolKind.allCases {
            let preview = SourcePreview(host: "a.example", kind: kind, profile: .unasked(
                host: "a.example", kind: kind
            ))
            var dispatcherAccepts = true
            do {
                _ = try await join.begin(preview)
            } catch JoinError.unsupportedKind {
                dispatcherAccepts = false
            } catch {
                // Any other failure means the dispatcher took it and the wire refused it.
            }
            #expect(dispatcherAccepts == SourceJoin.reads(kind), """
                \(kind) is one thing to `reads` and another to the dispatcher. A protocol \
                `look` admits and `begin` refuses is a preview whose Subscribe can only throw.
                """)
        }
    }

    // MARK: - What a look refuses

    /// The same `JoinError`s `begin(host:)` throws, thrown one stage earlier.
    ///
    /// A protocol this app cannot read must be refused at the field and not at the Subscribe
    /// button: a preview whose only possible outcome is a refusal is a screen that lies.
    @Test("A look refuses what a join would refuse, and never reaches a preview")
    func aLookRefusesWhatAJoinRefuses() async throws {
        let store = ItemStore()

        let probe = #"{"version": "2.7.2 (compatible; Pleroma 2.5.0)"}"#
        let pleroma = FixtureHTTP([
            "/": .text("<html><head><title>Pleroma</title></head><body></body></html>"),
            "/api/v2/instance": .text(probe),
        ])
        await #expect(throws: JoinError.unsupportedKind(.pleroma)) {
            _ = try await Self.joiner(pleroma, store).look(host: "pleroma.example")
        }

        let dead = FixtureHTTP(["/": .fail, "/api/v2/instance": .fail])
        await #expect(throws: JoinError.invalidHost) {
            _ = try await Self.joiner(dead, store).look(host: "http://first.example")
        }
        await #expect(throws: JoinError.unreachable) {
            _ = try await Self.joiner(dead, store).look(host: "gone.example")
        }

        #expect(await store.sources().isEmpty)
    }

    /// **A reader who walked away is not a server that would not answer.** The look is the one
    /// request a reader is most likely to abandon — they typed a host and thought better of it —
    /// and recording that as a fact about the host would be a lie the next preview repeats.
    @Test("A look the reader walked away from leaves, and says nothing about the host")
    func aCancelledLookLeaves() async throws {
        let store = ItemStore()
        let http = Self.mastodonHTTP(instance: .cancelled)
        await #expect(throws: CancellationError.self) {
            _ = try await Self.joiner(http, store).look(host: "old.example")
        }
        #expect(await store.sources().isEmpty)
    }

    // MARK: - What the press does with a preview

    @Test("The press on a Discuz! preview pauses at the boards, and still adds nothing")
    func theDiscuzPressPauses() async throws {
        let store = ItemStore()
        let http = Self.discuzHTTP()
        let join = Self.joiner(http, store)
        let preview = try await join.look(host: "install-c.example")

        guard case .chooseBoards(let offer) = try await join.begin(preview) else {
            Issue.record("a Discuz! should pause for the reader to choose")
            return
        }
        #expect(offer.host == "install-c.example")
        #expect(offer.kind == .discuz)
        #expect(offer.boards.map(\.fid) == [33])

        // Three stages, and the store is still untouched after the second of them.
        #expect(await store.sources().isEmpty)
        #expect(await store.all().isEmpty)
    }

    /// **The press asks nobody what the host is a second time.** The preview carries the kind, so
    /// the whole errand costs one detection — `SourceJoin`'s standing rule, at the new door.
    @Test("The press detects nothing again: the preview already carries what the host speaks")
    func thePressDoesNotDetectAgain() async throws {
        let store = ItemStore()
        let http = Self.discuzHTTP()
        let join = Self.joiner(http, store)
        let preview = try await join.look(host: "install-c.example")
        #expect(
            await http.paths.filter { $0 == "/" }.count == 1,
            "the premise: detection is one request to the front page"
        )

        _ = try await join.begin(preview)
        #expect(await http.paths.filter { $0 == "/" }.count == 1)
    }

    /// **The preview carries no client, and this is what that is for.**
    ///
    /// Between the look and the press the reader can be offered a sign-in and take it, and the
    /// transport they cleared the challenge in did not exist when they looked. So the press runs
    /// on a `SourceJoin` built *then* — a different object from the one that looked — and the
    /// preview has to be enough on its own for that to work.
    ///
    /// **Shown on the refused path, which is the one this rule is actually for.** A forum that
    /// answered the look carries its index in the preview and the press asks nothing at all; it
    /// is precisely the forum that turned the reader away that sends them to sign in, and whose
    /// press then has to read an index through the engine they signed in to.
    @Test("A preview refused at the look is taken through the transport that came after it")
    func aPreviewSurvivesItsJoiner() async throws {
        let closed = FixtureHTTP([
            "/": .text(Self.discuzFront),
            "https://install-c.example/forum.php": .text(#"""
            <html><head><meta name="generator" content="Discuz! X3.4" /></head><body>
            <div id="ct"><div id="messagetext" class="alert_info">
            <p>抱歉，您的权限不足，无法访问本版块。</p>
            </div></div></body></html>
            """#),
        ])
        let preview = try await Self.joiner(closed, ItemStore()).look(host: "install-c.example")
        #expect(preview.profile == .stated(SourceProfile(
            host: "install-c.example", kind: .discuz, readsWithoutAccount: false
        )), "the premise: the look was turned away, so it carries no index")

        // The engine the reader signed in with, standing in as a second transport entirely.
        let store = ItemStore()
        let signedIn = Self.discuzHTTP()
        guard case .chooseBoards(let offer) = try await Self.joiner(signedIn, store).begin(preview)
        else {
            Issue.record("the press on the signed-in transport should reach the boards")
            return
        }
        #expect(offer.boards.map(\.fid) == [33])
        // The second transport did the reading, and it never asked what the host was.
        #expect(await signedIn.paths == ["/forum.php"])
        #expect(await store.sources().isEmpty)
    }
}
