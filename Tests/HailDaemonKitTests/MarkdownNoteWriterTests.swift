#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// The Markdown destination's handler (#552): each note is one dated list item appended to the owner's file.
@Suite(.serialized) struct MarkdownNoteWriterTests {
    static let writer = MarkdownNoteWriter(now: { Date(timeIntervalSince1970: 0) })
    static let stamp = MarkdownNoteWriter.stamp(Date(timeIntervalSince1970: 0))

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func aNoteIsAppendedAsOneDatedItemOnALineOfItsOwn() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Inbox.md")
        try Data("# Inbox\n\n- older".utf8).write(to: file)
        #expect(Self.writer.append("buy milk;\nthen eggs", to: file.path) == "saved")
        #expect(Self.writer.append("call Dr. Lee", to: file.path) == "saved")
        let body = try String(contentsOf: file, encoding: .utf8)
        #expect(body == "# Inbox\n\n- older\n- \(Self.stamp) buy milk; then eggs\n- \(Self.stamp) call Dr. Lee\n")
    }

    @Test func anAbsentFileIsCreatedPrivate() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("New.md")
        #expect(Self.writer.append("x", to: file.path) == "saved")
        #expect(try String(contentsOf: file, encoding: .utf8) == "- \(Self.stamp) x\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    /// Never through a symlink, into a FIFO or directory, or into a directory that is not there.
    @Test func onlyARegularFileAtThatPathIsWritten() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real.md")
        try Data().write(to: real)
        let link = directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(Self.writer.append("x", to: link.path) == "open_failed")
        #expect(try Data(contentsOf: real).isEmpty)
        let fifo = directory.appendingPathComponent("fifo.md")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(Self.writer.append("x", to: fifo.path) == "not_a_file")
        let folder = directory.appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(Self.writer.append("x", to: folder.path) == "open_failed")
        #expect(Self.writer.append("x", to: directory.appendingPathComponent("gone/Inbox.md").path) == "open_failed")
    }

    @Test func theStampIsMinutesInAFixedFormat() {
        #expect(MarkdownNoteWriter.stamp(Date()).wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/) != nil)
    }
}
#endif
