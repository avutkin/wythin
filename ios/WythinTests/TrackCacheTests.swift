import XCTest
@testable import Wythin

@MainActor
final class TrackCacheTests: XCTestCase {

    private let cal = Calendar.current
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-cache-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func day(_ back: Int) -> Date {
        cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: Date()))!
    }

    /// 200 quality samples for the given day — enough to clear the 150 gate.
    private func samples(_ d: Date, dc: Float = 8) -> [MetricsHistoryPoint] {
        (0..<200).map { i in
            MetricsHistoryPoint(timestamp: d.addingTimeInterval(Double(i) * 2),
                                meanBPM: 60, rmssd: 40, rsaMs: 30, sdnn: 50,
                                dfa1: 1.0, rcmse: 1.4, pip: 55, dc: dc)
        }
    }

    func testRefreshComputesMissingDays() {
        let cache = TrackCache(fileURL: url)
        let days = [day(2), day(1), day(0)]
        let changed = cache.refresh(days: days, today: day(0)) { samples($0) }
        XCTAssertTrue(changed)
        XCTAssertEqual(cache.rollups(in: day(2)...day(0)).count, 3)
    }

    func testRefreshDoesNotRefetchCachedPastDays() {
        let cache = TrackCache(fileURL: url)
        let days = [day(2), day(1), day(0)]
        _ = cache.refresh(days: days, today: day(0)) { samples($0) }

        var fetched: [Date] = []
        _ = cache.refresh(days: days, today: day(0)) { d in
            fetched.append(d)
            return samples(d)
        }
        // Only today is recomputed; closed past days are trusted.
        XCTAssertEqual(fetched, [day(0)])
    }

    func testTodayIsAlwaysRecomputed() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 6) }
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 10) }
        let r = cache.rollups(in: day(0)...day(0)).first
        XCTAssertEqual(r?.dc ?? 0, 10, accuracy: 0.001)
    }

    func testDaysBelowTheQualityGateAreNotStored() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(1)], today: day(0)) { _ in [] }
        XCTAssertTrue(cache.rollups(in: day(1)...day(1)).isEmpty)
    }

    func testRollupsAreReturnedAscending() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0), day(2), day(1)], today: day(0)) { samples($0) }
        let days = cache.rollups(in: day(2)...day(0)).map(\.day)
        XCTAssertEqual(days, [day(2), day(1), day(0)])
    }

    func testPersistsAcrossInstances() {
        let a = TrackCache(fileURL: url)
        _ = a.refresh(days: [day(1)], today: day(0)) { samples($0) }

        let b = TrackCache(fileURL: url)
        b.load()
        XCTAssertEqual(b.rollups(in: day(1)...day(1)).count, 1)
    }

    func testCorruptFileRebuildsSilently() {
        try! Data("not json".utf8).write(to: url)
        let cache = TrackCache(fileURL: url)
        cache.load()
        XCTAssertTrue(cache.rollups(in: day(30)...day(0)).isEmpty)

        // And it can still be written to afterwards.
        _ = cache.refresh(days: [day(1)], today: day(0)) { samples($0) }
        XCTAssertEqual(cache.rollups(in: day(1)...day(1)).count, 1)
    }

    func testFingerprintIsStableForUnchangedValues() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(1)], today: day(0)) { samples($0) }
        XCTAssertEqual(cache.fingerprint(for: [day(1)]), cache.fingerprint(for: [day(1)]))
    }

    func testFingerprintChangesWhenValuesChange() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 6) }
        let before = cache.fingerprint(for: [day(0)])
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0, dc: 10) }
        XCTAssertNotEqual(before, cache.fingerprint(for: [day(0)]))
    }

    /// Today's rollup is rewritten on every Track appear (`refresh` always
    /// recomputes `today`). If those repeat writes produce identical values,
    /// the fingerprint must not change — otherwise the macro-read cache
    /// misses on every screen open, re-billing an LLM call each time.
    func testFingerprintStableAcrossIdenticalTodayRefreshes() {
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0) }
        let before = cache.fingerprint(for: [day(0)])
        _ = cache.refresh(days: [day(0)], today: day(0)) { samples($0) }
        XCTAssertEqual(before, cache.fingerprint(for: [day(0)]))
    }

    /// Pins `fingerprint` to a specific value derived from a fixed fixture,
    /// independent of `Date()` or any process state. A seeded-per-launch hash
    /// (Swift's `Hasher`) would fail this test nondeterministically across
    /// runs; a canonical, process-stable hash always returns this exact
    /// string for this exact data.
    func testFingerprintIsProcessStableForKnownFixture() {
        let fixedDay = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = TrackCache(fileURL: url)
        _ = cache.refresh(days: [fixedDay], today: fixedDay.addingTimeInterval(-86_400)) {
            samples($0)
        }
        XCTAssertEqual(cache.fingerprint(for: [fixedDay]), "3p2r5yc14g975")

        // Sanity check: the pinned value is genuinely derived from the data —
        // changing one input changes the fingerprint.
        let otherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: otherURL) }
        let other = TrackCache(fileURL: otherURL)
        _ = other.refresh(days: [fixedDay], today: fixedDay.addingTimeInterval(-86_400)) {
            samples($0, dc: 99)
        }
        XCTAssertNotEqual(other.fingerprint(for: [fixedDay]),
                          cache.fingerprint(for: [fixedDay]))
    }

    func testMacroReadsRoundTrip() {
        let a = TrackCache(fileURL: url)
        a.setMacroRead("Steady week.", key: "week|123|abc")

        let b = TrackCache(fileURL: url)
        b.load()
        XCTAssertEqual(b.macroRead(key: "week|123|abc"), "Steady week.")
        XCTAssertNil(b.macroRead(key: "week|123|different"))
    }
}
