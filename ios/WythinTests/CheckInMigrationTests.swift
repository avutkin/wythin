import Foundation
import SwiftData
import XCTest
@testable import Wythin

/// Frozen pre-acknowledgement entity. Its simple name and stored properties
/// match the shipped FeltStateLog; the namespace lets both versions coexist.
private enum LegacyCheckInSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self,
         ActivityLog.self, DailyAnchor.self, UsageEventLog.self, FeltStateLog.self,
         SleepWindowOverride.self]
    }

    @Model
    final class FeltStateLog {
        @Attribute(.unique) var id: UUID
        var timestamp: Date
        var focus: Double?
        var energy: Double?
        var stress: Double?
        var mood: Double?
        var stateKey: String?
        var kind: String?
        var anxiety: Double?
        var sleep: Double?
        var dayKey: String?
        var timezone: String?
        var wornMinutes: Double?

        init(id: UUID, timestamp: Date, kind: String?, focus: Double?, energy: Double?,
             stress: Double?, mood: Double?, anxiety: Double?, sleep: Double?,
             dayKey: String?, timezone: String?, wornMinutes: Double?, stateKey: String?) {
            self.id = id
            self.timestamp = timestamp
            self.kind = kind
            self.focus = focus
            self.energy = energy
            self.stress = stress
            self.mood = mood
            self.anxiety = anxiety
            self.sleep = sleep
            self.dayKey = dayKey
            self.timezone = timezone
            self.wornMinutes = wornMinutes
            self.stateKey = stateKey
        }
    }
}

final class CheckInMigrationTests: XCTestCase {
    @MainActor
    func testShippedAnswersSurviveAutomaticMigrationAndPersistAcknowledgements() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckInMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let momentID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let reviewID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
        let answeredAt = Date(timeIntervalSince1970: 1_800_000_000.125)
        let receipt = "https://example.test/api|device-checkin-migration"

        // Use the same unversioned Schema initializer as the shipped app.
        // No custom migration plan and no catch/recreate fallback may hide loss.
        try autoreleasepool {
            let schema = Schema(LegacyCheckInSchemaV1.models)
            let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            context.insert(LegacyCheckInSchemaV1.FeltStateLog(
                id: momentID, timestamp: answeredAt, kind: nil,
                focus: 0, energy: nil, stress: 100, mood: 71.5, anxiety: nil, sleep: nil,
                dayKey: nil, timezone: nil, wornMinutes: nil, stateKey: "sharp"))
            context.insert(LegacyCheckInSchemaV1.FeltStateLog(
                id: reviewID, timestamp: answeredAt.addingTimeInterval(60), kind: "previous_day",
                focus: 60, energy: 42.5, stress: 30, mood: nil, anxiety: 10, sleep: 35,
                dayKey: "2026-09-13", timezone: "Australia/Sydney", wornMinutes: 13.2,
                stateKey: nil))
            try context.save()
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<LegacyCheckInSchemaV1.FeltStateLog>()), 2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        let currentSchema = Schema([
            HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self,
            ActivityLog.self, DailyAnchor.self, UsageEventLog.self, FeltStateLog.self,
            SleepWindowOverride.self
        ])
        try autoreleasepool {
            let config = ModelConfiguration(schema: currentSchema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: currentSchema, configurations: [config])
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<FeltStateLog>(sortBy: [SortDescriptor(\.timestamp)]))
            XCTAssertEqual(rows.count, 2, "Opening the new schema must preserve both old answers")
            let moment = try XCTUnwrap(rows.first { $0.id == momentID })
            XCTAssertEqual(moment.timestamp, answeredAt)
            XCTAssertNil(moment.kind)
            XCTAssertEqual(moment.focus, 0)
            XCTAssertNil(moment.energy)
            XCTAssertEqual(moment.stress, 100)
            XCTAssertEqual(moment.mood, 71.5)
            XCTAssertNil(moment.anxiety)
            XCTAssertNil(moment.sleep)
            XCTAssertNil(moment.dayKey)
            XCTAssertNil(moment.timezone)
            XCTAssertNil(moment.wornMinutes)
            XCTAssertEqual(moment.stateKey, "sharp")
            XCTAssertNil(moment.uploadedDestination, "Old answers must remain eligible for backfill")
            let review = try XCTUnwrap(rows.first { $0.id == reviewID })
            XCTAssertEqual(review.timestamp, answeredAt.addingTimeInterval(60))
            XCTAssertEqual(review.kind, "previous_day")
            XCTAssertEqual(review.focus, 60)
            XCTAssertEqual(review.energy, 42.5)
            XCTAssertEqual(review.stress, 30)
            XCTAssertNil(review.mood)
            XCTAssertEqual(review.anxiety, 10)
            XCTAssertEqual(review.sleep, 35)
            XCTAssertEqual(review.dayKey, "2026-09-13")
            XCTAssertEqual(review.timezone, "Australia/Sydney")
            XCTAssertEqual(review.wornMinutes, 13.2)
            XCTAssertNil(review.stateKey)
            XCTAssertNil(review.uploadedDestination)
            moment.uploadedDestination = receipt
            try context.save()
        }

        try autoreleasepool {
            let config = ModelConfiguration(schema: currentSchema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: currentSchema, configurations: [config])
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<FeltStateLog>())
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == momentID }).uploadedDestination, receipt)
            XCTAssertNil(try XCTUnwrap(rows.first { $0.id == reviewID }).uploadedDestination)
        }
    }
}
