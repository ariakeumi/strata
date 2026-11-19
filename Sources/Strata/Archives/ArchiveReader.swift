import Foundation
import os
import StrataArchiveClient
import StrataModel
import StrataSupport

nonisolated package enum ArchiveReadError: Error, LocalizedError {
    case password, limit, unsafe, unreadable, encryption, needsExtraction
    /// Why an archive called `name` can't be read without its password: Strata's listings never ask for one.
    package static func passwordProtected(_ name: String) -> String {
        String(localized: "“\(name)” is password-protected. Open it with Archive Utility to enter the password.")
    }

    package var errorDescription: String? {
        switch self {
        case .needsExtraction: String(localized: "Extract the archive first to preview or copy this item.")
        case .encryption: String(localized: "This archive’s encryption isn’t supported.")
        case .password: String(localized: "The archive password wasn’t accepted.")
        case .limit: String(localized: "This selection is too large to preview or copy here.")
        case .unsafe: String(localized: "This archive contains unsafe or ambiguous paths.")
        case .unreadable: String(localized: "This archive couldn’t be read.")
        }
    }
}

nonisolated package struct ArchiveRecord: Sendable {
    package let path: [String]
    package let kind: UInt8
    package let size: Int64
    package let modified: Date
    package let body: Data?
    package init(path: [String], kind: UInt8, size: Int64, modified: Date, body: Data?) {
        self.path = path; self.kind = kind; self.size = size; self.modified = modified; self.body = body
    }
}

/// The names of an archive's entries, as a tree of components: each is looked up once, so checking a path takes time in
/// proportion to its length however deep it is. A path listed twice, one name spelled two ways (a Unicode alias), and a
/// name that is both a file and a folder are refused before anything is written. A folder a deeper path implied may
/// still be listed itself, once.
nonisolated package struct ArchivePathNames {
    private struct Component: Hashable { let parent: Int; let name: String }
    private var components: [Component: Int] = [:], spellings: [Data] = [], types: [UInt8] = [], listed: [Bool] = []

    package init() {}

    /// Adds `parts`: the last of kind `kind` (2 for a folder), the rest folders.
    package mutating func add(_ parts: [String], kind: UInt8) throws {
        var parent = -1
        for (depth, part) in parts.enumerated() {
            let key = Component(parent: parent, name: part), last = depth == parts.count - 1
            let type: UInt8 = last ? kind : 2
            if let known = components[key] {
                guard spellings[known].elementsEqual(part.utf8), types[known] == type, !(last && listed[known]) else {
                    throw ArchiveReadError.unsafe
                }
                if last { listed[known] = true }
                parent = known
            } else {
                guard spellings.count < 100_000 else { throw ArchiveReadError.limit }
                parent = spellings.count
                components[key] = parent
                spellings.append(Data(part.utf8))
                types.append(type)
                listed.append(last)
            }
        }
    }
}

/// What a survey counted, for the check before Extract. Counts from one that didn't finish are lower bounds; `limited`
/// says it stopped at a limit (time, CPU, memory), which an archive too large to count in time meets.
nonisolated package struct ArchiveSurvey: Sendable, Equatable {
    package var entries = 0
    package var bytes: Int64 = 0
    package var encrypted = false
    package var complete = false
    package var limited = false
    package init(entries: Int = 0, bytes: Int64 = 0, encrypted: Bool = false, complete: Bool = false,
                 limited: Bool = false) {
        self.entries = entries; self.bytes = bytes; self.encrypted = encrypted; self.complete = complete
        self.limited = limited
    }

    /// The size the archive holds at least: all of it when the survey finished, part of it when the survey ran into a
    /// limit. A survey stopped by damage may have counted a size the archive doesn't hold, so it says nothing.
    package var lowerBound: Int64? { complete || limited ? bytes : nil }
}

/// A listing of a whole archive. One cut short keeps what it read, and says why it stopped.
nonisolated package struct ArchiveReadListing: Sendable {
    package enum End: Sendable, Equatable { case complete, moreEntries, stopped(ArchiveReadError) }
    package let records: [ArchiveRecord]
    package let end: End
    package init(records: [ArchiveRecord], end: End) { self.records = records; self.end = end }
}

