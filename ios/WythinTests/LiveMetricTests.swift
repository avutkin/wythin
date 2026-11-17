import XCTest
@testable import Wythin

final class LiveMetricTests: XCTestCase {

    func testEveryCaseHasAPlainLanguageName() {
        let banned = ["HRV", "RMSSD", "RSA", "SDNN", "DFA", "LF/HF", "vagal", "entropy"]
        for metric in LiveMetric.allCases {
            XCTAssertFalse(metric.displayName.isEmpty, "\(metric) has no display name")
            for term in banned {
                XCTAssertFalse(metric.displayName.localizedCaseInsensitiveContains(term),
                               "\(metric) leaks the technical term \(term)")
            }
        }
    }

    /// One point carrying a DISTINCT value for every field, so a mis-wired
    /// extractor reads a number that belongs to another metric and the
    /// assertion fails. The previous version of this test covered 3 of 13,
    /// which is how `stressBalance` sat wired to the raw `lfHF` ratio through
    /// eight reviewed tasks: nothing asserted what it returned.
    private var allFieldsPoint: MetricsHistoryPoint {
        MetricsHistoryPoint(timestamp: Date(),
                            meanBPM: 61, rmssd: 33, rsaMs: 27, sdnn: 52,
                            lfHF: 1.7, coherence: 0.62, breathBPM: 14, cbi: 0.41,
                            dfa1: 1.08, rcmse: 1.35, pip: 44, dc: 7.5)
    }

    func testEveryExtractorReadsItsOwnField() {
        let p = allFieldsPoint
        XCTAssertEqual(LiveMetric.hr.value(p), 61)
        XCTAssertEqual(LiveMetric.rmssd.value(p), 33)
        XCTAssertEqual(LiveMetric.rsa.value(p), 27)
        XCTAssertEqual(LiveMetric.sdnn.value(p), 52)
        XCTAssertEqual(LiveMetric.coherence.value(p), 0.62)
        XCTAssertEqual(LiveMetric.breathBPM.value(p), 14)
        XCTAssertEqual(LiveMetric.cbi.value(p), 0.41)
        XCTAssertEqual(LiveMetric.pip.value(p), 44)
        XCTAssertEqual(LiveMetric.dfa1.value(p), 1.08)
        XCTAssertEqual(LiveMetric.dc.value(p), 7.5)
        XCTAssertEqual(LiveMetric.rcmse.value(p), 1.35)
        // vti is ln(RMSSD); the convenience initializer derives it that way.
        XCTAssertEqual(try XCTUnwrap(LiveMetric.vti.value(p)), log(Float(33)), accuracy: 0.0001)
        // Derived, not a stored field — see below.
        XCTAssertEqual(try XCTUnwrap(LiveMetric.stressBalance.value(p)), 54.7945, accuracy: 0.001)
    }

    /// The whole table at once: every case must be covered by the fixture
    /// above, so adding a `LiveMetric` case without wiring an extractor is
    /// caught here rather than by a metric that silently never scores.
    func testNoCaseIsLeftUnwiredOnAFullyPopulatedPoint() {
        let p = allFieldsPoint
        for metric in LiveMetric.allCases {
            XCTAssertNotNil(metric.value(p), "\(metric) read nil from a fully populated point")
        }
    }

    func testMissingFieldsReadAsNilRatherThanZero() {
        let empty = MetricsHistoryPoint(timestamp: Date(), meanBPM: 61)
        XCTAssertNil(LiveMetric.dfa1.value(empty))
        XCTAssertNil(LiveMetric.rmssd.value(empty))
        // No RMSSD and no LF/HF powers — the balance has nothing to work from.
        XCTAssertNil(LiveMetric.stressBalance.value(empty))
    }

