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
    /// What App Store Connect takes, in points, which at 1× is also in pixels. The default,
    /// and what every committed picture is taken at.
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
    /// How big to make the window first. The store's size unless a run asked for another --
    /// see `LaunchOptions.shootSize`, and #80, which needs widths no device in the shot list
    /// has because what a screen does at 700 points is what neither 440 nor 1024 shows.
    var size: CGSize = Shooter.size

    /// How long the ask to stop is given before the process stops anyway.
    ///
    /// `NSApp.terminate` is an ask, and a window running a modal session can refuse it — which
    /// is how a screen presented as a sheet used to hang a screenshot run for ever, with the
    /// file already written and the runner waiting on a process that would never end (#99).
    /// The ask is still made, politely, and then this.
    static let patience: DispatchTimeInterval = .seconds(2)

    func body(content: Content) -> some View {
        content.task {
            try? await Task.sleep(for: Self.settle)
            Self.shoot(named: name, at: size)
            Self.leave()
        }
    }

    /// Stops, one way or the other.
    ///
    /// The watchdog is armed before the ask and on a queue of its own, because the thing that
    /// would swallow the ask is a modal loop on the main one.
    @MainActor
    static func leave() {
        DispatchQueue.global().asyncAfter(deadline: .now() + patience) { exit(EXIT_SUCCESS) }
        NSApp.terminate(nil)
    }

    /// The frontmost window, sized and written. Says nothing on success and complains loudly on
    /// failure: a screenshot run that quietly produced no file is a release with a blank space
    /// in it, found by a reviewer.
    @MainActor
    static func shoot(named name: String, at size: CGSize = Shooter.size) {
        // **Not simply the first visible window** (#99). A sheet on macOS is its own window
        // attached to the one behind it, so with one up the first visible window is as likely
        // to be the sheet as the window it is over — and a sheet resized to 1280×800 and
        // photographed alone is neither the screen anybody meant nor a shape a sheet has.
        // The window to photograph is the one that is nobody's sheet.
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil })
        else {
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

        // The rep is told its size in points as well as in pixels, which is what pins the
        // render to 1×. Left alone it would take the window's backing scale and a retina
        // laptop would write 2560×1600 while a runner wrote 1280×800 — the same command
        // producing two different files, which is the one thing this must not do.
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        // And whatever is standing in front of it. Every screen this app presents as a sheet —
        // the inbox, the list of keys — was unphotographable on the Mac without this, and so
        // checked on one platform out of two (#99).
        draw(window.attachedSheet, over: rep, of: window)

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
            // Flushed here rather than left to the exit. stdout to a pipe is block-buffered,
            // and this line sitting in that buffer when the process is killed is a run that
            // wrote its file and told nobody — which is what a hang looked like from outside.
            fflush(stdout)
        } catch {
            complain("could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// The sheet standing over a window, drawn into the picture of that window.
    ///
    /// Where it goes is the one thing worth being careful about: both frames are in screen
    /// coordinates, and the bitmap is of the *content* view, so the offset is measured from
    /// the content rectangle rather than from the frame — the difference is the title bar, and
    /// getting it wrong would put every sheet a few points too high.
    @MainActor
    private static func draw(_ sheet: NSWindow?, over rep: NSBitmapImageRep, of window: NSWindow) {
        guard let sheet, let sheetView = sheet.contentView else { return }
        sheet.displayIfNeeded()

        // **Its layer, and not `cacheDisplay`** — which is what the window behind it is drawn
        // with, and which came back a blank white rectangle here. A sheet's content view is
        // layer-backed, and `cacheDisplay` asks a view hierarchy to draw itself: what is in a
        // layer tree is not in that hierarchy, so it drew the one thing it had, the background.
        guard let layer = sheetView.layer else { return complain("the sheet has no layer") }

        let content = window.contentRect(forFrameRect: window.frame)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.saveGState()
        // Where the sheet is over the window, measured from the *content* rectangle rather than
        // from the frame — the difference is the title bar, and taking the wrong one would put
        // every sheet a few points too high.
        cg.translateBy(x: sheet.frame.minX - content.minX, y: sheet.frame.minY - content.minY)
        // The ground under it. A window's background is drawn by the window and not by the view
        // in it, so rendering the layer alone left the sheet transparent and the timeline
        // reading through its words.
        background(of: sheet).setFill()
        // Rounded to whatever the sheet's own corner is, so the picture has the shape the
        // screen has rather than a rectangle where the app draws a panel.
        let corner = layer.cornerRadius
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: sheetView.bounds.size),
                     xRadius: corner, yRadius: corner).fill()
        // A layer renders from its own top-left downwards, and this bitmap counts from the
        // bottom up, so the last thing done before drawing is to turn it over.
        cg.translateBy(x: 0, y: sheetView.bounds.height)
        cg.scaleBy(x: 1, y: -1)
        layer.render(in: cg)
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// What is under a sheet, in the appearance the run is being photographed in.
    ///
    /// The window's own colour where it has an opaque one, and this app's surface where it does
    /// not — a sheet whose background is `clear` is one whose ground is drawn by something else
    /// entirely, and a screenshot cannot ask that something else to draw itself.
    @MainActor
    private static func background(of sheet: NSWindow) -> NSColor {
        let dark = sheet.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Resolved into a plain colour space rather than left dynamic: a colour that decides
        // what it is from the appearance of whatever is drawing it has nothing to decide from
        // here, and one that answered `clear` would leave the sheet see-through again.
        return NSColor(Palette.surface(dark ? .dark : .light))
            .usingColorSpace(.sRGB) ?? (dark ? .black : .white)
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
    func shooting(to path: String?, at size: CGSize? = nil) -> some View {
        #if DEBUG && os(macOS)
        if let path { modifier(Shooter(name: path, size: size ?? Shooter.size)) } else { self }
        #else
        self
        #endif
    }
}
