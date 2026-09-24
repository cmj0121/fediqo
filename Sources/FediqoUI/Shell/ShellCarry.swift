import FediqoCore
import Foundation
import Observation

/// Taking what this device holds away, and reading it back (#247, #252) — the steps, with every
/// decision in one place and nothing drawn here.
///
/// **Take away:** weigh → the person chooses pictures or not → sets a password, told first that
/// a lost one cannot be recovered → the package is written to a scratch file, with progress →
/// the system's mover puts it where the person chooses. **Read back:** the person picks a file →
/// gives its password → sees what it holds and, where this device holds a store, that it will be
/// replaced → says yes → it is read back, with progress → the shell adopts it. Every refusal is
/// its own step with its own sentence, and every way out is `dismiss()`.
///
/// **Nothing leaves this device.** Both acts are written to the run's record under
/// `SourceWork.thisDevice` as they start, which is how the list shows a line that reached
/// nowhere. The carrier does the work off the main actor; only what a screen draws is here.
@MainActor
@Observable
final class ShellCarry {
    /// Where the flow is, or nothing while nothing is under way.
    enum Step: Equatable {
        case weighing
        /// The person is choosing whether pictures ride.
        case choosing(PackageWeight)
        /// The person is setting the password, having chosen.
        case setting(pictures: Bool)
        case taking(PackageProgress)
        /// The package is written; the mover is up, or about to be.
        case moving(URL)
        /// The person is giving a picked file's password.
        case opening(URL)
        /// #252's question: what the package holds, and whether a store here would be replaced.
        case previewing(Preview)
        case reading(PackageProgress)
        case refused(Trouble)
        case done(Done)
    }

    struct Preview: Equatable {
        let url: URL
        let summary: PackageSummary
        /// Whether this device holds a store now, which a yes replaces.
        let held: Bool
    }

    /// Why a step could not go on, each said its own way.
    enum Trouble: Equatable {
        case package(PackageRefusal)
        case noRoom(needed: Int, free: Int)
        case emptyPassword
        case shortPassword
        /// Something else refused — a disk, the Keychain — said as itself.
        case other(String)

        init(_ error: any Error) {
            switch error {
            case let refusal as PackageRefusal: self = .package(refusal)
            case PackageFault.noRoom(let needed, let free): self = .noRoom(needed: needed, free: free)
            case PackageFault.emptyPassword: self = .emptyPassword
            case PackageFault.shortPassword: self = .shortPassword
            default: self = .other(String(describing: error))
            }
        }
    }

    enum Done: Equatable {
        case taken
        case readBack(PackageSummary)
    }

    private(set) var step: Step?

    /// What is asked of the person right now, as a sheet: a password to set, or one to give.
    enum Ask: Identifiable, Equatable {
        case set(pictures: Bool)
        case open(URL)

        var id: String {
            switch self {
            case .set: "set"
            case .open(let url): "open " + url.path
            }
        }
    }

    var ask: Ask? {
        switch step {
        case .setting(let pictures): .set(pictures: pictures)
        case .opening(let url): .open(url)
        default: nil
        }
    }

    /// The question up right now, where the step is one: choosing pictures, previewing a read
    /// back, a refusal or a done notice.
    var asking: Step? {
        switch step {
        case .choosing, .previewing, .refused, .done: step
        default: nil
        }
    }

    var progress: PackageProgress? {
        switch step {
        case .taking(let progress), .reading(let progress): progress
        default: nil
        }
    }

