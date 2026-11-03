import Foundation
import simd

/// The server's dedicated archive is not provisioned yet. Keep the raw
/// transport implementation dormant until the archive and its backup exist;
/// scalar metrics continue recording and syncing independently.
enum RawArchiveFeature {
    static let isAvailable = false
}

/// Small, bounded forensic record independent of metric computation and the
/// deferred raw archive. The Bluetooth delegate records packet counts before
/// handing work to the main actor; comparing these counts with saved metrics
/// distinguishes sensor delivery loss from a stalled processing pipeline.
final class CaptureAuditLog: @unchecked Sendable {
    struct Entry: Codable {
        let at: String
        let event: String
        let ecgPackets: Int
        let accPackets: Int
        let hrPackets: Int
        let rrIntervals: Int
        let savedMetrics: Int
        let failedSaves: Int
        let invalidPackets: Int
    }

    private let lock = NSLock()
    private let directory: URL
    private let file: URL
    private let maxBytes = 10_000_000
    private var lastSnapshotAt: Date?
    private var ecgPackets = 0
    private var accPackets = 0
    private var hrPackets = 0
    private var rrIntervals = 0
    private var savedMetrics = 0
    private var failedSaves = 0
    private var invalidPackets = 0

    init(directory: URL) throws {
        self.directory = directory
        self.file = directory.appendingPathComponent("capture-audit.jsonl")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: file.path)
        }
        try append(event: "launch", at: Date())
    }

    func recordBLE(_ stream: RawPacketRecord.Stream, rrCount: Int,
                   valid: Bool = true, at: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .ecg: ecgPackets += 1
        case .acc: accPackets += 1
        case .hr: hrPackets += 1
        }
        rrIntervals += rrCount
        if !valid { invalidPackets += 1 }
        snapshotIfDue(at: at)
    }

    func recordMetricSave(success: Bool, at: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if success { savedMetrics += 1 } else { failedSaves += 1 }
        snapshotIfDue(at: at)
    }

    func recordPhase(_ phase: String, at: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        try? append(event: phase, at: at)
    }

    /// Read-only export for device diagnostics and regression tests.
    func entries() throws -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let previous = directory.appendingPathComponent("capture-audit.previous.jsonl")
        return try [previous, file].filter { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
    }

    private func snapshotIfDue(at date: Date) {
        guard lastSnapshotAt.map({ date.timeIntervalSince($0) >= 10 }) ?? true else { return }
        do {
            try append(event: "snapshot", at: date)
            lastSnapshotAt = date
        } catch {
            // A failed diagnostic write must not stop the Bluetooth callback.
            // Retry on the next packet instead of advancing the snapshot clock.
        }
    }

    private func append(event: String, at date: Date) throws {
        let entry = Entry(at: ISO8601DateFormatter().string(from: date), event: event,
                          ecgPackets: ecgPackets, accPackets: accPackets,
                          hrPackets: hrPackets, rrIntervals: rrIntervals,
                          savedMetrics: savedMetrics, failedSaves: failedSaves,
                          invalidPackets: invalidPackets)
        var bytes = try JSONEncoder().encode(entry)
        bytes.append(0x0A)
        if (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 >= maxBytes {
            let previous = directory.appendingPathComponent("capture-audit.previous.jsonl")
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.moveItem(at: file, to: previous)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }
}

/// Exact Core Bluetooth notification bytes, before parsing or downsampling.
struct RawPacketRecord: Codable {
    enum Stream: String, Codable { case ecg, acc, hr }
    let id: UUID
    let stream: Stream
    let receivedAt: Date
    let deviceTimestampNs: UInt64?
    let payload: Data
}

/// Append-only packet segments. A complete JSON line is one notification;
/// an interrupted final line is discarded on restart. Completed segments are
/// left on disk until the server has acknowledged their contents.
final class RawPacketJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let maxBytes = 1_000_000
    private var currentURL: URL
    private var handle: FileHandle
    private var bytesWritten = 0
    private var openedAt = Date()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        // Background BLE delivery can continue after the screen locks. Keep
        // these files protected while allowing access after the first unlock.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
        for url in try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)
            where url.pathExtension == "open" {
            let data = try Data(contentsOf: url)
            if let lastNewline = data.lastIndex(of: 0x0A) {
                let writer = try FileHandle(forWritingTo: url)
                try writer.truncate(atOffset: UInt64(lastNewline + 1))
                try writer.close()
                try FileManager.default.moveItem(at: url,
                    to: url.deletingPathExtension().appendingPathExtension("ready"))
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("open")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        currentURL = url
        handle = try FileHandle(forWritingTo: url)
    }

    @discardableResult
    func append(stream: RawPacketRecord.Stream, payload: Data,
                receivedAt: Date, deviceTimestampNs: UInt64?) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let record = RawPacketRecord(id: UUID(), stream: stream,
                                     receivedAt: receivedAt,
                                     deviceTimestampNs: deviceTimestampNs,
                                     payload: payload)
        var line = try JSONEncoder().encode(record)
        line.append(0x0A)
        try handle.write(contentsOf: line)
        try handle.synchronize()
        bytesWritten += line.count
        if bytesWritten >= maxBytes || receivedAt.timeIntervalSince(openedAt) >= 60 {
            try sealLocked()
            return true
        }
        return false
    }

    func seal() throws {
        lock.lock()
        defer { lock.unlock() }
        try sealLocked()
    }

    private func sealLocked() throws {
        guard bytesWritten > 0 else { return }
        try handle.close()
        try FileManager.default.moveItem(at: currentURL,
            to: currentURL.deletingPathExtension().appendingPathExtension("ready"))
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("open")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        currentURL = url
        handle = try FileHandle(forWritingTo: url)
        bytesWritten = 0
        openedAt = Date()
    }

    func pendingChunks() throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return try FileManager.default.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ready" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func acknowledge(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard url.deletingLastPathComponent() == directory,
              url.pathExtension == "ready" else { throw CocoaError(.fileReadNoPermission) }
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Circular Buffer

