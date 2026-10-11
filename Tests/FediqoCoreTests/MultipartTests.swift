import Foundation
import Testing

@testable import FediqoCore

/// #312: a body of several parts — a file's bytes beside fields of text — as it leaves, byte
/// for byte, and what is refused before anything is made of it.
///
/// The boundary is drawn at random for every body; a test that reads exact bytes hands in the
/// draw instead, which is the one seam the maker has.
@Suite("A body of several parts")
struct MultipartTests {
    private static let crlf = "\r\n"

    /// A picture's first bytes and a few a text would not hold: a nul, a 0xFF, a line end.
    private static let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0D, 0x0A])

    private static func made(
        _ parts: [MultipartPart], limit: Int = MultipartBody.byteLimit, boundary: String = "B0undary"
    ) throws -> MultipartBody {
        try MultipartBody(parts, limit: limit) { boundary }
    }

    /// The one line a file's part is named on, as the body `made` of it says it.
    private static func disposition(ofFileNamed name: String) throws -> String {
        let body = try made([.file("avatar", named: name, type: "image/png", bytes)])
        let text = String(decoding: body.data, as: UTF8.self)
        let lines = text.components(separatedBy: crlf)
        return lines.first { $0.hasPrefix("Content-Disposition") } ?? ""
    }

    // MARK: - The bytes

    @Test("Two fields and a file leave as these bytes exactly: each part under the boundary, a field's text as UTF-8, a file's bytes untouched")
    func exactBytes() throws {
        let body = try Self.made([
            .field("display_name", "Mini 讀者"),
            .field("fields_attributes[0][name]", "site"),
            .file("avatar", named: "me.png", type: "image/png", Self.bytes),
        ])
        var expected = Data("""
        --B0undary\r
        Content-Disposition: form-data; name="display_name"\r
        \r
        Mini 讀者\r
        --B0undary\r
        Content-Disposition: form-data; name="fields_attributes[0][name]"\r
        \r
        site\r
        --B0undary\r
        Content-Disposition: form-data; name="avatar"; filename="me.png"\r
        Content-Type: image/png\r
        \r

        """.utf8)
        expected.append(Self.bytes)
        expected.append(Data("\r\n--B0undary--\r\n".utf8))
        #expect(body.data == expected)
        #expect(body.contentType == "multipart/form-data; boundary=B0undary")
    }

    @Test("A field with no text and a file with no bytes are parts all the same, with nothing in them")
    func emptyParts() throws {
        let body = try Self.made([
            .field("note", ""),
            .file("header", named: "none.png", type: "image/png", Data()),
        ])
        let expected = Data("""
        --B0undary\r
        Content-Disposition: form-data; name="note"\r
        \r
        \r
        --B0undary\r
        Content-Disposition: form-data; name="header"; filename="none.png"\r
        Content-Type: image/png\r
        \r
        \r
        --B0undary--\r

        """.utf8)
        #expect(body.data == expected)
    }

    // MARK: - What cannot break out of its line

    @Test("A part's name that could end its line, close its quotes, or is not plain ASCII is refused, and the refusal says nothing of it", arguments: [
        "", "a\"b", "note\r\nX-Injected: yes", "note\nmore", "note\rmore", "名字", "a b", "a;b", "a\\b", "a\u{0}b",
    ])
    func nameRefused(name: String) {
        #expect(throws: MultipartError.name) { try Self.made([.field(name, "x")]) }
        #expect(throws: MultipartError.name) {
            try Self.made([.file(name, named: "me.png", type: "image/png", Self.bytes)])
        }
        #expect(String(reflecting: MultipartError.name) == "FediqoCore.MultipartError.name")
    }

    @Test("A file goes by the last piece of its path alone, and whatever is not a plain letter, digit or one of -._~ in it is written as its bytes in hex", arguments: [
        ("/Users/me/Pictures/me.png", "me.png"),
        ("..\\..\\secret\\x.png", "x.png"),
        ("Pictures/", "Pictures"),
        ("a\"b\r\nX-Injected: yes.png", "a%22b%0D%0AX-Injected%3A%20yes.png"),
        ("照片.png", "%E7%85%A7%E7%89%87.png"),
        ("100%.png", "100%25.png"),
    ])
    func fileNameShown(given: String, shown: String) throws {
        let line = try Self.disposition(ofFileNamed: given)
        #expect(line == "Content-Disposition: form-data; name=\"avatar\"; filename=\"\(shown)\"")
    }

    @Test("A part holds the last piece of a file's path from the moment it is made, and prints as its kind and size alone: no name, no path, no text, no bytes")
    func partSaysNothingOfItself() throws {
        let field = MultipartPart.field("note", "hunter2-typed-by-hand")
        let file = MultipartPart.file(
            "avatar", named: "/Users/somebody/Private/holiday.png", type: "image/png", Data("pixels-of-it".utf8)
        )
        #expect(file.fileName == "holiday.png")
        #expect(String(describing: field) == "MultipartPart(field, 21 bytes)")
        #expect(String(describing: file) == "MultipartPart(file, 12 bytes)")

        let body = try Self.made([field, file])
        var dumped = ""
        dump([field, file], to: &dumped)
        dump(body, to: &dumped)
        let said = [
            String(describing: field), String(reflecting: field), String(describing: file), String(reflecting: file),
            String(describing: body), String(reflecting: body), "\([field, file])", dumped,
        ].joined(separator: "\n")
        for leak in ["hunter2", "somebody", "Private", "holiday", "pixels", "note", "avatar", "B0undary"] {
            #expect(!said.contains(leak), "\(leak) was printed")
        }
    }

    @Test("A file's name is kept to 255 bytes, cut at a whole character before its extension; one with no extension is cut at its end")
    func fileNameCapped() {
        let long = String(repeating: "讀", count: 200)
        let named = MultipartPart.lastPiece(of: "/Pictures/" + long + ".png")
        let expected: String = String(repeating: "讀", count: 83) + ".png"
        #expect(named == expected)
        #expect(named.utf8.count <= MultipartPart.fileNameBytes)

        let bare = MultipartPart.lastPiece(of: String(repeating: "a", count: 300))
        #expect(bare == String(repeating: "a", count: 255))
        // An ending too long to be an extension is cut with the rest.
        let odd = MultipartPart.lastPiece(of: "a." + String(repeating: "b", count: 300))
        #expect(odd.utf8.count == 255)
        #expect(MultipartPart.lastPiece(of: "short.png") == "short.png")
    }

    @Test("A file with no name left once its path is taken off is refused", arguments: ["", "/", "\\/"])
    func fileNameRefused(name: String) {
        #expect(throws: MultipartError.fileName) {
            try Self.made([.file("avatar", named: name, type: "image/png", Self.bytes)])
        }
    }

    @Test("A kind of bytes that is not one plain type and subtype is refused", arguments: [
        "", "image", "image/", "/png", "image/png\r\nX-Injected: yes", "image/png; name=\"x\"", "圖/png", "image/ png",
        "image/png/more",
    ])
    func typeRefused(type: String) {
        #expect(throws: MultipartError.type) {
            try Self.made([.file("avatar", named: "me.png", type: type, Self.bytes)])
        }
    }

    // MARK: - The boundary

    @Test("A boundary is drawn afresh for every body, and is letters, digits and hyphens")
    func boundaryIsRandom() throws {
        let parts = [MultipartPart.field("note", "x")]
        let first = try MultipartBody(parts), second = try MultipartBody(parts)
        #expect(first.contentType != second.contentType)
        let prefix = "multipart/form-data; boundary="
        #expect(first.contentType.hasPrefix(prefix))
        let boundary = String(first.contentType.dropFirst(prefix.count))
        let allowed = Set<UInt8>("abcdefghijklmnopqrstuvwxyz0123456789-".utf8)
        let plain: Bool = boundary.utf8.allSatisfy(allowed.contains)
        let length: Int = boundary.utf8.count
        #expect(plain)
        #expect(length >= 32)
        #expect(length <= 70)
    }

    @Test("A boundary that a part holds is not used: another is drawn, whether it stood in a field's text or a file's bytes")
    func boundaryCollision() throws {
        for part in [
            MultipartPart.field("note", "before TAKEN after"),
            MultipartPart.file("avatar", named: "me.png", type: "image/png", Data("\u{1}TAKEN\u{2}".utf8)),
        ] {
            var draws = ["TAKEN", "TAKEN", "free"]
            let body = try MultipartBody([.field("display_name", "x"), part], limit: 1 << 10) { draws.removeFirst() }
            #expect(body.contentType == "multipart/form-data; boundary=free")
            #expect(draws.isEmpty)
            #expect(body.data.range(of: Data("TAKEN--".utf8)) == nil)
        }
    }

    @Test("Where every draw is held by a part, the body is refused after a few and never made")
    func boundaryNeverFree() {
        var drawn = 0
        #expect(throws: MultipartError.boundary) {
            try MultipartBody([.field("note", "TAKEN")], limit: 1 << 10) {
                drawn += 1
                return "TAKEN"
            }
        }
        #expect(drawn == MultipartBody.draws)
    }

    // MARK: - The bound

    @Test("The bound is on the whole body, every line of it counted: a body of exactly the bound is made, one byte over is refused naming the bound")
    func bound() throws {
        let parts = [
            MultipartPart.field("note", "讀"),
            MultipartPart.file("avatar", named: "me.png", type: "image/png", Self.bytes),
        ]
        let whole = try Self.made(parts).data.count
        #expect(try Self.made(parts, limit: whole).data.count == whole)
        #expect(throws: MultipartError.tooLarge(limit: whole - 1)) { try Self.made(parts, limit: whole - 1) }
    }
}

