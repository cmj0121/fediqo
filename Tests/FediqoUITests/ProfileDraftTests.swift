import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FediqoCore
@testable import FediqoUI

/// #312: what the sheet that changes the reader's own account is handed — its rows, what has
/// changed, the seal a typed field loses, the counts it shows and the refusal by row — and that
/// every sentence it says is written in each language.
@MainActor
@Suite("The sheet that changes your own account, as values")
struct ProfileDraftTests {
    private static let host = "m.example"
    private static let checked = Date(timeIntervalSince1970: 1_767_225_600)
    private static let account = OwnAccount(
        name: "Me", words: "I write about rivers.",
        fields: [OwnAccount.Field(name: "Site", value: "https://me.example", verifiedAt: checked), OwnAccount.Field(name: "Pronouns", value: "they")],
        followWithoutAsking: false, findable: true, listsShown: nil
    )

    private func said(_ state: ProfileState, _ draft: ProfileDraft? = ProfileDraft(Self.account), waiting: Int? = nil) -> ProfileSaid {
        ProfileSaid(host: Self.host, state: state, draft: draft, waiting: waiting)
    }

    @Test("The rows hold the account as read; nothing is changed until something differs from it; a switch the source did not say starts on that and is no change, chosen Yes or No it is one; what is sent leaves out a row with nothing in it")
    func rowsAndChanges() {
        var draft = ProfileDraft(Self.account)
        #expect(draft.name == "Me" && draft.fields.map(\.label) == ["Site", "Pronouns"] && draft.lists == nil && !draft.changed)
        #expect(draft.after == OwnAccount(
            name: "Me", words: "I write about rivers.",
            fields: [OwnAccount.Field(name: "Site", value: "https://me.example"), OwnAccount.Field(name: "Pronouns", value: "they")],
            followWithoutAsking: false, findable: true, listsShown: nil
        ))
        draft.add()
        #expect(!draft.changed && draft.after.fields.count == 2, "an empty row is no field")
        draft.lists = false
        #expect(draft.changed)
        draft.lists = nil
        draft.name = "Me "
        #expect(draft.changed)
        draft.name = "Me"
        #expect(!draft.changed)
        draft.follow = true
        #expect(draft.changed && draft.after.followWithoutAsking == true)
    }

    @Test("Add appends an empty row up to the host's stated count, or sixteen where none is; a field moves up and down and is removed; nothing about it is sent until Save")
    func fieldsMoveAndGo() {
        var draft = ProfileDraft(Self.account, limits: OwnLimits(fields: 3))
        let added = draft.add()
        #expect(added != nil && draft.fields.count == 3 && !draft.canAdd && draft.add() == nil)
        let site = draft.fields[0].id
        draft.move(site, by: 1)
        #expect(draft.fields.map(\.label) == ["Pronouns", "Site", ""] && draft.changed)
        draft.move(draft.fields[0].id, by: -1)
        #expect(draft.fields.map(\.label) == ["Pronouns", "Site", ""], "nothing above the first")
        draft.remove(site)
        #expect(draft.fields.map(\.label) == ["Pronouns", ""] && draft.canAdd)
        #expect(ProfileDraft(Self.account).fieldRoom == Person.fieldCount)
    }

    @Test("A field the source checked wears its seal while its content is as read; typed otherwise the seal goes and the line under the fields says the check comes off; typed back, the seal returns")
    func theSeal() {
        var draft = ProfileDraft(Self.account)
        #expect(draft.fields[0].sealed && !draft.fields[1].sealed && !draft.losesCheck)
        draft.fields[0].label = "Web"
        #expect(draft.fields[0].sealed, "the label is not what was checked")
        draft.fields[0].content = "https://me.example/new"
        #expect(!draft.fields[0].sealed && draft.losesCheck)
        draft.fields[0].content = "https://me.example"
        #expect(draft.fields[0].sealed && !draft.losesCheck)
        #expect(String(format: L10n.t("profile.field.checkLoss", language: .english), Self.host)
            == "Change a checked field's content and m.example takes its check off until it checks the address again.")
    }

    @Test("A count stands only where the host states a limit — a field's only once within ten of it — counted in letters as typed, and over the limit says by how much; nothing holds Save back")
    func counts() {
        var draft = ProfileDraft(Self.account, limits: OwnLimits(name: 30, fieldName: 20))
        #expect(draft.nameCount?.words(host: Self.host, language: .english) == "2 of 30")
        #expect(draft.nameCount?.words(host: Self.host, language: .taiwanese) == "2 / 30")
        #expect(draft.wordsCount == nil, "no limit stated, none shown")
        #expect(draft.labelCount(draft.fields[0]) == nil, "four letters of twenty: far from it")
        draft.fields[0].label = String(repeating: "é", count: 11)
        #expect(draft.labelCount(draft.fields[0]) == ProfileCount(count: 11, limit: 20))
        draft.name = String(repeating: "🌊", count: 32)
        let over = draft.nameCount
        #expect(over?.over == true && over?.words(host: Self.host, language: .english) == "2 over the 30 m.example allows")
        #expect(over?.words(host: Self.host, language: .taiwanese) == "超過 m.example 允許的 30 個字 2 個")
        #expect(said(.read, draft).canSave)
    }

    @Test("Each state says its line and offers what it may: Save only where something changed and nothing is out; Cancel asks only where something typed would be lost; nothing puts the sheet down while a change is out")
    func states() {
        var changed = ProfileDraft(Self.account)
        changed.name = "River Me"
        let en = DummyLanguage.english
        let lines: [(ProfileState, String, Bool, Bool, Bool)] = [
            (.asking, "Asking m.example for your profile…", false, false, false),
            (.readFailed, "Could not ask m.example for your profile, so nothing can be changed yet.", false, false, true),
            (.read, "As m.example holds it now.", true, true, false),
            (.sending, "Saving to m.example…", false, false, false),
            (.refused(sentence: "", rows: [:]), "m.example refused this. What you typed is kept.", true, true, true),
            (.forbidden, "m.example would not let this sign-in change your profile. What you typed is kept.", true, true, true),
            (.failed, "m.example did not answer, so whether it took the change is not known. What you typed is kept: Save sends it again.", true, true, true),
            (.ended, "The sign-in at m.example has ended. What you typed is kept until you close this.", false, false, true),
        ]
        for (state, line, saves, asks, warns) in lines {
            let drawn = said(state, state == .asking || state == .readFailed ? nil : changed)
            #expect(drawn.stateLine(language: en) == line, "\(state)")
            #expect(drawn.canSave == saves && drawn.cancelAsks == asks && drawn.lineWarns == warns, "\(state)")
            #expect(drawn.held == (state == .sending), "\(state)")
        }
        #expect(!said(.read).canSave && !said(.read).cancelAsks, "nothing changed")
        #expect(!said(.ended, changed).offersSave && said(.read, changed).offersSave)
        #expect(!said(.partGone, changed).canSave && said(.partGone, changed).cancelAsks)
        #expect(!said(.sending, changed).editable && said(.sending, changed).drawsRows)
    }

    @Test("A refusal's words stand under each row it names — the source's word on that row, or its sentence where it said none of the row — and its sentence over them all; a refusal with no words names no row")
    func refusalByRow() {
        let refused = said(.refused(sentence: "Validation failed", rows: [.name: "is too long", .fields: ""]))
        #expect(refused.refusal(of: .name) == "is too long" && refused.refusal(of: .fields) == "Validation failed")
        #expect(refused.refusal(of: .words) == nil && refused.refusal(of: .listsShown) == nil)
        #expect(refused.refusalSaid(language: .english) == "m.example says: Validation failed")
        #expect(refused.refusalSaid(language: .taiwanese) == "m.example 說：Validation failed")
        let bare = said(.refused(sentence: "", rows: [.name: ""]))
        #expect(bare.refusalSaid() == nil && bare.refusal(of: .name) == nil)
    }

    @Test("Turning \"Follow you without asking\" on while people wait says, under the switch, how many will be let in at once; nobody waiting, already on, or left off, it says nothing")
    func theWaitingLine() {
        var on = ProfileDraft(Self.account)
        on.follow = true
        #expect(said(.read, on, waiting: 3).waitingLine(language: .english)
            == "3 people ask to follow you; with this on, m.example lets them follow you at once.")
        #expect(said(.read, on, waiting: 1).waitingLine(language: .english)
            == "1 person asks to follow you; with this on, m.example lets them follow you at once.")
        #expect(said(.read, on, waiting: 3).waitingLine(language: .taiwanese) == "有 3 個人要求跟隨你；開啟這一項後，m.example 會立刻讓他們跟隨你。")
        #expect(said(.read, on).waitingLine() == nil && said(.read, waiting: 3).waitingLine() == nil)
        var open = OwnAccount()
        open.followWithoutAsking = true
        var already = ProfileDraft(open)
        already.follow = true
        #expect(said(.read, already, waiting: 3).waitingLine() == nil)
    }

    @Test("Cancel with something typed asks first, naming the source nothing was sent to; Discard is the loss, Keep editing the way out")
    func cancelAsks() {
        let en = ProfileDiscardAsks.question(Self.host, language: .english)
        #expect(en.title == "Discard your changes?" && en.line == "Nothing was sent to m.example.")
        #expect(en.choices.map(\.label) == ["Discard"] && en.choices.map(\.role) == [.destructive] && en.cancel == "Keep editing")
        let zh = ProfileDiscardAsks.question(Self.host, language: .taiwanese)
        #expect(zh.title == "捨棄你的修改？" && zh.line == "什麼都沒有送到 m.example。" && zh.cancel == "繼續編輯")
    }

    @Test("A switch says Yes, No, or that the source did not say, in each language; the fields' line names the host's count where it states one")
    func switchesAndFieldsLine() {
        #expect(ProfileSwitch.word(true, host: Self.host, language: .english) == "Yes")
        #expect(ProfileSwitch.word(false, host: Self.host, language: .taiwanese) == "不行")
        #expect(ProfileSwitch.word(nil, host: Self.host, language: .english) == "m.example did not say")
        #expect(said(.read, ProfileDraft(Self.account, limits: OwnLimits(fields: 4))).fieldsLine(language: .english) == "Up to 4, shown in this order.")
        #expect(said(.read).fieldsLine(language: .english) == "Shown in this order.")
        #expect(ProfileSwitch.allCases.map { L10n.t($0.key, language: .english) }
            == ["Follow you without asking", "Find you, and see you suggested", "See who you follow and who follows you"])
    }

    @Test("Every sentence the sheet and Change say is written once in each language the app speaks, the two Chinese tables alike, and `l` says what it does on your own page")
    func everySentenceIsWritten() throws {
        let tables = try ["en", "zh-TW", "zh-Hant"].map {
            try String(contentsOf: ShellSource.root.appendingPathComponent("Resources/\($0).lproj/Localizable.strings"), encoding: .utf8)
        }
        let keys = tables[0].split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\"profile.") else { return nil }
            return String(line.dropFirst().prefix { $0 != "\"" })
        }
        #expect(keys.count == 79)
        for key in keys where key != "profile.switch.follow.waiting.one" {
            let english = L10n.t(key, language: .english), taiwanese = L10n.t(key, language: .taiwanese)
            #expect(english != key && taiwanese != key, "\(key)")
            for (table, name) in zip(tables, ["en", "zh-TW", "zh-Hant"]) {
                #expect(table.components(separatedBy: "\n\"\(key)\" = \"").count == 2, "\(key) is written once in \(name)")
            }
        }
        #expect(tables[1] == tables[2])
        #expect(L10n.t("shortcut.follow", language: .english).hasSuffix("— or, on your own page, change your profile"))
        #expect(L10n.t("profile.title", language: .english) == "Your profile" && L10n.t("profile.title", language: .taiwanese) == "你的個人檔案")
        #expect(!keys.contains { L10n.t($0, language: .taiwanese).contains("帳號") }, "the profile is 個人檔案, as the part's own words say")
    }

    // MARK: - The picture and the header

    /// A real picture's bytes: `side` pixels square, as a PNG.
    static func png(side: Int = 4) -> Data {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    private static let held = OwnAccount(name: "Me", picture: URL(string: "https://m.example/system/a.png"))

    @Test("A picture chosen is staged, not sent: it is a change, Save sends it as its own type and name, and Keep current puts back what was read; Remove takes away the one held, and over nothing held only lets the choice go")
    func choosingAndRemoving() {
        var draft = ProfileDraft(Self.held)
        #expect(draft.stage(of: .picture) == .held(Self.held.picture) && draft.stage(of: .header) == .held(nil))
        #expect(draft.canRemove(.picture) && !draft.canRemove(.header) && !draft.canKeep(.picture) && !draft.changed)
        let png = Self.png()
        #expect(draft.stage(.header, data: png, type: .png, name: "band.png") == nil)
        guard case .chosen(let chosen) = draft.stage(of: .header) else {
            Issue.record("not staged")
            return
        }
        #expect(chosen.image.width == 4 && draft.changed && draft.canKeep(.header) && draft.canRemove(.header))
        #expect(draft.pictureChanges == [.header: .chosen(png, type: "image/png", name: "band.png")])
        draft.remove(.header)
        #expect(draft.stage(of: .header) == .held(nil) && !draft.changed, "nothing held: the choice let go, nothing to take away")
        draft.remove(.picture)
        #expect(draft.stage(of: .picture) == .removed && draft.pictureChanges == [.picture: .removed] && draft.changed)
        #expect(!draft.canRemove(.picture) && draft.canKeep(.picture))
        draft.keep(.picture)
        #expect(draft.stage(of: .picture) == .held(Self.held.picture) && !draft.changed)
        #expect(draft.after.picture == nil, "a picture is never sent as a row")
    }

    @Test("A file over the host's stated limit is refused naming the file, its size, the limit and that it is the host's; with none stated, this app's own, said as Fediqo's; one that is no picture is refused as such — and each leaves what was there")
    func refusedAtTheChoice() {
        let png = Self.png()
        var stated = ProfileDraft(Self.held, limits: OwnLimits(picture: 10))
        let refusal = stated.stage(.picture, data: png, type: .png, name: "me.png")
        #expect(refusal == .tooLarge(name: "me.png", size: png.count, limit: 10, stated: true))
        #expect(stated.stage(of: .picture) == .held(Self.held.picture) && stated.refusals[.picture] == refusal && !stated.changed)
        let said = ProfileSaid(host: Self.host, state: .read, draft: stated)
        let size = PictureRefusal.bytes(png.count, language: .english)
        #expect(said.pictureRefusal(of: .picture, language: .english) == "me.png is \(size), and m.example takes pictures up to 10 bytes. Nothing was chosen.")
        #expect(said.pictureRefusal(of: .picture, language: .taiwanese)?.contains("而 m.example 只接受最大") == true)
        #expect(said.pictureLimitLine(language: .english) == "m.example takes pictures up to 10 bytes.")
        stated.keep(.picture)
        #expect(stated.refusals.isEmpty, "Keep current takes the line away")

        var unstated = ProfileDraft(Self.held)
        #expect(unstated.pictureLimit == (OwnPicture.byteLimit, false))
        #expect(ProfileSaid(host: Self.host, state: .read, draft: unstated).pictureLimitLine() == nil, "no line where none is stated")
        let big = Data(count: OwnPicture.byteLimit + 1)
        #expect(unstated.stage(.header, data: big, type: .png, name: "huge.png")
            == .tooLarge(name: "huge.png", size: big.count, limit: OwnPicture.byteLimit, stated: false))
        #expect(ProfileSaid(host: Self.host, state: .read, draft: unstated).pictureRefusal(of: .header, language: .english)?
            .hasSuffix("and Fediqo sends pictures up to 33.6 MB. Nothing was chosen.") == true)
        #expect(unstated.stage(.header, data: Data("not a picture".utf8), type: .png, name: "notes.png") == .unreadable(name: "notes.png"))
        #expect(PictureRefusal.unreadable(name: "notes.png").words(host: Self.host, language: .english)
            == "Fediqo could not read notes.png as a picture. Nothing was chosen.")
        #expect(unstated.stage(of: .header) == .held(nil))
        let over = ProfileDraft(Self.held, limits: OwnLimits(picture: OwnPicture.byteLimit + 1)).pictureLimit
        #expect(over == (OwnPicture.byteLimit, false), "a host stating more than this app sends: this app's own")
    }

    @Test("A picked file is measured before it is read: one over the limit is refused by its size, one within is read as the type its bytes say; a choice refused once staged goes back to what was read")
    func aPickedFileIsMeasuredFirst() async throws {
        let png = Self.png()
        let url = URL.temporaryDirectory.appending(path: "fediqo-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let name = url.lastPathComponent
        #expect(await ProfilePictureFile.read(url, limit: (10, true)) == .refused(.tooLarge(name: name, size: png.count, limit: 10, stated: true)))
        #expect(await ProfilePictureFile.read(url, limit: (OwnPicture.byteLimit, false)) == .read(png, type: .png, name: name))
        let gone = URL.temporaryDirectory.appending(path: "fediqo-\(UUID().uuidString).png")
        #expect(await ProfilePictureFile.read(gone, limit: (10, true)) == .refused(.unreadable(name: gone.lastPathComponent)))

        var draft = ProfileDraft(Self.held)
        draft.take(.picture, .read(png, type: .png, name: "me.png"))
        let staged = draft.stage(of: .picture)
        draft.take(.picture, .read(png, type: .png, name: "me.png"))
        #expect(draft.stage(of: .picture) != staged, "two choices of the same file are two choices, told apart without the bytes")
        draft.refuse(.picture, .tooLarge(name: "me.png", size: png.count, limit: 10, stated: true))
        #expect(draft.stage(of: .picture) == .held(Self.held.picture) && draft.refusals[.picture] != nil && !draft.changed)
    }

    @Test("Saved in part: Save stays live, Cancel asks, the line is in full ink and names what was not taken off, in each language")
    func savedInPart() {
        var draft = ProfileDraft(Self.held)
        draft.remove(.picture)
        let said = ProfileSaid(host: Self.host, state: .partly(failed: [.picture]), draft: draft)
        #expect(said.canSave && said.cancelAsks && said.lineWarns && said.editable)
        #expect(said.stateLine(language: .english) == "m.example saved your profile but did not take off your picture. Save asks it again.")
        #expect(said.stateLine(language: .taiwanese) == "m.example 已儲存你的個人檔案，但沒有拿掉你的大頭貼。按「儲存」會再要求一次。")
        let both = ProfileSaid(host: Self.host, state: .partly(failed: [.picture, .header]), draft: draft)
        #expect(both.stateLine(language: .english).contains("your picture and header."))
    }
}
