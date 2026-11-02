import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #443: on somebody's page a face is a press only where it is somebody else's.
@Suite("What a row opens")
struct ShellOpensTests {
    private static let host = "social.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let at = Date(timeIntervalSince1970: 1_700_000_000)

    private static func post(by name: String) -> Note {
        Note(
            id: "https://\(host)/users/\(name)/statuses/9", source: source, author: name,
            handle: "@\(name)@\(host)", body: "words", postedAt: at, categories: []
        )
    }

    private static func boost(by name: String, of target: Note) -> DummyItem {
        let note = Note(
            id: "https://\(host)/users/\(name)/statuses/900/activity", source: source, author: name,
            handle: "@\(name)@\(host)", body: "", postedAt: at, categories: [.home], statusID: "900",
            refs: [Reference(kind: .reblogs, id: target.id, statusID: "9")]
        )
        return DummyItem(note, reblogging: target)
    }

    @Test("Their own post and their boost of their own stay a picture; a boost of somebody else's opens that author")
    func onlySomebodyElse() throws {
        let bob = try #require(DummyPerson(handle: "@bob@\(Self.host)", host: Self.host))
        #expect(!bob.opensAuthor(of: DummyItem(Self.post(by: "bob"))))
        #expect(!bob.opensAuthor(of: Self.boost(by: "bob", of: Self.post(by: "bob"))))
        #expect(bob.opensAuthor(of: Self.boost(by: "bob", of: Self.post(by: "ada"))))
    }
}
