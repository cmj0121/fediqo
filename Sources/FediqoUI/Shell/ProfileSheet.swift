import FediqoCore
import SwiftUI
import UniformTypeIdentifiers

// The sheet that changes the reader's own account at a source (#312): the picture and the
// header, the name, the words, the fields and what others can do — **edited from the account as it was read when the sheet
// opened**, and drawn from values it is handed. It asks nothing and names no kind of source.

/// What stands where Follow would on the reader's own page: Change, and the lock it is where
/// the sign-in does not hold the account part.
struct OwnChangeEntry: Equatable {
    let host: String
    /// The lock's line, where the sign-in does not hold the account part. Nothing where Change
    /// opens the sheet.
    var lock: PartWords.Place?

    /// The lock's sentence, where there is one.
    func lockWords(language: DummyLanguage? = nil) -> String? {
        lock.map { String(format: L10n.t($0.key, language: language), host) }
    }

    func spoken(language: DummyLanguage? = nil) -> String {
        lockWords(language: language) ?? String(format: L10n.t("profile.change.spoken", language: language), host)
    }
}

/// Where the sheet stands.
enum ProfileState: Equatable {
    /// The account is being read: nothing to edit from yet.
    case asking
    /// It could not be read.
    case readFailed
    /// Read, and being edited.
    case read
    /// The change is out.
    case sending
    /// The source would not take it: its sentence, and its word on each row it named.
    case refused(sentence: String, rows: [OwnRow: String])
    /// The source refused this sign-in the change, though it holds the account part.
    case forbidden
    /// The sign-in no longer holds the account part.
    case partGone
    /// No answer, or none that could be read: whether it took the change is not known.
    case failed
    /// The sign-in has ended.
    case ended
    /// The change landed, but taking `failed` away did not: the page drew the answer, and the
    /// removals stay staged for Save to send again.
    case partly(failed: Set<OwnPicture>)
}

/// A count beside a row, against a limit the host stated.
struct ProfileCount: Equatable {
    let count: Int
    let limit: Int

    var over: Bool { count > limit }

    func words(host: String, language: DummyLanguage? = nil) -> String {
        over
            ? String(format: L10n.t("profile.count.over", language: language), count - limit, limit, host)
            : String(format: L10n.t("profile.count", language: language), count, limit)
    }

    /// The count of `text` against `limit`, where one is stated — and, with `near`, only once
    /// the text is within that many of it.
    static func of(_ text: String, limit: Int?, near: Int? = nil) -> ProfileCount? {
        guard let limit else { return nil }
        let count = text.count
        if let near, limit - count > near { return nil }
        return ProfileCount(count: count, limit: limit)
    }
}

/// What the sheet edits: the account as it was read, and what is typed over it.
struct ProfileDraft: Equatable {
    struct Field: Equatable, Identifiable {
        let id: Int
        var label: String
        var content: String
        /// The field as the source held it when it was read, where this row is one read.
        let read: OwnAccount.Field?

