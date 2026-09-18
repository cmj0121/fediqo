import Foundation
import Testing
@testable import FediqoCore

@Suite("A failure's log line")
struct NetLogTests {
    private let secrets = ["ids", "110230", "lists", "code=", "s3cr3t", "token", "Bearer", "https"]
    private let address = URL(string: "https://m.example/api/v1/lists/110230?code=s3cr3t&access_token=token")!

    @Test("A transport failure names the host and its class, not the address it carries")
    func transport() {
        let error = URLError(.timedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: address,
            NSURLErrorFailingURLStringErrorKey: address.absoluteString,
            NSLocalizedDescriptionKey: "Bearer token for \(address.absoluteString)",
        ])
        let line = NetLog.line("request", host: address.host() ?? "", error: error)
        #expect(line == "request m.example: NSURLErrorDomain -1001")
        for secret in secrets { #expect(!line.contains(secret)) }
    }

    @Test("An error that prints itself is named by its domain and code, never by what it prints")
    func printsItself() {
        enum Speaks: Error, CustomStringConvertible {
            case loud
            var description: String { "s3cr3t token" }
        }
        let line = NetLog.line("request", host: "m.example", error: Speaks.loud)
        for secret in secrets { #expect(!line.contains(secret)) }
        #expect(line.hasSuffix(" 0"))
    }

    @Test("A refusal names the host and its status")
    func status() {
        #expect(NetLog.line("request", host: "m.example", status: 401) == "request m.example: HTTP 401")
    }

    @Test("An error's payload never reaches the line, only its type and case")
    func payload() {
        enum Leaky: Error { case said(String) }
        let line = NetLog.line("sign-in", host: "m.example", error: Leaky.said("s3cr3t token"))
        for secret in secrets { #expect(!line.contains(secret)) }
        #expect(line == "sign-in m.example: Leaky.said")
        #expect(NetLog.line("sign-in", host: "m.example", error: MastodonSignInError.http(403))
            == "sign-in m.example: MastodonSignInError.http")
        #expect(NetLog.line("sign-in", host: "m.example", error: MastodonSignInError.denied)
            == "sign-in m.example: MastodonSignInError.denied")
        #expect(NetLog.line("read as you", host: "m.example", error: MastodonAuthError.signedOut)
            == "read as you m.example: MastodonAuthError.signedOut")
    }
}
