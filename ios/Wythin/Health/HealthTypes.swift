import Foundation
import CryptoKit

enum HealthMetric: String, Codable, CaseIterable, Sendable {
    case heartRate = "heart_rate", sdnn = "hrv_sdnn", activeEnergy = "active_energy"
    case walkingRunningDistance = "distance_walking_running", cyclingDistance = "distance_cycling"
    case swimmingDistance = "distance_swimming", steps = "step_count"

    var unit: String {
        switch self {
        case .heartRate: return "count/min"
        case .sdnn: return "ms"
        case .activeEnergy: return "kcal"
        case .steps: return "count"
        default: return "m"
        }
    }
    var label: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .sdnn: return "HRV · SDNN"
        case .activeEnergy: return "Active energy"
        case .steps: return "Steps"
        default: return "Distance"
        }
    }
    var isCumulative: Bool { self != .heartRate && self != .sdnn }
}

struct HealthSourceInfo: Codable, Equatable, Hashable, Sendable {
    var bundleIdentifier: String
    var name: String
    var version: String? = nil
}

struct HealthWorkoutEvent: Codable, Equatable, Sendable {
    var kind: String
    var startedAt: Date
    var endedAt: Date
}

struct HealthWorkoutSegment: Codable, Equatable, Sendable {
    var activityCode: UInt
    var startedAt: Date
    var endedAt: Date
}

struct HealthWorkout: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var activityCode: UInt
    var activityName: String
    var startedAt: Date
    var endedAt: Date
    var activeDurationSeconds: Double
    var source: HealthSourceInfo
    var timezone: String? = nil
    var energyKcal: Double? = nil
    var distanceMeters: Double? = nil
    var userEntered: Bool = false
    var events: [HealthWorkoutEvent] = []
    var segments: [HealthWorkoutSegment] = []
}

struct HealthSample: Codable, Equatable, Identifiable, Sendable {
    enum Representation: String, Codable, Sendable { case point, interval, series }
    var id: UUID
    var metric: HealthMetric
    var value: Double
    var startedAt: Date
    var endedAt: Date
    var source: HealthSourceInfo
    var parentId: UUID? = nil
    var representation: Representation = .point
    var workoutIds: [UUID] = []
    var parent: UUID { parentId ?? id }

    /// Stable child identity across retries; deleting the HK parent removes every child.
    static func childID(parent: UUID, index: Int) -> UUID {
        let digest = SHA256.hash(data: Data("\(parent.uuidString.lowercased()):\(index)".utf8))
        var b = Array(digest.prefix(16)); b[6] = (b[6] & 15) | 80; b[8] = (b[8] & 63) | 128
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
}

struct HealthWorkoutPage: Sendable {
    var workouts: [HealthWorkout]
    var deletedIDs: [UUID]
    var nextAnchor: Data?
    var hasMore: Bool
}

struct HealthSamplePage: Sendable {
    var samples: [HealthSample]
    var deletedIDs: [UUID]
    var nextAnchor: Data?
    var hasMore: Bool
}

protocol HealthSource: AnyObject, Sendable {
    var available: Bool { get }
    func requestAuthorization() async throws
    func workoutPage(anchor: Data?) async throws -> HealthWorkoutPage
    func samplePage(metric: HealthMetric, anchor: Data?) async throws -> HealthSamplePage
    func samples(metric: HealthMetric, start: Date, end: Date) async throws -> [HealthSample]
    func startObserving(onChange: @escaping @Sendable () async -> Void)
    func stopObserving()
}

enum HealthCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try c.encode(f.string(from: date))
        }
        e.keyEncodingStrategy = .convertToSnakeCase; e.outputFormatting = [.sortedKeys]
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid Health timestamp"))
        }
        return d
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder().decode(type, from: data) }
}