        /// Whether the source's check stands: it checked the field, and its content is as read.
        var sealed: Bool { read?.verifiedAt != nil && content == read?.value }
        /// Whether what was typed takes the source's check off.
        var losesCheck: Bool { read?.verifiedAt != nil && content != read?.value }
        /// A row with nothing in it is no field, and is not sent.
        var blank: Bool {
            label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// One site that may credit the account, as a row.
    struct Site: Equatable, Identifiable {
        let id: Int
        var name: String
    }

    /// A field's count is drawn only within this many of its limit: four counts on every row are noise.
    static let near = 10

    let before: OwnAccount
    let limits: OwnLimits
    var name: String
    var words: String
    var fields: [Field]
    var follow: Bool?
    var found: Bool?
    var lists: Bool?
    var automated: Bool?
    var indexed: Bool?
    var coversMedia: Bool?
    var coversPosts: Bool?
    /// The words for those who cannot see each, where the source said them.
    var descriptions: [OwnPicture: String]
    /// The sites that may credit the account, as rows, where the source said them.
    var sites: [Site]
    /// The picture and the header as the sheet holds them: as read, chosen, or taken away.
    private(set) var pictures: [OwnPicture: PictureStage]
    /// Why the last choice of each was not taken, until the next choice, Keep current or Save.
    var refusals: [OwnPicture: PictureRefusal] = [:]
    private var made: Int
    /// How many choices have been staged: each one's id.
    private var chosen = 0
    private var madeSites = 0

    init(_ account: OwnAccount, limits: OwnLimits = .none) {
        before = account
        self.limits = limits
        name = account.name
        words = account.words
        fields = account.fields.enumerated().map { Field(id: $0.offset, label: $0.element.name, content: $0.element.value, read: $0.element) }
        made = account.fields.count
        follow = account.followWithoutAsking
        found = account.findable
        lists = account.listsShown
        automated = account.automated
        indexed = account.indexed
        coversMedia = account.coversMedia
        coversPosts = account.coversPosts
        descriptions = [:]
        descriptions[.picture] = account.pictureDescription
        descriptions[.header] = account.headerDescription
        sites = (account.sites ?? []).enumerated().map { Site(id: $0.offset, name: $0.element) }
        madeSites = sites.count
        pictures = [.picture: .held(account.picture), .header: .held(account.header)]
    }

    /// The account as the sheet would have it: what a change is sent towards. A row with
    /// nothing in it is left out.
    var after: OwnAccount {
        OwnAccount(
            name: name, words: words,
            fields: fields.filter { !$0.blank }.map { OwnAccount.Field(name: $0.label, value: $0.content) },
            followWithoutAsking: follow, findable: found, listsShown: lists,
            pictureDescription: description(.picture), headerDescription: description(.header),
            sites: before.sites == nil ? nil : sitesNamed, automated: automated, indexed: indexed,
            coversMedia: coversMedia, coversPosts: coversPosts
        )
    }

    /// What is sent of a description: what is typed while there is a picture for it to describe,
    /// and what was read otherwise, the row being gone.
    private func description(_ which: OwnPicture) -> String? {
        describes(which) ? descriptions[which] : read(which)
    }

    private func read(_ which: OwnPicture) -> String? {
        switch which {
        case .picture: before.pictureDescription
        case .header: before.headerDescription
        }
    }

    /// Whether the row of words for `which` is drawn: the source said them, and a picture is
    /// held or chosen.
    func describes(_ which: OwnPicture) -> Bool {
        guard read(which) != nil else { return false }
        switch stage(of: which) {
        case .held(let url): return url != nil
        case .chosen: return true
        case .removed: return false
        }
    }

    func descriptionCount(_ which: OwnPicture) -> ProfileCount? {
        let limit = which == .picture ? limits.pictureDescription : limits.headerDescription
        return ProfileCount.of(descriptions[which] ?? "", limit: limit)
    }

    /// The sites named on the rows: each once, with no row that names nothing.
    private var sitesNamed: [String] {
        var seen = Set<String>()
        return sites.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether the sites stand in the sheet: the source said them.
    var offersSites: Bool { before.sites != nil }

    /// An empty site at the end; its id. **No limit is held here**: the host states none it
    /// holds to, so its refusal says it.
    @discardableResult
    mutating func addSite() -> Int? {
        guard offersSites else { return nil }
        let id = madeSites
        madeSites += 1
        sites.append(Site(id: id, name: ""))
        return id
    }

    mutating func removeSite(_ id: Int) {
        sites.removeAll { $0.id == id }
    }

    /// Rows of a change whose answer was lost: the source may hold them either way, so Save
    /// sends them again and Cancel asks, whatever the rows say now.
    var unsure: Set<OwnRow> = []
    /// Whether there is anything Save would send, or Cancel would lose.
    var unsettled: Bool { changed || !unsure.isEmpty }

    /// Whether anything differs from what was read. A switch left unsaid differs from nothing.
    var changed: Bool {
        let now = after
        func pairs(_ fields: [OwnAccount.Field]) -> [[String]] {
            fields.filter { !($0.name.isEmpty && $0.value.isEmpty) }.map { [$0.name, $0.value] }
        }
        let switches: [(Bool?, Bool?)] = [
            (now.followWithoutAsking, before.followWithoutAsking), (now.findable, before.findable),
            (now.listsShown, before.listsShown), (now.automated, before.automated), (now.indexed, before.indexed),
            (now.coversMedia, before.coversMedia), (now.coversPosts, before.coversPosts),
        ]
        return now.name != before.name || now.words != before.words || pairs(now.fields) != pairs(before.fields)
            || now.pictureDescription != before.pictureDescription || now.headerDescription != before.headerDescription
            || now.sites != before.sites
            || switches.contains { now, was in now != nil && now != was } || !pictureChanges.isEmpty
    }

    // MARK: - The picture and the header

    /// How many bytes one picture may be, and whether that is the host's word: the host's where
    /// it states one this app would send, else this app's own — as `change` bounds it.
    var pictureLimit: (bytes: Int, stated: Bool) {
        if let stated = limits.picture, stated > 0, stated <= OwnPicture.byteLimit { return (stated, true) }
        return (OwnPicture.byteLimit, false)
    }

    func stage(of which: OwnPicture) -> PictureStage { pictures[which] ?? .held(nil) }

    /// What the source held of `which` when the sheet opened.
    func held(_ which: OwnPicture) -> URL? {
        switch which {
        case .picture: before.picture
        case .header: before.header
        }
    }

    /// What Save sends of the two: each chosen one, and each taken away.
    var pictureChanges: [OwnPicture: OwnPictureChange] {
        pictures.compactMapValues { stage in
            switch stage {
            case .held: nil
            case .chosen(let chosen): .chosen(chosen.data, type: chosen.type.preferredMIMEType ?? "image/jpeg", name: chosen.name)
            case .removed: .removed
            }
        }
    }

    /// A file chosen as `which`: over the limit, or not a picture, it is refused and what was
    /// there stays; else it is staged, to go with Save. The refusal, where it was one.
    @discardableResult
    mutating func stage(_ which: OwnPicture, data: Data, type: UTType, name: String) -> PictureRefusal? {
        refusals[which] = nil
        let limit = pictureLimit
        let refusal: PictureRefusal
        if data.count > limit.bytes {
            refusal = .tooLarge(name: name, size: data.count, limit: limit.bytes, stated: limit.stated)
        } else if let image = ProfilePicturePreview.decode(data) {
            chosen += 1
            pictures[which] = .chosen(PictureChosen(id: chosen, data: data, type: type, name: name, image: image))
            return nil
        } else {
            refusal = .unreadable(name: name)
        }
        refusals[which] = refusal
        return refusal
    }

    /// What came of reading a picked file, taken: staged, or refused and what was there kept.
    mutating func take(_ which: OwnPicture, _ picked: PicturePicked) {
        switch picked {
        case .read(let data, let type, let name): stage(which, data: data, type: type, name: name)
        case .refused(let refusal): refusals[which] = refusal
        }
    }

    /// A choice refused once staged: put back to what was read, and why said under it.
    mutating func refuse(_ which: OwnPicture, _ refusal: PictureRefusal) {
        keep(which)
        refusals[which] = refusal
    }

    /// Whether Remove stands: something is held or chosen.
    func canRemove(_ which: OwnPicture) -> Bool {
        switch stage(of: which) {
        case .held(let url): url != nil
        case .chosen: true
        case .removed: false
        }
    }

    /// Remove: the one held taken away by Save; a choice over nothing held only let go.
    mutating func remove(_ which: OwnPicture) {
        refusals[which] = nil
        pictures[which] = held(which) == nil ? .held(nil) : .removed
    }

    /// Whether Keep current stands: a choice or a removal is staged.
    func canKeep(_ which: OwnPicture) -> Bool {
        if case .held = stage(of: which) { return false }
        return true
    }

    /// Keep current: what was read put back.
    mutating func keep(_ which: OwnPicture) {
        refusals[which] = nil
        pictures[which] = .held(held(which))
    }

    /// How many fields there may be: what the host states, or what this app keeps.
    var fieldRoom: Int { limits.fields ?? Person.fieldCount }
    var canAdd: Bool { fields.count < fieldRoom }
    /// Whether the line about checks taken off stands under the fields.
    var losesCheck: Bool { fields.contains(where: \.losesCheck) }

    var nameCount: ProfileCount? { ProfileCount.of(name, limit: limits.name) }
    var wordsCount: ProfileCount? { ProfileCount.of(words, limit: limits.words) }
    func labelCount(_ field: Field) -> ProfileCount? { ProfileCount.of(field.label, limit: limits.fieldName, near: Self.near) }
    func contentCount(_ field: Field) -> ProfileCount? { ProfileCount.of(field.content, limit: limits.fieldValue, near: Self.near) }

    /// An empty field at the end; its id. Nothing where the rows are at their room.
    @discardableResult
    mutating func add() -> Int? {
        guard canAdd else { return nil }
        made += 1
        let id = made + 1_000_000
        fields.append(Field(id: id, label: "", content: "", read: nil))
        return id
    }

    mutating func move(_ id: Int, by step: Int) {
        guard let at = fields.firstIndex(where: { $0.id == id }), fields.indices.contains(at + step) else { return }
        fields.swapAt(at, at + step)
    }

    mutating func remove(_ id: Int) {
        fields.removeAll { $0.id == id }
    }
}

/// What the sheet up is handed.
struct ProfileSaid: Equatable {
    let host: String
    var state: ProfileState
    var draft: ProfileDraft?
    /// How many ask to follow the reader, where the source said and somebody does.
    var waiting: Int?
    /// The lock of the account part, where the sign-in no longer holds it.
    var lock: PartWords.Place?
    /// Which opening of the sheet this is: what a late read is told apart by.
    var opening = 0
    /// The pictures whose files are being read: Save waits for them.
    var reading: Set<OwnPicture> = []

    /// Whether the rows are drawn: there is an account read to edit.
    var drawsRows: Bool { draft != nil && state != .asking && state != .readFailed }
    /// Whether the rows take typing.
    var editable: Bool { drawsRows && state != .sending }
    /// Whether Save stands at all: not once the sign-in has ended.
    var offersSave: Bool { state != .ended }

    var canSave: Bool {
        guard reading.isEmpty, draft?.unsettled == true else { return false }
        switch state {
        case .read, .refused, .forbidden, .failed, .partly: return true
        case .asking, .readFailed, .sending, .partGone, .ended: return false
        }
    }

    /// Whether Cancel asks before the typing is let go.
    var cancelAsks: Bool {
        guard draft?.unsettled == true else { return false }
        switch state {
        case .read, .refused, .forbidden, .partGone, .failed, .partly: return true
        case .asking, .readFailed, .sending, .ended: return false
        }
    }

    /// Whether Cancel, Escape and a swipe do nothing.
    var held: Bool { state == .sending }

    /// The line under the title: where the sheet stands.
    func stateLine(language: DummyLanguage? = nil) -> String {
        let key: String
        switch state {
        case .asking: key = "profile.asking"
        case .readFailed: key = "profile.readFailed"
        case .read: key = "profile.whose"
        case .sending: key = "profile.saving"
        case .refused: key = "profile.refused"
        case .forbidden: key = "profile.refused.forbidden"
        case .partGone: return lockWords(language: language) ?? String(format: L10n.t("profile.whose", language: language), host)
        case .failed: key = "profile.failed"
        case .ended: key = "profile.ended"
        case .partly(let failed):
            return String(format: L10n.t("profile.picture.partly", language: language), host, PictureRefusal.word(failed, language: language))
        }
        return String(format: L10n.t(key, language: language), host)
    }

    /// Whether the line is said in full ink: something went wrong.
    var lineWarns: Bool {
        switch state {
        case .readFailed, .refused, .forbidden, .failed, .ended, .partly: true
        case .asking, .read, .sending, .partGone: false
        }
    }

    /// What the source said of the refusal as a whole, where it said something.
    func refusalSaid(language: DummyLanguage? = nil) -> String? {
        guard case .refused(let sentence, _) = state, !sentence.isEmpty else { return nil }
        return String(format: L10n.t("profile.refused.said", language: language), host, sentence)
    }

    /// The line under the picture or the header, where its last choice was not taken.
    func pictureRefusal(of which: OwnPicture, language: DummyLanguage? = nil) -> String? {
        draft?.refusals[which]?.words(host: host, language: language)
    }

    /// The line beside "Picture": how large a picture the host takes, only where it states it.
    func pictureLimitLine(language: DummyLanguage? = nil) -> String? {
        guard let limit = draft?.pictureLimit, limit.stated else { return nil }
        return String(format: L10n.t("profile.pictures.limit", language: language), host, PictureRefusal.bytes(limit.bytes, language: language))
    }

    /// The source's word on `row`, where its refusal named that row.
    func refusal(of row: OwnRow) -> String? {
        guard case .refused(let sentence, let rows) = state, let said = rows[row] else { return nil }
        return said.isEmpty ? (sentence.isEmpty ? nil : sentence) : said
    }

    func lockWords(language: DummyLanguage? = nil) -> String? {
        lock.map { String(format: L10n.t($0.key, language: language), host) }
    }

    /// The line under "Follow you without asking", where it is turned on and somebody waits.
    func waitingLine(language: DummyLanguage? = nil) -> String? {
        guard let waiting, let draft, draft.follow == true, draft.before.followWithoutAsking != true else { return nil }
        // Singular where the language has it, as `L10n.count` reads a count.
        let one = "profile.switch.follow.waiting.one"
        let singular = waiting == 1 ? L10n.t(one, language: language) : one
        let format = singular == one ? L10n.t("profile.switch.follow.waiting", language: language) : singular
        return String(format: format, waiting, host)
    }

    /// The line over the fields.
    func fieldsLine(language: DummyLanguage? = nil) -> String {
        guard let room = draft?.limits.fields else { return L10n.t("profile.fields.line.unstated", language: language) }
        return String(format: L10n.t("profile.fields.line", language: language), room)
    }
}

/// What the sheet's presses do: each answered by whoever holds the sheet.
struct ProfileSheetActs {
    var onSave: () -> Void = {}
    /// Cancel with nothing to lose, or Discard: the sheet put down.
    var onClose: () -> Void = {}
    var onAgain: () -> Void = {}
    /// The lock's press, where the sign-in no longer holds the account part.
    var onAsk: () -> Void = {}
    /// A file is being read for a picture, in the sheet's opening of that number.
    var onReading: (Int, OwnPicture) -> Void = { _, _ in }
    /// What came of it, for that opening.
    var onPicked: (Int, OwnPicture, PicturePicked) -> Void = { _, _, _ in }
}

/// The switches, by the row each is.
enum ProfileSwitch: CaseIterable {
    case follow, found, lists, indexed, automated, coversMedia, coversPosts

    /// What others can do: those always drawn, a menu where the source did not say; then one
    /// drawn only where it did.
    static let others: [ProfileSwitch] = [.follow, .found, .lists, .indexed]
    static let about: [ProfileSwitch] = [.automated]
    static let newPosts: [ProfileSwitch] = [.coversMedia, .coversPosts]

    /// Whether the row is drawn for an account as read: **one that came with #436 only where
    /// the source said it** (D5).
    func drawn(for account: OwnAccount) -> Bool {
        switch self {
        case .follow, .found, .lists: true
        case .indexed, .automated, .coversMedia, .coversPosts: account[keyPath: read] != nil
        }
    }

    var read: KeyPath<OwnAccount, Bool?> {
        switch self {
        case .follow: \.followWithoutAsking
        case .found: \.findable
        case .lists: \.listsShown
        case .indexed: \.indexed
        case .automated: \.automated
        case .coversMedia: \.coversMedia
        case .coversPosts: \.coversPosts
        }
    }

    var row: OwnRow {
        switch self {
        case .follow: .followWithoutAsking
        case .found: .findable
        case .lists: .listsShown
        case .indexed: .indexed
        case .automated: .automated
        case .coversMedia: .coversMedia
        case .coversPosts: .coversPosts
        }
    }

    var key: String {
        switch self {
        case .follow: "profile.switch.follow"
        case .found: "profile.switch.found"
        case .lists: "profile.switch.lists"
        case .indexed: "profile.switch.indexed"
        case .automated: "profile.switch.automated"
        case .coversMedia: "profile.switch.coversMedia"
        case .coversPosts: "profile.switch.coversPosts"
        }
    }

    var path: WritableKeyPath<ProfileDraft, Bool?> {
        switch self {
        case .follow: \.follow
        case .found: \.found
        case .lists: \.lists
        case .indexed: \.indexed
        case .automated: \.automated
        case .coversMedia: \.coversMedia
        case .coversPosts: \.coversPosts
        }
    }

    /// The word beside a switch, or in its menu.
    static func word(_ value: Bool?, host: String, language: DummyLanguage? = nil) -> String {
        switch value {
        case true?: L10n.t("profile.switch.on", language: language)
        case false?: L10n.t("profile.switch.off", language: language)
        case nil: String(format: L10n.t("profile.switch.unsaid", language: language), host)
        }
    }
}

/// The sheet: Cancel and Save over the rows, the line that says where it stands, and the rows
/// once the account is read.
///
/// Mac 600 wide; a phone's large sheet. **Nothing is said by colour alone**: every switch has
/// its word, every seal its sentence, every refusal its glyph and words.
struct ProfileSheet: View {
    let said: ProfileSaid
    @Binding var draft: ProfileDraft
    var acts = ProfileSheetActs()
    /// Whether the sheet takes its own room; a check that hosts it at a phone's width says not.
    var framed = true

    enum Focus: Hashable {
        case name, words, label(Int), content(Int), site(Int)
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Focus?
    @AccessibilityFocusState private var lineFocused: Bool
    @State private var discarding = false
    @ShellMetric(relativeTo: .body) private var lineHeight: CGFloat = 20

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ShellSpace.step) {
                    stateBlock
                    if said.drawsRows { rows }
                }
                .padding(ShellSpace.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(ProfileScrollKeyboard())
            .background(ShellChrome.page(colorScheme))
            .navigationTitle(L10n.t("profile.title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        .modifier(ProfileSheetRoom(framed: framed))
        .interactiveDismissDisabled(said.held || said.cancelAsks)
        .modifier(ProfileDiscardAsks(discarding: $discarding, host: said.host, onDiscard: acts.onClose))
        .onChange(of: said.state, initial: true) { _, state in
            lineFocused = true
            if state == .read, focus == nil { focus = .name }
        }
    }

    // MARK: - Cancel and Save

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.t("profile.cancel"), action: cancel)
                .disabled(said.held)
        }
        ToolbarItem(placement: .confirmationAction) {
            if said.state == .sending {
                ProgressView().controlSize(.small)
            } else if said.offersSave {
                Button(L10n.t("profile.save"), action: acts.onSave)
                    .disabled(!said.canSave)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func cancel() {
        guard !said.held else { return }
        if said.cancelAsks { discarding = true } else { acts.onClose() }
    }


    // MARK: - Where it stands

    @ViewBuilder
    private var stateBlock: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                if said.state == .read || said.state == .sending { ShellWellPill(said.host) }
                stateLine
            }
            if let refused = said.refusalSaid() {
                Text(refused)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if said.state == .readFailed {
                ShellLinkButton(L10n.t("person.retry"), symbol: PersonHead.failedSymbol, action: acts.onAgain)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var stateLine: some View {
        let line = said.stateLine()
        if said.state == .partGone, let place = said.lock {
            Button(action: acts.onAsk) {
                Label(line, systemImage: SourceRow.permissionSymbol)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.markDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!place.asks)
            .help(place.asks ? ShellMark.said(line, L10n.t("mark.dim.askAgain")) : line)
            .accessibilityLabel(line)
            .accessibilityFocused($lineFocused)
        } else {
            Text(line)
                .shellFont(.meta)
                .foregroundStyle(said.lineWarns ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($lineFocused)
        }
    }

    // MARK: - The rows

    @ViewBuilder
    private var rows: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            picturesBlock
            ShellRule()
            nameRow
            wordsRow
            fieldsBlock
            ShellRule()
            ShellSectionHead(
                L10n.t("profile.others"), line: String(format: L10n.t("profile.others.line"), said.host)
            )
            switchRows(ProfileSwitch.others)
            if draft.offersSites || ProfileSwitch.about.contains(where: drawn) {
                ShellRule()
                ShellSectionHead(L10n.t("profile.about"))
                switchRows(ProfileSwitch.about)
                if draft.offersSites { sitesBlock }
            }
            if ProfileSwitch.newPosts.contains(where: drawn) {
                ShellRule()
                ShellSectionHead(
                    L10n.t("profile.newPosts"), line: String(format: L10n.t("profile.newPosts.line"), said.host)
                )
                switchRows(ProfileSwitch.newPosts)
            }
        }
        .disabled(!said.editable)
    }

    private func drawn(_ which: ProfileSwitch) -> Bool { which.drawn(for: draft.before) }

    private func switchRows(_ which: [ProfileSwitch]) -> some View {
        ForEach(which.filter(drawn), id: \.self) { switchRow($0) }
    }

    /// The picture and the header, their reads told which opening they belong to.
    private var picturesBlock: ProfilePicturesBlock {
        let (opening, acts) = (said.opening, acts)
        return ProfilePicturesBlock(
            said: said, draft: $draft, onReading: { acts.onReading(opening, $0) }, onPicked: { acts.onPicked(opening, $0, $1) }
        )
    }

    /// The source's word under a row its refusal named.
    @ViewBuilder
    private func refusal(_ row: OwnRow) -> some View {
        if let words = said.refusal(of: row) {
            Label(words, systemImage: PersonHead.failedSymbol)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func spokenValue(_ text: String, _ count: ProfileCount?, host: String) -> String {
        guard let count else { return text }
        return [text, count.words(host: host)].joined(separator: L10n.t("people.row.between"))
    }

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ProfileRowHead(title: L10n.t("profile.name"), count: draft.nameCount, host: said.host)
            TextField("", text: $draft.name)
                .shellFont(.body)
                .shellField(.alone)
                .focused($focus, equals: .name)
                .onSubmit { focus = .words }
                .accessibilityLabel(L10n.t("profile.name"))
                .accessibilityValue(Self.spokenValue(draft.name, draft.nameCount, host: said.host))
                .accessibilityHint(said.refusal(of: .name) ?? "")
            refusal(.name)
        }
    }

    private var wordsRow: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ProfileRowHead(title: L10n.t("profile.words"), count: draft.wordsCount, host: said.host)
            TextEditor(text: $draft.words)
                .shellFont(.body)
                .scrollContentBackground(.hidden)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .frame(minHeight: lineHeight * 5, maxHeight: lineHeight * 10)
                .overlay(RoundedRectangle(cornerRadius: ShellRadius.field).stroke(ShellChrome.hairline(colorScheme)))
                .focused($focus, equals: .words)
                .accessibilityLabel(L10n.t("profile.words"))
                .accessibilityValue(Self.spokenValue(draft.words, draft.wordsCount, host: said.host))
                .accessibilityHint(said.refusal(of: .words) ?? "")
            refusal(.words)
        }
    }

    // MARK: - The fields

    private var fieldsBlock: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                    ProfileRowName(title: L10n.t("profile.fields"))
                    Spacer(minLength: 0)
                    fieldsLine
                }
                VStack(alignment: .leading, spacing: ShellSpace.hair) {
                    ProfileRowName(title: L10n.t("profile.fields"))
                    fieldsLine
                }
            }
            ForEach(Array(draft.fields.enumerated()), id: \.element.id) { place, field in
                fieldRow(field, place: place)
            }
            if draft.canAdd {
                ShellLinkButton(L10n.t("profile.field.add"), symbol: "plus") {
                    if let id = draft.add() { focus = .label(id) }
                }
                .fixedSize()
            }
            if draft.losesCheck {
                Text(String(format: L10n.t("profile.field.checkLoss"), said.host))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            refusal(.fields)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: draft.losesCheck)
    }