    /// The load-bearing property of I1: the Tension axis's second input is the
    /// breathing-robust SNS share, NOT the raw LF/HF ratio. During resonance
    /// breathing the vagal peak moves into LF and the ratio spikes, while the
    /// RMSSD-driven dial is unmoved — so scoring the ratio would call the most
    /// vagally-activating breathing there is "stressed".
    func testStressBalanceIsTheBreathingRobustDialNotTheRawRatio() {
        // Same RMSSD, same heart rate; only the breathing rate and the
        // (consequently inverted) LF/HF ratio differ.
        let normal = MetricsHistoryPoint(timestamp: Date(), meanBPM: 60, rmssd: 45,
                                         sdnn: 50, lfHF: 0.8, breathBPM: 14)
        let paced  = MetricsHistoryPoint(timestamp: Date(), meanBPM: 60, rmssd: 45,
                                         sdnn: 50, lfHF: 9.0, breathBPM: 6)
        XCTAssertEqual(try XCTUnwrap(LiveMetric.stressBalance.value(normal)),
                       try XCTUnwrap(LiveMetric.stressBalance.value(paced)), accuracy: 0.0001,
                       "slow breathing must not move the stress dial when RMSSD has not moved")
        XCTAssertNotEqual(normal.lfHF, paced.lfHF, "the fixture's raw ratio really does differ")
    }

    /// Matches the value `DailyRollupCompute` stores in the typed
    /// `stressBalance` field — the two must be the same number, since the live
    /// path scores the dictionary entry and the charts plot the typed field.
    func testExtractorAgreesWithTheRollupsStoredStressBalance() {
        let p = allFieldsPoint
        XCTAssertEqual(try XCTUnwrap(DailyRollupCompute.stressBalance(p)),
                       Double(try XCTUnwrap(LiveMetric.stressBalance.value(p))), accuracy: 0.0001)
    }

    func testRawValuesAreStableWireKeys() {
        XCTAssertEqual(LiveMetric.hr.rawValue, "hr")
        XCTAssertEqual(LiveMetric.breathBPM.rawValue, "breath_bpm")
        // "stress_balance", never "lf_hf": the same distinction
        // `TrackMetricSpecTests.testTrendKeysAreUniqueAndStressBalanceIsNotLfHf`
        // already enforces for the Track payload. A 0–100 dial stored under
        // the ratio's key would be read back as a ratio.
        XCTAssertEqual(LiveMetric.stressBalance.rawValue, "stress_balance")
        XCTAssertFalse(LiveMetric.allCases.map(\.rawValue).contains("lf_hf"))
    }

    func testRawValuesAreUnique() {
        let keys = LiveMetric.allCases.map(\.rawValue)
        XCTAssertEqual(Set(keys).count, keys.count, "rawValue is a persisted dictionary key")
    }
}

final class LiveHistoryTimezoneTests: XCTestCase {
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private let dubai = TimeZone(identifier: "Asia/Dubai")!
    private let moscow = TimeZone(identifier: "Europe/Moscow")!
    private let day = LiveCivilDay(year: 2026, month: 11, day: 15)

    private func point(_ timestamp: String, zone: String?) -> MetricsHistoryPoint {
        MetricsHistoryPoint(timestamp: instant(timestamp), meanBPM: 60, rmssd: 40,
                            sdnn: 45, timezone: zone)
    }

    func testDubaiMidnightStaysOnRecordedDayWhenViewedFromMoscow() {
        let points = [point("2026-11-14T20:30:00Z", zone: "Asia/Dubai"),
                      point("2026-11-15T20:30:00Z", zone: "Asia/Dubai")]
        let result = LiveDayHistory.select(points, day: day, fallbackTimeZone: moscow, isToday: false)
        XCTAssertEqual(result.raw.map(\.timestamp), [instant("2026-11-14T20:30:00Z")])
        XCTAssertEqual(result.chartDay.bounds.lowerBound, instant("2026-11-14T20:00:00Z"))
        XCTAssertEqual(result.chartDay.bounds.upperBound, instant("2026-11-15T20:00:00Z"))
        XCTAssertEqual(result.chartDay.timeZone.identifier, "Asia/Dubai")
        XCTAssertEqual(result.chartDay.clockLabel(at: points[0].timestamp), "00:30")
    }

