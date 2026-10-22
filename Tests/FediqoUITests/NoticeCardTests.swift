import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #375: a notice is drawn as what it is about — the post's own row, who in faces over the
/// person's own post, the person's own row — and what has nothing behind it stays a line.
@Suite("A notice reads as the post or the person it is about")
@MainActor
struct NoticeCardTests {
    init() {
        L10n.language = .english
    }

    private static let source = Source(host: "a.example", kind: .mastodon)
    private static let ada = NoticePerson(handle: "@ada@a.example", name: "Ada", accountID: "7", words: "Tea, mostly.")
    private static let bo = NoticePerson(handle: "@bo@a.example", name: "Bo")
    private static let post = Note(
        id: "https://a.example/p/1", source: source, author: "Me", handle: "@me@a.example", body: "Words.",
        postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [], statusID: "1"
    )

    private static func notice(
        _ kind: Notice.Kind, people: [NoticePerson] = [ada], count: Int = 1, post: Note? = post
    ) -> Notice {
        Notice(
            source: source, handle: .one(id: "1"), kind: kind, people: people, count: count, post: post,
            at: Date(timeIntervalSince1970: 1_700_000_100), newestID: "1", oldestID: "1"
        )
    }

    @Test("An answer, a mention, a quotation, a new post, a poll that ended and a post changed are drawn over their post's own row")
    func postsAreTheirRows() {
        for kind in [Notice.Kind.mention, .quote, .unknown("status"), .poll, .update] {
            #expect(NoticeShape.of(Self.notice(kind)) == .post(Self.post), "\(kind)")
            #expect(NoticeShape.of(Self.notice(kind, post: nil)) == .line, "\(kind) with no post stays a line")
        }
    }

    @Test("A boost or a favourite is who, in faces, over the person's own post; a gathered line of follows is who without a post")
    func boostsAreFaces() {
        #expect(NoticeShape.of(Self.notice(.reblog)) == .faces(Self.post))
        #expect(NoticeShape.of(Self.notice(.favourite)) == .faces(Self.post))
        #expect(NoticeShape.of(Self.notice(.favourite, post: nil)) == .line)
        #expect(NoticeShape.of(Self.notice(.follow, people: [Self.ada, Self.bo], count: 2, post: nil)) == .faces(nil))
        #expect(NoticeShape.of(Self.notice(.follow, count: 3, post: nil)) == .faces(nil), "the source's count, not only who it sent")
    }

    @Test("A follower is their row, a request to follow is their row, and what has no post or person behind it stays a line")
    func peopleAreTheirRows() {
        #expect(NoticeShape.of(Self.notice(.follow, post: nil)) == .follower(Self.ada))
        #expect(NoticeShape.of(Self.notice(.followRequest, post: nil)) == .request(Self.ada))
        #expect(NoticeShape.of(Self.notice(.follow, people: [], post: nil)) == .line)
        for word in ["severed_relationships", "moderation_warning", "admin.sign_up", "admin.report"] {
            #expect(NoticeShape.of(Self.notice(.server(word), post: nil)) == .line, "\(word)")
        }
        #expect(NoticeShape.of(Self.notice(.unknown("annual_report"), post: nil)) == .line)
    }

    @Test("Who, as faces: the first two by name and how many others — the source's count", arguments: [DummyLanguage.english, .taiwanese])
    func whoAsFaces(_ language: DummyLanguage) {
        let one = Self.notice(.favourite)
        #expect(NoticeWords.facesNames(one, language: language) == "Ada" && NoticeWords.facesOthers(one, language: language) == nil)
        let two = Self.notice(.favourite, people: [Self.ada, Self.bo], count: 2)
        let pair = String(format: L10n.t("notices.faces.pair", language: language), "Ada", "Bo")
        #expect(NoticeWords.facesNames(two, language: language) == pair && NoticeWords.facesOthers(two, language: language) == nil)
        let five = Self.notice(.favourite, people: [Self.ada, Self.bo], count: 5)
        #expect(NoticeWords.facesNames(five, language: language) == String(format: L10n.t("notices.faces.list", language: language), "Ada", "Bo"))
        #expect(NoticeWords.facesOthers(five, language: language) == L10n.count("notices.faces.others", 3, language: language))
        #expect(NoticeWords.facesOthers(Self.notice(.favourite, people: [Self.ada, Self.bo], count: 3), language: .english) == "and 1 other")
        #expect(NoticeWords.facesOthers(five, language: .english) == "and 3 others")
    }

    @Test("Somebody a notice names is drawn as a person's row: their id, their handle, their name and what they say of themselves, as the source sent them")
    func aPersonFromANotice() {
        let person = NoticeCard.person(Self.ada, at: Self.source)
        #expect(person.accountID == "7" && person.handle == "@ada@a.example" && person.name == "Ada")
        #expect(PersonRow.firstLine(of: person) == "Tea, mostly.")
        let held = NoticeCard.person(Self.bo, at: Self.source)
        #expect(held.accountID.isEmpty && PersonRow.firstLine(of: held) == nil, "a line held before #375 has neither")
        let long = NoticePerson(handle: "@x@a.example", name: "X", words: String(repeating: "a", count: 1_000))
        #expect(long.words?.count == NoticePerson.wordsLength, "what is kept of them is bounded")
        #expect(NoticePerson(handle: "@y@a.example", name: "Y", words: "").words == nil)
    }

    @Test("A listener hears the line of a card say what happened, and the post's words only where no row of the post is drawn under it")
    func whatALineSays() {
        let mention = Self.notice(.mention)
        #expect(!NoticeWords.spokenLine(mention).contains("Words."), "the post's row says the post")
        let line = Self.notice(.unknown("annual_report"), post: Self.post)
        #expect(NoticeShape.of(line) == .line && NoticeWords.spokenLine(line) == NoticeWords.spoken(line))
    }
}
