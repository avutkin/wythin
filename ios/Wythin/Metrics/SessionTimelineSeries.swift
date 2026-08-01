import Foundation

/// One plotted point of the session timeline.
struct TimelinePoint: Identifiable, Equatable {
    let id:   Int
    let date: Date
    /// % of heart-rate reserve in use.
    let hrr:  Double
    /// % of pre-session vagal tone withdrawn. `nil` where DC is unavailable.
    let withdrawn: Double?
    /// Contiguous-coverage run this point belongs to. The chart plots each
    /// segment as its own series, so a dropout leaves a visible break rather
    /// than a straight line drawn across minutes that were never recorded.
    let segment: Int
}

/// Builds the session timeline's plotted series.
///
/// Extracted from the view so the arithmetic can be tested: a chart that
/// silently mis-buckets is indistinguishable from one that is right, and the
/// only way to tell is to assert against known values.
enum SessionTimelineSeries {

    /// Target number of plotted points, regardless of session length.
    static let targetBuckets = 120

    /// A stretch longer than this with no samples is missing data, not a flat
    /// line through it. Matches `ExerciseIntensity.maxGapSeconds`.
    static var maxGapSeconds: TimeInterval { ExerciseIntensity.maxGapSeconds }

    /// - Parameters:
    ///   - samples: quality-filtered points, any order.
    ///   - dcPre:   pre-session DC, the reference for "withdrawn". Nil disables
    ///              the vagal trace entirely rather than inventing a baseline.
    static func build(samples: [(date: Date, hr: Float?, dc: Float?)],
                      startedAt: Date,
                      endedAt: Date,
                      restingHR: Float,
                      ceiling: Float,
                      dcPre: Float?) -> [TimelinePoint] {

        let span = endedAt.timeIntervalSince(startedAt)
        guard span > 0 else { return [] }
        let bucket = max(span / Double(targetBuckets), 1)

        var hrSum: [Int: Double] = [:], hrN: [Int: Int] = [:]
        var dcSum: [Int: Double] = [:], dcN: [Int: Int] = [:]

        for s in samples where s.date >= startedAt && s.date < endedAt {
            let key = Int(s.date.timeIntervalSince(startedAt) / bucket)
            if let hr = s.hr {
                hrSum[key, default: 0] += ExerciseIntensity.hrReserve(
                    hr: hr, restingHR: restingHR, ceiling: ceiling) * 100
                hrN[key, default: 0] += 1
            }
            if let dc = s.dc {
                dcSum[key, default: 0] += Double(dc)
                dcN[key, default: 0] += 1
            }
        }

        let filled = hrSum.keys.sorted()
        guard !filled.isEmpty else { return [] }

        func date(_ key: Int) -> Date {
            startedAt.addingTimeInterval(Double(key) * bucket + bucket / 2)
        }

        var out: [TimelinePoint] = []
        var previous: Int?
        var segment = 0

        for key in filled {
            // A run of empty buckets wider than the dropout tolerance is a hole
            // in the record, so the next point starts a new segment.
            if let prev = previous, Double(key - prev - 1) * bucket > maxGapSeconds {
                segment += 1
            }
            var withdrawn: Double?
            if let pre = dcPre, pre > 0, let sum = dcSum[key], let n = dcN[key], n > 0 {
                withdrawn = min(max((1 - (sum / Double(n)) / Double(pre)) * 100, 0), 100)
            }
            out.append(TimelinePoint(id: key, date: date(key),
                                     hrr: hrSum[key]! / Double(hrN[key]!),
                                     withdrawn: withdrawn,
                                     segment: segment))
            previous = key
        }
        return out
    }
}
