import Foundation

/// The nine states. Raw values are the server's existing `state_key` contract
/// and must not change — the icon and colour lookup keys off them.
enum LiveStateKey: String, CaseIterable {
    case overloaded_exhausted
    case stressed_activated
    case engaged_performing
    case depleted_numb
    case stable_neutral
    case calm_alert
    case shutdown_burnout
    case recovering_resetting
    case renewed_thriving
}

struct LiveAxes: Equatable {
    let energy:   Float
    let tension:  Float
    let recovery: Float
}

struct StateContribution: Equatable {
    let metric: LiveMetric
    /// Signed pull on the state. Ranking uses the magnitude; the sign says
    /// which way it pushed.
    let value: Float
}

struct LiveStateResult: Equatable {
    let key: LiveStateKey
    let axes: LiveAxes
    /// Strongest pull first.
    let contributions: [StateContribution]
    /// Nothing moved much — the state is a weak call and the UI should show it
    /// as such rather than asserting it with the same confidence as a clear one.
    let isWeak: Bool
}

/// Turns a window's readings into one of the nine states.
///
/// Weighted rather than flat-averaged, and renormalised over whichever inputs
/// are present, so a missing metric weakens the axis's confidence rather than
/// silently dragging it toward zero.
///
/// NOTE: `stressBalance` is `1 − vagalIndex(rmssd)` scaled to 0–100 (see
/// `AutonomicCompute.balance`, which reaches its LF/HF fallback only when RMSSD
/// is absent), and RMSSD is also an Energy input — so the Tension and Energy
/// axes are not independent, and the same measurement is counted twice with
/// opposite sign. The z-scoring is sound: each is compared against the person's
/// own distribution of that same derived quantity, so the absolute map inside
/// `vagalIndex` cancels out. What the weights below have to account for is the
/// double-counting, which the spec names explicitly.
enum LiveStateClassifier {

    private static let energyWeights:   [LiveMetric: Float] = [.hr: 0.3, .rmssd: 0.4, .rcmse: 0.3]
    private static let tensionWeights:  [LiveMetric: Float] = [.pip: 0.55, .stressBalance: 0.45]
    private static let recoveryWeights: [LiveMetric: Float] = [.rsa: 0.3, .dc: 0.35, .vti: 0.35]

    private static func axis(_ weights: [LiveMetric: Float], _ r: LiveReading) -> Float {
        var sum = Float(0), used = Float(0)
        for (metric, w) in weights {
            guard let reading = r.readings[metric] else { continue }
            sum  += w * reading.effective
            used += w
        }
        return used > 0 ? sum / used : 0
    }

    static func axes(_ r: LiveReading) -> LiveAxes {
        LiveAxes(energy:   axis(energyWeights, r),
                 tension:  axis(tensionWeights, r),
                 recovery: axis(recoveryWeights, r))
    }

    /// A metric's weight is whichever single axis dictionary contains it — the
    /// three axes don't share metrics, so this is unambiguous. A metric in none
    /// of them (there currently are none among `LiveMetric`'s cases, but the
    /// enum is not exhaustively covered by contract) pulls on no axis and is
    /// excluded rather than silently treated as weight 1.
    private static func weight(for metric: LiveMetric) -> Float? {
        energyWeights[metric] ?? tensionWeights[metric] ?? recoveryWeights[metric]
    }

    /// Every metric's actual pull on the state — weight × effective, not the
    /// raw z-score — ranked strongest first. A raw z-score is how far the
    /// reading sits from usual; it says nothing about how much that reading
    /// moved the axis that decided the state, which is what "why" needs to
    /// rank honestly. Ties (equal weighted pull) break on the metric's own
    /// name rather than dictionary iteration order, which is seeded per
    /// process — otherwise the same reading could explain itself differently
    /// between launches, the same flicker this whole feature exists to stop.
    private static func rankedPulls(_ r: LiveReading) -> [StateContribution] {
        r.readings.values
            .compactMap { reading -> StateContribution? in
                guard let w = weight(for: reading.metric) else { return nil }
                return StateContribution(metric: reading.metric, value: w * reading.effective)
            }
            .sorted {
                let (la, lb) = (abs($0.value), abs($1.value))
                return la != lb ? la > lb : $0.metric.rawValue < $1.metric.rawValue
            }
    }

    static func classify(_ r: LiveReading) -> LiveStateResult {
        let a = axes(r)
        let pulls = rankedPulls(r)

        var contributions = pulls.filter { abs($0.value) >= LiveThresholds.contributionFloor }

        // A flat window still explains itself — otherwise WHY would be empty
        // exactly when the user most wants to know why nothing is happening.
        if contributions.isEmpty {
            contributions = Array(pulls.prefix(1))
        }

        let magnitude = max(abs(a.energy), abs(a.tension), abs(a.recovery))
        let isWeak = magnitude < LiveThresholds.weakCallCeiling

        return LiveStateResult(key: key(for: a, isWeak: isWeak),
                               axes: a,
                               contributions: contributions,
                               isWeak: isWeak)
    }

    /// Explicit rule table, ordered most-severe first so the worst true
    /// statement wins rather than whichever branch happens to come first.
    ///
    /// Thresholds are UNCALIBRATED first guesses, tuned only so the states named
    /// in the spec's example quadrants land where they should.
    private static func key(for a: LiveAxes, isWeak: Bool) -> LiveStateKey {
        if isWeak { return .stable_neutral }

        let tense     = a.tension  >  0.5
        let veryTense = a.tension  >  1.2
        let calm      = a.tension  < -0.3
        let lowE      = a.energy   < -0.5
        let highE     = a.energy   >  0.4
        let poorR     = a.recovery < -0.5
        let veryPoorR = a.recovery < -1.1
        let goodR     = a.recovery >  0.4
        let greatR    = a.recovery >  1.1

        if veryTense && lowE && veryPoorR { return .shutdown_burnout }
        if tense     && lowE && poorR     { return .overloaded_exhausted }
        // Not depleted (energy isn't low) plus real tension reads as activated
        // rather than exhausted, whether energy sits at the middle of its range
        // or clearly high — `hr` and `rmssd` can partially cancel in the energy
        // axis (see the class-level NOTE on the two axes sharing RMSSD), so
        // "tense but not low-energy" is a wider net than "tense and high-energy".
        if tense     && !lowE             { return .stressed_activated }
        if lowE      && poorR             { return .depleted_numb }
        if lowE      && goodR && calm     { return .recovering_resetting }
        if highE     && greatR && calm    { return .renewed_thriving }
        if highE     && goodR             { return .engaged_performing }
        if calm      && goodR             { return .calm_alert }
        return .stable_neutral
    }
}

/// Holds the displayed state until a challenger has won several evaluations in
/// a row. Without this the label flickers between neighbouring states while the
/// person feels no different.
final class LiveStateHysteresis {
    private let required: Int
    private var current: LiveStateKey?
    private var candidate: LiveStateKey?
    private var streak = 0

    init(required: Int = LiveThresholds.hysteresisCount) {
        self.required = required
    }

    func settle(_ key: LiveStateKey) -> LiveStateKey {
        guard let current else {
            self.current = key
            return key
        }
        if key == current {
            candidate = nil
            streak = 0
            return current
        }
        if key == candidate {
            streak += 1
        } else {
            candidate = key
            streak = 1
        }
        if streak >= required {
            self.current = key
            candidate = nil
            streak = 0
            return key
        }
        return current
    }
}
