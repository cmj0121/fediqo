import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #316: the choice to tell a Mastodon where this device stopped in Home, one host at a time,
/// beside the allowances. Off until it is made. A list that cannot be read is left as it is.
@Suite("Which sources are told where you stopped in Home")
@MainActor
struct ShellStoppedTests {
    /// One device's folder and preferences, and the stopped list in it.
    private final class Place {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "fediqo.stopped.\(UUID().uuidString)"
        let defaults: UserDefaults
        let lists: ListFiles

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            lists = ListFiles(directory: directory, defaults: defaults, protected: .always)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }

        var file: ListFile { lists.stopped }
        var onDisk: Data? { try? Data(contentsOf: directory.appendingPathComponent(ListFile.stoppedName)) }
    }

    @Test("Version 1 is the hosts that are on, and no file is none on")
    func read() throws {
        let place = try Place()
        #expect(ShellStopped(file: place.file).hosts.isEmpty)
        #expect(!ShellStopped(file: place.file).unreadable)
        #expect(place.file.write(Data(#"{"version":1,"hosts":["mastodon.social"]}"#.utf8)))
        let stopped = ShellStopped(file: place.file)
        #expect(stopped.hosts == Set(["mastodon.social"]) && !stopped.unreadable)
    }

    @Test("Turning a host on writes version 1 beside the allowances, under its key")
    func write() throws {
        let place = try Place()
        let stopped = ShellStopped(defaults: place.defaults, file: place.file)
        stopped.turnOn("mastodon.social")
        // The encoder's key order is its own: what is on disk is read, not matched byte for byte.
        let written = try #require(place.onDisk.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(written.keys) == ["version", "hosts"])
        #expect(written["version"] as? Int == 1 && written["hosts"] as? [String] == ["mastodon.social"])
        #expect(place.file.key == ShellStopped.key && ShellStopped.key == "fediqo.stopped")
        #expect(place.file.url.lastPathComponent == ListFile.stoppedName && ListFile.stoppedName == "stopped.json")
        #expect(place.file.url.deletingLastPathComponent().path == place.lists.allowances.url.deletingLastPathComponent().path)
        #expect(ShellStopped(file: place.file).hosts == Set(["mastodon.social"]))
    }

    @Test("A host is stored in lower case")
    func lowercased() throws {
        let place = try Place()
        let stopped = ShellStopped(file: place.file)
        stopped.turnOn("Mastodon.Social")
        #expect(stopped.hosts == Set(["mastodon.social"]))
        // The encoder's key order is its own: what is on disk is read, not matched byte for byte.
        let written = try #require(place.onDisk.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(written.keys) == ["version", "hosts"])
        #expect(written["version"] as? Int == 1 && written["hosts"] as? [String] == ["mastodon.social"])
        #expect(ShellStopped(file: place.file).hosts == Set(["mastodon.social"]))
    }

    @Test("A host turned on twice is stored once")
    func duplicate() throws {
        let place = try Place()
        let stopped = ShellStopped(file: place.file)
        stopped.turnOn("mastodon.social")
        stopped.turnOn("Mastodon.Social")
        #expect(stopped.hosts == Set(["mastodon.social"]))
        let data = try #require(place.onDisk)
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(top["hosts"] as? [String] == ["mastodon.social"])
    }

    @Test("A version this build does not know is unreadable and is not written over")
    func unknownVersion() throws {
        let place = try Place()
        let kept = Data(#"{"version":2,"hosts":["mastodon.social"]}"#.utf8)
        #expect(place.file.write(kept))
        let stopped = ShellStopped(file: place.file)
        #expect(stopped.unreadable && stopped.hosts.isEmpty)
        stopped.turnOn("other.social")
        stopped.turnOff("mastodon.social")
        #expect(stopped.unreadable && place.onDisk == kept)
    }

    @Test("A field this build does not know is unreadable and is not written over")
    func extraField() throws {
        let place = try Place()
        let kept = Data(#"{"version":1,"hosts":["mastodon.social"],"since":1}"#.utf8)
        #expect(place.file.write(kept))
        let stopped = ShellStopped(file: place.file)
        #expect(stopped.unreadable && stopped.hosts.isEmpty)
        stopped.turnOn("other.social")
        #expect(stopped.unreadable && place.onDisk == kept)
    }

    @Test("No file, and an empty list, are no host on")
    func emptyIsOff() throws {
        let place = try Place()
        #expect(ShellStopped(file: place.file).hosts.isEmpty && !ShellStopped(file: place.file).unreadable)
        #expect(place.onDisk == nil)
        #expect(place.file.write(Data(#"{"version":1,"hosts":[]}"#.utf8)))
        let stopped = ShellStopped(file: place.file)
        #expect(stopped.hosts.isEmpty && !stopped.unreadable)
    }

    @Test("Turning a host off removes it, and with none left nothing is kept — the same as no file")
    func turnedOff() throws {
        let place = try Place()
        let stopped = ShellStopped(file: place.file)
        stopped.turnOn("mastodon.social")
        stopped.turnOn("other.social")
        stopped.turnOff("Mastodon.Social")
        #expect(stopped.hosts == Set(["other.social"]))
        #expect(ShellStopped(file: place.file).hosts == Set(["other.social"]))
        stopped.turnOff("other.social")
        #expect(stopped.hosts.isEmpty && !stopped.unreadable)
        #expect(place.file.read() == .none)
        let again = ShellStopped(file: place.file)
        #expect(again.hosts.isEmpty && !again.unreadable)
    }

    @Test("What cannot be read is not written over")
    func unreadableStays() throws {
        let place = try Place()
        let kept = Data("not a list".utf8)
        #expect(place.file.write(kept))
        let stopped = ShellStopped(file: place.file)
        #expect(stopped.unreadable)
        stopped.turnOn("mastodon.social")
        stopped.turnOff("mastodon.social")
        #expect(stopped.unreadable && place.onDisk == kept)
    }

    @Test("Handed no file, the choice is kept under its key, and none left removes the key")
    func withoutAFile() throws {
        let suite = "fediqo.stopped.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stopped = ShellStopped(defaults: defaults)
        #expect(stopped.hosts.isEmpty && !stopped.unreadable)
        stopped.turnOn("Mastodon.Social")
        #expect(ShellStopped(defaults: defaults).hosts == Set(["mastodon.social"]))
        stopped.turnOff("mastodon.social")
        #expect(defaults.object(forKey: ShellStopped.key) == nil)
        #expect(ShellStopped(defaults: defaults).hosts.isEmpty && !ShellStopped(defaults: defaults).unreadable)
    }
}
