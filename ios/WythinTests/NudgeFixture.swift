import Foundation
@testable import Wythin

/// Shared builders for nudge tests: a personal baseline and a full 30-minute
/// signal window at the 30s background cadence, with every series overridable
/// so a test can shape exactly the one clause it is probing.
enum NudgeFixture {

    static let cadence: Double = 30

    static func baseline(lnSD: Float = 0.2,
                         dcSD: Float = 1.0,
                         restingHR: Float = 58,
                         n: Int = 200) -> AnchorBaseline {
        AnchorBaseline(
            lnRMSSD:    BaselineStat(mean: 3.8, sd: lnSD, n: n),
            restingHR:  BaselineStat(mean: restingHR, sd: 3, n: n),
            dc:         BaselineStat(mean: 7.0, sd: dcSD, n: n),
            pip:        BaselineStat(mean: 55, sd: 6, n: n),
            dfa1Median: 1.0,
            cv7:        nil,
            cv7Stat:    nil,
            medianHour: 8,
            anchorCount: n,
            hourMatched: true,
            provisional: n < AnchorBaseline.firmAnchors)
    }

    /// `i` runs 0 (oldest) → count-1 (newest). Buckets are 12 points wide at the
    /// default count, so `i < 12` is the first bucket and `i >= 48` the last.
    static func signals(now: Date = Date(),
                        count: Int = 60,
                        baseline: AnchorBaseline? = nil,
                        hr:        @escaping (Int) -> Float  = { _ in 62 },
                        rmssd:     @escaping (Int) -> Float  = { _ in 44 },
                        rsa:       @escaping (Int) -> Float? = { _ in 35 },
                        dfa1:      @escaping (Int) -> Float? = { _ in 1.0 },
                        motion:    @escaping (Int) -> Float? = { _ in 5 },
                        dc:        @escaping (Int) -> Float? = { _ in 7.0 },
                        coherence: @escaping (Int) -> Float? = { _ in 0.55 },
                        breath:    @escaping (Int) -> Float? = { _ in 14 },
                        quality:   @escaping (Int) -> Float? = { _ in 0.98 }) -> NudgeSignals {
        var b = NudgeSampleBuffer()
        for i in 0..<count {
            let t = now.addingTimeInterval(-Double(count - i) * cadence)
            b.append(MetricsHistoryPoint(
                timestamp: t,
                meanBPM: hr(i),
                rmssd: rmssd(i),
                rsaMs: rsa(i),
                sdnn: 50,
                coherence: coherence(i),
                breathBPM: breath(i),
                dfa1: dfa1(i),
                dc: dc(i),
                motion: motion(i),
                signalQuality: quality(i),
                ecgQualityTier: 2), now: t)
        }
        guard let s = NudgeSignals.derive(from: b, baseline: baseline ?? Self.baseline(), now: now) else {
            fatalError("fixture failed to derive signals — check count/cadence")
        }
        return s
    }

    /// A sedentary window whose RMSSD collapses across it: the canonical
    /// vagal-withdrawal shape D1 looks for.
    static func withdrawing(now: Date = Date()) -> NudgeSignals {
        signals(now: now, rmssd: { i in i < 12 ? 50 : (i >= 48 ? 18 : 30) })
    }

    /// Chest ACC well above the stillness gate, HR high, RMSSD suppressed.
    static func running(now: Date = Date()) -> NudgeSignals {
        signals(now: now,
                hr:     { _ in 150 },
                rmssd:  { _ in 12 },
                rsa:    { _ in 8 },
                motion: { _ in 200 })
    }

    /// Stationary cycling: chest barely moves, so the motion floor misses it and
    /// only the HR ceiling catches it.
    static func stationaryBike(now: Date = Date()) -> NudgeSignals {
        signals(now: now,
                hr:     { _ in 120 },
                rmssd:  { _ in 14 },
                rsa:    { _ in 10 },
                motion: { _ in 15 })
    }
}
