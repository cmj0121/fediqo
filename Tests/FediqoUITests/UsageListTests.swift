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
        for key in ["usage.gone.now.help", "usage.source.back", "usage.source.clear.help", "usage.drop.copies.help", "usage.tab.keep"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    @Test("The long explanations are drawn only behind a (?), and every action is an icon")
    func footersAndActions() throws {
        let files = try ["UsagePane", "UsageSources", "GoneSection"].map(Self.source)
        let all = files.joined()
        for (line, help) in [
            ("usage.cache.line", "prefs.cache.footer"), ("usage.drop.line", "prefs.drop.footer"),
            ("usage.gone.line", "prefs.gone.footer"),
        ] {
            #expect(all.contains("UsageFooter(line: \"\(line)\", help: \"\(help)\""), "\(help) is not behind a (?)")
            #expect(!all.contains("L10n.t(\"\(help)\")"), "\(help) is still drawn inline")
        }
        // The questions' own buttons are #238's; every press on the page itself is an icon.
        for name in ["prefs.cache.clear", "prefs.drop.copies", "prefs.password.forget", "prefs.gone.now"] {
            #expect(all.contains("name: \"\(name)\""), "\(name) is not an icon button")
            #expect(!all.contains("Button(L10n.t(\"\(name)\")"), "\(name) is still a text button")
        }
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