    func testCandidateQueryCoversBothSidesOfDateLineFromAnyViewerZone() {
        let range = day.candidateRange
        XCTAssertEqual(range.lowerBound, instant("2026-11-14T10:00:00Z"))
        XCTAssertEqual(range.upperBound, instant("2026-11-16T14:00:00Z"))
        let points = [point("2026-11-14T10:01:00Z", zone: "Pacific/Kiritimati"),
                      point("2026-11-16T11:59:00Z", zone: "Etc/GMT+12")]
        XCTAssertTrue(points.allSatisfy { range.contains($0.timestamp) })
        let result = LiveDayHistory.select(points, day: day, fallbackTimeZone: moscow, isToday: false)
        XCTAssertEqual(result.raw.count, 2)
        XCTAssertEqual(result.chartDay.bounds.lowerBound, instant("2026-11-14T10:00:00Z"))
        XCTAssertEqual(result.chartDay.bounds.upperBound, instant("2026-11-16T12:00:00Z"))
        XCTAssertEqual(result.chartDay.timeZone.identifier, "Pacific/Kiritimati")
        XCTAssertEqual(result.chartDay.windowRange(.h24, panOffset: 0, now: .distantFuture),
                       instant("2026-11-14T10:00:00Z")..<instant("2026-11-16T12:00:00Z"))
    }

    func testEarliestKnownSelectedZoneIsReferenceEvenIfInputIsUnsortedOrStartsWithLegacy() {
        let points = [point("2026-11-15T08:00:00Z", zone: "Europe/Moscow"),
                      point("2026-11-14T21:00:00Z", zone: nil),
                      point("2026-11-14T22:00:00Z", zone: "Asia/Dubai"),
                      point("2026-11-14T10:00:00Z", zone: "Europe/London")]
        let result = LiveDayHistory.select(points, day: day, fallbackTimeZone: moscow, isToday: false)
        XCTAssertEqual(result.raw.count, 3)
        XCTAssertEqual(result.chartDay.timeZone.identifier, "Asia/Dubai")
        XCTAssertEqual(result.chartDay.bounds.upperBound, instant("2026-11-15T21:00:00Z"))
    }

    func testLegacyAndInvalidZonesUseExplicitFallbackWithoutInventingProvenance() {
        let points = [point("2026-11-14T20:30:00Z", zone: nil),
                      point("2026-11-14T21:30:00Z", zone: "invalid/zone")]
        let result = LiveDayHistory.select(points, day: day, fallbackTimeZone: moscow, isToday: false)
        XCTAssertEqual(result.raw.count, 1)
        XCTAssertEqual(result.raw.first?.timezone, "invalid/zone")
        XCTAssertEqual(result.chartDay.timeZone, moscow)
        let fromDubai = LiveDayHistory.select(points, day: day, fallbackTimeZone: dubai, isToday: false)
        XCTAssertEqual(fromDubai.raw.count, 2)
        XCTAssertNil(fromDubai.raw.first?.timezone)
    }

