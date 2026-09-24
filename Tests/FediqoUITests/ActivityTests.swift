import AVFoundation
import FediqoCore
import Foundation
import Observation
import SwiftUI
import Testing
@testable import FediqoUI

/// #218: every outward act of this run can be watched — which source, when, and what for — newest
/// first, narrowed to one source, and never more of a request than a host.
///
/// Every test builds its own `SourceWork` and hands it to the object under test, so nothing here
/// reads or writes the app's shared one.
@MainActor
@Suite("This run's requests")
struct ActivityTests {
    private static let source = "one.example"

    /// The record as source, reached host and purpose, oldest first.
    private static func record(_ work: SourceWork) -> [String] {
        work.record.map { "\($0.source) \($0.reached) \($0.purpose.rawValue)" }
    }

    // MARK: - The record

    @Test("A piece of work is written to the record as it starts, and stays after it ends")
    func startsAndStays() {
        let work = SourceWork()
        let token = work.begin(host: "One.Example", for: .timeline)
        #expect(Self.record(work) == ["one.example one.example timeline"])
        work.end(token)
        #expect(work.now.isEmpty, "the running list is still now only")
        #expect(Self.record(work) == ["one.example one.example timeline"], "the record forgot an act that ended")
    }

    @Test("A request is recorded by its host and a word, and nothing past the host reaches a line")
    func onlyTheHost() async throws {
        let work = SourceWork()
        let address = "https://one.example/api/v1/timelines/list/987654?max_id=9&access_token=s3cret"
        let client = WatchedHTTP(FixtureHTTP([address: .text("[]")]), for: .timeline, in: work)
        _ = try await client.data(from: URL(string: address)!)
        let act = try #require(work.record.first)
        #expect(act.source == Self.source)
        #expect(act.reached == Self.source)
        for language in [DummyLanguage.english, .taiwanese] {
            let said = [act.source, act.purposeText(language: language), act.time(language: language),
                        act.spoken(language: language)].joined(separator: " ")
            for leak in ["/api", "timelines", "987654", "max_id", "s3cret", "https"] {
                #expect(!said.contains(leak), "\(leak) reached a line in \(language)")
            }
        }
        // What an act holds is a host, a host, a word, a time and which fixed entry let it
        // through (#220): no field could carry more.
        let held = Mirror(reflecting: act).children.map { "\($0.label ?? "")" }
        #expect(held == ["id", "source", "reached", "purpose", "at", "allowedBy"])
    }

