import Foundation
import Darwin
import os

/// Local technical evidence only. Reuses the bounded BLE log/export, never the
/// strict automatic-report schema. A sampled peak is not an OS lifetime peak.
@MainActor
final class RecordingMemoryMonitor {
    struct Snapshot {
        var footprintBytes: UInt64?
        var availableBytes: UInt64?
    }
    private let read: () -> Snapshot
    private let output: (String) -> Void
    private var lastSample: TimeInterval?
    private var observedPeak: UInt64?

    init(read: @escaping () -> Snapshot = RecordingMemoryMonitor.systemSnapshot,
         output: @escaping (String) -> Void = BLEDiag.log) {
        self.read = read; self.output = output
    }

    func record(_ reason: RecordingDiagnosticEvent.Reason, uptime: TimeInterval) {
        guard uptime.isFinite, uptime >= 0 else { return }
        if reason != .memoryWarning, let lastSample, uptime >= lastSample, uptime - lastSample < 60 {
            return
        }
        lastSample = uptime
        let snapshot = read()
        if let footprint = snapshot.footprintBytes {
            observedPeak = max(observedPeak ?? footprint, footprint)
        }
        func bytes(_ value: UInt64?) -> String { value.map(String.init) ?? "unknown" }
        output("MEMORY reason=\(reason.rawValue) footprint_bytes=\(bytes(snapshot.footprintBytes)) " +
               "observed_peak_bytes=\(bytes(observedPeak)) available_bytes=\(bytes(snapshot.availableBytes))")
    }

    nonisolated static func systemSnapshot() -> Snapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Snapshot(footprintBytes: status == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil,
                        // Advisory headroom, not a promise that an allocation will
                        // succeed. Zero is valid when the process is at its limit.
                        availableBytes: UInt64(os_proc_available_memory()))
    }
}

enum RecordingDiagnostics {
    private static let sectionLimit = 262_144

    static func readTail(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > UInt64(sectionLimit) ? size - UInt64(sectionLimit) : 0)
        return String(decoding: try handle.read(upToCount: sectionLimit) ?? Data(), as: UTF8.self)
    }

    static func write(directory: URL, metadata: [String: String], bluetooth: String,
                      capture: String?, captureError: String?) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Wythin-recording-diagnostics.txt")
        let manifest = metadata.keys.sorted().prefix(48).map {
            "\($0.prefix(80)): \(metadata[$0, default: ""].prefix(512))"
        }.joined(separator: "\n")
        let captureText = capture ?? "Capture audit unavailable: \(captureError ?? "not initialized")"
        let text = """
        Wythin recording diagnostics
        Exported: \(ISO8601DateFormatter().string(from: Date()))

        [Environment and delivery]
        \(manifest)

        [Bluetooth and upload events — recent tail]
        \(bounded(bluetooth))

        [Capture and local persistence — recent tail]
        \(bounded(captureText))
        """
        try Data(redacted(text).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        return url
    }

    private static func bounded(_ text: String) -> String {
        String(decoding: Data(text.utf8).suffix(sectionLimit), as: UTF8.self)
    }

    private static func redacted(_ text: String) -> String {
        var result = text
        for pattern in [
            #"(?im)(authorization|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token)\s*[\"']?\s*[:=]\s*[^\r\n]+"#,
            #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..., in: result), withTemplate: "[credential redacted]")
        }
        return result
    }
}