    /// The package written and not yet moved, for the mover.
    var moving: URL? {
        if case .moving(let url) = step { url } else { nil }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The password given for the file being read back, held only between its two steps.
    @ObservationIgnored private var password = ""
    /// A picked file this flow is allowed to read, until it is dismissed.
    @ObservationIgnored private var scoped: URL?
    @ObservationIgnored let work: SourceWork

    init(work: SourceWork = .shared) {
        self.work = work
    }

    // MARK: - Taking away

    /// Weighs, then asks about pictures.
    func beginTakeAway(with carrier: any StoreCarrier) {
        guard step == nil else { return }
        step = .weighing
        run {
            let weight = try await carrier.weigh()
            return .choosing(weight)
        }
    }

    /// The person chose. A package that would not fit the scratch space is refused with the
    /// numbers before a password is asked.
    func chose(pictures: Bool) {
        guard case .choosing(let weight) = step else { return }
        let needed = pictures ? weight.withPictures : weight.withoutPictures
        guard weight.free >= needed else {
            step = .refused(.noRoom(needed: needed, free: weight.free))
            return
        }
        step = .setting(pictures: pictures)
    }

    /// The password is set; the package is written to a scratch file. `save` is what writes the
    /// store to disk first, so the package holds what is on screen.
    func set(password: String, with carrier: any StoreCarrier, save: @escaping @MainActor () async -> Void) {
        guard case .setting(let pictures) = step else { return }
        guard !password.isEmpty else {
            step = .refused(.emptyPassword)
            return
        }
        guard password.count >= PackageFormat.minPasswordCount else {
            step = .refused(.shortPassword)
            return
        }
        step = .taking(PackageProgress(done: 0, total: 0))
        let url = Self.scratchFile()
        work.note(host: SourceWork.thisDevice, for: .takeAway)
        run(save: save) { [weak self] in
            try await carrier.takeAway(to: url, key: .password(password), pictures: pictures) { progress in
                Task { @MainActor in self?.advance(.taking(progress)) }
            }
            return .moving(url)
        }
    }

    /// The mover put the file where the person chose, or did not.
    func moved(_ result: Result<URL, any Error>) {
        guard case .moving(let scratch) = step else { return }
        switch result {
        case .success:
            step = .done(.taken)
        case .failure(let error):
            try? FileManager.default.removeItem(at: scratch)
            step = .refused(.other(String(describing: error)))
        }
    }

    /// The mover was put away without moving: the scratch file goes, and nothing was taken.
    func moveCancelled() {
        guard case .moving(let scratch) = step else { return }
        try? FileManager.default.removeItem(at: scratch)
        step = nil
    }

    /// Where the package is written before the person says where it goes: the app's own
    /// scratch space, named by the day.
    static func scratchFile(now: Date = Date()) -> URL {
        let day = now.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash).year().month().day())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeaway-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Fediqo \(day).fediqo")
    }

    // MARK: - Reading back

    /// The person picked a file. It is held open for the flow, and its password is asked.
    func picked(_ url: URL) {
        guard step == nil else { return }
        if url.startAccessingSecurityScopedResource() { scoped = url }
        step = .opening(url)
    }

    /// The password given: the header is opened and #252's question built from it. Nothing on
    /// this device changes.
    func open(password: String, with carrier: any StoreCarrier) {
        guard case .opening(let url) = step else { return }
        guard !password.isEmpty else {
            step = .refused(.emptyPassword)
            return
        }
        self.password = password
        step = .weighing
        run {
            let summary = try await carrier.preview(url, key: .password(password))
            let held = try await carrier.weigh().holdsStore
            return .previewing(Preview(url: url, summary: summary, held: held))
        }
    }

    /// The person said yes: the package is read back, and `adopt` is run once it is, on the main
    /// actor, so the shell reads what is now here.
    func confirmReadBack(with carrier: any StoreCarrier, adopt: @escaping @MainActor () async -> Void) {
        guard case .previewing(let preview) = step else { return }
        let password = self.password
        step = .reading(PackageProgress(done: 0, total: preview.summary.bytes))
        work.note(host: SourceWork.thisDevice, for: .readBack)
        run { [weak self] in
            try await carrier.readBack(preview.url, key: .password(password), replacing: preview.held) { progress in
                Task { @MainActor in self?.advance(.reading(progress)) }
            }
            await adopt()
            return .done(.readBack(preview.summary))
        }
    }

    // MARK: - Every way out

    /// Whatever is up comes down and whatever is running stops; nothing half done is kept.
    func dismiss() {
        task?.cancel()
        task = nil
        password = ""
        if let scoped {
            scoped.stopAccessingSecurityScopedResource()
            self.scoped = nil
        }
        if case .moving(let scratch) = step { try? FileManager.default.removeItem(at: scratch) }
        step = nil
    }

    /// Whether Escape has something here to close.
    var isUp: Bool { step != nil }

    /// A progress line, taken only while its step is still the one running.
    private func advance(_ next: Step) {
        switch (step, next) {
        case (.taking, .taking), (.reading, .reading): step = next
        default: break
        }
    }

    private func run(save: (@MainActor () async -> Void)? = nil, _ body: @escaping @Sendable () async throws -> Step) {
        task = Task { @MainActor [weak self] in
            await save?()
            do {
                let next = try await body()
                guard !Task.isCancelled else { return }
                self?.step = next
            } catch {
                guard !Task.isCancelled else { return }
                self?.step = .refused(Trouble(error))
            }
        }
    }
}
