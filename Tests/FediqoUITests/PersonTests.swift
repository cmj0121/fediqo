import FediqoCore
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #99 — pressing an author's face opens that person.
///
/// What a test can reach: who a row names, what counts as theirs, where a person sits in the
/// layer order and so what a press to leave gives back, the sentence the page counts with, and
/// the name a pointer and a screen reader are given for the press. What it cannot: that the face
/// and the name are drawn as presses, which lives in a `View` body no test in this package can
/// execute — it is named in the report rather than claimed here.
///
/// **The suite is `@MainActor`** for the reason `TouchTests` states.
@Suite("Opening whoever wrote it")
@MainActor
struct PersonTests {
    init() {
        L10n.language = .english
    }

    private static let posted = Date(timeIntervalSince1970: 1_700_000_000)

    private static func note(
        id: String = "n1",
        host: String = "first.example",
        kind: ProtocolKind = .mastodon,
        author: String = "Ada",
        handle: String? = "@ada@first.example",
        at seconds: TimeInterval = 0
    ) -> Note {
        Note(
            id: id,
            source: Source(host: host, kind: kind),
            author: author,
            handle: handle ?? "",
            body: "words",
            postedAt: posted.addingTimeInterval(seconds),
            categories: [.public],
            avatarURL: URL(string: "https://\(host)/a.png"),
            counts: Counts()
        )
    }

    private static func row(_ note: Note) -> DummyItem { DummyItem(note) }

    // MARK: - Who a row names

    /// A row names somebody, and the person it names is the author of it.
    @Test("A row with an author names a person, and names them by handle where there is one")
    func aRowNamesAPerson() {
        let person = DummyPerson(Self.row(Self.note()))
        #expect(person?.name == "Ada")
        #expect(person?.handle == "@ada@first.example")
        #expect(person?.host == "first.example")
        #expect(person?.avatarURL != nil)
    }

    /// A forum thread carries an author and no handle at all, which is the ordinary case on every
    /// Discuz! install this app reads. A person there is a name on a host — weaker than a handle,
    /// and what the forum gives.
    @Test("A forum row, which has no handle, names a person by their name and their host")
    func aForumRowNamesAPersonByName() {
        let person = DummyPerson(Self.row(Self.note(kind: .discuz, handle: nil)))
        #expect(person?.handle == nil)
        #expect(person?.name == "Ada")
        #expect(person?.id.contains("Ada") == true)
    }

    /// **Nothing rather than an empty person.** A row that names nobody has nobody to open, and
    /// the absence is what makes "such a row offers no press" a fact rather than a habit: there
    /// is no value for a call site to hand over.
    @Test("A row that names nobody names no person")
    func aRowWithNoAuthorNamesNobody() {
        #expect(DummyPerson(Self.row(Self.note(author: "", handle: nil))) == nil)
        // An empty handle is no handle. A source that sends "" must not make a person whose whole
        // identity is an empty string on a host.
        let named = DummyPerson(Self.row(Self.note(author: "Ada", handle: "")))
        #expect(named?.handle == nil)
    }

    /// One handle on two servers is two people, which is `DummyItem.id`'s rule (#10) one layer up.
    /// A person built without the host would gather a stranger's posts the moment two instances
    /// share a name.
    @Test("The same handle on two hosts is two people")
    func twoHostsAreTwoPeople() {
        let here = DummyPerson(Self.row(Self.note(host: "first.example")))
        let there = DummyPerson(Self.row(Self.note(host: "second.example", handle: "@ada@first.example")))
        #expect(here != there)
        #expect(here?.id != there?.id)
    }

    // MARK: - What this device holds of theirs

    /// Theirs, and newest first. The page's question is what they said last.
    @Test("What is held of theirs is theirs, newest first")
    func whatIsHeldIsTheirsNewestFirst() {
        let notes = [
            Self.note(id: "old", at: 0),
            Self.note(id: "new", at: 100),
            Self.note(id: "somebody", author: "Bob", handle: "@bob@first.example"),
        ]
        let person = DummyPerson(Self.row(Self.note()))!
        let held = DummyPerson.held(of: person, in: notes)
        #expect(held.count == 2)
        #expect(held.map(\.noteID) == ["new", "old"])
    }

    /// The host is read first, so a handle that reads the same on another server is not theirs.
    /// This is the one failure a page like this must not have.
    @Test("A note through another host is not theirs, however the handle reads")
    func anotherHostIsNotTheirs() {
        let person = DummyPerson(Self.row(Self.note()))!
        let elsewhere = Self.note(id: "n2", host: "second.example", handle: "@ada@first.example")
        #expect(DummyPerson.held(of: person, in: [elsewhere]).isEmpty)
    }

    /// A person known by a handle does not gather a note that carries only a name. "Somebody
    /// called this" is not "somebody", and gathering on the weaker key would put a stranger's
    /// posts under this person's face.
    @Test("A handle does not gather a note that carries only a name")
    func aHandleDoesNotGatherABareName() {
        let byHandle = DummyPerson(Self.row(Self.note()))!
        let bare = Self.note(id: "n2", kind: .discuz, handle: nil)
        #expect(DummyPerson.held(of: byHandle, in: [bare]).isEmpty)
        // And the other way round: a forum person gathers the forum's own rows.
        let byName = DummyPerson(Self.row(Self.note(kind: .discuz, handle: nil)))!
        #expect(DummyPerson.held(of: byName, in: [bare]).count == 1)
    }

