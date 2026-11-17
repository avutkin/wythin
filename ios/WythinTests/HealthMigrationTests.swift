import Foundation
import SwiftData
import XCTest
@testable import Wythin

/// Persisted ActivityLog schema frozen from source commit 62c0cd3,
/// ios/Wythin/Models/ActivityLog.swift. Do not add new production properties here:
/// this fixture must remain capable of creating the pre-Health on-disk store.
/// Computed properties and @Transient previewEnd are intentionally excluded.
private enum LegacyHealthSchema {
    static var models: [any PersistentModel.Type] {
        [HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self,
         ActivityLog.self, DailyAnchor.self, UsageEventLog.self, FeltStateLog.self,
         SleepWindowOverride.self]
    }

    @Model
    final class ActivityLog {
        @Attribute(.unique) var id: UUID
        var activityType:    String
        var activitySubtype: String?
        var customName:      String?
        var startedAt:       Date
        var endedAt:         Date?
        var notes:           String?
        var isManual:        Bool
        var targetMinutes: Int?
        var settledAt: Date?
        var insightText:     String?
        var beforeHR:    Float?;  var duringHR:    Float?;  var afterHR:    Float?
        var beforeSDNN:  Float?;  var duringSDNN:  Float?;  var afterSDNN:  Float?
        var beforeRSA:   Float?;  var duringRSA:   Float?;  var afterRSA:   Float?
        var beforeVTI:   Float?;  var duringVTI:   Float?;  var afterVTI:   Float?
        var beforeLFHF:  Float?;  var duringLFHF:  Float?;  var afterLFHF:  Float?
        var beforeStress: Float?;  var duringStress: Float?;  var afterStress: Float?
        var beforeRMSSD: Float?;  var duringRMSSD: Float?;  var afterRMSSD: Float?
        var beforeRCMSE: Float?;  var duringRCMSE: Float?;  var afterRCMSE: Float?
        var beforePIP:   Float?;  var duringPIP:   Float?;  var afterPIP:   Float?
        var beforeDC:    Float?;  var duringDC:    Float?;  var afterDC:    Float?
        var beforeDFA1:  Float?;  var duringDFA1:  Float?;  var afterDFA1:  Float?
        var beforeBreath: Float?;  var duringBreath: Float?;  var afterBreath: Float?
        var sleepScore: Int?
        var sleepScoreArithmetic: String?
        var sleepStageSummary: String?
        var sleepAsleepMinutes: Int?
        var sleepRegularity: Float?
        var sleepBedtimeSDMin: Double?
        var sleepPartsJSON: String?
        var sleepQuietRMSSD: Float?
        var sleepQuietDC:    Float?
        var sleepDetectedStart: Date?
        var sleepDetectedEnd:   Date?
        var sleepCorrectedAt:   Date?
        var sleepTiming: Int?
        var sleepDuration: Int?
        var sleepContinuity: Int?
        var sleepAutonomic: Int?
        var sleepBreathing: Int?
        var sleepDeepMinutes: Int?
        var sleepLightMinutes: Int?
        var sleepREMMinutes: Int?
        var sleepAwakeMinutes: Int?
        var sleepN1Minutes: Int?
        var sleepAlgorithmVersion: Int?
        var sleepReadText: String?
        var sleepDetailJSON: String?
        var readinessScore:        Int?
        var readinessPeerCount:    Int?
        var exerciseLoad:          Double?
        var vsiSlopePer10:         Double?
        var efficiencySlope:       Double?
        var hasExternalWorkSignal: Bool = false
        var domainModerateSec:     Double?
        var domainHeavySec:        Double?
        var domainSevereSec:       Double?
        var afterTailDC:           Float?
        var duringDCTrough:        Float?
        var hrr60Bpm:              Double?
        var t30Seconds:            Double?
        var duringHRPeak:          Float?
        var zone1Sec:              Double?
        var zone2Sec:              Double?
        var zone3Sec:              Double?
        var zone4Sec:              Double?
        var zone5Sec:              Double?
        var halfRecoveryMinutes:   Double?
        var recoveryObservedMinutes: Double?
        var hrReturnMinutes:         Double?
        var hrReturnObservedMinutes: Double?
        var t30Score:                Int?
        var vagalRoseDuring:       Bool = false
        var suppressionScore:      Int?
        var efficiencyScore:       Int?
        var scoreHistoryCount:     Int?

        init(id: UUID, activityType: String, startedAt: Date, endedAt: Date?, isManual: Bool) {
            self.id = id
            self.activityType = activityType
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.isManual = isManual
        }
    }
}

final class HealthMigrationTests: XCTestCase {
    @MainActor
    func testExistingActivityStoreMigratesWithoutLosingManualOrSleepHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let manualID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
        let sleepID = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
        let importedID = UUID(uuidString: "A0000000-0000-4000-8000-000000000003")!
        let externalID = "b0000000-0000-4000-8000-000000000004"
        let start = Date(timeIntervalSince1970: 1_800_000_000.125)
        let end = start.addingTimeInterval(2_400)
        let sleepDetails = "{\"wake_bouts\":2,\"longest_unbroken_min\":180}"

