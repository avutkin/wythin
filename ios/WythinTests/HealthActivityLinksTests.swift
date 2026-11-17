import XCTest
@testable import Wythin

final class HealthActivityLinksTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var workout: HealthWorkout {
        HealthWorkout(id: UUID(), activityCode: 37, activityName: "Running", startedAt: start,
            endedAt: start.addingTimeInterval(1800), activeDurationSeconds: 1500,
            source: HealthSourceInfo(bundleIdentifier: "synthetic.watch", name: "Watch"))
    }
    private func record(offset: TimeInterval = 0, duration: TimeInterval? = 1800,
                        exercise: Bool = true, imported: Bool = false, subtype: String? = "Easy Run") -> HealthActivityLinks.Record {
        let began = start.addingTimeInterval(offset)
        return .init(id: UUID(), startedAt: began, endedAt: duration.map { began.addingTimeInterval($0) },
            isExercise: exercise, isImported: imported, subtype: subtype)
    }

    func testSuggestionsRequireFinishedManualExerciseAndCompatibleSport() {
        let valid = record(offset: 30, duration: 1770)
        let candidates = [record(duration: nil), record(exercise: false), record(imported: true),
                          record(subtype: "Yoga"), record(offset: 600), record(duration: 600), valid]
        XCTAssertEqual(HealthActivityLinks.candidates(for: workout, among: candidates).map(\.id), [valid.id])
    }

    func testClosestCandidateComesFirstWithoutAutomaticLink() throws {
        let suite = "HealthActivityLinksTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let links = HealthActivityLinks(defaults: defaults), workout = workout
        let farther = record(offset: 90), closer = record(offset: 15)
        XCTAssertEqual(HealthActivityLinks.candidates(for: workout, among: [farther, closer]).map(\.id), [closer.id, farther.id])
        XCTAssertNil(links.linkedActivityID(for: workout.id))
    }

    func testExplicitLinkSurvivesReloadAndUnlinkKeepsOtherLinks() throws {
        let suite = "HealthActivityLinksTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let links = HealthActivityLinks(defaults: defaults), first = workout, second = workout
        let firstManual = record(), secondManual = record(offset: 10)
        XCTAssertTrue(links.link(first, to: firstManual))
        XCTAssertTrue(links.link(second, to: secondManual))
        let reloaded = HealthActivityLinks(defaults: defaults)
        XCTAssertEqual(reloaded.linkedActivityID(for: first.id), firstManual.id)
        reloaded.unlink(first.id)
        XCTAssertNil(links.linkedActivityID(for: first.id))
        XCTAssertEqual(links.linkedActivityID(for: second.id), secondManual.id)
        links.removeAll()
        XCTAssertNil(reloaded.linkedActivityID(for: second.id))
    }

    func testLinkRejectsAnActiveRecordEvenWhenCalledOutsideTheView() throws {
        let suite = "HealthActivityLinksTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let links = HealthActivityLinks(defaults: defaults), workout = workout
        XCTAssertFalse(links.link(workout, to: record(duration: nil)))
        XCTAssertNil(links.linkedActivityID(for: workout.id))
    }

    func testShortOrPausedWorkoutsAreComparedUsingElapsedTimeAndRealOverlap() {
        var short = workout
        short.endedAt = start.addingTimeInterval(30)
        short.activeDurationSeconds = 20
        XCTAssertTrue(HealthActivityLinks.candidates(for: short, among: [record(offset: 40, duration: 30)]).isEmpty)
        XCTAssertEqual(HealthActivityLinks.candidates(for: workout, among: [record()]).count, 1)
    }

    func testLinkStorageContainsOnlyRecordIdentifiers() throws {
        let suite = "HealthActivityLinksTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let links = HealthActivityLinks(defaults: defaults), workout = workout, manual = record()
        XCTAssertTrue(links.link(workout, to: manual))
        let domain = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        let saved = try XCTUnwrap(domain.values.first as? [String: String])
        XCTAssertEqual(saved, [workout.id.uuidString.lowercased(): manual.id.uuidString.lowercased()])
    }

    func testRestoredAnalysisSourcesRemainSelectableWithoutRawSamples() {
        let saved = HealthSourceInfo(bundleIdentifier: "synthetic.watch", name: "Watch")
        XCTAssertEqual(HealthActivityDetailSources.combine(observed: [], saved: [saved]), [saved])
        let other = HealthSourceInfo(bundleIdentifier: "synthetic.other", name: "Other")
        XCTAssertEqual(HealthActivityDetailSources.combine(observed: [saved], saved: [saved, other]), [other, saved])
    }
}
