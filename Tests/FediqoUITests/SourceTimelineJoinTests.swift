import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #372: a joined source's page offers to join the timelines already written — the join's last
/// step, opened later — greyed with the same icon where none of them can take it now.
@MainActor
@Suite("Joining the timelines from a source's page")
struct SourceTimelineJoinTests {
    private static let host = "social.example"
    private static let forum = "forum.example"
    private static let a = "a.example"
    private static let friends = ListSubscription(id: "42", name: "Friends")

    init() {
        L10n.language = .english
    }

    /// A timeline written before the source came: A's public.
    private static func onlyA() -> TimelineDefinition {
        TimelineDefinition(name: "Mine", rules: [
            Rule.source(a)!, Rule.category(.public, in: .source(host: a), sources: [Source(host: a, kind: .mastodon)])!,
        ])
    }

    /// A Mastodon and a forum joined, signed in to the Mastodon or not, its lists as given.
    private func joined(signedIn: Bool, lists: [ListSubscription] = []) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        if signedIn {
            try tokens.save(MastodonToken(host: Self.host, accessToken: "tok-1", clientID: "c", clientSecret: "s"))
        }
        let store = ItemStore()
        await store.add(Source(host: Self.host, kind: .mastodon, lists: lists))
        await store.add(Source(host: Self.forum, kind: .discourse))
        let session = ShellSession(
            http: FixtureHTTP(), store: store, mastodon: MastodonSessions(tokens: tokens, sender: Refusing())
        )
        session.mastodon.refresh()
        await session.reloadFromStore()
        return session
    }

    private func offered(_ session: ShellSession) -> [FediqoCore.Category] {
        session.timelineJoinOffers(host: Self.host).first?.divisions.map(\.category) ?? []
    }

    @Test("The entry opens the same chooser for that source, from its page")
    func opensTheChooser() async throws {
        let session = try await joined(signedIn: false)
        session.written = [Self.onlyA()]
        session.openSource(host: Self.host)
        let mark = SourceSettings.joinMark(host: Self.host, in: session, language: .english)
        #expect(mark.look == .live && mark.symbol == TimelineJoinEntry.symbol)
        session.openTimelineJoin(host: Self.host)
        guard case .joiningTimelines(let choice) = session.stage else {
            Issue.record("the chooser did not open: \(String(describing: session.stage))")
            return
        }
        #expect(choice.host == Self.host && choice.offers.map(\.name) == ["Mine"])
    }

    @Test("Nothing to join: greyed with the same icon, saying no timeline can take it, and its press opens nothing")
    func greyedWhenNothingOffered() async throws {
        let session = try await joined(signedIn: false)
        session.openSource(host: Self.forum)
        let mark = SourceSettings.joinMark(host: Self.forum, in: session, language: .english)
        #expect(mark.look == .dim(.noTimeline) && mark.symbol == TimelineJoinEntry.symbol)
        #expect(mark.spoken == "Join timelines. None of your timelines can take it")
        #expect(ShellMark.press(mark.look) == .nothing)
        let stage = session.stage
        session.openTimelineJoin(host: Self.forum)
        #expect(session.stage == stage, "a greyed entry opened something")
    }

    @Test("A written timeline that hides the source leaves its entry greyed, while the same timeline lights another source's")
    func greyedWithAWrittenTimeline() async throws {
        let session = try await joined(signedIn: false)
        let onlyA = TimelineDefinition(name: "A", rules: [Rule.source(Self.a)!])
        session.written = [onlyA]
        #expect(SourceSettings.joinMark(host: Self.forum, in: session).look == .live, "the premise: the forum would get in whole")

        let hidesForum = TimelineDefinition(
            name: "A, no forum", rules: [Rule.source(Self.a)!, Rule.source(Self.forum, effect: .exclude)!]
        )
        session.written = [hidesForum]
        #expect(SourceSettings.joinMark(host: Self.forum, in: session).look == .dim(.noTimeline))
        session.openSource(host: Self.forum)
        let stage = session.stage
        session.openTimelineJoin(host: Self.forum)
        #expect(session.stage == stage, "a greyed entry opened something")
        session.dismissStage()

        #expect(SourceSettings.joinMark(host: Self.host, in: session).look == .live, "the same timeline takes the Mastodon whole")
        session.openTimelineJoin(host: Self.host)
        guard case .joiningTimelines(let choice) = session.stage else {
            Issue.record("the Mastodon's entry opened nothing")
            return
        }
        #expect(choice.offers.map(\.name) == ["A, no forum"] && choice.offers[0].divisions.isEmpty)
    }

    @Test("Every joined source has its gear, one with no other part too; a source not joined has none")
    func everyJoinedSourceHasItsGear() async throws {
        let session = try await joined(signedIn: false)
        #expect(SourceSettings.parts(host: Self.forum, in: session).isEmpty, "the premise: a forum has no other part")
        #expect(SourceSettingsGear.shows(host: Self.forum, in: session))
        #expect(SourceSettingsGear.shows(host: Self.host, in: session))
        #expect(!SourceSettingsGear.shows(host: "elsewhere.example", in: session))
    }

    @Test("Home is offered once signed in, and a list once chosen")
    func homeAndLists() async throws {
        let out = try await joined(signedIn: false)
        out.written = [Self.onlyA()]
        #expect(offered(out) == [.public])

        let signed = try await joined(signedIn: true)
        signed.written = [Self.onlyA()]
        #expect(offered(signed).contains(.home))

        let listed = try await joined(signedIn: true, lists: [Self.friends])
        listed.written = [Self.onlyA()]
        #expect(offered(listed).contains(.list(id: Self.friends.id)))
    }

    @Test("The page lays out with the entry, live and greyed, at 420, 390 and 320 at the largest text, in light and in dark", arguments: 0..<2)
    func laidOut(_ dark: Int) async throws {
        let session = try await joined(signedIn: false)
        session.written = [Self.onlyA()]
        for host in [Self.host, Self.forum] {
            for (width, size) in HostedFit.rooms {
                let page = SourceSettingsPage(host: host, session: session, onBack: {})
                #expect(HostedFit.fits(page, width: width, height: 900, scheme: HostedFit.scheme(dark), size: size), "\(host) at \(width)")
                let entry = TimelineJoinEntry(host: host, session: session)
                #expect(HostedFit.fits(entry, width: width, scheme: HostedFit.scheme(dark), size: size), "the entry for \(host) at \(width)")
            }
        }
    }

    @Test("The entry's words, hint and the reason it is greyed are in every language")
    func sentences() {
        for language in DummyLanguage.allCases {
            for said in [
                L10n.t("source.settings.join", language: language), TimelineJoinEntry.hint(language: language),
                L10n.t(DimReason.noTimeline.key, language: language),
            ] {
                #expect(!said.isEmpty && !said.hasPrefix("source.settings") && !said.hasPrefix("mark.dim"), "missing in \(language)")
            }
        }
        #expect(TimelineJoinEntry.hint(language: .english) == "Choose which of your timelines this source joins")
    }
}

/// A signed-in door that answers every request with a refusal.
private struct Refusing: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }
}