        // Each autorelease pool releases its context/container before reopening
        // the same SQLite file. No memory-only store or recovery fallback is used.
        try autoreleasepool {
            let schema = Schema(LegacyHealthSchema.models)
            let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            let manual = LegacyHealthSchema.ActivityLog(
                id: manualID, activityType: "Exercise", startedAt: start, endedAt: end, isManual: true)
            manual.activitySubtype = "Easy Run"
            manual.notes = "Keep the original handwritten note"
            manual.beforeRMSSD = 42.25
            manual.afterRMSSD = 51.5
            manual.settledAt = end.addingTimeInterval(600)
            manual.exerciseLoad = 87.75
            manual.hasExternalWorkSignal = true
            context.insert(manual)

            let night = LegacyHealthSchema.ActivityLog(
                id: sleepID, activityType: "Sleep", startedAt: start.addingTimeInterval(-28_800),
                endedAt: start, isManual: false)
            night.sleepScore = 72
            night.sleepQuietRMSSD = 44.75
            night.sleepAsleepMinutes = 442
            night.sleepAlgorithmVersion = 13
            night.sleepDetailJSON = sleepDetails
            context.insert(night)
            try context.save()
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<LegacyHealthSchema.ActivityLog>()), 2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        let currentSchema = Schema([
            HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self,
            Wythin.ActivityLog.self, DailyAnchor.self, UsageEventLog.self, FeltStateLog.self,
            SleepWindowOverride.self
        ])
        try autoreleasepool {
            let config = ModelConfiguration(schema: currentSchema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: currentSchema, configurations: [config])
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<Wythin.ActivityLog>())
            XCTAssertEqual(rows.count, 2, "Automatic migration must preserve both existing entries")
            let manual = try XCTUnwrap(rows.first { $0.id == manualID })
            XCTAssertEqual(manual.activityType, "Exercise")
            XCTAssertEqual(manual.activitySubtype, "Easy Run")
            XCTAssertEqual(manual.startedAt, start)
            XCTAssertEqual(manual.endedAt, end)
            XCTAssertEqual(manual.notes, "Keep the original handwritten note")
            XCTAssertTrue(manual.isManual)
            XCTAssertEqual(manual.beforeRMSSD, 42.25)
            XCTAssertEqual(manual.afterRMSSD, 51.5)
            XCTAssertEqual(manual.settledAt, end.addingTimeInterval(600))
            XCTAssertEqual(manual.exerciseLoad, 87.75)
            XCTAssertTrue(manual.hasExternalWorkSignal)
            XCTAssertNil(manual.origin)
            XCTAssertNil(manual.externalWorkoutID)
            XCTAssertFalse(manual.isHealthImported)

            let night = try XCTUnwrap(rows.first { $0.id == sleepID })
            XCTAssertEqual(night.activityType, "Sleep")
            XCTAssertFalse(night.isManual)
            XCTAssertEqual(night.sleepScore, 72)
            XCTAssertEqual(night.sleepQuietRMSSD, 44.75)
            XCTAssertEqual(night.sleepAsleepMinutes, 442)
            XCTAssertEqual(night.sleepAlgorithmVersion, 13)
            XCTAssertEqual(night.sleepDetailJSON, sleepDetails)
            XCTAssertNil(night.origin)
            XCTAssertNil(night.externalWorkoutID)

            let imported = Wythin.ActivityLog(activityType: "Exercise", activitySubtype: "Running",
                                               startedAt: end.addingTimeInterval(86_400),
                                               endedAt: end.addingTimeInterval(87_000))
            imported.id = importedID
            imported.origin = "apple_health"
            imported.externalWorkoutID = externalID
            context.insert(imported)
            manual.notes = "Original note remains editable after migration"
            try context.save()
        }

        // A second open proves both migrated history and new Health fields were
        // persisted, rather than merely surviving in one context's object cache.
        try autoreleasepool {
            let config = ModelConfiguration(schema: currentSchema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: currentSchema, configurations: [config])
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<Wythin.ActivityLog>())
            XCTAssertEqual(rows.count, 3)
            let manual = try XCTUnwrap(rows.first { $0.id == manualID })
            XCTAssertEqual(manual.notes, "Original note remains editable after migration")
            XCTAssertTrue(manual.isManual)
            XCTAssertEqual(manual.beforeRMSSD, 42.25)
            XCTAssertNil(manual.origin)
            XCTAssertNil(manual.externalWorkoutID)
            let night = try XCTUnwrap(rows.first { $0.id == sleepID })
            XCTAssertEqual(night.sleepScore, 72)
            XCTAssertEqual(night.sleepDetailJSON, sleepDetails)
            let imported = try XCTUnwrap(rows.first { $0.id == importedID })
            XCTAssertTrue(imported.isHealthImported)
            XCTAssertEqual(imported.origin, "apple_health")
            XCTAssertEqual(imported.externalWorkoutID, externalID)
        }
    }
}
