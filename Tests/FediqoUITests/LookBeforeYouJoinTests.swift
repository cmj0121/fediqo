import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// Looking at a server and reading it are two decisions, and only the second one writes
/// anything down. The picker's model can make the first and cannot make the second: it has no
/// `AppState` to add to, which is the guarantee rather than a promise anyone has to keep.
@Suite("Look before you join")
@MainActor
struct LookBeforeYouJoinTests {
    private let info = InstanceInfo(host: "one.example", title: "One", summary: "A small server.")

    @Test("A fresh picker has looked at nothing")
    func startsIdle() {
        let model = ServerPickerModel(socialProtocol: .mastodon)
        #expect(model.probe == .idle)
    }

    @Test("What the server said becomes a source only where something asks for it")
    func serverFromWhatWasSaid() {
        let model = ServerPickerModel(socialProtocol: .mastodon)
        let server = model.server(from: info)

        #expect(server.host == "one.example")
        #expect(server.title == "One")
        #expect(server.socialProtocol == .mastodon)
        // Asking for it changed nothing: the model still has looked at nothing.
        #expect(model.probe == .idle)
    }

    @Test("A server already being read has nothing left to decide")
    func alreadyReading() {
        let model = ServerPickerModel(socialProtocol: .mastodon)
        let mine = [Server(host: "one.example", socialProtocol: .mastodon, title: "One")]
        let someone = [Server(host: "two.example", socialProtocol: .mastodon, title: "Two")]

        #expect(model.alreadyReading(info, among: mine))
        #expect(!model.alreadyReading(info, among: someone))
        #expect(!model.alreadyReading(info, among: []))
    }

    @Test("Nothing is looked up until what was typed looks like a hostname")
    func nothingToLookUpYet() {
        let model = ServerPickerModel(socialProtocol: .mastodon)
        #expect(!model.canSubmit)

        model.typed = "not a host"
        #expect(!model.canSubmit)

        model.typed = "one.example"
        #expect(model.canSubmit)
    }

    @Test("Putting the answer away leaves the app as it was")
    func clearing() {
        let model = ServerPickerModel(socialProtocol: .mastodon)
        model.typed = "one.example"
        model.clear()

        #expect(model.probe == .idle)
        // Clearing the answer is not clearing the question: what was typed stays typed.
        #expect(model.typed == "one.example")
    }
}