/// #312: the same body through the signed-in door — to the token's own host and nowhere else,
/// and nothing sent where the body would not do.
@Suite("The signed-in door sends a body of several parts")
struct MultipartDoorTests {
    private static let path = "/api/v1/accounts/update_credentials"
    private static let picture = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])

    private static func door(
        _ routes: [String: FixtureSender.Outcome] = [path: .json("{}")]
    ) throws -> (MastodonAuthorized, FixtureSender, MemoryMastodonTokens) {
        let server = FixtureSender(routes)
        let store = MemoryMastodonTokens()
        try store.save(MastodonFixture.token)
        return (MastodonAuthorized(token: MastodonFixture.token, sender: server, store: store), server, store)
    }

    @Test("A signed-in PATCH carries the token, the fields and the file to its own host, as one request whose body is the maker's own bytes")
    func patch() async throws {
        let (door, server, _) = try Self.door()
        let parts = [
            MultipartPart.field("note", "讀者"),
            MultipartPart.file("avatar", named: "me.png", type: "image/png", Self.picture),
        ]
        let answer = try await door.patch(path: Self.path, parts: parts)
        #expect(answer == Data("{}".utf8))

        let requests = await server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://social.example/api/v1/accounts/update_credentials")
        #expect(request.httpMethod == "PATCH")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

        let said = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        #expect(said.hasPrefix(prefix))
        let boundary = String(said.dropFirst(prefix.count))
        let expected = try MultipartBody(parts, limit: MultipartBody.byteLimit) { boundary }
        #expect(request.httpBody == expected.data)
    }

    @Test("A body over the bound is refused naming the bound, and nothing is sent")
    func overTheBound() async throws {
        let (door, server, _) = try Self.door()
        let tooBig = MultipartPart.file(
            "header", named: "big.png", type: "image/png", Data(count: MultipartBody.byteLimit)
        )
        await #expect(throws: MultipartError.tooLarge(limit: MultipartBody.byteLimit)) {
            try await door.patch(path: Self.path, parts: [tooBig])
        }
        #expect(await server.requests.isEmpty)
    }

    @Test("A caller that knows its source takes less says so, and a body over that is refused before anything is sent; a bound said above the app's own is the app's own")
    func callersLimit() async throws {
        let (door, server, _) = try Self.door()
        let parts = [MultipartPart.file("avatar", named: "me.png", type: "image/png", Data(count: 4096))]
        await #expect(throws: MultipartError.tooLarge(limit: 1024)) {
            try await door.patch(path: Self.path, parts: parts, limit: 1024)
        }
        let tooBig = MultipartPart.file(
            "header", named: "big.png", type: "image/png", Data(count: MultipartBody.byteLimit)
        )
        await #expect(throws: MultipartError.tooLarge(limit: MultipartBody.byteLimit)) {
            try await door.patch(path: Self.path, parts: [tooBig], limit: .max)
        }
        #expect(await server.requests.isEmpty)
        _ = try await door.patch(path: Self.path, parts: parts, limit: 8192)
        #expect(await server.requests.count == 1)
    }

    @Test("A part that would not do is refused before anything is sent")
    func refusedPart() async throws {
        let (door, server, _) = try Self.door()
        await #expect(throws: MultipartError.name) {
            try await door.patch(path: Self.path, parts: [.field("note\r\nX-Injected: yes", "x")])
        }
        await #expect(throws: MultipartError.type) {
            try await door.patch(path: Self.path, parts: [
                .file("avatar", named: "me.png", type: "image/png\r\nX-Injected: yes", Self.picture),
            ])
        }
        #expect(await server.requests.isEmpty)
    }

    @Test("Whatever the path is made to say, the body and the token go to the token's own host or nowhere", arguments: [
        "@evil.example/api", "//evil.example/api", "https://evil.example/api", ".evil.example/api", ":8443/api",
    ])
    func ownHostOnly(path: String) async throws {
        let (door, server, _) = try Self.door([:])
        _ = try? await door.patch(path: path, parts: [.field("note", "x")])
        let hosts = await server.requests.map { $0.url?.host() }
        #expect(hosts.allSatisfy { $0 == "social.example" })
        let ports = await server.requests.compactMap { $0.url?.port }
        #expect(ports.isEmpty)
    }

    @Test("A redirect of it off the token's origin may not be followed, so the body and the token are not sent on")
    func redirectRule() async throws {
        let (door, server, _) = try Self.door()
        _ = try await door.patch(path: Self.path, parts: [.field("note", "x")])
        let request = try #require(await server.requests.first)
        #expect(request.httpBody?.isEmpty == false)
        #expect(!CappedBody.mayFollow(from: request, to: URL(string: "https://evil.example/api")!))
        #expect(!CappedBody.mayFollow(from: request, to: URL(string: "https://social.example:8443/api")!))
        #expect(CappedBody.mayFollow(from: request, to: URL(string: "https://social.example/moved")!))
    }

    @Test("A 401 to it is checked with the account check alone: the body is not sent a second time")
    func unauthorizedIsCheckedWithoutTheBody() async throws {
        let (door, server, store) = try Self.door([
            Self.path: .json("{}", status: 401),
            MastodonAuthorized.accountCheck: .json(MastodonFixture.me),
        ])
        await #expect(throws: MastodonAuthError.http(401)) {
            try await door.patch(path: Self.path, parts: [.file("avatar", named: "me.png", type: "image/png", Self.picture)])
        }
        let requests = await server.requests
        #expect(requests.map(\.httpMethod) == ["PATCH", "GET"])
        #expect(requests.last?.httpBody == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(try store.token(host: MastodonFixture.host) != nil)
    }
}

// On `HTTPTests` so it shares its serialisation: `StubURLProtocol` is one global stub.
extension HTTPTests {
    @Test("A body of several parts answered with a redirect off its origin is refused where it stands: nothing is asked of the other host")
    func partsRedirectedOffOriginRefused() async throws {
        StubURLProtocol.prepare(
            status: 200, body: Data("{}".utf8), http: true, redirect: "https://elsewhere.test/api/v1/accounts/update_credentials"
        )
        defer { StubURLProtocol.reset() }

        let token = MastodonToken(host: "urlprotocol.test", accessToken: "tok-123", clientID: "x", clientSecret: "x")
        let store = MemoryMastodonTokens()
        try store.save(token)
        let client = URLSessionClient(session: StubURLProtocol.session(), watchedOnly: false)
        let door = MastodonAuthorized(token: token, sender: client, store: store)
        await #expect(throws: URLError(.unsupportedURL)) {
            try await door.patch(path: "/api/v1/accounts/update_credentials", parts: [.field("note", "x")])
        }
        #expect(StubURLProtocol.lastRequest()?.url?.host() == "urlprotocol.test")
    }
}
