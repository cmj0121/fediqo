import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// #346: a check removes what it made and nothing else. Every check's scratch is a name of its
/// own **in the one temporary directory**, which the three test processes share with each
/// other and with every other program the person runs — so a teardown that removes the folder
/// *above* what it was given removes all of that, as far as the walk gets.
///
/// That is what made a different check fail each time, and only beside others: four teardowns,
/// in two suites, removed the folder above a package (`PackagerFixture.package()`), which is
/// the temporary directory itself. Whatever store another check had open at that moment lost
/// its index under its connection — the system's SQLite then refuses every read and write of
/// it as a disk I/O error (`SQLITE_IOERR_VNODE`), once its watcher has seen the file go — and
/// its lists, its markers and its copies went with it. Seen by its unlink, with the teardown's
/// own frames above it; never when a suite ran alone, there being nobody else's to remove.
///
/// **Held to the source**, since a removal cannot be watched from inside the process that
/// does it: no check removes the folder above anything, nor the temporary directory by any of
/// the ways it is written. A folder reached through a name of its own (`let above = …;
/// removeItem(at: above)`) is not seen here.
///
/// **What a removed folder does to a store open in it** is held as far as it happens every
/// time: the index is gone from its path at once, and the connection is left holding a file
/// with no name. What SQLite then answers is not held: its watcher runs when it runs, and a
/// statement before it is answered and one after it is refused.
@Suite("A check removes only what it made")
struct ScratchIsOnesOwnTests {
    /// Every removal in `text` of the folder above something, or of the temporary directory
    /// outright — each as it is written, on one line. Read by the removal's whole argument,
    /// over however many lines it is written, and by these spellings of "above":
    ///
    /// - `deletingLastPathComponent`, a URL's or a path's;
    /// - a `".."` appended;
    /// - the temporary directory with nothing appended to it after;
    /// - a name shortened in place (`x.deleteLastPathComponent()`) earlier in the same block.
    static func removalsAbove(in text: String) -> [String] {
        // The names shortened in place, each from where it is shortened to the end of the
        // block it is shortened in.
        var shortened: [(name: String, from: String.Index, to: String.Index)] = []
        var cursor = text.startIndex
        while let hit = text.range(of: #"\w+\.deleteLastPathComponent\(\)"#, options: .regularExpression, range: cursor..<text.endIndex) {
            var depth = 0
            var end = text.endIndex
            var index = hit.upperBound
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" { depth -= 1 }
                if depth < 0 { end = index; break }
                index = text.index(after: index)
            }
            shortened.append((String(text[hit].prefix { $0 != "." }), hit.upperBound, end))
            cursor = hit.upperBound
        }
        var found: [String] = []
        cursor = text.startIndex
        while let call = text.range(of: "removeItem(", range: cursor..<text.endIndex) {
            cursor = call.upperBound
            // The argument, to the parenthesis that closes the call.
            var depth = 1
            var index = call.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1 }
                if depth > 0 { index = text.index(after: index) }
            }
            let argument = text[call.upperBound..<index].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            func says(_ pattern: String) -> Bool { argument.range(of: pattern, options: .regularExpression) != nil }
            let above = says("deletingLastPathComponent") || says(#""\.\.""#)
                || says(#"[tT]emporaryDirectory(?!.*(appending|\+))"#)
                || shortened.contains { $0.from <= call.lowerBound && call.lowerBound < $0.to && says("\\b\($0.name)\\b") }
            if above { found.append("removeItem(\(argument))") }
        }
        return found
    }

    /// The ones read and found to remove what the check itself made: the file, and what it
    /// removes. A line added here is a line somebody has read.
    private static let known: [String: [String]] = [
        // Two up from `scratch()/Application Support/Fediqo`: its own scratch.
        "FediqoCoreTests/GuardedTests.swift": [
            "removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent())",
        ],
    ]

    @Test("The folder above a package is the temporary directory itself: everybody's")
    func thePremise() {
        let above = PackagerFixture.package().deletingLastPathComponent().standardizedFileURL
        #expect(above.path == FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }

    @Test("No check removes the folder above what it was given, nor the temporary directory")
    func nothingAbove() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var found: [String: [String]] = [:]
        var read: [String: Int] = [:]
        // This file is left out: the samples below are the very removals it looks for.
        for path in try FileManager.default.subpathsOfDirectory(atPath: tests.path)
        where path.hasSuffix(".swift") && !path.hasSuffix("ScratchIsOnesOwnTests.swift") {
            read[String(path.prefix { $0 != "/" }), default: 0] += 1
            let above = Self.removalsAbove(in: try String(contentsOf: tests.appendingPathComponent(path), encoding: .utf8))
            if !above.isEmpty { found[path] = above }
        }
        #expect(found == Self.known, "\(found.filter { Self.known[$0.key] != $0.value })")
        // Each of the three targets was read: a walk that found no files would hold nothing.
        for target in ["FediqoCoreTests", "FediqoPersistenceTests", "FediqoUITests"] {
            #expect(read[target, default: 0] > 0, "\(target): no file of it was read")
        }
    }

    @Test("The removals that did it are caught by that reading, in each way they may be written, and a removal of one's own is not", arguments: [
        ("defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }", true),
        ("try FileManager.default.removeItem(atPath: url.deletingLastPathComponent().path)", true),
        ("try manager.removeItem(atPath: (p as NSString).deletingLastPathComponent)", true),
        ("try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory)", true),
        ("try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.standardizedFileURL)", true),
        ("try? manager.removeItem(atPath: NSTemporaryDirectory())", true),
        ("try? manager.removeItem(at: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))", true),
        ("try? FileManager.default.removeItem(\n    at: package\n        .deletingLastPathComponent()\n)", true),
        ("func f() {\n    var x = package\n    x.deleteLastPathComponent()\n    try? FileManager.default.removeItem(at: x)\n}", true),
        ("try? FileManager.default.removeItem(at: package.appendingPathComponent(\"..\"))", true),
        ("defer { try? FileManager.default.removeItem(at: package) }", false),
        ("try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name))", false),
        ("try? manager.removeItem(atPath: NSTemporaryDirectory() + name)", false),
        ("let above = url.deletingLastPathComponent()", false),
        // Shortened in one block, and another's own removed in the next: not the same name's.
        ("func f() {\n    var x = here\n    x.deleteLastPathComponent()\n}\nfunc g() {\n    let x = scratch()\n    try? FileManager.default.removeItem(at: x)\n}", false),
    ])
    func caught(text: String, removes: Bool) {
        #expect(!Self.removalsAbove(in: text).isEmpty == removes, "\(Self.removalsAbove(in: text))")
    }

    @Test("A folder removed while a store is open in it takes the index from its path at once, and leaves the connection a file with no name")
    func removedUnderAStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try StoreFile(at: folder)
        try await file.save(sources: [Source(host: "alpha.test", kind: .mastodon)], notes: [])
        let index = folder.appendingPathComponent(StoreFile.indexName)
        // The connection's own descriptor, found by the file it holds.
        let ending = "/\(folder.lastPathComponent)/\(StoreFile.indexName)"
        let descriptor = try #require((Int32(3)..<getdtablesize()).first { descriptor in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            return fcntl(descriptor, F_GETPATH, &path) == 0 && String(cString: path).hasSuffix(ending)
        }, "the store holds no descriptor on its index")
        var status = stat()
        try #require(fstat(descriptor, &status) == 0)
        #expect(status.st_nlink == 1, "the premise: a file with its name")

        try FileManager.default.removeItem(at: folder)

        #expect(!FileManager.default.fileExists(atPath: index.path))
        try #require(fstat(descriptor, &status) == 0, "the connection no longer holds it")
        #expect(status.st_nlink == 0, "still a file by a name")
        // The store is the one that held it throughout: not closed and made again meanwhile.
        withExtendedLifetime(file) {}
    }
}
