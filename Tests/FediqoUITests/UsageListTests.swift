import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #234: Usage reads as a list of sources, each opening what it holds; its long explanations are
/// short lines with a (?), its actions are icons, and no tab holds a list and a setting together.
@Suite("Usage says the least first", .serialized)
@MainActor
struct UsageListTests {
    private static let mastodon = Source(host: "mastodon.example", kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)

    private func makeSession() -> ShellSession {
        let session = ShellSession(http: FixtureHTTP())
        session.sources = [Self.mastodon, Self.forum]
        return session
    }

    @Test("Entering a source opens its detail, and Escape's close goes back to the list once")
    func detailOpensAndCloses() {
        let session = makeSession()
        #expect(session.usageOpened == nil)
        #expect(!session.closeUsageSource(), "nothing open is not a press Escape spends")
        session.usageOpened = Self.forum.host
        #expect(session.usageDetailShown)
        #expect(session.closeUsageSource())
        #expect(session.usageOpened == nil)
        #expect(session.usageReturning == Self.forum.host, "the list lights the row that was opened")
    }

    @Test("A detail not on screen is not shown, and Escape is not spent on it")
    func hiddenDetailIsNotShown() {
        let session = makeSession()
        session.usageOpened = "gone.example"
        #expect(!session.usageDetailShown, "a host no longer joined")
        #expect(!session.closeUsageSource())

        session.usageOpened = Self.mastodon.host
        session.usagePurpose = .time
        #expect(!session.usageDetailShown, "the Time tab draws no detail")
        #expect(!session.closeUsageSource())
    }

    @Test("Moving to another tab leaves the detail behind")
    func rotationClosesTheDetail() {
        let session = makeSession()
        session.usageOpened = Self.mastodon.host
        session.rotateUsageTab(by: 1)
        #expect(session.usageOpened == nil)
        session.rotateUsageTab(by: -1)
        #expect(session.usagePurpose == .source)
        #expect(!session.usageDetailShown)
    }

    @Test("Removing a source leaves its detail, so adding it again opens on the list")
    func removalClosesTheDetail() async {
        let session = makeSession()
        session.usageOpened = Self.forum.host
        await session.remove(host: "Forum.Example")
        #expect(session.usageOpened == nil)
        session.sources = [Self.mastodon, Self.forum]
        #expect(!session.usageDetailShown)
    }

