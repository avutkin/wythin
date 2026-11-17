import Foundation
import SwiftData
import CryptoKit

@Model final class HealthStoredObject {
    @Attribute(.unique) var key: String
    var kind: String
    var externalId: UUID
    var parentId: UUID
    var startedAt: Date
    var endedAt: Date
    var payload: Data
    var revision: Int = 0
    var ackedRevision: Int = 0
    var serverRevision: Int = 0
    var annotationServerRevision: Int = 0
    var analysisFromCloud: Bool = false
    var restoredAnalysisRevision: Int = 0
    var tombstoned: Bool = false
    init(kind: String, id: UUID, parent: UUID? = nil, start: Date = .distantPast, end: Date = .distantPast, payload: Data) {
        self.key = "\(kind):\(id.uuidString.lowercased())"; self.kind = kind; externalId = id
        parentId = parent ?? id; startedAt = start; endedAt = end; self.payload = payload
    }
}

@Model final class HealthQueueRecord {
    @Attribute(.unique) var id: UUID
    var ordinal: Int
    var objectKey: String
    var objectRevision: Int
    var payload: Data
    var childRevisions: Data? = nil
    init(id: UUID, ordinal: Int, objectKey: String, objectRevision: Int, payload: Data) {
        self.id = id; self.ordinal = ordinal; self.objectKey = objectKey
        self.objectRevision = objectRevision; self.payload = payload
    }
}

@Model final class HealthStateRecord {
    @Attribute(.unique) var key: String = "state"
    var payload: Data
    init(payload: Data) { self.payload = payload }
}

struct HealthLocalState: Codable, Sendable {
    var enabled = false
    var cloudConsent = false
    var pendingPurge = false
    var connectionId: UUID?
    var connectionEpoch = 1
    var streamId = UUID()
    var nextSequence = 1
    var nextOrdinal = 1
    var anchors: [String: Data] = [:]
    var historyComplete = false
    var restoreCursor: String?
    var lastSuccess: Date?
    var frozenBatch: Data?
    var frozenQueueIds: [UUID] = []
    var retryAfter: Date?
    var retryCount = 0
    var cloudServer: String?
    var pausePending = false
    var cloudAuthBlocked = false
    var rebuildCloudSnapshot: Bool? = nil
    var purgeKeptLocal: Bool? = nil
    var localGeneration: UUID? = nil
}

struct HealthEntry: Codable, Sendable {
    var workout: HealthWorkout
    var activityId: UUID
    var analysis: HealthAnalysis?
    var notes: String?
    var title: String?
    var deleted = false
    var needsAnalysis = true
    var contextPending: [HealthMetric] = HealthMetric.allCases
}

enum HealthStoreError: Error { case invalidWorkout, oversizedChange, connectionMissing, staleAcknowledgement, annotationTooLong }