    // MARK: - Where a person sits, and what leaving gives back

    /// **The order, and the half of it that is load-bearing.** A person opens over a conversation,
    /// so a face pressed inside one goes somewhere; a press to leave then gives the conversation
    /// back, which is where the reader was.
    @Test("A person opens over a conversation, and leaving gives the conversation back")
    func aPersonOpensOverAConversation() {
        #expect(DummyCommand.canOpen(.person, whenOpen: [.selection]))
        #expect(DummyCommand.canOpen(.person, whenOpen: [.thread, .selection]))
        #expect(DummyCommand.outermost(of: [.person, .thread, .selection]) == .person)
        // Leaving takes the person and only the person: the thread is still open under it.
        #expect(DummyCommand.outermost(of: [.thread, .selection]) == .thread)
    }

    /// And under the two things that are drawn over the whole app, like everything else. A key
    /// never closes what is above it to make room for itself.
    @Test("A person does not open under the guide or the viewer")
    func aPersonDoesNotOpenUnderWhatIsOverTheApp() {
        #expect(!DummyCommand.canOpen(.person, whenOpen: [.viewer]))
        #expect(!DummyCommand.canOpen(.person, whenOpen: [.shortcuts]))
    }

    /// **The stated cost of that order, pinned rather than left to be discovered.** A row on
    /// somebody's page lights and does not open a conversation, because a thread may not open
    /// underneath them. `PersonPane` hands its rows no open action rather than one that would be
    /// refused, and this is the rule that makes that the right shape.
    @Test("A conversation does not open from under somebody's page")
    func aThreadDoesNotOpenUnderAPerson() {
        #expect(!DummyCommand.canOpen(.thread, whenOpen: [.person]))
        #expect(!FediqoRootView.canOpenThread(place: .timeline, open: [.person, .selection]))
    }

    /// The press's own guard, asked the way the root asks it.
    @Test("A face may be pressed on the timeline and nowhere else")
    func aFaceMayBePressedOnTheTimeline() {
        #expect(FediqoRootView.canOpenPerson(place: .timeline, open: []))
        #expect(FediqoRootView.canOpenPerson(place: .timeline, open: [.thread, .selection]))
        #expect(!FediqoRootView.canOpenPerson(place: .timeline, open: [.viewer]))
        for place in ShellPlace.allCases where place != .timeline {
            #expect(!FediqoRootView.canOpenPerson(place: place, open: []), "\(place)")
        }
    }

    /// **Nothing is fetched for a person**, which is 0.4.0's line and 0.5.0's boundary. `r` has
    /// nothing to ask for on their page, and the mark that is `r`'s touch path is absent with it.
    @Test("Nothing is asked of anybody while somebody's page is open")
    func nothingIsAskedOnAPersonsPage() {
        #expect(!FediqoRootView.canReload(
            place: .timeline, editing: false, hasSources: true, open: [.person, .selection]
        ))
    }

    /// **A person is not a source.** A source is a server the reader joined — it has a sign-in,
    /// boards, a Clear button and a place on the rail. Somebody's page has none of that, and the
    /// sharpest way to say so is that the rail did not grow a sixth destination.
    @Test("A person is not a place on the rail, and not a source")
    func aPersonIsNotASource() {
        #expect(ShellPlace.allCases == [.timeline, .notices, .account, .usage, .preferences])
        // What a person is identified by is a host and a name — never a `Source`, which is what a
        // page that had quietly become a source page would have had to carry.
        let person = DummyPerson(Self.row(Self.note()))!
        #expect(person.host == "first.example")
        #expect(person.id.hasPrefix("first.example"))
    }

    // MARK: - What it says out loud

    /// The press names the person, not the verb. A bare "Open" beside forty faces says which act
    /// and never which person, and a glyph is nothing to a listener.
    @Test("The press names whoever it opens, in every language the app ships")
    func thePressNamesThePerson() {
        let person = DummyPerson(Self.row(Self.note()))!
        for language in DummyLanguage.allCases {
            L10n.language = language
            let spoken = DummyItemRow.spokenPerson(person)
            #expect(spoken.contains("Ada"), "\(language): \(spoken)")
            #expect(spoken != "item.person.open", "\(language) has no line for the press")
        }
        L10n.language = .english
    }

    /// A person known by a handle alone is still named, rather than announced as an empty string
    /// with a verb in front of it.
    @Test("Somebody with no name is still named by their handle")
    func somebodyWithNoNameIsStillNamed() {
        let person = DummyPerson(Self.row(Self.note(author: "", handle: "@ada@first.example")))!
        #expect(DummyItemRow.spokenPerson(person).contains("@ada@first.example"))
    }

    /// How much of theirs is here, said as a count of what this device holds — never of what they
    /// have written, which is a figure only their server could give.
    @Test("The page counts what this device holds, in every language the app ships")
    func thePageCountsWhatIsHeld() {
        for language in DummyLanguage.allCases {
            L10n.language = language
            for count in [0, 1, 7] {
                let line = PersonPane.heldLine(count)
                #expect(line.contains("\(count)"), "\(language): \(line)")
                #expect(!line.contains("person.held"), "\(language) has no line for the count")
            }
            // The empty page's own sentence, which is about this device rather than about them.
            #expect(L10n.t("person.none") != "person.none", "\(language)")
            #expect(L10n.t("person.back") != "person.back", "\(language)")
            #expect(L10n.t("person.through") != "person.through", "\(language)")
        }
        L10n.language = .english
    }
}