    @Test("Leaving Usage for another place leaves the detail behind")
    func placeChangeClosesTheDetail() throws {
        let root = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/FediqoUI/FediqoRootView.swift"),
            encoding: .utf8
        )
        let change = try #require(root.range(of: ".onChange(of: place) {"))
        let next = try #require(root.range(of: ".onChange(of: availability)", range: change.upperBound..<root.endIndex))
        #expect(root[change.upperBound..<next.lowerBound].contains("session.usageOpened = nil"))
    }

    @Test("Every short line is one line, in both languages, with its long explanation behind it")
    func shortLinesHaveTheirHelp() {
        let pairs = [
            ("usage.cache.line", "prefs.cache.footer"),
            ("usage.drop.line", "prefs.drop.footer"),
            ("usage.gone.line", "prefs.gone.footer"),
            ("usage.empty.detail", "usage.empty.help"),
        ]
        for (line, help) in pairs {
            for language in [DummyLanguage.english, .taiwanese] {
                let short = L10n.t(line, language: language)
                let long = L10n.t(help, language: language)
                #expect(short != line && long != help, "\(line) or \(help) is missing in \(language)")
                #expect(short.count <= 80, "\(line) is not short in \(language): \(short)")
                #expect(long.count > short.count, "\(help) says less than \(line)")
            }
        }
        for key in ["usage.source.back", "usage.tab.keep"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    @Test("The long explanations are drawn only behind a (?), and every action is an icon")
    func footersAndActions() throws {
        let files = try ["UsagePane", "UsageSources", "GoneSection", "SpanSection", "KeptSection", "LimitAccountSection"]
            .map(Self.source)
        let all = files.joined()
        for (line, help) in [
            ("usage.cache.line", "prefs.cache.footer"), ("usage.drop.line", "prefs.drop.footer"),
            ("usage.gone.line", "prefs.gone.footer"), ("usage.span.line", "prefs.span.footer"),
        ] {
            #expect(all.contains("line: \"\(line)\", help: \"\(help)\")"), "\(help) is not behind its heading's (?)")
            #expect(!all.contains("L10n.t(\"\(help)\")"), "\(help) is still drawn inline")
        }
        // The questions' own buttons are #238's. Every press on the page that takes something
        // away is an item of a `…`, named there, and never a button of its own.
        for name in [
            "prefs.cache.clear", "prefs.password.forget", "prefs.drop.copies", "prefs.gone.now", "usage.span.now",
            "usage.kept.stop.from", "prefs.limits.clear",
        ] {
            #expect(all.contains("L10n.t(\"\(name)\", language: language)"), "\(name) is not offered")
            #expect(!all.contains("name: \"\(name)\""), "\(name) is still a button of its own")
            #expect(!all.contains("Button(L10n.t(\"\(name)\")"), "\(name) is a text button")
        }
        #expect(!all.contains("ShellIconButton("), "Usage draws a button of its own")
        #expect(!all.contains(".shellConfirm($asking") && !all.contains("droppingCopies"), "a question is put outside a …")
    }

    // MARK: - The list row (quiet rows, U7)

    @Test("A source's row is given its host and nothing else to draw, cut in its middle")
    func rowDrawsOnlyTheHost() throws {
        let sources = try Self.source("UsageSources")
        let list = try #require(sources.range(of: "struct UsageSourceList"))
        let detail = try #require(sources.range(of: "struct UsageRemovedSourceDetail"))
        let body = sources[list.upperBound..<detail.lowerBound]
        #expect(body.components(separatedBy: "ShellListRow(").count == 2, "here and removed are not one row")
        #expect(!body.contains("brief:") && !body.contains("figure:"), "the row is handed a second line or a figure")
        #expect(body.contains("cut: .middle"), "a long host is not cut in its middle")
    }

    @Test("VoiceOver still hears what the row stopped drawing")
    func rowSaysItsFigures() {
        let session = makeSession()
        let here = UsageSourceList.spoken(Self.mastodon, in: session, onDisk: ["mastodon.example": 4096], removed: false)
        #expect(here == [
            Self.mastodon.host, UsagePane.postsLine(0),
            UsagePane.picturesLine(Self.mastodon, in: session, onDisk: ["mastodon.example": 4096]),
        ].joined(separator: L10n.t("mark.dim.names")))
        #expect(L10n.t("mark.dim.names", language: .taiwanese) == "、", "the row is joined as English joins")

        let gone = Source(host: "gone.example", kind: .mastodon)
        let removed = UsageSourceList.spoken(gone, in: session, onDisk: nil, removed: true)
        #expect(removed == [gone.host, L10n.t("item.left"), UsagePane.postsLine(0)].joined(separator: L10n.t("mark.dim.names")))
    }

    @Test("A row with only its host draws at every width, and as tall as one with a brief",
          arguments: [CGFloat(200), 360, 900])
    func rowDrawsAtEveryWidth(_ width: CGFloat) throws {
        let long = "a-very-long-subdomain-of-a-server.with-a-long-name.example.social"
        func height(_ face: ShellListRowFace<Image>, _ size: DynamicTypeSize) throws -> Int {
            let renderer = ImageRenderer(content: face.dynamicTypeSize(size).frame(width: width))
            return try #require(renderer.cgImage).height
        }
        for size in [DynamicTypeSize.large, .accessibility5] {
            let mark = Image(systemName: "server.rack")
            let host = ShellListRowFace(title: long, brief: nil, figure: nil, cut: .middle, selected: false, mark: mark)
            let full = ShellListRowFace(title: "a.example", brief: "b", figure: nil, selected: false, mark: mark)
            let (alone, briefed) = (try height(host, size), try height(full, size))
            #expect(alone == briefed, "\(size) at \(width)")
        }
    }

    // MARK: - The detail's `…` (quiet rows, U7)

    private func holding(_ host: String) throws -> (ShellSession, ForumSessions) {
        let credentials = MemoryCredentials()
        try credentials.save(ForumCredential(host: host, username: "u", password: "p"))
        let forums = ForumSessions(credentials: credentials)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        session.sources = [Self.mastodon, Self.forum]
        return (session, forums)
    }

    @Test("A source's detail holds Clear and Forget password behind …, both destructive",
          arguments: [DummyLanguage.english, .taiwanese])
    func detailMore(_ language: DummyLanguage) throws {
        let (session, _) = try holding(Self.forum.host)
        let more = UsageSourceDetail.more(Self.forum, in: session, language: language)
        #expect(more.items.map(\.symbol) == ["eraser", "key.slash"])
        #expect(more.items.map(\.name) == [
            L10n.t("prefs.cache.clear", language: language), L10n.t("prefs.password.forget", language: language),
        ])
        #expect(more.ordinary.isEmpty && more.dangers.count == 2 && !more.divides)
        #expect(more.head.isEmpty)
        #expect(more.items.map(\.answers) == [true, true])
        #expect(more.label(language: language) == L10n.t("mark.more", language: language))
    }

    @Test("On a forum that could hold a password and holds none, the head says none is saved",
          arguments: [DummyLanguage.english, .taiwanese])
    func forgetSaysNoneIsSaved(_ language: DummyLanguage) {
        let more = UsageSourceDetail.more(Self.forum, in: makeSession(), language: language)
        #expect(more.head == [L10n.t("prefs.password.none", language: language)])
        #expect(more.head.first != "prefs.password.none")
        let forget = more.items[1]
        #expect(forget.look == .dim(.notNow) && !forget.answers)
        // The head has said why, in its own words; the item is its name alone.
        #expect(forget.title(language: language) == L10n.t("prefs.password.forget", language: language))
        #expect(!forget.title(language: language).contains(L10n.t("mark.dim.never", language: language)))
        var put: [ShellMoreAsk] = []
        forget.press { put.append($0) }
        #expect(put.isEmpty)
        #expect(UsageSourceDetail.savesPassword(.discuz) && !UsageSourceDetail.savesPassword(.mastodon))
    }

    @Test("Forget password is dim on a kind that saves none, and then neither asks nor acts")
    func forgetIsDimWhereNoneIsHeld() {
        let session = makeSession()
        #expect(UsageSourceDetail.more(Self.mastodon, in: session, language: .english).head.isEmpty)
        let forget = UsageSourceDetail.more(Self.mastodon, in: session, language: .english).items[1]
        #expect(forget.look == .dim(.never))
        #expect(!forget.answers)
        #expect(forget.title(language: .english) == "Forget the password. " + L10n.t("mark.dim.never", language: .english))
        var put: [ShellMoreAsk] = []
        forget.press { put.append($0) }
        #expect(put.isEmpty)
    }

    @Test("Forget password asks its own question first, and only the yes forgets")
    func forgetAsksFirst() throws {
        let (session, forums) = try holding(Self.forum.host)
        let forget = UsageSourceDetail.more(Self.forum, in: session).items[1]
        #expect(forget.look == .live)
        var put: [ShellMoreAsk] = []
        forget.press { put.append($0) }
        let ask = try #require(put.first)
        #expect(ask.question == ShellQuestion.forgetPassword(host: Self.forum.host))
        #expect(ask.question.warns, "a password does not come back")
        #expect(forums.hasPassword(host: Self.forum.host), "asking forgot it")

        ask.answered("something else")
        #expect(forums.hasPassword(host: Self.forum.host))
        ask.answered(ShellQuestion.yes)
        #expect(!forums.hasPassword(host: Self.forum.host))
        #expect(UsageSourceDetail.more(Self.forum, in: session).items[1].look == .dim(.notNow))
    }

    @Test("Clear asks the question Account's Clear asks, and only the yes clears")
    func clearAsksFirst() async throws {
        let (session, forums) = try holding(Self.forum.host)
        let clear = UsageSourceDetail.more(Self.forum, in: session).items[0]
        var put: [ShellMoreAsk] = []
        clear.press { put.append($0) }
        let ask = try #require(put.first)
        #expect(put.count == 1, "one press put more than one question")
        #expect(ask.question == session.clearQuestion(host: Self.forum.host))
        #expect(ask.question.warns, "a saved password goes with this Clear")
        #expect(session.cleared == 0 && forums.hasPassword(host: Self.forum.host), "asking cleared something")

        ask.answered(ShellQuestion.yes)
        for _ in 0..<200 where session.cleared == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.cleared == 1)
        #expect(!forums.hasPassword(host: Self.forum.host))
    }

    @Test("A removed source's detail has nothing to do, and draws no …")
    func removedDetailHasNoMore() throws {
        let sources = try Self.source("UsageSources")
        let removed = try #require(sources.range(of: "struct UsageRemovedSourceDetail"))
        let detail = try #require(sources.range(of: "struct UsageSourceDetail"))
        let body = sources[removed.upperBound..<detail.lowerBound]
        #expect(!body.contains("ShellMore") && !body.contains("trailing:"))
        #expect(body.contains("\"item.left\"") && body.contains("\"usage.removed.line\""), "the detail no longer says it left")
        #expect(sources[detail.upperBound...].contains("ShellMoreButton(Self.more(source, in: session))"))
    }

    @Test("The password line is a line, with no press beside it")
    func passwordIsALine() throws {
        let sources = try Self.source("UsageSources")
        let line = try #require(sources.range(of: "private var passwordLine: some View {"))
        let next = try #require(sources.range(of: "private func reading", range: line.upperBound..<sources.endIndex))
        let body = sources[line.upperBound..<next.lowerBound]
        #expect(body.contains("\"prefs.password.held\"") && !body.contains("Button") && !body.contains("HStack"))
    }

    @Test("No tab holds a list and a setting together")
    func oneStyleATab() throws {
        let pane = try Self.source("UsagePane")
        let sources = try Self.source("UsageSources")
        #expect(!sources.contains("Picker(") && !sources.contains("Toggle("), "the sources list holds a setting")
        let page = try #require(pane.range(of: "switch session.usagePurpose"))
        let time = try #require(pane.range(of: "case .time:", range: page.upperBound..<pane.endIndex))
        let keep = try #require(pane.range(of: "case .keep:", range: time.upperBound..<pane.endIndex))
        let copies = try #require(pane.range(of: "case .copies:", range: keep.upperBound..<pane.endIndex))
        #expect(pane[time.upperBound..<keep.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines) == "breakdown(session)")
        let keeping = pane[keep.upperBound..<copies.lowerBound]
        #expect(keeping.contains("keep") && keeping.contains("GoneSection"))
    }

    @Test("A source's pictures read as one line, with the disk half only once it has been read")
    func picturesLine() {
        #expect(UsagePane.picturesLine(count: 0, bytes: 0, disk: nil) == L10n.t("prefs.cache.pictures.none"))
        #expect(UsagePane.picturesLine(count: 2, bytes: 2048, disk: nil).components(separatedBy: " · ").count == 2)
        #expect(UsagePane.picturesLine(count: 2, bytes: 2048, disk: 4096).components(separatedBy: " · ").count == 3)
        let line = UsagePane.picturesLine(Self.mastodon, in: makeSession(), onDisk: ["mastodon.example": 0])
        #expect(line.components(separatedBy: " · ").count == 2, "nothing in memory, and the disk read: \(line)")
    }

    @Test("The list, a detail and the empty page draw, light and dark, at the largest size",
          arguments: [ColorScheme.light, .dark])
    func draws(_ scheme: ColorScheme) throws {
        let session = makeSession()
        let views: [AnyView] = [
            AnyView(UsageSourceList(session: session, onDisk: nil, returning: Self.forum.host)),
            AnyView(UsageSourceDetail(
                session: session, source: Self.forum, catalogue: nil, cataloguesRead: true, onDisk: [:]
            )),
            AnyView(UsageRemovedSourceDetail(session: session, source: Source(host: "gone.example", kind: .discuz))),
            AnyView(ShellNotice(symbol: "chart.bar.xaxis", title: "Nothing kept yet", detail: "Add a source.",
                                help: "The rest.")),
        ]
        for view in views {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let renderer = ImageRenderer(
                    content: VStack { view }
                        .environment(\.colorScheme, scheme)
                        .dynamicTypeSize(size)
                        .frame(width: 360)
                        .background(ShellChrome.page(scheme))
                )
                let image = try #require(renderer.cgImage)
                #expect(image.width > 0 && image.height > 0)
            }
        }
    }

    private static func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/FediqoUI/Shell/\(name).swift"),
            encoding: .utf8
        )
    }
}
