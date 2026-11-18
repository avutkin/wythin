import Foundation

/// A closed technical schema. Never add signal values, device names, free-form
/// errors or credentials here: these snapshots are automatically uploaded.
struct RecordingDiagnosticEvent: Codable, Equatable {
    enum Reason: String, Codable { case launch, heartbeat, lifecycle, state, saveError = "save_error", memoryWarning = "memory_warning", termination }
    enum Phase: String, Codable { case foreground, background, inactive, unknown }
    enum CentralState: String, Codable { case unknown, resetting, unsupported, unauthorized, poweredOff = "powered_off", poweredOn = "powered_on" }
    enum ConnectionState: String, Codable { case idle, scanning, connecting, connected, disconnected, standby, unauthorized, unsupported }
    enum SensorErrorDomain: String, Codable { case coreBluetooth = "core_bluetooth", pmd, cocoa, posix, other }
    enum SaveErrorDomain: String, Codable { case cocoa, sqlite, other }
    enum DeliveryState: String, Codable { case unknown, idle, uploading, retrying, storageBlocked = "storage_blocked" }

    struct Sensor: Codable, Equatable {
        var centralState: CentralState = .unknown
        var connectionState: ConnectionState = .idle
        var intended = false
        var rrLive = false
        var ecgLive = false
        var accLive = false
        var generation = 0
        var connectionAgeSeconds: Double?
        var lastRrAt: Date?
        var lastEcgAt: Date?
        var lastAccAt: Date?
        var sensorContact: Bool?
        var hrPackets: Int?
        var ecgPackets: Int?
        var accPackets: Int?
        var rrIntervals: Int?
        var validRrIntervals: Int?
        var invalidPackets: Int?
        var errorDomain: SensorErrorDomain?
        var errorCode: Int?
        var errorAt: Date?
    }

    struct Recording: Codable, Equatable {
        var computedCount = 0
        var savedCount = 0
        var failedSaveCount = 0
        var lastComputedAt: Date?
        var lastComputedSampleAt: Date?
        var lastSavedAt: Date?
        var lastSavedSampleAt: Date?
        var computedAgeSeconds: Double?
        var savedAgeSeconds: Double?
        var rrActiveAgeSeconds: Double?
        var saveErrorDomain: SaveErrorDomain?
        var saveErrorCode: Int?
    }

    struct Delivery: Codable, Equatable {
        var state: DeliveryState = .unknown
        var queuedBatches = 0
        var inFlight = 0
        var maximumAttempts = 0
        var pendingSamples: Int?
        var oldestQueuedAt: Date?
        var lastAttemptAt: Date?
        var lastAckAt: Date?
        var lastAckSampleAt: Date?
        var lastHttpStatus: Int?
        var lastErrorCode: Int?
    }

    var schemaVersion = 1
    var eventId = UUID()
    var installationId: UUID
    var launchId: UUID
    var launchSequence: Int
    var sequence: Int
    var observedAt: Date
    var uptimeSeconds: Double
    var reason: Reason
    var appVersion: String
    var appBuild: String
    var osVersion: String
    var phase: Phase
    var sensor: Sensor
    var recording: Recording
    var delivery: Delivery
    var droppedReports: Int

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func technicalVersion(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._ -")
        let result = String(String.UnicodeScalarView(value.unicodeScalars.filter { allowed.contains($0) })).prefix(32)
        return result.isEmpty ? "unknown" : String(result)
    }

    static func errorCode(_ error: Error) -> Int { Int(Int32(clamping: (error as NSError).code)) }
}