/// Parses only the worker's bounded, length-delimited protocol. Text command listings never authorize extraction.
nonisolated package enum ArchiveReader {
    /// The most member data one selection reads.
    package static let memberLimit = ArchiveService.byteLimit
    private static let log = Logger(subsystem: "dev.strata.app", category: "archives")

    @concurrent package static func read(_ source: FileReadSource, member: [String]? = nil, directory: Bool = false,
                                password: String? = nil) async throws -> [ArchiveRecord] {
        let path = try requested(member ?? [], password: password)
        let request = ArchiveService.Request(mode: member != nil ? .extract : .list, folder: directory, path: path)
        let (output, status) = try await exchange(source, request, password: password, timeout: 20, allowance: .shared)
        if let error = error(for: status) { throw error }
        return try parse(output, member: member, directory: directory)
    }

    private static func requested(_ member: [String], password: String?) throws -> Data {
        let path = Data(member.joined(separator: "/").utf8)
        guard path.count <= 4096, (password?.utf8.count ?? 0) <= 1024, !path.contains(0),
              !(password?.utf8.contains(0) ?? false) else { throw ArchiveReadError.limit }
        return path
    }

    /// Lists the whole archive, keeping what a listing cut short by its limits, its time or an error read.
    @concurrent package static func list(_ source: FileReadSource, timeout: TimeInterval) async throws
        -> ArchiveReadListing {
        let (output, status) = try await exchange(source, ArchiveService.Request(mode: .list), password: nil,
                                                  timeout: timeout, allowance: .listings)
        let decoded = try decode(output, member: nil, directory: false)
        guard let error = error(for: status) else { return decoded }
        return ArchiveReadListing(records: decoded.records, end: .stopped(error))
    }

    /// Counts what the archive holds without listing it, for the check before Extract.
    @concurrent package static func survey(_ source: FileReadSource, timeout: TimeInterval) async throws
        -> ArchiveSurvey {
        let (output, status) = try await exchange(source, ArchiveService.Request(mode: .survey), password: nil,
                                                  timeout: timeout, allowance: .surveys)
        var survey = decodeSurvey(output)
        let error = error(for: status)
        if error == .password { survey.encrypted = true }
        if error == .limit { survey.limited = true }
        return survey
    }

    /// The last snapshot of a survey's totals, complete only when the worker ended the stream itself.
    package static func decodeSurvey(_ data: Data) -> ArchiveSurvey {
        let bytes = [UInt8](data)
        guard bytes.count <= ArchiveService.outputLimit, bytes.starts(with: Array("SAS1".utf8)) else {
            return ArchiveSurvey()
        }
        func number(_ offset: Int) -> UInt64 { bigEndian(bytes[offset..<(offset + 8)]) }
        var survey = ArchiveSurvey(), offset = 4
        while offset < bytes.count {
            if bytes[offset] == endMark, offset + 1 == bytes.count {
                survey.complete = true
                break
            }
            guard bytes[offset] == snapshotMark, bytes.count - offset >= 18 else { break }
            survey.entries = Int(clamping: number(offset + 1))
            survey.bytes = Int64(clamping: number(offset + 9))
            survey.encrypted = bytes[offset + 17] != 0
            offset += 18
        }
        return survey
    }

    private static func exchange(_ source: FileReadSource, _ request: ArchiveService.Request, password: String?,
                                 timeout: TimeInterval, allowance: ArchiveReadAllowance) async throws
        -> (Data, ArchiveService.Status) {
        try await withRead(source, allowance: allowance) { file in
            try await send(request, password: ArchiveService.Secret(password ?? ""), archive: file, timeout: timeout)
        }
    }

    /// One read in the archive service, pinned to `source` and counted against the reads `allowance` permits at once.
    private static func withRead<T: Sendable>(_ source: FileReadSource, allowance: ArchiveReadAllowance,
                                    _ read: @escaping @Sendable (FileHandle) async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await allowance.enter(id)
        } onCancel: { Task { await allowance.cancel(id) } }
        defer { Task { await allowance.leave(id) } }
        try Task.checkCancellation()
        do {
            return try await source.read(read)
        } catch let error as POSIXError {
            // The archive is gone or changed while it was read (one still downloading does), or staging the read failed.
            log.info("An archive couldn't be read: \(error.localizedDescription, privacy: .public)")
            throw ArchiveReadError.unreadable
        }
    }

    /// Extract's read, on the calling thread: the worker sends every entry of `archive` to `consume`, which reads the
    /// pipe it is given through `reader` (see `ArchiveWriter`). The read's status, once its worker has ended.
    package static func unpack(_ archive: FileHandle, reader: PipeReader, consume: (Int32) throws -> Void) throws
        -> ArchiveService.Status {
        let request = ArchiveService.Request(mode: .unpack).encoded(password: ArchiveService.Secret(""))
        return try routed(request, archive: archive, harness: ["--unpacking"], consume: consume) {
            try ArchiveService.unpack(encoded: request, to: $0, archive: archive, reader: reader, consume: consume)
        }
    }

    /// A read whose output `consume` takes as it comes: through the app's service with `read`, or the harness with
    /// `harness` as its arguments.
    private static func routed(_ request: ArchiveService.Secret, archive: FileHandle, harness arguments: [String],
                               consume: (Int32) throws -> Void, read: (String) throws -> ArchiveService.Reply) throws
        -> ArchiveService.Status {
        switch ReadWorker.selectedRoute {
        case .service(let service):
            let reply = try read(service)
            if !reply.ended { log.error("The archive service didn't confirm that a stopped read's worker ended.") }
            return reply.outcome
        case .harness:
            try ReadWorker.requireHarness()
            guard let input = try ArchiveService.requestPipe(request) else { return .limit }
            defer { try? input.close() }
            let status = try ProcessRunner.stream(ReadWorker.harness.path, arguments, standardInput: input, file: archive,
                                                  consume: consume)
            return ArchiveService.Status(rawValue: status) ?? .unreadable
        case .missingService:
            log.error("The app has no archive service (Contents/XPCServices/StrataArchiveService.xpc).")
            throw ArchiveReadError.unreadable
        }
    }

    package static func error(for status: ArchiveService.Status) -> ArchiveReadError? {
        switch status {
        case .success: return nil
        case .password: return .password
        case .limit: return .limit
        case .unsafe: return .unsafe
        case .encryption: return .encryption
        case .needsExtraction: return .needsExtraction
        case .unsandboxed:
            log.error("Archive reads were refused as unconfined: check the App Sandbox entitlements and the bootstrap port drop.")
            return .unreadable
        case .unreadable, .missing, .stopped: return .unreadable
        }
    }

    private static func send(_ request: ArchiveService.Request, password: ArchiveService.Secret, archive: FileHandle,
                             timeout: TimeInterval) async throws -> (Data, ArchiveService.Status) {
        try await ReadWorker.send(request.encoded(password: password), file: archive, timeout: timeout)
    }

    /// The worker's records, in a stream it ended or not: what was decoded before the stream ended, or turned out
    /// unsafe, is kept.
    package static func decode(_ data: Data, member: [String]?, directory: Bool) throws -> ArchiveReadListing {
        var records: [ArchiveRecord] = []
        do {
            let end = try decode(data, member: member, directory: directory, into: &records)
            return ArchiveReadListing(records: records, end: end)
        } catch let error as ArchiveReadError {
            return ArchiveReadListing(records: records, end: .stopped(error))
        }
    }

    /// The strict form, for a read that must be complete.
    package static func parse(_ data: Data, member: [String]?, directory: Bool) throws -> [ArchiveRecord] {
        let decoded = try decode(data, member: member, directory: directory)
        switch decoded.end {
        case .complete: return decoded.records
        case .moreEntries: throw ArchiveReadError.limit
        case .stopped(let error): throw error
        }
    }

    private static func bigEndian(_ bytes: some Collection<UInt8>) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// The modification times a copy takes: years 1 to 9999.
    fileprivate static let years: ClosedRange<Int64> = -62_135_596_800...253_402_300_799

    /// The worker's marks (CArchivePreview.h).
    package static let endMark: UInt8 = 0, moreMark: UInt8 = 4, snapshotMark: UInt8 = 0x53

    private static func decode(_ data: Data, member: [String]?, directory: Bool,
                               into records: inout [ArchiveRecord]) throws -> ArchiveReadListing.End {
        guard data.count <= ArchiveService.outputLimit, data.starts(with: Data("SAP1".utf8)) else {
            throw ArchiveReadError.unreadable
        }
        var offset = 4
        var names = ArchivePathNames()
        func number(_ count: Int) throws -> UInt64 {
            guard count <= data.count - offset else { throw ArchiveReadError.unreadable }
            defer { offset += count }
            return bigEndian(data[offset..<(offset+count)])
        }
        while offset < data.count {
            try Task.checkCancellation()
            let mark = try number(1)
            if mark == UInt64(endMark) || mark == UInt64(moreMark) {
                guard offset == data.count, member == nil || (mark == UInt64(endMark) && !records.isEmpty) else {
                    throw ArchiveReadError.unreadable
                }
                return mark == UInt64(endMark) ? .complete : .moreEntries
            }
            let kind = mark
            guard (1...3).contains(kind), records.count < 50_000 else { throw ArchiveReadError.limit }
            let count = try number(4), size = try number(8), seconds = Int64(bitPattern: try number(8))
            guard (1...4096).contains(count), count <= data.count - offset, size <= Int64.max else { throw ArchiveReadError.limit }
            // Years 1 to 9999. A listing shows an odd date at the nearest end; a copy refuses it.
            guard member == nil || Self.years.contains(seconds) else { throw ArchiveReadError.unreadable }
            let shown = min(max(seconds, Self.years.lowerBound), Self.years.upperBound)
            let modified = Date(timeIntervalSince1970: Double(shown))
            let bytes = data.subdata(in: offset..<(offset+Int(count)))
            offset += Int(count)
            guard let path = String(data: bytes, encoding: .utf8), !path.hasPrefix("/"), !path.hasSuffix("/"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\\" }) else {
                throw ArchiveReadError.unsafe
            }
            let parts = path.components(separatedBy: "/")
            guard parts.count <= 128, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
                throw ArchiveReadError.unsafe
            }
            try names.add(parts, kind: UInt8(kind))
            var body: Data?
            if let member {
                let chosen = parts.count >= member.count && zip(parts, member).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
                guard chosen, directory || parts.count == member.count, kind != 3,
                      size <= data.count - offset else { throw ArchiveReadError.unsafe }
                if kind == 1 {
                    body = data.subdata(in: offset..<(offset+Int(size)))
                    offset += Int(size)
                }
            }
            records.append(ArchiveRecord(path: parts, kind: UInt8(kind), size: Int64(size),
                                                modified: modified, body: body))
        }
        throw ArchiveReadError.unreadable
    }
}

/// Tells the shipping app, whose service is in its bundle, from a test or development build.
nonisolated private final class PreviewArchiveBundle: NSObject {}
