import Foundation
import Testing
@testable import FediqoCore

/// #347 — what is read off the table for asking a sign-in for more where it stands: how it
/// stands to a part, what it has been asked across pages, the words it gives up, and the
/// source's own account of what a token holds.
@Suite("How a sign-in stands to a part, and what its source says it holds")
struct MastodonPartStandingTests {
    private static let reading = "read:statuses read:lists read:accounts"

    private func held(_ scopes: String?, asked: String? = nil, refused: String? = nil) -> MastodonHeld {
        MastodonHeld(scopes: scopes, asked: asked, refused: refused)
    }

    @Test("A part is held by every word of it; refused where a missing word was refused on the page; partly held with some; never asked where no missing word was asked; and otherwise asked and not given")
    func standings() {
        typealias P = MastodonParts
        #expect(P.standing(.reading, of: held(Self.reading)) == .held)
        #expect(P.standing(.bookmarks, of: held(Self.reading)) == .unasked)
        #expect(P.standing(.bookmarks, of: held(Self.reading, asked: Self.reading)) == .unasked)
        #expect(P.standing(.bookmarks, of: held(Self.reading, asked: "write:bookmarks")) == .notGiven)
        let refused = held(Self.reading, asked: "write:bookmarks", refused: "write:bookmarks")
        #expect(P.standing(.bookmarks, of: refused) == .refused)
        #expect(P.standing(.notices, of: refused) == .unasked, "one part's refusal was read as another's")
        #expect(P.standing(.reading, of: held("read:statuses")) == .partly)
        #expect(P.standing(.reading, of: held(nil)) == .unasked)
        #expect(P.standing(.bookmarks, of: held("write:bookmarksplus")) == .unasked, "a word that only contains one was read as it")
        // Granted since, a refusal written before no longer stands.
        #expect(P.standing(.bookmarks, of: held("write:bookmarks", refused: "write:bookmarks")) == .held)
    }

    @Test("A sign-in kept before refusals were written down reads as it did: asked and not held is not given, for bookmarks and for notices")
    func olderRecordsReadAsTheyDid() {
        for scopes in [nil, Self.reading, MastodonOAuth.scopes(writing: true, bookmarks: false)] as [String?] {
            for asked in [nil, scopes, MastodonOAuth.scopes(writing: true, notices: true)] as [String?] {
                let record = held(scopes, asked: asked)
                let bookmarks: Bool = MastodonOAuth.bookmarks(asked) && !MastodonOAuth.bookmarks(scopes)
                let notices: Bool = MastodonOAuth.notices(asked) && !MastodonOAuth.notices(scopes)
                #expect(record.bookmarksRefused == bookmarks)
                #expect(record.noticesRefused == notices)
            }
        }
    }

    @Test("What a sign-in has been asked is every word of every page, each once and in the order met; a page's words beyond what is held are those it does not hold; and bookmarks and media only add to acting")
    func unionsAndWhatIsMore() {
        #expect(MastodonParts.union("a b", nil, "b c") == "a b c")
        #expect(MastodonParts.union(nil, nil) == nil && MastodonParts.union("", nil) == nil)
        #expect(MastodonParts.more(on: "a b c", than: "c a") == ["b"])
        #expect(MastodonParts.more(on: "a b", than: nil) == ["a", "b"])
        #expect(MastodonParts.same("a b", "b a") && !MastodonParts.same("a", "a b") && MastodonParts.same(nil, ""))
        #expect(MastodonParts.words(of: [.bookmarks, .reading]) == Self.reading + " write:bookmarks")
        #expect(MastodonParts.words(of: [.reading]) { $0 != "read:lists" } == "read:statuses read:accounts")
        #expect(MastodonPart.allCases.filter(\.needsActing) == [.bookmarks, .media])
    }

    @Test("A held word the table does not know is one a sign-in asked for more gives up: each once, in the order held — the source's one word for every read among them, and no word of any part")
    func wordsGivenUp() {
        let everything = MastodonParts.everything
        #expect(MastodonParts.unknown(in: everything).isEmpty)
        #expect(MastodonParts.unknown(in: "read " + everything + " push push follow") == ["read", "push", "follow"])
        #expect(MastodonParts.unknown(in: nil).isEmpty)
    }

    @Test("A source is believed for what it says a token holds, and for no word this device knows it never asked for")
    func whatASourceSaysIsBelieved() {
        #expect(MastodonParts.believed(["b", "a"], asked: nil) == "b a")
        #expect(MastodonParts.believed(["a", "write:bookmarks", "b"], asked: "b a") == "a b")
        #expect(MastodonParts.believed([], asked: "a") == "")
    }

