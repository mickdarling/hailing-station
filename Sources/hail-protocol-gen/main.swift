import Foundation
import HailProtocol
import HailProtocolFixtures

// Usage: swift run hail-protocol-gen [fixtures-dir]   (default: fixtures/frames)
let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "fixtures/frames")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for example in Fixtures.all {
    let data = try FrameCoding.encode(example.frame)
    try (data + Data([0x0A])).write(to: directory.appendingPathComponent("\(example.name).json"))
}
let schemaDirectory = directory.deletingLastPathComponent().appendingPathComponent("schema")
try FileManager.default.createDirectory(at: schemaDirectory, withIntermediateDirectories: true)
let schema = try FrameCoding.encoder().encode(Schema.json) + Data([0x0A])
try schema.write(to: schemaDirectory.appendingPathComponent("frame-v\(ProtocolVersion.current).schema.json"))
print("wrote \(Fixtures.all.count) fixtures to \(directory.path) and the v\(ProtocolVersion.current) schema")
