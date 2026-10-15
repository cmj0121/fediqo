import FediqoCore
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// The picture and the header in the profile sheet (#312, F12 §1): **chosen on the device and
// staged in the draft, sent by Save with the rest** — so Cancel undoes a choice, and what is
// seen before Save is drawn at the size the reader's own page draws it. Chosen through the
// system's own pickers alone; drawn from values it is handed, and it asks nothing.

/// A picture or the header as the sheet holds it.
enum PictureStage: Equatable {
    /// As the source held it when the sheet opened: where it is, or nothing.
    case held(URL?)
    /// Chosen on the device, not sent yet.
    case chosen(PictureChosen)
    /// Taken away, not sent yet.
    case removed
}

/// A file chosen as a picture: its bytes as they go, and the image drawn before Save.
struct PictureChosen: Equatable {
    let data: Data
    let type: UTType
    let name: String
    let image: CGImage

    static func == (lhs: PictureChosen, rhs: PictureChosen) -> Bool {
        lhs.data == rhs.data && lhs.type == rhs.type && lhs.name == rhs.name
    }
}

/// Why a choice was not taken: nothing was staged, and what was there stays.
enum PictureRefusal: Equatable {
    /// `size` bytes over `limit`: the host's own word where `stated`, else this app's.
    case tooLarge(name: String, size: Int, limit: Int, stated: Bool)
    /// Not a picture this device could read.
    case unreadable(name: String)

    func words(host: String, language: DummyLanguage? = nil) -> String {
        switch self {
        case .tooLarge(let name, let size, let limit, true):
            String(format: L10n.t("profile.picture.tooLarge", language: language), name, Self.bytes(size, language: language), host, Self.bytes(limit, language: language))
        case .tooLarge(let name, let size, let limit, false):
            String(format: L10n.t("profile.picture.tooLarge.app", language: language), name, Self.bytes(size, language: language), Self.bytes(limit, language: language))
        case .unreadable(let name):
            String(format: L10n.t("profile.picture.unreadable", language: language), name)
        }
    }

    /// A size as a file's, in the shell's language.
    static func bytes(_ count: Int, language: DummyLanguage? = nil) -> String {
        Int64(count).formatted(.byteCount(style: .file).locale(L10n.locale(language)))
    }

    /// The word for one or both of the two, as a sentence names them.
    static func word(_ which: Set<OwnPicture>, language: DummyLanguage? = nil) -> String {
        if which.count > 1 { return L10n.t("profile.pictures.word", language: language) }
        return L10n.t(which.first == .header ? "profile.header.word" : "profile.picture.word", language: language)
    }
}

/// The image drawn before Save, decoded on the device.
enum ProfilePicturePreview {
    /// The longest side a preview is decoded at: more than a header band on any screen.
    static let side = 1_600

    /// The image `data` holds, upright; nothing where it holds none.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The type the bytes themselves say they are, where they say one.
    static func type(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let id = CGImageSourceGetType(source) else { return nil }
        return UTType(id as String)
    }

    /// The kinds of file the panel offers.
    static let kinds: [UTType] = [.jpeg, .png, .gif, .webP]
}

extension OwnPicture {
    var key: String {
        switch self {
        case .picture: "profile.picture"
        case .header: "profile.header"
        }
    }

    /// The row a source's refusal of it names.
    var refusedAs: OwnRow {
        switch self {
        case .picture: .picture
        case .header: .header
        }
    }

    var standing: RemoteImage.Standing {
        switch self {
        case .picture: .avatar
        case .header: .picture
        }
    }
}

