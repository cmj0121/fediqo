import SwiftUI

#if DEBUG && os(macOS)
import AppKit
import UniformTypeIdentifiers

/// The Mac app photographing itself, at exactly the size the store takes.
///
/// **`#if DEBUG`, whole file**, and asked for only when `FEDIQO_SHOOT` names a path — the build
/// that goes to the store cannot compile this, and a reader's own run never enters it.
///
/// ## Why the app draws itself rather than something photographing it
///
/// `screencapture` needs the Screen Recording permission, and that is the difference between a
/// laptop and a runner rather than a detail of either. A hosted runner is granted it in the
/// image; the Mac this was written on is not, and answers `could not create image from display`.
/// A screenshot command that works in one place and not the other is two commands, and #30 asks
/// for one.
///
/// A window drawing itself into a bitmap needs no permission at all, because nothing is being
/// captured — the app is rendering its own view hierarchy, which it may always do. So the same
/// line works on a laptop with nothing granted, on a runner, and in a checkout that has never
/// been near either.
///
/// It also settles the size, which `screencapture` cannot. App Store Connect takes 16:10 and
/// nothing else, and no display mode a hosted runner offers is 16:10 — the modes go 1024×768,
/// 1280×720, 1600×900, 1920×1080, and not one of them has the shape. Rendering into a bitmap
/// this file chose the pixel count of makes the display's own size beside the point.
///
/// ## Why exactly 1280×800, and not the retina sizes
///
/// The store's four are 1280×800, 1440×900, 2560×1600 and 2880×1800. The last two are a retina
/// display's, and asking for them here would mean rendering at 2× — which is a different
/// picture, not a bigger one: a 2× render lays out at 1280×800 points and would look identical.
/// It is not that they are impossible; it is that 1280×800 is what this project ships, decided
/// once, and a run on any machine produces the same file.
struct Shooter: ViewModifier {
    /// What App Store Connect takes, in points, which at 1× is also in pixels.
    static let size = CGSize(width: 1280, height: 800)

    /// How long the window is given to finish being a window before it is photographed.
    ///
    /// Everything drawn here is already in the fixture's own temporary directory rather than
    /// off a network, so this is waiting for layout and for `AsyncImage` to read a file — not
    /// for anybody's server. Long enough that a slow runner is not photographed mid-fade.
    static let settle: Duration = .seconds(3)

    /// What to call the file. A name and not a path, and that is the sandbox's doing rather
    /// than a preference: #27 put this app in a box, so it may write into its own container
    /// and nowhere else. Told to write to a directory somebody chose, it is refused — which is
    /// the sandbox working, and the box is not going to be opened for a screenshot.
    ///
    /// So the app writes where it may and says where that was, and whoever asked moves it.
    let name: String

    func body(content: Content) -> some View {
        content.task {
            try? await Task.sleep(for: Self.settle)
            Self.shoot(named: name)
            NSApp.terminate(nil)
        }
    }

    /// The frontmost window, sized and written. Says nothing on success and complains loudly on
    /// failure: a screenshot run that quietly produced no file is a release with a blank space
    /// in it, found by a reviewer.
    @MainActor
    static func shoot(named name: String) {
        guard let window = NSApp.windows.first(where: \.isVisible) else {
            return complain("no window to photograph")
        }
        window.setContentSize(size)
        window.displayIfNeeded()

        guard let view = window.contentView else { return complain("the window has no content") }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return complain("could not make a bitmap of \(size)") }

        // The rep is told it is 1280×800 points as well as pixels, which is what pins the
        // render to 1×. Left alone it would take the window's backing scale and a retina
        // laptop would write 2560×1600 while a runner wrote 1280×800 — the same command
        // producing two different files, which is the one thing this must not do.
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            return complain("could not encode a PNG")
        }
        // Inside the container, because that is the only place there is. The path is printed
        // rather than assumed by the caller: a container's address has the bundle identifier
        // and the operating system's opinions in it, and a script that spells one out is a
        // script that is wrong the day either changes.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try png.write(to: url)
            print("shot: \(url.path)")
        } catch {
            complain("could not write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func complain(_ what: String) {
        FileHandle.standardError.write(Data("shoot: \(what)\n".utf8))
    }
}
#endif

extension View {
    /// Photographs this window and stops, where a run was told to. Nothing anywhere else.
    ///
    /// Declared outside the `#if` above for the reason `fixtureWindow` is: every platform has
    /// to have the method, or the one line calling it stops compiling on the platform with
    /// nothing to do.
    @ViewBuilder
    func shooting(to path: String?) -> some View {
        #if DEBUG && os(macOS)
        if let path { modifier(Shooter(name: path)) } else { self }
        #else
        self
        #endif
    }
}
