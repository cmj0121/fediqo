import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// The post in focus sits a little above the middle (#473).
@Suite("The post in focus sits a little above the middle")
struct FocusAnchorTests {
    @Test("Two fifths of the way down, across the middle of the row")
    func place() {
        #expect(ShellScroll.focus == UnitPoint(x: 0.5, y: 0.4))
    }

    @Test("No list scrolls a row in focus to the middle any more: every one goes to the one place")
    func everyList() throws {
        let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FediqoUI/Shell")
        let files = try FileManager.default.contentsOfDirectory(atPath: shell.path).filter { $0.hasSuffix(".swift") }
        var focused = 0
        for file in files {
            let source = try String(contentsOf: shell.appendingPathComponent(file), encoding: .utf8)
            #expect(!source.contains("anchor: .center)"), "\(file) still scrolls to the middle")
            focused += source.components(separatedBy: "anchor: ShellScroll.focus)").count - 1
        }
        #expect(focused >= 30, "the lists walked by a keyboard each scroll to the focus")
    }
}