/// Fixed-capacity FIFO that overwrites the oldest element when full.
struct CircularBuffer<T> {
    private var storage: [T]
    private var head: Int = 0   // write index
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int, defaultValue: T) {
        self.capacity = capacity
        self.storage  = [T](repeating: defaultValue, count: capacity)
    }

    mutating func append(_ value: T) {
        storage[head] = value
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    mutating func append(contentsOf values: [T]) {
        for v in values { append(v) }
    }

    /// Returns elements in FIFO order (oldest first).
    func toArray() -> [T] {
        guard count > 0 else { return [] }
        if count < capacity {
            return Array(storage[0..<count])
        }
        // Wrap-around case
        let start = head % capacity
        return Array(storage[start...]) + Array(storage[..<start])
    }

    /// Most recent `n` elements (or all if count < n).
    func last(_ n: Int) -> [T] {
        let all = toArray()
        return Array(all.suffix(n))
    }

    mutating func clear() {
        head = 0
        count = 0
    }
}

// MARK: - DataBuffer Actor

/// Actor-isolated ring buffers mirroring the Python DataBuffer.
/// All mutations and reads are serialised through the actor executor.
actor DataBuffer {

    // ECG: 130 Hz × 8 s = 1040 samples for metrics; keep 10 s for display
    private var ecgBuf:  CircularBuffer<Float>        = CircularBuffer(capacity: 1300, defaultValue: 0)
    // ACC Z: 200 Hz × 60 s = 12 000 samples (needed for coherence, phase detection)
    // 16384 samples = 81.9 s at 200 Hz. Sized so `welchPSD` at nperseg 8192
    // still averages 3 half-overlapping segments — at the old 12000 the finer
    // resolution would have degraded the estimate to a single bare
    // periodogram, whose variance is what makes a peak jitter between bins.
    // `CoherenceCompute` deliberately does NOT inherit this wider window: it
    // pins itself to the last 12000 samples. Any other consumer of the ACC
    // arrays must make the same choice consciously.
    private var accZBuf: CircularBuffer<Float>        = CircularBuffer(capacity: 16384, defaultValue: 0)
    // ACC XYZ: keep 60 s for breathing/phase
    private var accXYZBuf: CircularBuffer<SIMD3<Float>> = CircularBuffer(capacity: 16384, defaultValue: .zero)
    // RR intervals: last 1200 beats (~20 min at rest).
    // ULF power (0–0.003 Hz) requires fftLen ≥ 2048, which needs ~600 beats; 1200 gives comfortable headroom.
    private var rrBuf:   CircularBuffer<Int>          = CircularBuffer(capacity: 1200, defaultValue: 0)
    // Instantaneous BPM (for ULF power, logged at 0.5 Hz)
    private var bpmBuf:  CircularBuffer<Float>        = CircularBuffer(capacity: 1800, defaultValue: 0)

    // MARK: Write

    func appendECG(_ samples: [Float]) {
        ecgBuf.append(contentsOf: samples)
    }

    func appendACC(xyz: [SIMD3<Int16>]) {
        for v in xyz {
            let fv = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
            accXYZBuf.append(fv)
            accZBuf.append(fv.z)
        }
    }

    func appendRR(_ intervals: [Int]) {
        for rr in intervals where rr >= 300 && rr <= 2000 {
            rrBuf.append(rr)
        }
    }

    func appendBPM(_ bpm: Float) {
        bpmBuf.append(bpm)
    }

    // MARK: Read — Snapshot

    /// Returns copies of all buffers for off-actor metric computation.
    func snapshot(ecgLive: Bool = true, accLive: Bool = true) -> DataSnapshot {
        DataSnapshot(
            ecg:    ecgLive ? ecgBuf.toArray() : [],
            accZ:   accLive ? accZBuf.toArray() : [],
            accXYZ: accLive ? accXYZBuf.toArray() : [],
            rr:     rrBuf.toArray(),
            bpm:    bpmBuf.toArray()
        )
    }

    /// Last N ECG samples for waveform display.
    func ecgDisplay(samples: Int = 650) -> [Float] {
        ecgBuf.last(samples)
    }

    /// Last N ACC Z samples for breathing waveform display (200 Hz → 3 s = 600 samples).
    func accDisplay(samples: Int = 600) -> [Float] {
        accZBuf.last(samples)
    }

    /// All clean RR intervals as Float (ms), FIFO order — for tachogram display.
    func rrDisplay() -> [Float] {
        rrBuf.toArray().map { Float($0) }
    }

    /// RR interval count (used to check whether metrics are computable).
    var rrCount: Int { rrBuf.count }

    func clear() {
        ecgBuf.clear()
        accZBuf.clear()
        accXYZBuf.clear()
        rrBuf.clear()
        bpmBuf.clear()
    }
}

// MARK: - Snapshot (value type for off-actor processing)

struct DataSnapshot {
    let ecg:    [Float]
    let accZ:   [Float]
    let accXYZ: [SIMD3<Float>]
    let rr:     [Int]
    let bpm:    [Float]
}
