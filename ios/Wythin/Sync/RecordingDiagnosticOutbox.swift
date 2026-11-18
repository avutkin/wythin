import Foundation

/// Main-actor owned disk state. Reports are separate so a bad record cannot
/// strand the queue. A persisted batch refers to an immutable upload file.
@MainActor
final class RecordingDiagnosticOutbox {
    struct Identity {
        let installationID: UUID
        let launchSequence: Int
    }

    struct Batch: Codable {
        let id: UUID
        let eventIDs: [UUID]
        var attempts = 0
        var notBefore: Date
        var transferID: UUID?
    }

    private struct State: Codable {
        let installationID: UUID
        var launchSequence = 0
        var droppedReports = 0
        var batch: Batch?
        // The counter and removal intent are committed together. A crash
        // between those writes and unlinking must not count a report twice.
        var discardedIDs: [UUID] = []
    }

    private struct Report {
        let id: UUID
        let queuedAt: Date
        let launchSequence: Int
        let sequence: Int
        let url: URL

        init?(url: URL) {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard url.pathExtension == "json", parts.count == 4,
                  let stamp = Double(parts[0]), stamp.isFinite,
                  let launchSequence = Int(parts[1]), let sequence = Int(parts[2]),
                  let id = UUID(uuidString: String(parts[3])) else { return nil }
            self.id = id
            self.queuedAt = Date(timeIntervalSince1970: stamp)
            self.launchSequence = launchSequence
            self.sequence = sequence
            self.url = url
        }
    }

    private struct Payload: Codable {
        let events: [RecordingDiagnosticEvent]
    }

    private let root: URL
    private let reportsDirectory: URL
    private let stateURL: URL
    private let files = FileManager.default
    private var reports: [UUID: Report] = [:]
    private var state: State
    private static let capacity = 2048
    private static let maximumAge: TimeInterval = 48 * 3600
    private static let maxBodyBytes = 256 * 1024
    private static let maximumCounter = 9_007_199_254_740_991

    var droppedReports: Int { state.droppedReports }
    var currentBatch: Batch? { state.batch }

