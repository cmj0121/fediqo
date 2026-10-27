import Foundation
import Testing
@testable import FediqoCore

@Suite("Notices told on the reader's own Mastodon line")
struct MastodonNoticeLineTests {
    private static let source = Source(host: LocalServers.mastodon, kind: .mastodon)

    private static func told() throws -> [LineEvent] {
        var reader = ServerSentEvents()
        return try reader.feed(Data(ServerSentEventsTests.closed(MastodonNoticeLineCaptures.user).utf8))
    }

    @Test("The real line's notices read as the single read reads them: a favourite, a boost, a mention and a follow, each a line of one by its own id")
    func captured() throws {
        let told = try Self.told()
        #expect(told.map(\.name) == ["update", "notification", "notification", "update", "notification", "notification", "delete"])
        let notices = told.compactMap { MastodonNotices.told($0, source: Self.source) }
        #expect(notices.map(\.kind) == [.favourite, .reblog, .mention, .follow])
        #expect(notices.map(\.newestID) == ["138", "139", "140", "142"], "141, held back, is never told")
        #expect(notices.allSatisfy { $0.count == 1 && $0.source == Self.source })
        #expect(notices.map(\.handle) == [.one(id: "138"), .one(id: "139"), .one(id: "140"), .one(id: "142")])
        #expect(notices[0].post != nil && notices[3].post == nil, "a follow is about nobody's post")
        #expect(notices[3].people.first?.handle.contains("fediqo_hidden") == true)
    }

    @Test("Any other event, or words that will not read, is no notice")
    func notNotices() throws {
        let told = try Self.told()
        #expect(MastodonNotices.told(told[0], source: Self.source) == nil)
        #expect(MastodonNotices.told(LineEvent(name: "notification", data: "{not json"), source: Self.source) == nil)
    }
}