    @Test("A request that fails, or is sent rather than fetched, is recorded all the same")
    func everyKindOfRequest() async {
        let work = SourceWork()
        let failing = WatchedHTTP(FixtureHTTP(["/x": .fail]), for: .search, in: work)
        _ = try? await failing.data(from: URL(string: "https://one.example/x")!)
        let sending = WatchedHTTP(sender: RefusingSender(), for: .write, in: work)
        _ = try? await sending.send(URLRequest(url: URL(string: "https://two.example/api/v1/statuses")!))
        #expect(Self.record(work) == [
            "one.example one.example search", "two.example two.example write",
        ])
    }

    @Test("What the page draws follows the record as it grows")
    func thePageFollows() async {
        let work = SourceWork()
        work.note(host: Self.source, for: .page)
        #expect(await spun { work.log.acts.map(\.source) == [Self.source] }, "the page never saw it")
        work.note(host: "two.example", for: .page)
        #expect(await spun { work.log.acts.count == 2 })
    }

    @Test("The record is bounded, cut in one chunk past its bound, and counts what went")
    func bounded() {
        let log = SourceRecord()
        let start = Date(timeIntervalSince1970: 0)
        func acts(_ range: Range<Int>) -> [SourceAct] {
            range.map { SourceAct(id: $0, reached: "h\($0 % 3).example", purpose: .picture, at: start) }
        }
        log.append(acts(0..<SourceRecord.kept))
        #expect(log.acts.count == SourceRecord.kept, "nothing goes up to the bound")
        #expect(log.dropped == 0)
        log.append(acts(SourceRecord.kept..<(SourceRecord.kept + 3)))
        #expect(log.acts.count == SourceRecord.trimmedTo)
        #expect(log.dropped == SourceRecord.kept + 3 - SourceRecord.trimmedTo)
        #expect(log.acts.first?.id == SourceRecord.kept + 3 - SourceRecord.trimmedTo, "the oldest went first")
        #expect(log.acts.last?.id == SourceRecord.kept + 2)
        #expect(log.listed(from: "h0.example").allSatisfy { $0.source == "h0.example" })
        #expect(log.listed(from: "h0.example").count + log.listed(from: "h1.example").count
            + log.listed(from: "h2.example").count == SourceRecord.trimmedTo, "the index was cut with it")
        #expect(L10n.count("activity.dropped", 3, language: .english).contains("3"))
    }

    @Test("An act with no host reached nowhere, and is not written")
    func noHost() {
        let work = SourceWork()
        work.note(host: "", for: .video, source: Self.source)
        let token = work.begin(host: "", for: .timeline)
        work.end(token)
        #expect(work.record.isEmpty)
    }

    // MARK: - Newest first, and one source

    @Test("Lines are newest first, and narrowing to one source shows its lines and no other")
    func narrowing() {
        let start = Date(timeIntervalSince1970: 1_000)
        let log = SourceRecord()
        log.append([
            SourceAct(id: 1, reached: "one.example", purpose: .timeline, at: start),
            SourceAct(id: 2, reached: "cdn.example", pointedBy: "One.Example", purpose: .picture, at: start),
        ])
        log.append([
            SourceAct(id: 3, reached: "two.example", purpose: .conversation, at: start.addingTimeInterval(1)),
            SourceAct(id: 4, reached: "one.example", purpose: .search, at: start.addingTimeInterval(2)),
        ])
        #expect(log.listed().map(\.id) == [4, 3, 2, 1])
        #expect(log.listed(from: "one.example").map(\.id) == [4, 2, 1])
        #expect(log.listed(from: "TWO.example").map(\.id) == [3])
        #expect(log.listed(from: "cdn.example").isEmpty, "a pointed-to host is not a source")
        #expect(log.sources == ["one.example", "two.example"])
    }

    @Test("A page narrowed to one source is woken when a line of that source arrives")
    func narrowedFollows() {
        let log = SourceRecord()
        let start = Date(timeIntervalSince1970: 0)
        log.append([SourceAct(id: 1, reached: "one.example", purpose: .timeline, at: start)])
        let woken = Woken()
        withObservationTracking {
            _ = log.listed(from: "one.example")
        } onChange: {
            woken.flag()
        }
        log.append([SourceAct(id: 2, reached: "one.example", purpose: .search, at: start)])
        #expect(woken.was, "the narrowed page never heard of the new line")
        #expect(log.listed(from: "one.example").map(\.id) == [2, 1])
    }

    @Test("A chosen source the record no longer holds is let go of")
    func aChoiceThatWent() {
        #expect(ActivityPanel.stillChosen("one.example", among: ["one.example", "two.example"]) == "one.example")
        #expect(ActivityPanel.stillChosen("gone.example", among: ["one.example"]) == nil)
        #expect(ActivityPanel.stillChosen(nil, among: ["one.example"]) == nil)
    }

    // MARK: - Who it is listed under

    @Test("An act is listed under the source that pointed to it, and a blank pointer is none")
    func attribution() {
        #expect(SourceAct.attributed(reached: "CDN.example", pointedBy: "One.Example") == "one.example")
        #expect(SourceAct.attributed(reached: "CDN.example", pointedBy: nil) == "cdn.example")
        #expect(SourceAct.attributed(reached: "cdn.example", pointedBy: "  ") == "cdn.example")
    }

    @Test("A picture kept on another host is listed under the source whose row asked for it")
    func aPicture() async {
        let work = SourceWork()
        let pictures = ShellPictures(http: FixtureHTTP(["/a.png": .fail]), enforcingViewerContract: false)
        pictures.work = work
        await pictures.fetch(
            URL(string: "https://cdn.example/a.png?sig=abc"), scale: 2, tier: .deck, host: Self.source
        )
        #expect(Self.record(work) == ["one.example cdn.example picture"])
    }

    @Test("An emoji kept on another host is listed under the source whose line asked for it")
    func anEmoji() async {
        let work = SourceWork()
        let cache = EmojiCache(http: FixtureHTTP(["/wave.png": .fail]))
        cache.work = work
        let wave = CustomEmoji(shortcode: "wave", url: URL(string: "https://files.example/wave.png")!)
        await cache.fetch(EmojiCache.Request(
            emojis: [wave], metrics: .init(side: 20, baseline: -4), scale: 2, host: "One.Example",
            still: false
        ))
        #expect(Self.record(work) == ["one.example files.example emoji"])
    }

    @Test("A page opened from a post is listed under that post's source, each place it goes")
    func aPage() {
        let work = SourceWork()
        let reader = ShellReader()
        reader.work = work
        #expect(reader.open(URL(string: "https://blog.example/2026/09/a-post?ref=x")!, from: Self.source))
        // What the web view asks as it loads: the page, a frame inside it, a refused move, a
        // redirect onward.
        #expect(reader.decide(URL(string: "https://blog.example/2026/09/a-post?ref=x")!, mainFrame: true))
        #expect(reader.decide(URL(string: "https://ads.example/frame")!, mainFrame: false))
        #expect(!reader.decide(URL(string: "http://plain.example/")!, mainFrame: true))
        #expect(reader.reading?.refused == true, "a refused move of the page is said")
        #expect(reader.decide(URL(string: "https://elsewhere.example/moved")!, mainFrame: true))
        #expect(Self.record(work) == [
            "one.example blog.example page", "one.example elsewhere.example page",
        ], "a frame inside the page, and a refused move, are not the page")
    }

    @Test("A video handed to the player is listed under the source of its post")
    func aVideo() {
        let work = SourceWork()
        let playback = ShellPlayback()
        playback.work = work
        // A player that is never given the file, so nothing is fetched.
        playback.makePlayer = { _ in AVPlayer() }
        #expect(playback.toggle(
            URL(string: "https://media.invalid/v/1.mp4?token=x"), of: "post", on: .row, from: "One.Example"
        ))
        #expect(Self.record(work) == ["one.example media.invalid video"])
        playback.stop()
        #expect(Self.record(work).count == 1, "stopping is not an act")
    }

    @Test("Reading a timeline is recorded under its source", .timeLimit(.minutes(1)))
    func aTimeline() async {
        let work = SourceWork()
        let http = FixtureHTTP([
            "https://one.example/api/v1/trends/statuses?limit=20": .text("[]"),
            MastodonInstance.address(Self.source): MastodonInstance.mastodon(Self.source),
        ])
        let store = ItemStore()
        await store.add(Source(host: Self.source, kind: .mastodon))
        let session = ShellSession(
            http: http, store: store,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: RefusingSender())
        )
        session.work = work
        await session.reloadFromStore()
        await session.reload.timeline(.trends, in: session)
        #expect(work.record.contains { $0.source == Self.source && $0.purpose == .timeline })
        #expect(work.record.allSatisfy { $0.source == Self.source })
    }

    // MARK: - The words

    @Test("Every word the record says is there in every language the app has")
    func theWords() throws {
        let keys = SourceWork.Purpose.allCases.map(\.titleKey) + [
            "activity.open", "activity.open.footer", "activity.title", "activity.close",
            "activity.filter", "activity.filter.all", "activity.none", "activity.footer",
            "activity.dropped", "activity.row.spoken",
        ]
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"),
                encoding: .utf8
            )
            for key in keys {
                #expect(strings.contains("\"\(key)\" = "), "\(key) is missing in \(lproj)")
            }
        }
        let act = SourceAct(
            id: 1, reached: "cdn.example", pointedBy: Self.source, purpose: .picture,
            at: Date(timeIntervalSince1970: 0)
        )
        let english = act.spoken(language: .english)
        #expect(english.hasPrefix("one.example, Pictures, at "))
        let taiwanese = act.spoken(language: .taiwanese)
        #expect(taiwanese.hasPrefix("one.example，圖片，"))
    }

    /// No view inspector, so what VoiceOver reads is pinned by what the line draws: one element
    /// labelled with `spoken`, which names the source, what for and when.
    @Test("VoiceOver reads each line as one sentence: the source, what for, when")
    func eachLineIsSpoken() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Shell/ActivityPanel.swift")
        let page = try String(contentsOf: file, encoding: .utf8)
        #expect(page.contains(".accessibilityLabel(Text(act.spoken()))"))
        #expect(page.contains(".accessibilityElement(children: .ignore)"))
        for reach in ["http", "URL", ".task", "begin(", "note("] {
            #expect(!page.contains(reach), "the page reaches for \(reach)")
        }
    }

    @Test("A line draws in light and in dark", arguments: [ColorScheme.light, .dark])
    func drawsInBothSchemes(_ scheme: ColorScheme) throws {
        let act = SourceAct(id: 1, reached: Self.source, purpose: .timeline, at: Date(timeIntervalSince1970: 0))
        let renderer = ImageRenderer(
            content: ActivityLine(act: act)
                .environment(\.colorScheme, scheme)
                .frame(width: 320)
                .padding()
                .background(ShellChrome.page(scheme))
        )
        let image = try #require(renderer.cgImage)
        #expect(image.width > 0 && image.height > 0)
    }

    @Test("Opening the page is a flag on the session, which a press of Preferences sets")
    func opening() throws {
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore())
        #expect(!session.activityShown)
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Shell/PreferencesPane.swift")
        let pane = try String(contentsOf: file, encoding: .utf8)
        #expect(pane.contains("ActivityEntry(session: session)"))
        let panel = try String(
            contentsOf: file.deletingLastPathComponent().appendingPathComponent("ActivityPanel.swift"),
            encoding: .utf8
        )
        #expect(panel.contains("session.activityShown = true"))
        let root = try String(
            contentsOf: file.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("FediqoRootView.swift"),
            encoding: .utf8
        )
        #expect(root.contains(".modifier(ActivitySheet(session: session))"))
    }
}

/// A sender that answers every request with a refusal.
private struct RefusingSender: HTTPSender {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

/// Whether an observation fired.
private final class Woken: @unchecked Sendable {
    private(set) var was = false
    func flag() { was = true }
}