    func testWholeDayFollowsDSTInsteadOfAssuming24Hours() {
        let newYork = TimeZone(identifier: "America/New_York")!
        for (civil, start, end, duration) in [
            (LiveCivilDay(year: 2026, month: 3, day: 8), "2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", 23.0),
            (LiveCivilDay(year: 2026, month: 11, day: 1), "2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", 25.0)
        ] {
            let result = LiveDayHistory.select([], day: civil, fallbackTimeZone: newYork, isToday: false)
            let range = result.chartDay.windowRange(.h24, panOffset: -7200, now: .distantFuture)
            XCTAssertEqual(range, instant(start)..<instant(end))
            XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), duration * 3600)
        }
    }

    func testShortWindowsPanInAbsoluteTimeAcrossRepeatedDSTHour() {
        let chart = LiveDayHistory.select([], day: LiveCivilDay(year: 2026, month: 11, day: 1),
                                          fallbackTimeZone: TimeZone(identifier: "America/New_York")!,
                                          isToday: false).chartDay
        let range = chart.windowRange(.h2, panOffset: -22 * 3600, now: .distantFuture)
        XCTAssertEqual(range, instant("2026-11-01T05:00:00Z")..<instant("2026-11-01T07:00:00Z"))
        XCTAssertEqual(chart.clockLabel(at: range.lowerBound), "01:00")
        XCTAssertEqual(chart.clockLabel(at: range.upperBound), "02:00")
        XCTAssertEqual(chart.windowRange(.h2, panOffset: -999999, now: .distantFuture).lowerBound,
                       instant("2026-11-01T04:00:00Z"))
    }

    func testTodayUsesExplicitIdentityEvenWhenReferenceClockHasAlreadyAdvanced() {
        let bounds = instant("2026-11-14T20:00:00Z")..<instant("2026-11-16T12:00:00Z")
        let chart = LiveChartDay(bounds: bounds, timeZone: dubai, isToday: true)
        let now = instant("2026-11-15T23:00:00Z") // Nov 16 in Dubai, still Nov 15 for the viewer.
        XCTAssertEqual(chart.windowRange(.h2, panOffset: 0, now: now).upperBound, now)
        XCTAssertEqual(chart.windowRange(.h24, panOffset: 0, now: now), bounds)
    }

    func testCivilDateSurvivesViewerTimezoneChangeAndDayListRollover() {
        let original = LiveCivilDay(date: instant("2026-11-14T20:00:00Z"), timeZone: dubai)
        XCTAssertEqual(original, day)
        XCTAssertEqual(original.interval(in: moscow).lowerBound, instant("2026-11-14T21:00:00Z"))
        let newDays = LiveCivilDay.recentDays(now: instant("2026-11-16T12:00:00Z"), timeZone: moscow)
        XCTAssertEqual(newDays.last, LiveCivilDay(year: 2026, month: 11, day: 16))
        XCTAssertEqual(newDays[newDays.count - 2], original)
    }

    func testLiveRefreshRetainsPersistedSamplesBeyond24HoursAndReplacesOverlappingTicks() {
        let early = point("2026-11-14T10:01:00Z", zone: "Pacific/Kiritimati")
        let overlap = point("2026-11-15T13:00:00Z", zone: "Etc/GMT+12")
        let updated = MetricsHistoryPoint(timestamp: overlap.timestamp, meanBPM: 72, rmssd: 40,
                                          sdnn: 45, timezone: "Etc/GMT+12")
        let late = point("2026-11-16T11:59:00Z", zone: "Etc/GMT+12")
        let merged = LiveDayHistory.mergedPoints([early, overlap], incoming: [updated, late])
        let result = LiveDayHistory.select(merged, day: day, fallbackTimeZone: moscow, isToday: true)
        XCTAssertEqual(result.raw.map(\.timestamp), [early.timestamp, overlap.timestamp, late.timestamp])
        XCTAssertEqual(result.raw.map(\.meanBPM), [60, 72, 60])
        XCTAssertEqual(result.chartDay.bounds.lowerBound, instant("2026-11-14T10:00:00Z"))
        XCTAssertEqual(result.chartDay.bounds.upperBound, instant("2026-11-16T12:00:00Z"))
    }

    func testLiveMergePreservesKnownRecordingZoneWhenRollingCopyHasNoValidZone() {
        let saved = point("2026-11-14T20:30:00Z", zone: "Asia/Dubai")
        for unknownZone: String? in [nil, "invalid/zone"] {
            let legacy = point("2026-11-14T20:30:00Z", zone: unknownZone)
            let merged = LiveDayHistory.mergedPoints([saved], incoming: [legacy])
            let result = LiveDayHistory.select(merged, day: day, fallbackTimeZone: moscow, isToday: true)
            XCTAssertEqual(result.raw.count, 1)
            XCTAssertEqual(result.raw.first?.timezone, "Asia/Dubai")
        }
    }

    func testLiveRefreshCannotReintroducePersistedSamplesFromAnotherRecordedDay() {
        // In Dubai this is Nov 16 00:30, so it must stay off the Nov 15 page
        // even though a legacy in-memory copy looks like Nov 15 in Moscow.
        let saved = point("2026-11-15T20:30:00Z", zone: "Asia/Dubai")
        for unknownZone: String? in [nil, "invalid/zone"] {
            var history = LiveDayHistory.select([saved], day: day, fallbackTimeZone: moscow, isToday: true)
            XCTAssertTrue(history.raw.isEmpty)
            for _ in 0..<3 {
                history = history.refreshing(with: [point("2026-11-15T20:30:00Z", zone: unknownZone)],
                                             day: day, fallbackTimeZone: moscow, isToday: true)
                XCTAssertTrue(history.raw.isEmpty, "recorded-day exclusion must survive every live refresh")
            }
        }
    }

    func testDSTBoundarySamplesHaveVisibleBucketCenters() {
        let points = [point("2026-11-01T04:00:01Z", zone: "America/New_York"),
                      point("2026-11-02T04:59:59Z", zone: "America/New_York")]
        let history = LiveDayHistory.select(points, day: LiveCivilDay(year: 2026, month: 11, day: 1),
                                            fallbackTimeZone: moscow, isToday: false)
        let card = MetricChartCard(title: "Pulse", subtitle: "", yLabel: "bpm", color: .blue,
                                   windows: [.h24], refs: [], yDomain: 0...100, win: .h24,
                                   selectedX: .constant(nil), panOffset: .constant(0),
                                   history: history.filtered, date: history.chartDay.bounds.lowerBound,
                                   liveDay: history.chartDay, extract: { $0.meanBPM.map(Double.init) })
        XCTAssertEqual(card.points.count, 2)
        XCTAssertTrue(card.points.allSatisfy { history.chartDay.bounds.contains($0.date) },
                      "epoch-aligned bucket centers must not push midnight samples outside the plotted day")
    }

    func testPinnedActivitySpanTakesPriorityOverLiveDay() {
        let history = LiveDayHistory.select([], day: day, fallbackTimeZone: dubai, isToday: false)
        let start = instant("2026-11-14T18:00:00Z")
        let end = instant("2026-11-15T03:00:00Z")
        let card = MetricChartCard(title: "Pulse", subtitle: "", yLabel: "bpm", color: .blue,
                                   windows: [.h24], refs: [], yDomain: 0...100, win: .h24,
                                   night: start...end, selectedX: .constant(nil), panOffset: .constant(-3600),
                                   history: [], date: start, liveDay: history.chartDay,
                                   extract: { $0.meanBPM.map(Double.init) })
        XCTAssertEqual(card.windowDates.start, start)
        XCTAssertEqual(card.windowDates.end, end)
    }

    func testDayTimezoneAndHistoryRevisionChangesClearCachedHistoryAndReference() {
        let original = LiveDayLoadID(day: day, fallbackTimeZone: moscow, historyRevision: 1, isToday: true)
        let changes = [
            LiveDayLoadID(day: LiveCivilDay(year: 2026, month: 11, day: 16), fallbackTimeZone: moscow, historyRevision: 1, isToday: true),
            LiveDayLoadID(day: day, fallbackTimeZone: dubai, historyRevision: 1, isToday: true),
            LiveDayLoadID(day: day, fallbackTimeZone: moscow, historyRevision: 2, isToday: true),
            LiveDayLoadID(day: day, fallbackTimeZone: moscow, historyRevision: 1, isToday: false)
        ]
        let reference = LiveDayReference(stats: [:], dayCount: 7)
        for changed in changes {
            var state = LiveDayHistoryState()
            state.begin(original)
            state.history = LiveDayHistory.select([point("2026-11-15T08:00:00Z", zone: "Asia/Dubai")],
                                                 day: day, fallbackTimeZone: moscow, isToday: true)
            state.reference = reference
            state.begin(original)
            XCTAssertEqual(state.history?.raw.count, 1, "same load retains its snapshot")
            state.begin(changed)
            XCTAssertNil(state.history, "changed day/clock/revision must refetch even if raw was nonempty")
            XCTAssertNil(state.reference)
        }
    }
}
