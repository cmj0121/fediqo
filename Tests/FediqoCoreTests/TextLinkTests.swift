import Foundation
import Testing
@testable import FediqoCore

@Suite("An address in what somebody wrote")
struct TextLinkTests {
    private func links(_ text: String) -> [String] {
        TextLinks.runs(in: text).compactMap { if case .link(let words, _) = $0 { words } else { nil } }
    }

    @Test("A line with no address is one run of what was written")
    func nothingToFind() {
        #expect(TextLinks.runs(in: "no addresses here, none at all") == [.text("no addresses here, none at all")])
        #expect(TextLinks.runs(in: "") == [])
    }

    @Test("An address is cut out of the words around it, and keeps them")
    func oneLink() {
        let runs = TextLinks.runs(in: "see https://example.org/x for more")
        #expect(runs == [.text("see "),
                         .link("https://example.org/x", URL(string: "https://example.org/x")!),
                         .text(" for more")])
    }

    @Test("What ends the sentence does not end up in the address")
    func punctuationIsNotPartOfIt() {
        #expect(links("read https://example.org/x.") == ["https://example.org/x"])
        #expect(links("(https://example.org/x)") == ["https://example.org/x"])
        #expect(links("a, https://example.org/x, and b") == ["https://example.org/x"])
    }

    @Test("Several in one line, each on its own")
    func severalLinks() {
        #expect(links("https://one.example and https://two.example/x")
                == ["https://one.example", "https://two.example/x"])
    }

    @Test("A word that only looks like one is left alone")
    func notEverythingIsAnAddress() {
        #expect(links("the file is main.swift and the ratio is 3.14").isEmpty)
        #expect(links("write to a@b — no, do not").isEmpty)
    }

    @Test("An address with no scheme is still where the reader meant")
    func aBareHostIsStillAnAddress() {
        let runs = TextLinks.runs(in: "at example.org/rules")
        guard case .link(let words, let url)? = runs.last else {
            Issue.record("expected a link, got \(runs)"); return
        }
        #expect(words == "example.org/rules")
        #expect(url.host() == "example.org")
    }
}
