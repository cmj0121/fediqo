import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// The page ground is the octopus' ink, on every plate, and it is the only ground there is.
///
/// What a test can reach: the colour of each plate, what every ink of the shell measures on it,
/// that the ground drawn before the app's first frame is the same colour, and that no view's
/// source names a ground of its own. What it cannot: how the violet looks beside a photograph on
/// a running screen, which is named in the report rather than claimed here.
///
/// **The figures are the ones `ShellChrome` states**: 4.5:1 for whatever is written on a plate,
/// and `placeFloor`, 3:1, for a glyph. `MarkContrastTests` holds the dim mark and
/// `WaitingContrastTests` the waiting plates; this holds everything else that is ink.
@Suite("The ground is one ink, and everything written on it can be read")
@MainActor
struct ChassisGroundTests {
    private static let schemes: [ColorScheme] = [.light, .dark]

    /// Small type's floor, which is the one `inkFaint` sets for the file.
    private static let written: Double = 4.5

    // MARK: - The values

    /// The person's pick, as the eight bits a screen is given. A plate nudged by hand moves
    /// here first, and is then measured below.
    @Test("Each plate is the Ink the person picked, in light and in dark")
    func thePlatesAreInk() {
        let picked: [(String, (ColorScheme) -> Color, light: String, dark: String)] = [
            ("page", ShellChrome.page, "#EFF0FF", "#131324"),
            ("rail", ShellChrome.rail, "#E6E6F5", "#0F0E1E"),
            ("well", ShellChrome.well, "#E4E4F3", "#262638"),
            ("raised", ShellChrome.raised, "#E9EAF8", "#1D1D2E"),
            ("hoverFill", ShellChrome.hoverFill, "#EBECFA", "#414155"),
            ("floatFill", ShellChrome.floatFill, "#F8F8FF", "#252537"),
        ]
        for (named, plate, light, dark) in picked {
            #expect(Self.hex(plate(.light), .light) == light, "\(named) in light")
            #expect(Self.hex(plate(.dark), .dark) == dark, "\(named) in dark")
        }
        // The wash under a pointer is a plate in light and a veil in dark, as it was.
        #expect(ShellContrast.resolved(ShellChrome.hoverFill(.light), .light).opacity == 1)
        #expect(abs(Double(ShellContrast.resolved(ShellChrome.hoverFill(.dark), .dark).opacity) - 0.55) < 0.001)
    }

    // MARK: - What is written on them

    /// Every ink that is words somewhere — the ramp's three steps, the lamp, the refusal, and
    /// the four audiences — on every plate, in both schemes.
    @Test("Every ink that is written clears 4.5:1 on every plate")
    func whatIsWrittenCanBeRead() {
        for scheme in Self.schemes {
            var inks: [(String, Color)] = [
                ("ink", ShellChrome.ink(scheme)),
                ("inkDim", ShellChrome.inkDim(scheme)),
                ("inkFaint", ShellChrome.inkFaint(scheme)),
                ("phosphor", ShellChrome.phosphor(scheme)),
                ("alarm", ShellChrome.alarm(scheme)),
            ]
            for audience in DummyAudience.allCases {
                inks.append(("\(audience)", ShellChrome.vis(audience, scheme)))
            }
            for (ink, colour) in inks {
                for (named, ground) in ShellContrast.plates(scheme) {
                    let ratio = ShellContrast.ratio(colour, on: ground, scheme)
                    #expect(ratio >= Self.written, "\(ink) is \(ratio):1 on \(named) in \(scheme)")
                }
            }
        }
    }

