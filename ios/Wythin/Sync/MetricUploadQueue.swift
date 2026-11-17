import Foundation

/// The server counts accepted input rows, including idempotent replays. Only
/// completely valueless rows may be skipped; a partial receipt is not an ack.
enum MetricUploadReceipt {
    struct Counts: Decodable { let stored: Int; let skipped: Int? }
    static func validate(_ data: Data, stored: Int, skipped: Int) throws {
        let receipt = try JSONDecoder().decode(Counts.self, from: data)
        guard receipt.stored == stored, (receipt.skipped ?? 0) == skipped,
              receipt.stored >= 0, (receipt.skipped ?? 0) >= 0 else {
            throw URLError(.badServerResponse)
        }
    }
}

/// Immutable, credential-free payload files plus atomic retry/receipt records.
/// A receipt remains durable until its SwiftData membership has been saved.
/// The service bounds this queue to three batches; the remaining backlog stays
/// in SwiftData, so long offline recordings do not duplicate the whole store.
final class MetricUploadQueue {
    struct Entry: Codable, Identifiable {
        let id: UUID
        let members: [Data]
        let latestSampleAt: Date
        let expectedStored: Int
        let expectedSkipped: Int
        let createdAt: Date
        var attempts = 0
        var nextAttemptAt: Date
        var acknowledgedAt: Date?
    }
    private struct State: Codable { let migrationBoundary: Date }
    let root: URL
    let migrationBoundary: Date
    private(set) var entries: [Entry] = []

    init(root: URL, migrationBoundary: Date) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: root.path)
        #endif
        var excluded = root
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try excluded.setResourceValues(resources)
        let stateURL = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            self.migrationBoundary = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)).migrationBoundary
        } else {
            self.migrationBoundary = migrationBoundary
            try Self.write(try JSONEncoder().encode(State(migrationBoundary: migrationBoundary)), to: stateURL)
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "batch" {
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
            guard file.deletingPathExtension().lastPathComponent == entry.id.uuidString,
                  entry.expectedStored >= 0, entry.expectedSkipped >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            entries.append(entry)
        }
        entries.sort { $0.createdAt < $1.createdAt }
        // A crash after writing payload but before the manifest cannot lose a
        // sample: its SwiftData marker is still pending, so it is rebuilt.
        let known = Set(entries.map { $0.id.uuidString })
        for file in files where file.pathExtension == "payload" && !known.contains(file.deletingPathExtension().lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func payloadURL(for id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).payload") }
    private func metadataURL(for id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).batch") }

    @discardableResult
    func enqueue(payload: Data, members: [Data], latestSampleAt: Date,
                 expectedStored: Int, expectedSkipped: Int, now: Date) throws -> Entry {
        guard expectedStored >= 0, expectedSkipped >= 0, expectedStored + expectedSkipped > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let entry = Entry(id: UUID(), members: members, latestSampleAt: latestSampleAt,
                          expectedStored: expectedStored, expectedSkipped: expectedSkipped,
                          createdAt: now, nextAttemptAt: now)
        try Self.write(payload, to: payloadURL(for: entry.id))
        try persist(entry)
        entries.append(entry)
        return entry
    }

    func fail(_ id: UUID, now: Date) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].acknowledgedAt == nil else { return }
        var entry = entries[index]
        entry.attempts = min(entry.attempts + 1, 30)
        let delay = min(3600, 30 * pow(2, Double(min(entry.attempts - 1, 8))))
        entry.nextAttemptAt = now.addingTimeInterval(delay)
        try persist(entry)
        entries[index] = entry
    }

    func acknowledge(_ id: UUID, response: Data, now: Date) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].acknowledgedAt == nil else { return }
        var entry = entries[index]
        try MetricUploadReceipt.validate(response, stored: entry.expectedStored, skipped: entry.expectedSkipped)
        entry.acknowledgedAt = now
        try persist(entry)
        entries[index] = entry
    }

    /// Call only after the matching rows have been durably marked accepted.
    func removeAcknowledged(_ id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].acknowledgedAt != nil else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.removeItem(at: metadataURL(for: id))
        entries.remove(at: index)
        // An orphan payload is safe and will also be removed during reopening.
        try? FileManager.default.removeItem(at: payloadURL(for: id))
    }

    private func persist(_ entry: Entry) throws {
        try Self.write(try JSONEncoder().encode(entry), to: metadataURL(for: entry.id))
    }
    private static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