/// The two rows above Display name: the picture at the head's own 56 points, the header as
/// About's band, each with Choose…, Remove and Keep current, and the limit the host states.
struct ProfilePicturesBlock: View {
    let said: ProfileSaid
    @Binding var draft: ProfileDraft

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ShellMetric(relativeTo: .body) private var faceSide: CGFloat = 56
    @ShellMetric(relativeTo: .body) private var bandHeight: CGFloat = 96
    @AccessibilityFocusState private var refusalFocused: OwnPicture?
    /// The one being chosen, while its picker is up or its bytes are read.
    @State private var choosing: OwnPicture?
    @State private var reading: OwnPicture?
    @State private var filesUp = false
    @State private var photosUp = false
    @State private var photo: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            pictureRow
            headerRow
        }
        .fileImporter(isPresented: $filesUp, allowedContentTypes: ProfilePicturePreview.kinds, onCompletion: picked)
        .modifier(ProfilePhotosPicking(up: $photosUp, item: $photo, onPicked: pickedPhoto))
        .onChange(of: draft.refusals) { _, refusals in
            if let which = OwnPicture.allCases.first(where: { refusals[$0] != nil }) { refusalFocused = which }
        }
    }

    // MARK: - The two rows

    private var pictureRow: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                    rowName(.picture)
                    Spacer(minLength: 0)
                    limitLine
                }
                VStack(alignment: .leading, spacing: ShellSpace.hair) {
                    rowName(.picture)
                    limitLine
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: ShellSpace.snug) {
                    frame(.picture)
                    presses(.picture)
                }
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    frame(.picture)
                    presses(.picture)
                }
            }
            stageLine(.picture)
            refusal(.picture)
        }
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            rowName(.header)
            frame(.header)
            presses(.header)
            stageLine(.header)
            refusal(.header)
        }
    }

    private func rowName(_ which: OwnPicture) -> some View {
        Text(L10n.t(which.key))
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var limitLine: some View {
        if let line = said.pictureLimitLine() {
            Text(line)
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The frame

    /// What the page will draw: the head's plate for the picture, About's band for the header.
    private func frame(_ which: OwnPicture) -> some View {
        drawn(which)
            .frame(width: which == .picture ? faceSide : nil, height: which == .picture ? faceSide : bandHeight)
            .frame(maxWidth: which == .header ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: DummyItemRow.Box.plate, style: .continuous))
            .overlay { if reading == which { ProgressView().controlSize(.small) } }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: draft.stage(of: which))
            .accessibilityElement()
            .accessibilityLabel(String(format: L10n.t(which == .picture ? "profile.picture.spoken" : "profile.header.spoken"), said.host))
            .accessibilityValue(spokenStage(which))
            .accessibilityHint(said.pictureRefusal(of: which) ?? said.refusal(of: which.refusedAs) ?? "")
    }

    @ViewBuilder
    private func drawn(_ which: OwnPicture) -> some View {
        switch draft.stage(of: which) {
        case .chosen(let chosen):
            Image(decorative: chosen.image, scale: 1)
                .resizable()
                .scaledToFill()
                .transition(.opacity)
        case .held(let url?):
            RemoteImage(
                url: url, tier: .deck, host: said.host, standing: which.standing, alt: nil, speaks: false,
                radius: DummyItemRow.Box.plate
            )
        case .held(nil), .removed:
            ShellVacant(standing: which.standing, radius: DummyItemRow.Box.plate)
                .overlay {
                    if which == .header {
                        Text(L10n.t("profile.header.none"))
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                    }
                }
        }
    }

    private func spokenStage(_ which: OwnPicture) -> String {
        switch draft.stage(of: which) {
        case .held(.some): String(format: L10n.t("profile.picture.spoken.now"), said.host)
        case .held(nil): L10n.t("profile.picture.spoken.none")
        case .chosen: L10n.t("profile.picture.spoken.new")
        case .removed: L10n.t("profile.picture.spoken.removed")
        }
    }

    // MARK: - The presses

    private func presses(_ which: OwnPicture) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) { pressList(which) }
            VStack(alignment: .leading, spacing: ShellSpace.tight) { pressList(which) }
        }
        .disabled(reading != nil)
    }

    @ViewBuilder
    private func pressList(_ which: OwnPicture) -> some View {
        choose(which)
        if draft.canRemove(which) {
            ShellLinkButton(L10n.t("profile.picture.remove"), symbol: "minus.circle") { draft.remove(which) }
                .fixedSize()
                .accessibilityLabel(L10n.t(which == .picture ? "profile.picture.remove.spoken" : "profile.header.remove.spoken"))
        }
        if draft.canKeep(which) {
            ShellLinkButton(L10n.t("profile.picture.keep"), symbol: "arrow.uturn.backward") { draft.keep(which) }
                .fixedSize()
                .accessibilityLabel(String(format: L10n.t("profile.picture.keep.spoken"), said.host))
        }
    }

    /// Choose…: the open panel on a Mac; on a phone, Photos or Files.
    @ViewBuilder
    private func choose(_ which: OwnPicture) -> some View {
        let spoken = L10n.t(which == .picture ? "profile.picture.choose.spoken" : "profile.header.choose.spoken")
        #if os(iOS)
        Menu {
            Button(L10n.t("profile.picture.fromPhotos"), systemImage: "photo.on.rectangle") { pick(which, photos: true) }
            Button(L10n.t("profile.picture.fromFiles"), systemImage: "folder") { pick(which, photos: false) }
        } label: {
            Label(L10n.t("profile.picture.choose"), systemImage: "photo")
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
        }
        .fixedSize()
        .accessibilityLabel(spoken)
        #else
        ShellLinkButton(L10n.t("profile.picture.choose"), symbol: "photo") { pick(which, photos: false) }
            .fixedSize()
            .accessibilityLabel(spoken)
        #endif
    }

    private func pick(_ which: OwnPicture, photos: Bool) {
        choosing = which
        if photos { photosUp = true } else { filesUp = true }
    }

    // MARK: - What is staged

    @ViewBuilder
    private func stageLine(_ which: OwnPicture) -> some View {
        let line: String? = switch draft.stage(of: which) {
        case .chosen: L10n.t("profile.picture.chosen")
        case .removed: String(format: L10n.t("profile.picture.removed"), said.host)
        case .held: which == .header ? L10n.t("profile.picture.preview") : nil
        }
        if let line {
            Text(line)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        } else if case .held(nil) = draft.stage(of: which) {
            Text(L10n.t("profile.picture.none"))
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why the last choice was not taken, or the source's word on the row at Save.
    @ViewBuilder
    private func refusal(_ which: OwnPicture) -> some View {
        if let words = said.pictureRefusal(of: which) ?? said.refusal(of: which.refusedAs) {
            Label(words, systemImage: PersonHead.failedSymbol)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($refusalFocused, equals: which)
        }
    }

    // MARK: - Reading what was chosen

    private func picked(_ result: Result<URL, any Error>) {
        guard let which = choosing else { return }
        choosing = nil
        guard case .success(let url) = result else { return }
        reading = which
        Task {
            let read = await ProfilePictureFile.read(url)
            reading = nil
            let name = url.lastPathComponent
            guard let read else {
                draft.refusals[which] = .unreadable(name: name)
                return
            }
            draft.stage(which, data: read.data, type: read.type, name: name)
        }
    }

    private func pickedPhoto(_ item: PhotosPickerItem) {
        guard let which = choosing else { return }
        choosing = nil
        photo = nil
        reading = which
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            reading = nil
            let type = data.flatMap(ProfilePicturePreview.type(of:)) ?? item.supportedContentTypes.first ?? .jpeg
            let name = "photo." + (type.preferredFilenameExtension ?? "jpg")
            guard let data else {
                draft.refusals[which] = .unreadable(name: name)
                return
            }
            draft.stage(which, data: data, type: type, name: name)
        }
    }
}

/// A file the person picked, read once: reached through the sandbox's leave for that one file.
enum ProfilePictureFile {
    struct Read: Sendable {
        let data: Data
        let type: UTType
    }

    static func read(_ url: URL) async -> Read? {
        let reached = url.startAccessingSecurityScopedResource()
        defer { if reached { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let named = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return Read(data: data, type: ProfilePicturePreview.type(of: data) ?? named ?? .jpeg)
    }
}

/// Photos on a phone: the system's picker, which hands over only what was picked. Nothing on a Mac.
private struct ProfilePhotosPicking: ViewModifier {
    @Binding var up: Bool
    @Binding var item: PhotosPickerItem?
    let onPicked: (PhotosPickerItem) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .photosPicker(isPresented: $up, selection: $item, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: item) { _, item in if let item { onPicked(item) } }
        #else
        content
        #endif
    }
}
