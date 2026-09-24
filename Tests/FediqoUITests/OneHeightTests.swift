import Foundation
import SwiftUI
import Testing
@testable import FediqoUI
#if os(macOS)
import AppKit
#endif

/// #242: a description heads its data, and every row of a list is one height.
///
/// **Measured, not argued.** Each row is hosted off screen and its fitting height read back, at
/// the standard type size and at the largest; a row that grew with what it holds would measure a
/// second number. Only relations are asserted — the ink a system font reports is a fact about the
/// machine. Few and cheap, for the watchdog `test-before-push` names.
@Suite("A description heads its data, and a row is one height", .serialized)
@MainActor
struct OneHeightTests {
    #if os(macOS)
    private static func height(_ view: some View, size: DynamicTypeSize, width: CGFloat = 360) -> CGFloat {
        let host = NSHostingView(rootView: view.dynamicTypeSize(size).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private static let long = String(repeating: "a brief line that runs on well past one line of this row ", count: 6)

    /// The faces a list draws: short, long, none, a long title, a figure and none.
    private static func faces() -> [ShellListRowFace<Image>] {
        let mark = Image(systemName: "server.rack")
        return [
            ShellListRowFace(title: "mastodon.social", brief: "12 posts", figure: "4.2 MB", selected: false, mark: mark),
            ShellListRowFace(title: "mastodon.social", brief: long, figure: "4.2 MB", selected: true, mark: mark),
            ShellListRowFace(title: "forum.example", brief: nil, figure: nil, selected: false, mark: mark),
            ShellListRowFace(title: long, brief: long, figure: nil, selected: false, mark: mark),
            ShellListRowFace(title: "a.example", brief: "short", figure: "12,345 posts held", selected: false, mark: mark),
        ]
    }

    @Test("Every list row is one height, whatever it holds, and the largest type makes them all taller alike")
    func listRowIsOneHeight() {
        let standard = Set(Self.faces().map { Self.height($0, size: .large) })
        #expect(standard.count == 1, "one height at the standard size, got \(standard.sorted())")
        let largest = Set(Self.faces().map { Self.height($0, size: .accessibility5) })
        #expect(largest.count == 1, "one height at the largest size, got \(largest.sorted())")
        #expect((largest.first ?? 0) > (standard.first ?? 0))
    }

    @Test("A row's control does not make it taller than its neighbours")
    func controlKeepsTheHeight() {
        let lit = Binding<String?>.constant(nil)
        let plain = ShellListRow(id: "a", title: "a", brief: "b", selection: lit, onOpen: {}) {
            Image(systemName: "server.rack")
        }
        let switched = ShellListRow(id: "b", title: "b", brief: Self.long, selection: lit, onOpen: {}) {
            Image(systemName: "server.rack")
        } control: {
            Toggle("", isOn: .constant(true)).labelsHidden()
        }
        #expect(Self.height(plain, size: .large) == Self.height(switched, size: .large))
    }
    #endif

    @Test("At the accessibility sizes the figure leads the brief line, and an empty row says nothing")
    func briefLineReads() {
        let font = Font.body
        #expect(ShellListRowFace<Image>.brief(nil, figure: nil, figureFont: font) == nil)
        #expect(ShellListRowFace<Image>.brief("b", figure: nil, figureFont: font) == Text(verbatim: "b"))
        #expect(ShellListRowFace<Image>.brief(nil, figure: "4 MB", figureFont: font) == Text(verbatim: "4 MB").font(font))
        #expect(ShellListRowFace<Image>.brief("b", figure: "4 MB", figureFont: font)
            == Text(verbatim: "4 MB").font(font) + Text(verbatim: " \u{00B7} ") + Text(verbatim: "b"))
    }

    @Test("A group's heading draws its title, its line and its (?), light and dark and at the largest type",
          arguments: [ColorScheme.light, .dark])
    func sectionHeadDraws(_ scheme: ColorScheme) throws {
        for head in [
            ShellSectionHead("Held on this device", line: "Most of this is read again.", help: "The long of it."),
            ShellSectionHead("Sources", line: "Everything this device reads.", help: nil),
            ShellSectionHead("Hosts you added", line: nil, help: "Each serves one of your sources."),
        ] {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let renderer = ImageRenderer(
                    content: head.environment(\.colorScheme, scheme).dynamicTypeSize(size).frame(width: 360)
                )
                let image = try #require(renderer.cgImage)
                #expect(image.width > 0 && image.height > 0)
            }
        }
    }
}