    /// The warm hue is a glyph everywhere and a count in one place: beside a mark that is on,
    /// under a post — the page, or the plate a selected row is lifted onto. It is held to text's
    /// floor there and to a glyph's on every plate; on a light recess it is 4.1:1, as it was on
    /// the ground before this one, and nothing is written in it there.
    @Test("The on-mark's hue clears 4.5:1 where its count is written and 3:1 on every plate")
    func theWarmHueStandsApart() {
        for scheme in Self.schemes {
            let filament = ShellChrome.filament(scheme)
            for (named, ground) in ShellContrast.plates(scheme) {
                let ratio = ShellContrast.ratio(filament, on: ground, scheme)
                let floor = ["the page", "a selected row"].contains(named) ? Self.written : ShellChrome.placeFloor
                #expect(ratio >= floor, "filament is \(ratio):1 on \(named) in \(scheme)")
            }
            let chosen = ShellContrast.ratio(filament, on: Self.selectedListRow(scheme), scheme)
            #expect(chosen >= ShellChrome.placeFloor, "filament is \(chosen):1 on a selected list row in \(scheme)")
        }
    }

    /// A selected list row is the lamp's wash over the page, and three inks are written on it:
    /// the lamp itself — what `selectFill` says of itself — `ink`, and `inkDim`. `inkFaint` is
    /// not among them: it is 4.47:1 on this wash in light, and no row writes in it once chosen.
    @Test("What is written on a selected list row clears 4.5:1")
    func whatIsWrittenOnASelectedListRow() {
        for scheme in Self.schemes {
            let written = [
                ("selectInk", ShellChrome.selectInk(scheme)),
                ("ink", ShellChrome.ink(scheme)),
                ("inkDim", ShellChrome.inkDim(scheme)),
            ]
            for (ink, colour) in written {
                let ratio = ShellContrast.ratio(colour, on: Self.selectedListRow(scheme), scheme)
                #expect(ratio >= Self.written, "\(ink) is \(ratio):1 on a selected list row in \(scheme)")
            }
        }
    }

    /// The rule that keeps the faintest ink off that wash where it was written on it: a board's
    /// figures are the faintest ink until the board is chosen, and a step up once it is — and
    /// what they are written in then clears 4.5:1 on the row they are on.
    @Test("A chosen board's figures are written a step up the ramp, and can be read")
    func aChosenBoardsFiguresCanBeRead() {
        for scheme in Self.schemes {
            #expect(BoardPickerList.figuresInk(on: false, scheme) == ShellChrome.inkFaint(scheme))
            #expect(BoardPickerList.figuresInk(on: true, scheme) == ShellChrome.inkDim(scheme))
            let chosen = ShellContrast.ratio(
                BoardPickerList.figuresInk(on: true, scheme), on: Self.selectedListRow(scheme), scheme
            )
            #expect(chosen >= Self.written, "a chosen board's figures are \(chosen):1 in \(scheme)")
            let resting = ShellContrast.ratio(
                BoardPickerList.figuresInk(on: false, scheme), on: [ShellChrome.page(scheme)], scheme
            )
            #expect(resting >= Self.written, "a board's figures are \(resting):1 in \(scheme)")
        }
    }

    // MARK: - One ground

    /// The plates differ from the page by lightness and not by hue: the same violet, so no plate
    /// reads as a second ground laid beside the first.
    @Test("Every plate leans the way the page does: blue over red and green, in both schemes")
    func thePlatesAreOneHue() {
        for scheme in Self.schemes {
            for (named, plate) in [
                ("page", ShellChrome.page(scheme)), ("rail", ShellChrome.rail(scheme)),
                ("well", ShellChrome.well(scheme)), ("raised", ShellChrome.raised(scheme)),
                ("hoverFill", ShellChrome.hoverFill(scheme)), ("floatFill", ShellChrome.floatFill(scheme)),
            ] {
                let drawn = ShellContrast.resolved(plate, scheme)
                #expect(drawn.blue > drawn.red && drawn.blue > drawn.green, "\(named) in \(scheme)")
                #expect(abs(drawn.red - drawn.green) < 0.01, "\(named) in \(scheme)")
            }
        }
    }

