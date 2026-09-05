import Foundation
import Testing
import FediqoCore
@testable import FediqoUI

/// Every template a reader can start a timeline from has words, in both languages.
///
/// The builder's menu is `TimelineTemplate.all` and its labels are `template.<id>.name`, so a
/// template added in `FediqoCore` with nothing written for it here is a blank line in a menu —
/// which compiles, ships, and is found only by somebody opening the sheet. #113 added two.
///
/// **The catalogue is read rather than `t(...)` called**, and that is not a shortcut. SwiftPM
/// copies `Localizable.xcstrings` into the test bundle without compiling it, so every key would
/// come back as itself here and the test would fail on the strings that are there. The catalogue
/// is the thing a person edits and the thing Xcode compiles, so it is the thing to hold to.
@Suite("A template a reader can read")
struct TemplateWordsTests {
    /// Every key in the catalogue, with the languages each is written in.
    private static let catalogue: [String: Set<String>] = {
        let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings")!
        struct Catalogue: Decodable {
            struct Entry: Decodable {
                struct Localisation: Decodable {
                    struct Unit: Decodable { let value: String }
                    let stringUnit: Unit?
                }
                let localizations: [String: Localisation]?
            }
            let strings: [String: Entry]
        }
        let read = try! JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: url))
        return read.strings.mapValues { entry in
            Set((entry.localizations ?? [:]).compactMap { language, localisation in
                (localisation.stringUnit?.value.isEmpty == false) ? language : nil
            })
        }
    }()

    /// Both of them, every time. A listing that says less in one language is a listing that says
    /// less, and the app ships in two.
    private static let languages: Set<String> = ["en", "zh-TW"]

    /// Whether a key is in the catalogue in both languages. Shared, because a second suite
    /// wanting the same answer should not grow a second reader of the same file.
    static func written(_ key: String) -> Bool {
        catalogue[key] == languages
    }

    private func written(_ key: String, _ comment: Comment) {
        let languages = Self.catalogue[key]
        #expect(languages != nil, comment)
        #expect(languages ?? [] == Self.languages, comment)
    }

    @Test("Every template has a name and a line under it", arguments: TimelineTemplate.all)
    func everyTemplateHasWords(template: TimelineTemplate) {
        written("template.\(template.id).name", "\(template.id) has no name")
        written("template.\(template.id).summary", "\(template.id) has no summary")
    }

    /// The prompt is asked for only where the template asks the reader to name something, so it
    /// is the one of the three allowed to be absent — and only there.
    @Test("A template that asks for something says what it is asking for")
    func atemplateThatAsksSaysSo() {
        for template in TimelineTemplate.all where template.parameter != .none {
            written("template.\(template.id).prompt", "\(template.id) asks for something silently")
        }
    }

    /// The two cuts are named in the sentence a person would have asked them in, because that is
    /// what a reader is shown when a server would not cut (#113).
    @Test("Each cut of the public timeline has words", arguments: [Writers.here, .elsewhere])
    func everyCutHasWords(writers: Writers) {
        written("writers.\(writers.rawValue)", "the \(writers.rawValue) cut has no words")
    }

    @Test("A server that would not cut can be told about in both languages")
    func therefusalHasWords() {
        written("error.wouldNotCut", "a server that would not cut says nothing")
    }
}
