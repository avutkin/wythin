import Foundation

/// Turns a stored session into the 0–100 readings the row displays.
///
/// Only indices whose inputs are already persisted appear. An index with no
/// data is **left out entirely** rather than shown empty — the row this
/// replaces printed three dashes and a "1 of 7", which told its reader nothing
/// except that the app was unsure of itself.
///

extension ActivityLog {

    var scoredIndices: [ScoredIndex] {
        [
            readinessIndex,
            brakeReleaseIndex,
            efficiencyIndex,
            bounceBackIndex,
        ].compactMap { $0 }
    }

    /// How you arrived — the only reading here you could still have acted on.
    var readinessIndex: ScoredIndex? {
        ReadinessScore.index(value: readinessScore, peerCount: readinessPeerCount ?? 0)
    }

    /// How far the calm brake came off for the work that was done.
    var brakeReleaseIndex: ScoredIndex? {
        guard case let .score(value, _) = suppressionAxis else { return nil }
        return BrakeReleaseIndex.index(score: value,
                                       troughDC: duringDCTrough.map(Double.init))
    }

    /// Brake given up per extra beat — the price, where Brake release is the depth.
    ///
    /// Chest motion does not measure barbell work, so a session with no
    /// external work signal has no efficiency to report and says so by absence.
    var efficiencyIndex: ScoredIndex? {
        guard hasExternalWorkSignal, efficiencySlope != nil,
              let value = efficiencyScore else { return nil }
        let brake = ExerciseSuppression.brakePerBeat(dcPre: beforeDC.map(Double.init),
                                                     dcDuring: duringDC.map(Double.init),
                                                     hrPre: beforeHR.map(Double.init),
                                                     hrDuring: duringHR.map(Double.init))
        return ScoredIndex(
            name: "Efficiency",
            value: value,
            verdict: value >= IndexBand.keepAbove ? "cheap for the work"
                   : value >= IndexBand.actBelow  ? "fair price"
                                                  : "expensive per beat",
            detail: brake.map { String(format: "%.2f ms/beat", $0) } ?? "")
    }

    /// How fast the system came back, from the readings that survived.
    ///
    /// Decoupling is passed a history count of zero until it is stored, which
    /// keeps it out of the mean rather than letting an unscored construct
    /// silently weight the result.
    var recoveryComposite: RecoveryIndex.Result? {
        RecoveryIndex.compose(hrr60: hrr60Bpm,
                              t30Seconds: t30Seconds,
                              t30Peers: [],          // ranked at derive time; see `t30Score`
                              rmssdBefore: beforeRMSSD.map(Double.init),
                              rmssdAfter: afterRMSSD.map(Double.init),
                              vagal: recoveryOutcome,
                              heartRate: heartRateReturnOutcome,
                              t30Ranked: t30Score)
    }

    /// How fast the system came back, from every checkpoint that has arrived.
    ///
    /// It used to be a mean of three readings, and fell back to the vagal
    /// timing alone when none of them resolved — which is how a session with a
    /// four-minute heart-rate return and a brake still down at thirty-four
    /// printed **0**. A lone checkpoint can no longer be the score:
    /// `RecoveryIndex` returns nothing below two, and the card shows its
    /// checkpoints instead of a number it cannot support.
    var bounceBackIndex: ScoredIndex? {
        guard let composite = recoveryComposite else { return nil }
        let value = composite.value

        // The detail keeps quoting the measurement rather than the firmness
        // label. How complete the cascade is belongs beside the headline, where
        // the card can show it with the checkpoint list; a row that swapped
        // "halfway in 9.0 min" for "provisional · 2 of 5" would have traded a
        // fact for bookkeeping.
        let detail: String
        switch recoveryOutcome {
        case let .reached(minutes):    detail = String(format: "halfway in %.1f min", minutes)
        case let .notReached(observed):
            // Restored days can carry hours of samples after a session; quoting
            // "not halfway in 240 min" reads as an alarm rather than a bound.
            detail = observed > 30 ? "not halfway while recorded"
                                   : "not halfway in \(Int(observed.rounded())) min"
        case .notObserved:              detail = hrr60Bpm.map { "\(Int($0.rounded())) bpm shed" } ?? ""
        }

        return ScoredIndex(name: BounceBackIndex.displayName,
                           value: value,
                           verdict: value >= IndexBand.keepAbove ? "came back fast"
                                  : value >= IndexBand.actBelow  ? "came back slowly"
                                                                 : "still coming back",
                           detail: detail)
    }

    /// The four implemented index slots, every one always present: a slot with
    /// no reading carries the reason instead of vanishing. Asked for twice —
    /// a two-cell grid read as "metrics look off", not as honest absence.
    /// True for a measured night. Nights take a scoring channel of their own —
    /// none of the exercise or practice machinery applies to eight hours of
    /// lying still, and letting it run produces confident nonsense.
    var isSleep: Bool { ActivityType.fromStored(activityType) == .sleep }

    /// Whether the during-vs-before practice score applies at all.
    ///
    /// `RestorativeScore` credits during-vs-before uplift. For a night the
    /// before-window is the five minutes before sleep onset — awake, upright,
    /// possibly still moving — so the uplift is enormous and the score pins
    /// near the top for every night regardless of how the night went. A number
    /// that is always 96 measures nothing.
    var showsRestorativeScore: Bool { !isSleep }