/// A separate store keeps imported sensor records out of Polar's sample schema.
/// Each actor call commits source records, cursor and immutable outbox together.
@ModelActor actor HealthRepository {
    init(inMemory: Bool = false, url: URL? = nil) throws {
        let schema = Schema([HealthStoredObject.self, HealthQueueRecord.self, HealthStateRecord.self])
        let configuration: ModelConfiguration
        if inMemory { configuration = ModelConfiguration("Health", schema: schema, isStoredInMemoryOnly: true) }
        else {
            let destination = url ?? URL.applicationSupportDirectory.appending(path: "WythinHealth/health.store")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            var directory = destination.deletingLastPathComponent()
            var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
            try directory.setResourceValues(attributes)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            configuration = ModelConfiguration("Health", schema: schema, url: destination, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container); context.autosaveEnabled = false
        for row in try context.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.kind == "restore" })) { context.delete(row) }
        try context.save()
        self.modelContainer = container
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    func state() throws -> HealthLocalState {
        if let row = try modelContext.fetch(FetchDescriptor<HealthStateRecord>()).first {
            return try HealthCoding.decode(HealthLocalState.self, from: row.payload)
        }
        let state = HealthLocalState(); try saveState(state); try modelContext.save(); return state
    }
    func updateState(_ state: HealthLocalState) throws { try transaction { try saveState(state) } }
    func setEnabled(_ enabled: Bool) throws {
        var s = try state(); guard !s.pendingPurge || !enabled else { return }; s.enabled = enabled; try updateState(s)
    }
    func setCloudConsent(_ enabled: Bool, server: String) throws {
        try transaction {
        var s = try state(); guard !s.pendingPurge else { return }
        s.cloudConsent = enabled
        s.pausePending = !enabled && s.connectionId != nil
        if enabled { s.cloudServer = server; s.retryAfter = nil; s.retryCount = 0; s.cloudAuthBlocked = false }
        if enabled && s.rebuildCloudSnapshot == true { try enqueueSnapshot(state: &s); s.rebuildCloudSnapshot = false }
        try saveState(s)
        }
    }
    func completeCloudPause() throws { var s = try state(); s.pausePending = false; try updateState(s) }
    func blockCloudAuthentication() throws { var s = try state(); s.cloudAuthBlocked = true; try updateState(s) }
    func adoptWriterStream(_ id: UUID) throws {
        var s = try state()
        guard s.connectionId == nil, s.frozenBatch == nil, !s.pendingPurge else { return }
        s.streamId = id; try updateState(s)
    }
    func bindConnection(id: UUID, epoch: Int, expectedSequence: Int) throws {
        var s = try state(); guard !s.pendingPurge else { throw HealthStoreError.staleAcknowledgement }
        if let current = s.connectionId, current != id || s.connectionEpoch != epoch { throw HealthStoreError.staleAcknowledgement }
        s.connectionId = id; s.connectionEpoch = epoch
        if s.frozenBatch == nil { s.nextSequence = expectedSequence }
        try updateState(s)
    }
    func markSynced() throws { var s = try state(); s.lastSuccess = .now; try updateState(s) }
    func scheduleRetry(after seconds: Double) throws {
        var s = try state(); s.retryCount += 1; s.retryAfter = Date.now.addingTimeInterval(seconds); try updateState(s)
    }
    func pendingCount() throws -> Int { try modelContext.fetchCount(FetchDescriptor<HealthQueueRecord>()) }
    func entries() throws -> [HealthEntry] {
        try workoutRows().map { row in
            var entry = try HealthCoding.decode(HealthEntry.self, from: row.payload); entry.deleted = row.tombstoned; return entry
        }
    }
    func entry(_ id: UUID) throws -> HealthEntry? {
        guard let row = try object("workout", id) else { return nil }
        var entry = try HealthCoding.decode(HealthEntry.self, from: row.payload); entry.deleted = row.tombstoned; return entry
    }
    func samples(for workout: HealthWorkout) throws -> [HealthSample] {
        let lower = workout.startedAt.addingTimeInterval(-300), upper = workout.endedAt.addingTimeInterval(600)
        let query = FetchDescriptor<HealthStoredObject>(predicate: #Predicate {
            $0.kind == "sample" && !$0.tombstoned && $0.startedAt <= upper && $0.endedAt >= lower
        }, sortBy: [SortDescriptor(\.startedAt)])
        return try modelContext.fetch(query).map { try HealthCoding.decode(HealthSample.self, from: $0.payload) }
    }

    func applyWorkouts(_ page: HealthWorkoutPage, expectedEpoch: Int? = nil) throws {
        try transaction {
            var state = try state()
            guard !state.pendingPurge, expectedEpoch == nil || (state.enabled && expectedEpoch == state.connectionEpoch) else { return }
            for workout in page.workouts {
                guard workout.endedAt >= workout.startedAt, workout.activeDurationSeconds.isFinite,
                      workout.activeDurationSeconds >= 0 else { throw HealthStoreError.invalidWorkout }
                let existing = try object("workout", workout.id)
                let tombstone = try object("workout_tombstone", workout.id)
                if existing?.tombstoned == true || tombstone != nil { continue }
                var entry = try existing.map { try HealthCoding.decode(HealthEntry.self, from: $0.payload) }
                    ?? HealthEntry(workout: workout, activityId: HealthSample.childID(parent: workout.id, index: -1))
                if existing != nil && entry.workout == workout { continue }
                entry.workout = workout; entry.needsAnalysis = true; entry.contextPending = HealthMetric.allCases
                let row = existing ?? HealthStoredObject(kind: "workout", id: workout.id, payload: Data())
                if existing == nil { modelContext.insert(row) }
                row.startedAt = workout.startedAt; row.endedAt = workout.endedAt
                row.payload = try HealthCoding.encode(entry); row.revision += 1
                var payload = try dictionary(workout); payload.removeValue(forKey: "id")
                try enqueue("upsert_workout", id: workout.id, row: row, field: "workout", payload: payload, state: &state)
            }
            for id in page.deletedIDs { try deleteWorkout(id, state: &state) }
            if let anchor = page.nextAnchor { state.anchors["workouts"] = anchor }
            state.historyComplete = !page.hasMore
            try saveState(state)
        }
    }

    func applySamples(_ page: HealthSamplePage, metric: HealthMetric, updateAnchor: Bool = true, expectedEpoch: Int? = nil) throws {
        try transaction {
            var state = try state()
            guard !state.pendingPurge, expectedEpoch == nil || (state.enabled && expectedEpoch == state.connectionEpoch) else { return }
            let workouts = try workoutRows().filter { !$0.tombstoned }
            var affected = Set<UUID>()
            var changedSeries = Set<UUID>()
            for var sample in page.samples {
                guard sample.value.isFinite, sample.value >= 0 else { continue }
                let relevant = workouts.filter {
                    HealthAnalysis.overlaps(sample, bounds: ($0.startedAt.addingTimeInterval(-300), $0.endedAt.addingTimeInterval(600)))
                }
                guard !relevant.isEmpty else { continue }
                if try object("sample_tombstone", sample.parent) != nil { continue }
                sample.workoutIds = relevant.map(\.externalId).sorted { $0.uuidString < $1.uuidString }
                let data = try HealthCoding.encode(sample), existing = try object("sample", sample.id)
                if existing?.payload == data && existing?.tombstoned == false { continue }
                let row = existing ?? HealthStoredObject(kind: "sample", id: sample.id, parent: sample.parent, start: sample.startedAt, end: sample.endedAt, payload: data)
                if existing == nil { modelContext.insert(row) }
                row.payload = data; row.tombstoned = false; row.revision += 1
                affected.formUnion(relevant.map(\.externalId))
                var payload = try dictionary(sample); payload.removeValue(forKey: "id"); payload["unit"] = sample.metric.unit
                if sample.parent != sample.id { changedSeries.insert(sample.parent) }
                else { try enqueue("upsert_sample", id: sample.id, row: row, field: "sample", payload: payload, state: &state) }
            }
            for parent in changedSeries { try enqueueSeries(parent, state: &state) }
            for parent in page.deletedIDs {
                let rows = try modelContext.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.kind == "sample" && $0.parentId == parent }))
                for row in rows {
                    let sample = try HealthCoding.decode(HealthSample.self, from: row.payload)
                    affected.formUnion(sample.workoutIds); row.tombstoned = true; row.revision += 1
                    try enqueue("delete_sample", id: row.externalId, row: row, state: &state)
                }
                if try object("sample_tombstone", parent) == nil {
                    let marker = HealthStoredObject(kind: "sample_tombstone", id: parent, payload: Data()); marker.tombstoned = true; marker.revision = 1
                    modelContext.insert(marker)
                    try enqueue("delete_sample", id: parent, row: marker, state: &state)
                }
            }
            for id in affected { try markAnalysisDirty(id) }
            if updateAnchor, let anchor = page.nextAnchor { state.anchors[metric.rawValue] = anchor }
            try saveState(state)
        }
    }

    func finishContext(workout id: UUID, metric: HealthMetric) throws {
        try transaction {
            guard let row = try object("workout", id), !row.tombstoned else { return }
            var entry = try HealthCoding.decode(HealthEntry.self, from: row.payload)
            entry.contextPending.removeAll { $0 == metric }
            // An empty HealthKit read may mean denied access. It must not erase a restored analysis.
            if entry.analysis == nil { entry.needsAnalysis = true }
            row.payload = try HealthCoding.encode(entry)
        }
    }

    func refreshAnalyses(now: Date = .now, limit: Int = 20) throws {
        try transaction {
            var state = try state(), remaining = limit
            for row in try workoutRows() where !row.tombstoned && remaining > 0 {
                var entry = try HealthCoding.decode(HealthEntry.self, from: row.payload)
                guard entry.needsAnalysis || (!row.analysisFromCloud && entry.analysis?.status == "pending" && now >= entry.workout.endedAt.addingTimeInterval(600)) else { continue }
                let analysis = HealthAnalysis.compute(workout: entry.workout, samples: try samples(for: entry.workout), now: now)
                entry.analysis = analysis; entry.needsAnalysis = false; remaining -= 1
                row.payload = try HealthCoding.encode(entry); row.revision += 1
                var payload = try dictionary(analysis); payload["input_revision"] = row.revision
                try enqueue("upsert_analysis", id: row.externalId, row: row, field: "analysis", payload: payload, state: &state)
            }
            try saveState(state)
        }
    }

    func annotate(_ id: UUID, title: String?, notes: String?) throws {
        guard (title?.unicodeScalars.count ?? 0) <= 200, (notes?.unicodeScalars.count ?? 0) <= 10_000 else { throw HealthStoreError.annotationTooLong }
        try transaction {
            guard let row = try object("workout", id), !row.tombstoned else { return }
            var state = try state(), entry = try HealthCoding.decode(HealthEntry.self, from: row.payload)
            entry.title = title; entry.notes = notes; row.revision += 1; row.payload = try HealthCoding.encode(entry)
            try enqueue("update_annotation", id: id, row: row, field: "annotation", payload: ["title": title as Any? ?? NSNull(), "notes": notes as Any? ?? NSNull()], state: &state)
            try saveState(state)
        }
    }

    func hideWorkout(_ id: UUID) throws {
        try transaction { var state = try state(); try deleteWorkout(id, state: &state); try saveState(state) }
    }

    /// Freeze exact bytes before sending. A retry never regenerates operation IDs or sequence.
    func prepareBatch() throws -> Data? {
        var state = try state()
        guard state.enabled, state.cloudConsent, !state.pendingPurge else { return nil }
        if let data = state.frozenBatch { return data }
        guard let connection = state.connectionId else { throw HealthStoreError.connectionMissing }
        var descriptor = FetchDescriptor<HealthQueueRecord>(sortBy: [SortDescriptor(\.ordinal)]); descriptor.fetchLimit = 200
        let queued = try modelContext.fetch(descriptor); guard !queued.isEmpty else { return nil }
        var selected: [HealthQueueRecord] = [], changes: [[String: Any]] = [], bytes = 0
        for row in queued {
            if bytes + row.payload.count > 1_900_000 { break }
            changes.append(try JSONSerialization.jsonObject(with: row.payload) as! [String: Any]); selected.append(row); bytes += row.payload.count
        }
        guard !selected.isEmpty else { throw HealthStoreError.oversizedChange }
        let body: [String: Any] = ["schema_version": 1, "connection_id": connection.uuidString.lowercased(),
            "connection_epoch": state.connectionEpoch, "stream_id": state.streamId.uuidString.lowercased(),
            "sequence": state.nextSequence, "batch_id": UUID().uuidString.lowercased(), "changes": changes]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        state.frozenBatch = data; state.frozenQueueIds = selected.map(\.id)
        try updateState(state); return data
    }

    func acknowledge(batchId: UUID, sequence: Int, epoch: Int, serverRevision: Int) throws {
        try transaction {
            var state = try state()
            guard !state.pendingPurge, epoch == state.connectionEpoch, let frozen = state.frozenBatch,
                  let body = try JSONSerialization.jsonObject(with: frozen) as? [String: Any],
                  (body["batch_id"] as? String)?.lowercased() == batchId.uuidString.lowercased(), sequence == state.nextSequence else { throw HealthStoreError.staleAcknowledgement }
            let ids = Set(state.frozenQueueIds)
            for row in try modelContext.fetch(FetchDescriptor<HealthQueueRecord>()) where ids.contains(row.id) {
                if let object = try object(key: row.objectKey) {
                    object.ackedRevision = max(object.ackedRevision, row.objectRevision)
                    let change = try JSONSerialization.jsonObject(with: row.payload) as? [String: Any]
                    if change?["operation"] as? String == "update_annotation" { object.annotationServerRevision = max(object.annotationServerRevision, serverRevision) }
                }
                if let revisions = row.childRevisions, let values = try JSONSerialization.jsonObject(with: revisions) as? [String: Int] {
                    for (raw, revision) in values {
                        if let id = UUID(uuidString: raw), let sample = try object("sample", id) { sample.ackedRevision = max(sample.ackedRevision, revision) }
                    }
                }
                modelContext.delete(row)
            }
            state.nextSequence += 1; state.frozenBatch = nil; state.frozenQueueIds = []
            state.retryCount = 0; state.retryAfter = nil; try saveState(state)
            for deferred in try modelContext.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.kind == "deferred_workout" })) {
                let body = try JSONSerialization.jsonObject(with: deferred.payload) as? [String: Any]
                if (body?["server_revision"] as? Int ?? 0) <= serverRevision { modelContext.delete(deferred) }
                else if try mergeRestoredItem(deferred.payload) { modelContext.delete(deferred) }
            }
        }
    }

    func beginPurge(retainingLocal: Bool = false) throws {
        try transaction {
            var state = try state(); state.pendingPurge = true; state.cloudConsent = false; state.localGeneration = UUID()
            state.purgeKeptLocal = retainingLocal; state.rebuildCloudSnapshot = retainingLocal
            if !retainingLocal { state.enabled = false; state.anchors = [:] }
            state.frozenBatch = nil; state.frozenQueueIds = []; state.restoreCursor = nil
            state.pausePending = false
            for row in try modelContext.fetch(FetchDescriptor<HealthQueueRecord>()) { modelContext.delete(row) }
            for row in try modelContext.fetch(FetchDescriptor<HealthStoredObject>()) {
                if !retainingLocal || ["deferred_workout", "restore"].contains(row.kind) { modelContext.delete(row) }
                else { row.serverRevision = 0 }
            }
            try saveState(state)
        }
    }
    func finishPurge(epoch: Int) throws {
        var state = try state(); state.pendingPurge = false; state.connectionEpoch = epoch
        state.connectionId = nil; state.streamId = UUID(); state.nextSequence = 1; state.nextOrdinal = 1
        if state.purgeKeptLocal != true { state.historyComplete = false }
        state.purgeKeptLocal = nil; state.retryAfter = nil; state.retryCount = 0; state.cloudAuthBlocked = false
        try updateState(state)
    }

    private func enqueueSnapshot(state: inout HealthLocalState) throws {
        for row in try workoutRows() where !row.tombstoned {
            let entry = try HealthCoding.decode(HealthEntry.self, from: row.payload)
            row.revision += 1
            var wire = try dictionary(entry.workout); wire.removeValue(forKey: "id")
            try enqueue("upsert_workout", id: row.externalId, row: row, field: "workout", payload: wire, state: &state)
        }
        var parents = Set<UUID>()
        for row in try modelContext.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.kind == "sample" && !$0.tombstoned })) {
            let sample = try HealthCoding.decode(HealthSample.self, from: row.payload)
            if sample.parent != sample.id { parents.insert(sample.parent); continue }
            row.revision += 1
            var wire = try dictionary(sample); wire.removeValue(forKey: "id"); wire["unit"] = sample.metric.unit
            try enqueue("upsert_sample", id: row.externalId, row: row, field: "sample", payload: wire, state: &state)
        }
        for parent in parents { try enqueueSeries(parent, state: &state) }
        for row in try workoutRows() where !row.tombstoned {
            let entry = try HealthCoding.decode(HealthEntry.self, from: row.payload)
            if let analysis = entry.analysis {
                var wire = try dictionary(analysis); wire.removeValue(forKey: "stale"); wire["input_revision"] = row.revision
                try enqueue("upsert_analysis", id: row.externalId, row: row, field: "analysis", payload: wire, state: &state)
            }
            try enqueue("update_annotation", id: row.externalId, row: row, field: "annotation", payload: ["title": entry.title as Any? ?? NSNull(), "notes": entry.notes as Any? ?? NSNull()], state: &state)
        }
        for row in try modelContext.fetch(FetchDescriptor<HealthStoredObject>()) where row.kind == "workout_tombstone" || row.kind == "sample_tombstone" {
            try enqueue(row.kind == "workout_tombstone" ? "delete_workout" : "delete_sample", id: row.externalId, row: row, state: &state)
        }
    }

    func mergeRestored(_ items: [Data], cursor: String?, expectedEpoch: Int? = nil) throws {
        try transaction {
            let state = try state()
            guard !state.pendingPurge, expectedEpoch == nil || (state.enabled && state.cloudConsent && state.connectionEpoch == expectedEpoch) else { return }
            for data in items {
                if try !mergeRestoredItem(data),
                   let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let raw = body["external_id"] as? String, let id = UUID(uuidString: raw) {
                    let existing = try object("deferred_workout", id)
                    let deferred = existing ?? HealthStoredObject(kind: "deferred_workout", id: id, payload: data)
                    if existing == nil { modelContext.insert(deferred) }
                    deferred.payload = data
                }
            }
            var latest = try self.state(); latest.restoreCursor = cursor; try saveState(latest)
        }
    }
    /// ACK revisions are stream watermarks, not proof that authoritative objects
    /// were merged. Dirty items retain their restore payload until local ACK.
    private func mergeRestoredItem(_ data: Data) throws -> Bool {
                let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                guard let raw = body["external_id"] as? String, let id = UUID(uuidString: raw),
                      let revision = body["server_revision"] as? Int else { return true }
                if try object("workout_tombstone", id) != nil { return true }
                let existing = try object("workout", id)
                if let existing, existing.serverRevision >= revision { return true }
                if body["deleted"] as? Bool == true {
                    if try object("workout_tombstone", id) == nil {
                        let marker = HealthStoredObject(kind: "workout_tombstone", id: id, payload: Data()); marker.tombstoned = true
                        modelContext.insert(marker)
                    }
                    try removeWorkoutData(id)
                    return true
                }
                guard var workoutBody = body["workout"] as? [String: Any] else { return true }
                workoutBody["id"] = id.uuidString
                let workout = try HealthCoding.decode(HealthWorkout.self, from: JSONSerialization.data(withJSONObject: workoutBody))
                let canonical = (body["activity_id"] as? String).flatMap(UUID.init(uuidString:)) ?? HealthSample.childID(parent: id, index: -1)
                var entry = HealthEntry(workout: workout, activityId: canonical)
                entry.deleted = body["deleted"] as? Bool ?? false
                if let analysis = body["analysis"] as? [String: Any] {
                    entry.analysis = try HealthCoding.decode(HealthAnalysis.self, from: JSONSerialization.data(withJSONObject: analysis))
                }
                let annotation = body["annotation"] as? [String: Any]
                entry.title = annotation?["title"] as? String; entry.notes = annotation?["notes"] as? String
                entry.needsAnalysis = entry.analysis == nil
                if let existing, existing.revision > existing.ackedRevision {
                    var local = try HealthCoding.decode(HealthEntry.self, from: existing.payload)
                    local.activityId = canonical
                    let queued = try modelContext.fetch(FetchDescriptor<HealthQueueRecord>()).filter { $0.objectKey == existing.key }
                    let hasLocalAnnotation = try queued.contains { (try JSONSerialization.jsonObject(with: $0.payload) as? [String: Any])?["operation"] as? String == "update_annotation" }
                    if !hasLocalAnnotation && existing.annotationServerRevision <= revision { local.title = entry.title; local.notes = entry.notes }
                    // A new installation may read no metrics because permission was denied.
                    // Restore its saved analysis before freezing an empty replacement upload.
                    if (existing.analysisFromCloud || (existing.serverRevision == 0 && local.analysis?.statistics.isEmpty != false)), revision > existing.restoredAnalysisRevision, let saved = entry.analysis {
                        let frozen = Set(try state().frozenQueueIds)
                        let analyses = try queued.filter { (try JSONSerialization.jsonObject(with: $0.payload) as? [String: Any])?["operation"] as? String == "upsert_analysis" }
                        if !analyses.contains(where: { frozen.contains($0.id) }) {
                            analyses.forEach { modelContext.delete($0) }
                            local.analysis = saved; local.needsAnalysis = false
                            existing.analysisFromCloud = true; existing.restoredAnalysisRevision = revision
                            var state = try self.state(), payload = try dictionary(saved)
                            payload.removeValue(forKey: "stale"); payload["input_revision"] = existing.revision
                            try enqueue("upsert_analysis", id: id, row: existing, field: "analysis", payload: payload, state: &state)
                            try saveState(state)
                        }
                    }
                    existing.payload = try HealthCoding.encode(local)
                    return false
                }
                let row = existing ?? HealthStoredObject(kind: "workout", id: id, payload: Data())
                if existing == nil { modelContext.insert(row) }
                row.payload = try HealthCoding.encode(entry); row.tombstoned = entry.deleted; row.serverRevision = revision
                row.analysisFromCloud = entry.analysis != nil; row.restoredAnalysisRevision = revision
                row.startedAt = workout.startedAt; row.endedAt = workout.endedAt
                return true
    }

    /// Pages are invisible until the revision-consistent detail response is complete.
    func stageCloudSamples(_ items: [Data], job: UUID) throws -> Bool {
        try transaction {
            var complete = true
            for data in items {
                var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                if body["stale"] as? Bool == true { complete = false; continue }
                guard let external = body["external_id"] as? String, let id = UUID(uuidString: external) else { continue }
                body["id"] = id.uuidString
                let sample = try HealthCoding.decode(HealthSample.self, from: JSONSerialization.data(withJSONObject: body))
                let row = HealthStoredObject(kind: "restore-\(job)", id: id, parent: job, payload: try HealthCoding.encode(sample))
                row.kind = "restore"; modelContext.insert(row)
            }
            return complete
        }
    }
    func discardCloudSamples(job: UUID) throws {
        try transaction {
            for row in try modelContext.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.kind == "restore" && $0.parentId == job })) { modelContext.delete(row) }
        }
    }
    func publishCloudSamples(job: UUID, workoutId: UUID, epoch: Int, generation: UUID? = nil, connectionId: UUID? = nil) throws {
        try transaction {
            let state = try state()
            guard !state.pendingPurge, state.connectionEpoch == epoch, state.localGeneration == generation,
                  connectionId == nil || state.connectionId == connectionId,
                  let workout = try object("workout", workoutId), !workout.tombstoned,
                  workout.revision == workout.ackedRevision else { return }
            let staged = try modelContext.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.kind == "restore" && $0.parentId == job }))
            let incomingIds = Set(staged.map(\.externalId))
            for old in try modelContext.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.kind == "sample" && !$0.tombstoned })) where !incomingIds.contains(old.externalId) && old.revision == old.ackedRevision {
                var sample = try HealthCoding.decode(HealthSample.self, from: old.payload)
                guard sample.workoutIds.contains(workoutId) else { continue }
                sample.workoutIds.removeAll { $0 == workoutId }
                if sample.workoutIds.isEmpty { modelContext.delete(old) }
                else { old.payload = try HealthCoding.encode(sample) }
            }
            for stagedRow in staged {
                let sample = try HealthCoding.decode(HealthSample.self, from: stagedRow.payload)
                if try object("sample_tombstone", sample.parent) != nil { continue }
                let existing = try object("sample", sample.id)
                if let existing, existing.tombstoned || existing.revision > existing.ackedRevision { continue }
                let row = existing ?? HealthStoredObject(kind: "sample", id: sample.id, parent: sample.parent, start: sample.startedAt, end: sample.endedAt, payload: stagedRow.payload)
                if existing == nil { modelContext.insert(row) }
                row.payload = stagedRow.payload
                modelContext.delete(stagedRow)
            }
        }
    }

    private func deleteWorkout(_ id: UUID, state: inout HealthLocalState) throws {
        if try object("workout_tombstone", id) == nil {
            let marker = HealthStoredObject(kind: "workout_tombstone", id: id, payload: Data()); marker.tombstoned = true; marker.revision = 1
            modelContext.insert(marker)
            try enqueue("delete_workout", id: id, row: marker, state: &state)
        }
        try removeWorkoutData(id)
    }
    private func removeWorkoutData(_ id: UUID) throws {
        if let row = try object("workout", id) { modelContext.delete(row) }
        for row in try modelContext.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.kind == "sample" })) {
            var sample = try HealthCoding.decode(HealthSample.self, from: row.payload)
            guard sample.workoutIds.contains(id) else { continue }
            sample.workoutIds.removeAll { $0 == id }
            if sample.workoutIds.isEmpty { modelContext.delete(row) }
            else { row.payload = try HealthCoding.encode(sample) }
        }
    }
    private func markAnalysisDirty(_ id: UUID) throws {
        guard let row = try object("workout", id), !row.tombstoned else { return }
        var entry = try HealthCoding.decode(HealthEntry.self, from: row.payload); entry.needsAnalysis = true
        row.revision += 1
        row.analysisFromCloud = false
        row.payload = try HealthCoding.encode(entry)
    }
    private func enqueueSeries(_ parent: UUID, state: inout HealthLocalState) throws {
        let rows = try modelContext.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate {
            $0.kind == "sample" && $0.parentId == parent && !$0.tombstoned
        }, sortBy: [SortDescriptor(\.startedAt), SortDescriptor(\.key)]))
        guard !rows.isEmpty else { return }
        let existing = try object("series", parent)
        let record = existing ?? HealthStoredObject(kind: "series", id: parent, payload: Data())
        if existing == nil { modelContext.insert(record) }
        record.revision += 1
        let generation = UUID().uuidString.lowercased()
        let manifest = rows.map { $0.externalId.uuidString.lowercased() }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
        let partSize = 100, count = (rows.count + partSize - 1) / partSize
        try enqueue("begin_series", id: parent, row: record, field: "series",
                    payload: ["generation": generation, "expected_parts": count, "digest": digest], state: &state)
        for part in 0..<count {
            let selected = rows[(part * partSize)..<min(rows.count, (part + 1) * partSize)]
            let samples = try selected.map { row -> [String: Any] in
                let sample = try HealthCoding.decode(HealthSample.self, from: row.payload)
                var wire = try dictionary(sample); wire.removeValue(forKey: "id")
                wire["external_id"] = sample.id.uuidString.lowercased(); wire["unit"] = sample.metric.unit
                return wire
            }
            try enqueue("series_part", id: parent, row: record, field: "series",
                        payload: ["generation": generation, "part_index": part, "samples": samples], state: &state)
        }
        let commit = try enqueue("commit_series", id: parent, row: record, field: "series", payload: ["generation": generation], state: &state)
        commit.childRevisions = try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: rows.map { ($0.externalId.uuidString, $0.revision) }))
    }
    private func workoutRows() throws -> [HealthStoredObject] {
        try modelContext.fetch(FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.kind == "workout" }, sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))
    }
    private func object(_ kind: String, _ id: UUID) throws -> HealthStoredObject? { try object(key: "\(kind):\(id.uuidString.lowercased())") }
    private func object(key: String) throws -> HealthStoredObject? {
        var query = FetchDescriptor<HealthStoredObject>(predicate: #Predicate { $0.key == key }); query.fetchLimit = 1
        return try modelContext.fetch(query).first
    }
    private func saveState(_ state: HealthLocalState) throws {
        let data = try HealthCoding.encode(state)
        if let row = try modelContext.fetch(FetchDescriptor<HealthStateRecord>()).first { row.payload = data }
        else { modelContext.insert(HealthStateRecord(payload: data)) }
    }
    private func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: HealthCoding.encode(value)) as! [String: Any]
    }
    @discardableResult private func enqueue(_ operation: String, id: UUID, row: HealthStoredObject, field: String? = nil,
                         payload: [String: Any]? = nil, state: inout HealthLocalState) throws -> HealthQueueRecord {
        let operationId = UUID()
        var change: [String: Any] = ["operation_id": operationId.uuidString.lowercased(), "operation": operation, "external_id": id.uuidString.lowercased()]
        if let field, let payload { change[field] = payload }
        let data = try JSONSerialization.data(withJSONObject: change, options: [.sortedKeys])
        let record = HealthQueueRecord(id: operationId, ordinal: state.nextOrdinal, objectKey: row.key, objectRevision: row.revision, payload: data)
        modelContext.insert(record)
        state.nextOrdinal += 1
        return record
    }
    private func transaction<T>(_ block: () throws -> T) throws -> T {
        do { let result = try block(); try modelContext.save(); return result }
        catch { modelContext.rollback(); throw error }
    }
}