    /// The ground the system draws before the app has drawn a frame — the launch screen on a
    /// phone, the window on a Mac — is a named colour in the app's catalogue, since neither can
    /// ask `ShellChrome`. Its two values are the page's, and both hosts name it.
    @Test("What is drawn before the first frame is the page")
    func theGroundBeforeTheFirstFrame() throws {
        let set = Self.root.appendingPathComponent("Apps/Shared/Assets.xcassets/Ground.colorset/Contents.json")
        let catalogue = try JSONDecoder().decode(ColourSet.self, from: Data(contentsOf: set))
        #expect(catalogue.colors.count == 2)
        for entry in catalogue.colors {
            let scheme: ColorScheme = entry.appearances?.contains { $0.value == "dark" } == true ? .dark : .light
            let parts = entry.color.components
            let named = "#" + [parts.red, parts.green, parts.blue].map { $0.dropFirst(2).uppercased() }.joined()
            #expect(entry.color.colorSpace == "srgb")
            #expect(named == Self.hex(ShellChrome.page(scheme), scheme), "the catalogue's ground in \(scheme)")
        }
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(Self.squeezed(project).contains("UILaunchScreen:UIColorName:Ground"))
        let plist = try String(contentsOf: Self.root.appendingPathComponent("Apps/iOS/Info.plist"), encoding: .utf8)
        #expect(Self.squeezed(plist).contains(
            "<key>UILaunchScreen</key><dict><key>UIColorName</key><string>Ground</string>"
        ))
        let app = try String(contentsOf: Self.root.appendingPathComponent("Apps/Shared/FediqoApp.swift"), encoding: .utf8)
        #expect(app.contains(".containerBackground(Color(\"Ground\"), for: .window)"))
    }

    /// No view names a ground of its own: a colour built from numbers, or the system's
    /// background, is written in `ShellChrome` and nowhere else under the shell.
    ///
    /// **A tripwire, and not a proof.** It catches the spellings listed below and no others: a
    /// ground reached through a name this list does not hold, or left to whatever the system
    /// draws by saying nothing at all, passes it.
    @Test("No view builds a colour from numbers or asks the system for its background")
    func noViewNamesItsOwnGround() throws {
        let sources = Self.root.appendingPathComponent("Sources/FediqoUI")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let own = [
            "Color(red:", "Color(white:", "Color(hue:", "Color(nsColor:", "Color(uiColor:", "Color(.s",
            ".background(.background)", ".background()", ".background(.white", "windowBackground", "systemBackground", "systemGroupedBackground",
            "controlBackgroundColor", "textBackgroundColor", "Color.white", "Material)",
        ]
        var read = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            read += 1
            guard file.lastPathComponent != "ShellChrome.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for name in own {
                    #expect(!line.contains(name), "\(file.lastPathComponent) names \(name)")
                }
            }
        }
        #expect(read > 50, "the shell's sources were read")
    }

    // MARK: - Measuring

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private struct ColourSet: Decodable {
        struct Entry: Decodable {
            struct Appearance: Decodable { let value: String }
            struct Colour: Decodable {
                struct Components: Decodable { let red, green, blue: String }
                let colorSpace: String
                let components: Components
                enum CodingKeys: String, CodingKey {
                    case colorSpace = "color-space"
                    case components
                }
            }
            let appearances: [Appearance]?
            let color: Colour
        }
        let colors: [Entry]
    }

    /// A selected list row: the lamp's wash over the page.
    private static func selectedListRow(_ scheme: ColorScheme) -> [Color] {
        [ShellChrome.page(scheme), ShellChrome.selectFill(scheme)]
    }

    /// A file with every space, tab and line end taken out, so what is asked is which key
    /// follows which and not how either tool indents.
    private static func squeezed(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// The colour as the eight bits a channel a screen is handed, opacity aside.
    private static func hex(_ colour: Color, _ scheme: ColorScheme) -> String {
        let drawn = ShellContrast.resolved(colour, scheme)
        return "#" + [drawn.red, drawn.green, drawn.blue]
            .map { String(format: "%02X", Int((Double($0) * 255).rounded())) }
            .joined()
    }
}