    var indexSlots: [(name: String, index: ScoredIndex?, whenEmpty: String)] {
        if isSleep { return sleepIndexSlots }
        // The yoga rule (research §4): a mind-body session that MEASURES
        // restorative or mixed is scored on the regulation channel — the vagal
        // rebound it exists to produce — never on suppression or HRR framing,
        // whose expectations invert here. One that measures as a workout
        // (power vinyasa) earns the exercise read below.
        if let mb = mindBodyClass, mb != .workout {
            return [
                (ReadinessScore.displayName, readinessIndex,
                 "needs \(ReadinessScore.minimumPeers) sessions"),
                ("Regulation", regulationIndex, "no after-window"),
            ]
        }
        return [
            (ReadinessScore.displayName, readinessIndex,
             "needs \(ReadinessScore.minimumPeers) sessions"),
            (MobilizedIndex.displayName, mobilizedIndex, "no pulse rise measured"),
            (SustainedIndex.displayName, sustainedIndex, "no intensity data"),
            ("Cost", costIndex,
             (brakePerBeat.map { $0 <= 0 } ?? false) || vagalRoseDuring
                ? "vagal tone held" : "no reading"),
            ("Recovery", recoveryIndex, "no after-window"),
        ]
    }

    var mobilizedIndex: ScoredIndex? {
        guard let before = beforeHR.map(Double.init) else { return nil }
        let peak = duringHRPeak.map(Double.init) ?? duringHR.map(Double.init)
        return MobilizedIndex.index(pulseRise: peak.map { $0 - before })
    }

    var sustainedIndex: ScoredIndex? {
        SustainedIndex.index(value: SustainedIndex.score(
            zoneModerate: [zone1Sec, zone2Sec, zone3Sec].compactMap { $0 }.reduce(0, +),
            zoneHeavy: zone4Sec ?? 0, zoneSevere: zone5Sec ?? 0,
            domModerate: domainModerateSec ?? 0, domHeavy: domainHeavySec ?? 0,
            domSevere: domainSevereSec ?? 0))
    }

    /// The Cost section is the economy score under its section name.
    var costIndex: ScoredIndex? {
        brakeReleaseIndex.map {
            ScoredIndex(name: "Cost", value: $0.value, verdict: $0.verdict, detail: $0.detail)
        }
    }

    /// The Recovery section: bounce-back under its section name; the
    /// morning-anchor calm-return sub joins when its stored field lands.
    var recoveryIndex: ScoredIndex? {
        bounceBackIndex.map {
            ScoredIndex(name: "Recovery", value: $0.value, verdict: $0.verdict, detail: $0.detail)
        }
    }

    /// The transparent overall, from the four performance sections.
    var sectionOverall: AxisValue {
        ExerciseOverallScore.composeSections(recovery: recoveryIndex?.value,
                                             sustained: sustainedIndex?.value,
                                             cost: costIndex?.value,
                                             mobilized: mobilizedIndex?.value)
    }

    /// The quantities with no good or bad direction.
    ///
    /// Kept apart from the scored grid so the screen never implies a verdict on
    /// how much work was done. A heavier session is not a better one.
    var ungradedDoses: [UngradedDose] {
        var out: [UngradedDose] = []
        if let load = exerciseLoad {
            out.append(UngradedDose(name: "Load",
                                    value: "\(Int(load.rounded()))",
                                    caption: "effort × time"))
        }
        if let peak = duringHRPeak {
            // The mockup captions this "81% of reserve", which needs the
            // personal ceiling and therefore a model context. The row has no
            // context, so it states what it knows rather than estimating a
            // ceiling — the fraction belongs on the detail screen, which does.
            out.append(UngradedDose(name: "Peak",
                                    value: "\(Int(Double(peak).rounded())) bpm",
                                    caption: "highest reached"))
        }
        return out
    }
}


// MARK: - Sleep sections

extension ActivityLog {

    /// The five sections a night is scored on, in evidence order. Each carries
    /// its own weight in the headline, and each is absent rather than zero when
    /// its input was not measured.
    var sleepIndexSlots: [(name: String, index: ScoredIndex?, whenEmpty: String)] {
        [
            ("Timing", sleepSection(.timing, sleepTiming), "needs a second night"),
            ("Duration", sleepSection(.duration, sleepDuration), "no sleep time"),
            ("Continuity", sleepSection(.continuity, sleepContinuity), "no stages"),
            ("Autonomic", sleepSection(.autonomic, sleepAutonomic), "no heart rate"),
            ("Breathing", sleepSection(.breathing, sleepBreathing), "needs respiratory effort"),
        ]
    }

    private func sleepSection(_ section: SleepSection, _ value: Int?) -> ScoredIndex? {
        guard let value else { return nil }
        return ScoredIndex(name: section.name,
                           value: value,
                           verdict: SleepSection.verdict(for: value),
                           detail: sleepSectionDetail(section))
    }

    private func sleepSectionDetail(_ section: SleepSection) -> String {
        switch section {
        case .timing:
            return sleepRegularity.map { "regularity index \(Int($0))" } ?? "how steady your hours are"
        case .duration:
            guard let m = sleepAsleepMinutes else { return "time asleep" }
            return "\(m / 60)h \(String(format: "%02d", m % 60))m asleep"
        case .continuity:
            return sleepStageSummary ?? "how unbroken the night was"
        case .autonomic:
            return "how far your heart rate settled, and when"
        case .breathing:
            return "steadiness of breathing overnight"
        }
    }
}
