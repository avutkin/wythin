import Foundation

// MARK: - Band

enum PotentialBand: String, Equatable {
    case full, good, steady, light, depleted

    static func forScore(_ s: Int) -> PotentialBand {
        switch s {
        case 80...:   return .full
        case 60..<80: return .good
        case 40..<60: return .steady
        case 25..<40: return .light
        default:      return .depleted
        }
    }

    /// User-visible label. Plain language only.
    var label: String {
        switch self {
        case .full:     return "full reserves"
        case .good:     return "good reserves"
        case .steady:   return "steady"
        case .light:    return "running light"
        case .depleted: return "depleted"
        }
    }
}

// MARK: - Explainability

struct PotentialComponents: Equatable {
    let lnRMSSDz:   Float
    let dcZ:        Float?
    /// Benefit-signed: a lower resting rate than usual is positive.
    let restingHRz: Float
}

struct PotentialPenalties: Equatable {
    let stability:     Float
    let fragmentation: Float
    let organization:  Float

    var total: Float { stability + fragmentation + organization }
}

struct PotentialResult: Equatable {
    let score:      Int
    let band:       PotentialBand
    let components: PotentialComponents
    let penalties:  PotentialPenalties
    let saturated:  Bool
}

// MARK: - Score

/// Capacity, scored against the user's own anchors.
///
/// Weighted rather than flat-averaged on purpose: every input is a lens on
/// the same vagal axis, so an equal-weight mean would over-weight whichever
/// axis has the most representatives.
///
/// Fragmentation enters only as a penalty. A fragmented rhythm inflates
/// short-term HRV indices including RMSSD while indicating worse autonomic
/// function (Costa, Davis & Goldberger 2017) — so it must never read as good
/// news, and it suppresses any "high recovery" claim downstream.
///
/// No published work validates this specific composite as "readiness". The
/// weights are reasoned extension and live here so they can be calibrated.
/// If the composite ever disagrees with plain lnRMSSD inexplicably, plain
/// lnRMSSD is the one to trust.
enum PotentialScore {

    static let wLnRMSSD:   Float = 0.50
    static let wDC:        Float = 0.30
    static let wRestingHR: Float = 0.20

    /// Anchors this far (hours) from the personal median hour are not comparable.
    static let maxHourDeviation: Double = 4
    /// Saturation cap — a deeply rested read is flagged, not celebrated.
    static let saturationCap = 75
    /// DFA α1 has no meaningful per-person SD at this sample size, so its
    /// deviation is scaled by a fixed step instead.
    static let dfa1Step: Float = 0.15

    static func evaluate(anchor: AnchorReading, baseline: AnchorBaseline) -> PotentialResult? {
        // Validity: circadian comparability.
        guard abs(anchor.hour - baseline.medianHour) <= maxHourDeviation else { return nil }

        guard let lnZ = baseline.lnRMSSD.z(anchor.lnRMSSD),
              let hrZraw = baseline.restingHR.z(anchor.restingHR) else { return nil }
        let hrZ = -hrZraw   // benefit-signed: lower resting HR is better

        let dcZ: Float? = {
            guard let dc = anchor.dc, let stat = baseline.dc else { return nil }
            return stat.z(dc)
        }()

        // Core, with DC's weight redistributed proportionally when absent.
        let capacityZ: Float
        if let dcZ {
            capacityZ = wLnRMSSD * lnZ + wDC * dcZ + wRestingHR * hrZ
        } else {
            let scale = 1 / (wLnRMSSD + wRestingHR)
            capacityZ = (wLnRMSSD * lnZ + wRestingHR * hrZ) * scale
        }

        let raw = min(max((50 + 25 * capacityZ).rounded(), 0), 100)

        // Penalties — capped, never bonuses.
        let stability: Float = {
            guard let cv7 = baseline.cv7, let stat = baseline.cv7Stat,
                  let z = stat.z(cv7) else { return 0 }
            return min(max(10 * z / 2, 0), 10)
        }()

        let fragmentation: Float = {
            guard let pip = anchor.pip, let stat = baseline.pip,
                  let z = stat.z(pip) else { return 0 }
            return min(max(10 * z / 2, 0), 10)
        }()

        let organization: Float = {
            guard let dfa1 = anchor.dfa1, let median = baseline.dfa1Median else { return 0 }
            let z = abs(dfa1 - median) / dfa1Step
            return min(max(5 * z / 2, 0), 5)
        }()

        let penalties = PotentialPenalties(stability: stability,
                                           fragmentation: fragmentation,
                                           organization: organization)

        var score = Int(min(max(raw - penalties.total, 0), 100))

        // Saturation guard: a high vagal index with an unusually low resting
        // rate is deep rest, not a peak — "higher is always better" breaks
        // here. Cap rather than celebrate.
        let rmssdToday    = exp(anchor.lnRMSSD)
        let rmssdBaseline = exp(baseline.lnRMSSD.mean)
        let ratioToday    = rmssdToday / (60_000 / anchor.restingHR)
        let ratioBaseline = rmssdBaseline / (60_000 / baseline.restingHR.mean)
        let saturated = lnZ > 1 && hrZraw < -1 && ratioToday > ratioBaseline
        if saturated { score = min(score, saturationCap) }

        return PotentialResult(
            score:      score,
            band:       PotentialBand.forScore(score),
            components: PotentialComponents(lnRMSSDz: lnZ, dcZ: dcZ, restingHRz: hrZ),
            penalties:  penalties,
            saturated:  saturated)
    }
}