    @Test("What a source says a sign-in holds is believed only where it reads, word for word: every word of reading. Nothing, a list that only writes, reading short of a word, and the source's one word for every read — which no page of this app can ask for again — are not")
    func whatReads() {
        #expect(MastodonParts.reads(Self.reading))
        #expect(MastodonParts.reads("write:statuses read:accounts read:lists read:statuses"))
        #expect(!MastodonParts.reads("read write"), "a sign-in whose reading no page can carry was read as one to ask in place")
        #expect(!MastodonParts.reads("read read:statuses read:lists"))
        #expect(!MastodonParts.reads(nil))
        #expect(!MastodonParts.reads(""))
        #expect(!MastodonParts.reads("write write:statuses read:search"))
        #expect(!MastodonParts.reads("read:statuses read:lists"))
        #expect(!MastodonParts.reads("read:statuses read:lists read:accountsx reader"))
    }

    @Test("A sign-in reads exactly where a page that widens it still reads: whatever is held, the page built over it carries every word of reading where the sign-in is said to read, and where it is not said to, a page for another part alone does not",
          arguments: [
              "read:statuses read:lists read:accounts", "read:accounts read:lists read:statuses write:statuses",
              "read", "read write", "read write follow push", "read:statuses read:lists", "read read:statuses",
              "write:statuses write:favourites", "", "read:statuses read:lists read:accounts read push",
          ])
    func readingAndThePageAgree(_ held: String) {
        let literal: Set<String> = ["read:statuses", "read:lists", "read:accounts"]
        for tick in MastodonPart.allCases where tick != .reading {
            let page = Set(MastodonParts.page(held: held, ticked: [tick]).split(separator: " ").map(String.init))
            let carries: Bool = literal.isSubset(of: page)
            #expect(MastodonParts.reads(held) == carries, "held \(held): said to read, and its page for \(tick.rawValue) does not agree")
        }
    }

    @Test("A page that brings acting and another part together asks for that part's act too, and the act is named by the part it belongs to: dismissing, where the page adds it to what is held — and none where it is held already, or is not on the page")
    func whatAPageAsksBeside() {
        let acts = Self.reading + " write:statuses write:favourites"
        let notified = Self.reading + " read:notifications"
        let both = acts + " read:notifications write:notifications"
        #expect(MastodonParts.page(held: notified, ticked: [.acting]) == both)
        #expect(MastodonParts.beside(on: both, than: notified) == [.notices])
        #expect(MastodonParts.beside(on: both, than: acts) == [.notices])
        #expect(MastodonParts.beside(on: both, than: both).isEmpty)
        #expect(MastodonParts.beside(on: acts + " write:bookmarks", than: acts).isEmpty)
        #expect(MastodonParts.beside(on: notified, than: Self.reading).isEmpty)
        #expect(MastodonParts.beside(on: both, than: nil) == [.notices])
    }

    /// One answer for whatever is sent, and what was sent.
    private actor Source: HTTPSender {
        private let body: String
        private let status: Int
        private(set) var sent: [URLRequest] = []

        init(_ body: String, status: Int = 200) {
            self.body = body
            self.status = status
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            sent.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private let token = MastodonToken(host: "social.example", accessToken: "held", clientID: "cid", clientSecret: "csecret")

    @Test("The source's own account of a token is asked at one fixed address on the token's host, with the token; its list of words is read as given, in order — as a Mastodon 4.6 answered")
    func theSourcesAccountOfAToken() async throws {
        let source = Source(MastodonSignInCaptures.wholeInfo)
        let words = try await MastodonOAuth(host: "social.example", sender: source).words(of: token)
        #expect(words == ["read", "write"])
        let sent = await source.sent
        #expect(sent.map(\.url?.absoluteString) == ["https://social.example/oauth/token/info"])
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer held")
        #expect((sent.first?.httpMethod ?? "GET") == "GET")
    }

    @Test("An account of a token that names no list, a list that is not words, or far too many is no account; and an answer that is not a yes is a failure that names only its status")
    func noAccountOfAToken() async throws {
        let long = (0...MastodonOAuth.tokenInfoWords).map { "\"w\($0)\"" }.joined(separator: ",")
        for body in [#"{"resource_owner_id":1}"#, #"{"scope":"read write"}"#, #"{"scope":["read",7]}"#, #"{"scope":["a b"]}"#, "{\"scope\":[\(long)]}", "<html>"] {
            let words = try await MastodonOAuth(host: "social.example", sender: Source(body)).words(of: token)
            #expect(words == nil, "\(body.prefix(24)) was read as an account of a token")
        }
        await #expect(throws: MastodonSignInError.http(401)) {
            _ = try await MastodonOAuth(host: "social.example", sender: Source(MastodonSignInCaptures.invalidInfo, status: 401)).words(of: token)
        }
    }
}
