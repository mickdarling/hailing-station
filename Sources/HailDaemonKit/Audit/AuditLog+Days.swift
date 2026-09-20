import Foundation

extension AuditLog {
    struct PreviousDay: Equatable, Sendable {
        var day: String
        var hash: String
    }

    /// The newest real day file before `day`. Dotfiles and unrelated names are deliberately ignored;
    /// the selected file is verified and a failure is reported rather than falling back to an older day.
    func previousDay(before day: String, in directoryDescriptor: Int32) throws -> PreviousDay? {
        let names = try Self.directoryNames(in: directoryDescriptor, at: directory)
        var newest: String?
        for name in names {
            guard name.count == 16, name.hasSuffix(".jsonl") else { continue }
            let candidate = String(name.dropLast(6))
            guard AuditChain.dayHasShape(candidate) else { continue }
            guard candidate <= day else {
                throw AuditLogError.fileRefused(
                    path: path(day: day).path, reason: "later day file already exists"
                )
            }
            guard candidate < day else { continue }
            if candidate > (newest ?? "") { newest = candidate }
        }
        guard let newest else { return nil }
        let url = path(day: newest)
        let descriptor = openat(directoryDescriptor, url.lastPathComponent,
                                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? PolicyFileError.wrongType(url.path) : AuditLogError.unwritable(url.path)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { throw AuditLogError.inUse(url.path) }
        defer { flock(descriptor, LOCK_UN) }
        let tail = try Self.verify(lines: try Self.read(descriptor, at: url), path: url.path, day: newest)
        return PreviousDay(day: newest, hash: tail.lastHash)
    }

    static func directoryNames(
        in directoryDescriptor: Int32,
        at directory: URL,
        readEntry: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>? = { readdir($0) }
    ) throws -> [String] {
        let duplicate = openat(directoryDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicate >= 0 else { throw AuditLogError.unwritable(directory.path) }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate)
            throw AuditLogError.unwritable(directory.path)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readEntry(stream) else {
                guard errno == 0 else { throw AuditLogError.unwritable(directory.path) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            names.append(name)
        }
        return names
    }

    func openingRecord(day: String, previous: PreviousDay?, at date: Date) throws -> AuditRecord {
        var chain = AuditChain()
        var record = try chain.append(.chainOpened(day: day), at: date)
        if let previous {
            record.fields["previous_day"] = .string(previous.day)
            record.fields["previous_hash"] = .string(previous.hash)
            record.hash = try AuditChain.hash(of: record)
        }
        return record
    }

    func checkPrevious(_ first: AuditRecord, against previous: PreviousDay?, at url: URL) throws {
        if first.fields["previous_day"] == nil, first.fields["previous_hash"] == nil { return }
        let expectedDay = previous?.day ?? ""
        let expectedHash = previous?.hash ?? AuditChain.genesis
        guard first.fields["previous_day"] == .string(expectedDay),
              first.fields["previous_hash"] == .string(expectedHash) else {
            throw AuditLogError.fileRefused(path: url.path, reason: "previous day link does not match")
        }
    }
}