    init(root: URL) throws {
        self.root = root
        reportsDirectory = root.appendingPathComponent("reports", isDirectory: true)
        stateURL = root.appendingPathComponent("state.json")
        let protection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try files.createDirectory(at: reportsDirectory, withIntermediateDirectories: true, attributes: protection)
        var directory = root
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try directory.setResourceValues(properties)
        // Reading rather than checking existence distinguishes missing files
        // from a protected volume that has not yet been unlocked.
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            state = State(installationID: UUID())
        }
        let reportFiles = try files.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil)
        for url in reportFiles.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let report = Report(url: url), reports[report.id] == nil else {
                try remove(url)
                continue
            }
            reports[report.id] = report
        }
        try finishDiscards()
        try invalidateCorruptBatch()
        try cleanOrphanPayloads()
    }

    func beginLaunch() throws -> Identity {
        guard state.launchSequence < Self.maximumCounter else { throw CocoaError(.fileWriteOutOfSpace) }
        var updated = state
        updated.launchSequence += 1
        try commit(updated)
        return Identity(installationID: updated.installationID, launchSequence: updated.launchSequence)
    }

    func payloadURL(_ batch: Batch) -> URL { root.appendingPathComponent("batch-\(batch.id.uuidString).json") }

    func enqueue(_ event: RecordingDiagnosticEvent, at now: Date) throws {
        try finishDiscards()
        guard reports[event.eventId] == nil else { return }
        let body = try RecordingDiagnosticEvent.encoder().encode(event)
        guard body.count <= Self.maxBodyBytes - 13 else {
            try discard([event.eventId])
            return
        }
        let stamp = now.timeIntervalSince1970
        let name = "\(stamp)_\(event.launchSequence)_\(event.sequence)_\(event.eventId.uuidString).json"
        let url = reportsDirectory.appendingPathComponent(name)
        guard let report = Report(url: url) else { throw CocoaError(.fileWriteInvalidFileName) }
        try write(body, to: url)
        reports[report.id] = report
        _ = try pendingReports(at: now)
    }

    func nextBatch(at now: Date) throws -> Batch? {
        try finishDiscards()
        try invalidateCorruptBatch()
        let pending = try pendingReports(at: now)
        if let batch = state.batch { return batch }
        var body = Data("{\"events\":[".utf8)
        var members: [UUID] = []
        var invalid: [UUID] = []
        let decoder = RecordingDiagnosticEvent.decoder()
        let encoder = RecordingDiagnosticEvent.encoder()
        for report in pending {
            let data: Data
            do {
                data = try readReport(report)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileReadCorruptFile {
                invalid.append(report.id)
                continue
            }
            guard let event = try? decoder.decode(RecordingDiagnosticEvent.self, from: data),
                  event.eventId == report.id, event.schemaVersion == 1,
                  event.launchSequence == report.launchSequence, event.sequence == report.sequence else {
                invalid.append(report.id)
                continue
            }
            // Decoding can ignore unknown fields. Upload only the model's
            // typed keys and values, even when replaying a stored snapshot.
            let wire = try encoder.encode(event)
            guard body.count + (members.isEmpty ? 0 : 1) + wire.count + 2 <= Self.maxBodyBytes else { break }
            if !members.isEmpty { body.append(44) } // comma
            body.append(wire)
            members.append(report.id)
            if members.count == 50 { break }
        }
        try discard(invalid)
        guard !members.isEmpty else { return nil }
        body.append(contentsOf: "]}".utf8)
        let batch = Batch(id: UUID(), eventIDs: members, notBefore: now)
        try write(body, to: payloadURL(batch))
        var updated = state
        updated.batch = batch
        do { try commit(updated) }
        catch {
            try? remove(payloadURL(batch))
            throw error
        }
        return batch
    }

    func registerTransfer(_ batch: Batch) throws -> UUID {
        guard var current = state.batch, current.id == batch.id else { throw CocoaError(.fileNoSuchFile) }
        let id = UUID()
        current.transferID = id
        var updated = state
        updated.batch = current
        try commit(updated)
        return id
    }

    func retry(_ batch: Batch, at now: Date) throws {
        guard var current = state.batch, current.id == batch.id else { return }
        current.attempts = min(8, current.attempts + 1)
        current.notBefore = now.addingTimeInterval(min(3600, 30 * pow(2, Double(current.attempts - 1))))
        current.transferID = nil
        var updated = state
        updated.batch = current
        try commit(updated)
    }

    func resolve(_ batch: Batch, dropped: Bool) throws {
        try finishDiscards()
        guard state.batch?.id == batch.id else { return }
        var updated = state
        updated.batch = nil
        updated.discardedIDs = batch.eventIDs
        if dropped { updated.droppedReports = min(Self.maximumCounter, updated.droppedReports + batch.eventIDs.count) }
        try commit(updated)
        try finishDiscards()
        try cleanOrphanPayloads()
    }

    func clear() throws {
        try finishDiscards()
        if state.batch != nil || !reports.isEmpty {
            var updated = state
            updated.batch = nil
            updated.discardedIDs = Array(reports.keys)
            try commit(updated)
            try finishDiscards()
        }
        for url in try files.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: nil) {
            try remove(url)
        }
        try cleanOrphanPayloads()
    }

    private func pendingReports(at now: Date) throws -> [Report] {
        let inFlight = Set(state.batch?.eventIDs ?? [])
        let pending = reports.values.filter { !inFlight.contains($0.id) }
        let oldest = now.addingTimeInterval(-Self.maximumAge)
        let fresh = pending.filter { $0.queuedAt >= oldest }.sorted {
            if $0.launchSequence != $1.launchSequence { return $0.launchSequence > $1.launchSequence }
            if $0.sequence != $1.sequence { return $0.sequence > $1.sequence }
            return $0.id.uuidString > $1.id.uuidString
        }
        try discard(pending.filter { $0.queuedAt < oldest }.map(\.id)
                    + fresh.dropFirst(Self.capacity).map(\.id))
        return Array(fresh.prefix(Self.capacity))
    }

    private func discard(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        var updated = state
        updated.discardedIDs = ids
        updated.droppedReports = min(Self.maximumCounter, updated.droppedReports + ids.count)
        try commit(updated)
        try finishDiscards()
    }

    func finishDiscards() throws {
        guard !state.discardedIDs.isEmpty else { return }
        for id in state.discardedIDs {
            guard let report = reports[id] else { continue }
            try remove(report.url)
            reports.removeValue(forKey: id)
        }
        var updated = state
        updated.discardedIDs = []
        try commit(updated)
    }

    private func invalidateCorruptBatch() throws {
        guard let batch = state.batch, try !validPayload(for: batch) else { return }
        // The old transfer token can no longer be restored. The source
        // reports can build a fresh batch from permitted fields.
        var updated = state
        updated.batch = nil
        try commit(updated)
        try remove(payloadURL(batch))
    }

    private func validPayload(for batch: Batch) throws -> Bool {
        let data: Data
        let url = payloadURL(batch)
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maxBodyBytes else { return false }
            data = try Data(contentsOf: url)
        }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
        guard data.count <= Self.maxBodyBytes,
              let payload = try? RecordingDiagnosticEvent.decoder().decode(Payload.self, from: data),
              !payload.events.isEmpty, payload.events.count <= 50,
              payload.events.allSatisfy({ $0.schemaVersion == 1 }),
              payload.events.map(\.eventId) == batch.eventIDs else { return false }
        // Only resume the exact canonical body. This catches extra keys,
        // including repeated JSON keys a decoder could otherwise ignore.
        return data == (try RecordingDiagnosticEvent.encoder().encode(payload))
    }

    private func readReport(_ report: Report) throws -> Data {
        let size = try report.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= Self.maxBodyBytes - 13 else { throw CocoaError(.fileReadCorruptFile) }
        return try Data(contentsOf: report.url)
    }

    private func cleanOrphanPayloads() throws {
        let active = state.batch.map(payloadURL)?.lastPathComponent
        for url in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("batch-") && url.lastPathComponent != active {
            try remove(url)
        }
    }

    private func remove(_ url: URL) throws {
        do { try files.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    private func commit(_ updated: State) throws {
        try write(JSONEncoder().encode(updated), to: stateURL)
        state = updated
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
