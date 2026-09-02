import Foundation
import Testing
@testable import FediqoCore

/// Somebody as a server describes them, and what the reader is to them — the two halves of #88,
/// which are two answers from two different servers and are decoded apart.
@Suite("A person, and what you are to them")
struct ProfileTests {
    private func decode(_ json: String) throws -> MastodonDTO.Account {
        try MastodonClient.decoder.decode(MastodonDTO.Account.self, from: Data(json.utf8))
    }

    /// The whole shape a profile endpoint answers with, including the parts a status's copy of
    /// an account never carries.
    @Test("A profile carries what a status's copy of an account does not")
    func fullProfile() throws {
        let account = try decode("""
        {
          "id": "10", "url": "https://cedar.example/@tove", "username": "tove", "acct": "tove",
          "display_name": "Tove", "avatar": "https://cedar.example/tove.png",
          "note": "<p>Reading rooms, mostly.</p>",
          "statuses_count": 412, "followers_count": 89, "following_count": 130,
          "created_at": "2024-03-16T00:00:00.000Z", "locked": true
        }
        """)
        let profile = account.asProfile(on: "cedar.example")

        #expect(profile.id == "10")
        #expect(profile.authorId == "https://cedar.example/@tove")
        #expect(profile.name == "Tove")
        // Local accounts come back bare and are qualified here, the way a row spells them.
        #expect(profile.handle == "@tove@cedar.example")
        // Words rather than the markup the server sent, like a post's own text.
        #expect(profile.note == "Reading rooms, mostly.")
        #expect(profile.posts == 412)
        #expect(profile.followers == 89)
        #expect(profile.following == 130)
        #expect(profile.locked)
        #expect(profile.joined != nil)
    }

    /// S5, on a page rather than on a row. A server that did not say how many followers somebody
    /// has has not said nobody follows them, and the two must not arrive at the screen looking
    /// alike.
    @Test("A count no server sent is not a zero")
    func silenceIsNotZero() throws {
        let account = try decode("""
        {
          "id": "11", "url": "https://cedar.example/@ines", "username": "ines",
          "acct": "ines@birch.example", "display_name": "Ines Okafor", "avatar": null
        }
        """)
        let profile = account.asProfile(on: "cedar.example")

        #expect(profile.posts == nil)
        #expect(profile.followers == nil)
        #expect(profile.following == nil)
        #expect(profile.joined == nil)
        #expect(profile.note.isEmpty)
        // Not locked is what a server that did not mention it means: the endpoint answers about
        // it for every account it holds, so silence here is the ordinary case and not a gap.
        #expect(!profile.locked)
        // Already qualified by the server, and left as it came rather than qualified twice.
        #expect(profile.handle == "@ines@birch.example")
        #expect(profile.avatarURL == nil)
    }

    /// The relationship endpoint answers about every kind at once, so a kind it did not mention
    /// is one it says is not there. `PostMarks` keeps absent and false apart for the opposite
    /// reason, and the two are not to be made to match.
    @Test("A relationship a server did not mention is one it says is not there")
    func absentIsFalse() {
        let none = MastodonClient.relationship(from: ["id": "10"])
        #expect(!none.following)
        #expect(!none.followedBy)
        #expect(!none.requested)
        #expect(!none.muting)
        #expect(!none.blocking)
        #expect(!none.isOn)
    }

    @Test("Every kind is read off the server's own answer")
    func readsEachKind() {
        let all = MastodonClient.relationship(from: [
            "following": true, "followed_by": true, "requested": false,
            "muting": true, "blocking": false,
        ])
        #expect(all.following)
        #expect(all.followedBy)
        #expect(all.muting)
        #expect(!all.blocking)
    }

    /// A locked account leaves a reader neither following nor not, and the control has to say
    /// something. `isOn` is what it says: asked counts as on, so pressing again withdraws rather
    /// than asking twice.
    @Test("Asked and not yet answered is on, and is not following")
    func requestedIsOnButNotFollowing() {
        let asked = MastodonClient.relationship(from: ["requested": true])
        #expect(asked.isOn)
        #expect(!asked.following)
    }
}
