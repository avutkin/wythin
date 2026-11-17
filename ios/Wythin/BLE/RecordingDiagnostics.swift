import Foundation

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