    private var fieldsLine: some View {
        Text(said.fieldsLine())
            .shellFont(.reading)
            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One field: its seal, its label and its content, and its `…`. Side by side where the
    /// sheet has room, and the label over the content where it has not.
    private func fieldRow(_ field: ProfileDraft.Field, place: Int) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: ShellSpace.snug) {
                    seal(field)
                    labelField(field, place: place).frame(minWidth: 140, maxWidth: 180)
                    contentField(field, place: place).frame(minWidth: 220)
                    fieldMore(field, place: place)
                }
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    HStack(alignment: .center, spacing: ShellSpace.snug) {
                        seal(field)
                        labelField(field, place: place)
                        fieldMore(field, place: place)
                    }
                    contentField(field, place: place)
                }
            }
            fieldCounts(field)
        }
    }

    @ViewBuilder
    private func fieldCounts(_ field: ProfileDraft.Field) -> some View {
        let label = draft.labelCount(field), content = draft.contentCount(field)
        if label != nil || content != nil {
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                if let label { ProfileRowCount(count: label, host: said.host).accessibilityLabel(L10n.t("profile.field.label") + " " + label.words(host: said.host)) }
                if let content { ProfileRowCount(count: content, host: said.host).accessibilityLabel(L10n.t("profile.field.value") + " " + content.words(host: said.host)) }
            }
        }
    }

    @ViewBuilder
    private func seal(_ field: ProfileDraft.Field) -> some View {
        Group {
            if field.sealed {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .help(PersonSaid.checked(said.host))
                    .accessibilityLabel(PersonSaid.checked(said.host))
                    .transition(.opacity)
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .shellFont(.mark)
        .frame(width: lineHeight, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: field.sealed)
    }

    private func binding(_ id: Int, _ path: WritableKeyPath<ProfileDraft.Field, String>) -> Binding<String> {
        Binding(
            get: { draft.fields.first { $0.id == id }?[keyPath: path] ?? "" },
            set: { text in
                guard let at = draft.fields.firstIndex(where: { $0.id == id }) else { return }
                draft.fields[at][keyPath: path] = text
            }
        )
    }

    private func labelField(_ field: ProfileDraft.Field, place: Int) -> some View {
        TextField(L10n.t("profile.field.label"), text: binding(field.id, \.label))
            .shellFont(.body)
            .shellField(.alone)
            .focused($focus, equals: .label(field.id))
            .onSubmit { focus = .content(field.id) }
            .accessibilityLabel(String(format: L10n.t("profile.field.spoken.label"), place + 1))
    }

    private func contentField(_ field: ProfileDraft.Field, place: Int) -> some View {
        TextField(L10n.t("profile.field.value"), text: binding(field.id, \.content))
            .shellFont(.body)
            .shellField(.alone)
            .focused($focus, equals: .content(field.id))
            .onSubmit { focus = draft.fields.dropFirst(place + 1).first.map { .label($0.id) } }
            .accessibilityLabel(String(format: L10n.t("profile.field.spoken.value"), place + 1))
    }

    private func fieldMore(_ field: ProfileDraft.Field, place: Int) -> some View {
        let label = ShellMore.label(only: String(format: L10n.t("profile.field.spoken.more"), place + 1))
        return ShellMoreButton(label: label) { fieldMenu(field.id, place: place) }
            .fixedSize()
    }

    private func fieldMenu(_ id: Int, place: Int) -> ShellMore {
        var items: [ShellMoreItem] = []
        if place > 0 { items.append(.plain("arrow.up", L10n.t("profile.field.up")) { draft.move(id, by: -1) }) }
        if place < draft.fields.count - 1 {
            items.append(.plain("arrow.down", L10n.t("profile.field.down")) { draft.move(id, by: 1) })
        }
        items.append(.plain("minus.circle", L10n.t("profile.field.remove")) { draft.remove(id) })
        return ShellMore(items: items)
    }

    // MARK: - The sites that may credit the account

    private var sitesBlock: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            ProfileRowName(title: L10n.t("profile.sites"))
            Text(L10n.t("profile.sites.line"))
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(draft.sites.enumerated()), id: \.element.id) { place, site in
                siteRow(site, place: place)
            }
            ShellLinkButton(L10n.t("profile.site.add"), symbol: "plus") {
                if let id = draft.addSite() { focus = .site(id) }
            }
            .fixedSize()
            refusal(.sites)
        }
    }

    private func siteRow(_ site: ProfileDraft.Site, place: Int) -> some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            TextField("example.com", text: Binding(
                get: { draft.sites.first { $0.id == site.id }?.name ?? "" },
                set: { name in
                    guard let at = draft.sites.firstIndex(where: { $0.id == site.id }) else { return }
                    draft.sites[at].name = name
                }
            ))
            .shellFont(.body)
            .shellField(.alone)
            .modifier(ProfileSiteTyping())
            .focused($focus, equals: .site(site.id))
            .accessibilityLabel(String(format: L10n.t("profile.site.spoken"), place + 1))
            .accessibilityHint(said.refusal(of: .sites) ?? "")
            Button { draft.removeSite(site.id) } label: {
                Image(systemName: "minus.circle")
                    .shellFont(.mark)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("profile.field.remove"))
            .accessibilityLabel(String(format: L10n.t("profile.site.remove.spoken"), place + 1))
        }
    }

    // MARK: - What others can do

    private func switchRow(_ which: ProfileSwitch) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: ShellSpace.snug) {
                    switchName(which)
                    Spacer(minLength: ShellSpace.snug)
                    switchControl(which)
                }
                VStack(alignment: .trailing, spacing: ShellSpace.tight) {
                    switchName(which).frame(maxWidth: .infinity, alignment: .leading)
                    switchControl(which)
                }
            }
            if which == .follow, let waiting = said.waitingLine() {
                Text(waiting)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            refusal(which.row)
        }
    }

    private func switchName(_ which: ProfileSwitch) -> some View {
        Text(L10n.t(which.key))
            .shellFont(.body)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    /// A switch the source said: its word beside it, in full ink. One it did not: a menu of
    /// three, starting on "did not say", which sends nothing.
    @ViewBuilder
    private func switchControl(_ which: ProfileSwitch) -> some View {
        let value = draft[keyPath: which.path]
        let spoken = ProfileSwitch.word(value, host: said.host)
        if draft.before[keyPath: which.read] == nil {
            Picker(L10n.t(which.key), selection: $draft[dynamicMember: which.path]) {
                Text(ProfileSwitch.word(nil, host: said.host)).tag(Bool?.none)
                Text(ProfileSwitch.word(true, host: said.host)).tag(Bool?.some(true))
                Text(ProfileSwitch.word(false, host: said.host)).tag(Bool?.some(false))
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(String(format: L10n.t("profile.switch.unsaid.help"), said.host))
            .accessibilityLabel(L10n.t(which.key))
            .accessibilityValue(spoken)
            .accessibilityHint(said.refusal(of: which.row) ?? "")
        } else {
            HStack(alignment: .center, spacing: ShellSpace.snug) {
                Text(spoken)
                    .shellFont(.body)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .accessibilityHidden(true)
                Toggle(L10n.t(which.key), isOn: Binding(
                    get: { draft[keyPath: which.path] ?? false },
                    set: { draft[keyPath: which.path] = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(L10n.t(which.key))
                .accessibilityValue(spoken)
                .accessibilityHint(said.refusal(of: which.row) ?? "")
            }
            .fixedSize()
        }
    }
}

/// A row's name.
struct ProfileRowName: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row's count against what the host states, where one is drawn.
struct ProfileRowCount: View {
    let count: ProfileCount?
    let host: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let count {
            Text(count.words(host: host))
                .shellFont(.reading)
                .foregroundStyle(count.over ? ShellChrome.ink(colorScheme) : ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row's name, and its count beside it where one is drawn — under it where both do not fit.
struct ProfileRowHead: View {
    let title: String
    let count: ProfileCount?
    let host: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                ProfileRowName(title: title)
                Spacer(minLength: 0)
                ProfileRowCount(count: count, host: host)
            }
            VStack(alignment: .leading, spacing: ShellSpace.hair) {
                ProfileRowName(title: title)
                ProfileRowCount(count: count, host: host)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Cancel with something typed asks first: Discard puts the sheet down, Keep editing does nothing.
struct ProfileDiscardAsks: ViewModifier {
    @Binding var discarding: Bool
    let host: String
    let onDiscard: () -> Void

    func body(content: Content) -> some View {
        content.shellConfirm($discarding, question: ProfileDiscardAsks.question(host), onChoice: chose)
    }

    private func chose(_ id: String) {
        if id == "discard" { onDiscard() }
    }

    static func question(_ host: String, language: DummyLanguage? = nil) -> ShellConfirmation {
        ShellConfirmation(
            symbol: "arrow.uturn.backward", title: L10n.t("profile.discard.title", language: language),
            line: String(format: L10n.t("profile.discard.line", language: language), host), help: nil,
            choices: [.init("discard", L10n.t("profile.discard", language: language), role: .destructive)],
            cancel: L10n.t("profile.discard.keep", language: language)
        )
    }
}

/// The sheet's own room: 600 wide and at least 560 high on a Mac; a phone's large sheet.
private struct ProfileSheetRoom: ViewModifier {
    let framed: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        if framed { content.frame(width: 600).frame(minHeight: 560) } else { content }
        #else
        content.presentationDetents([.large])
        #endif
    }
}

/// A site's name is no sentence: on a phone, typed as it is.
private struct ProfileSiteTyping: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        content
        #endif
    }
}

/// On a phone, the keyboard goes down as the rows are scrolled.
private struct ProfileScrollKeyboard: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.scrollDismissesKeyboard(.interactively)
        #else
        content
        #endif
    }
}

/// The sheet presented from the root while one is up — one line there, and no closure
/// presenter in its body.
struct ProfileSheetPresenter: ViewModifier {
    let profile: ShellProfile
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(item: shown) { _ in ProfileSheetHost(profile: profile, session: session) }
    }

    private var shown: Binding<ProfileOpen?> {
        Binding(get: { profile.open }, set: { if $0 == nil { profile.putDown() } })
    }
}

/// The sheet, drawn from what the profile holds now.
private struct ProfileSheetHost: View {
    let profile: ShellProfile
    let session: ShellSession

    var body: some View {
        if let said = profile.said(in: session) {
            ProfileSheet(said: said, draft: draft, acts: acts)
        }
    }

    private var draft: Binding<ProfileDraft> {
        Binding(get: { profile.draft ?? ProfileDraft(OwnAccount()) }, set: { if profile.draft != nil { profile.draft = $0 } })
    }

    private var acts: ProfileSheetActs {
        ProfileSheetActs(
            onSave: { profile.save(in: session) },
            onClose: { profile.putDown() },
            onAgain: { profile.readAgain(in: session) },
            onAsk: { profile.askForPart(in: session) },
            onReading: { profile.reading($1, opening: $0) },
            onPicked: { profile.picked($1, $2, opening: $0) }
        )
    }
}
