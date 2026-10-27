import Foundation
import Testing
@testable import haild

struct ReplyFileStabilityTests {
    @Test func growingFileNeedsAnEarlierEqualSizeAndSentFilesAreSkipped() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["second.raw", "growing.raw", "first.raw", "empty.raw", "ignored.txt"].map {
            directory.appendingPathComponent($0)
        }
        for (index, file) in files.enumerated() {
            try Data(repeating: 0, count: index == 3 ? 0 : 4).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(10 - index))],
                                                  ofItemAtPath: file.path)
        }
        var stability = VBSayFileStability()
        #expect(try stability.stableFiles(in: directory).isEmpty) // first pass never publishes
        let handle = try FileHandle(forWritingTo: files[1])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 4))
        try handle.close()
        let stable = try stability.stableFiles(in: directory)
        // Pass two: fresh sizes, modification-date order.
        #expect(stable.map(\.lastPathComponent) == ["first.raw", "second.raw"])
        #expect(!stable.contains { $0.lastPathComponent == "growing.raw" }) // the growing file is never sent early
        stability.sent.formUnion(stable)
        let settled = try stability.stableFiles(in: directory)
        #expect(settled.map(\.lastPathComponent) == ["growing.raw"])
        stability.sent.formUnion(settled)
        #expect(try stability.stableFiles(in: directory).isEmpty)
    }
}
