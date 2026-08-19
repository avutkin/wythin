import Foundation
import SwiftData

/// One metrics tick (~2 s snapshot) within a session.
@Model
final class HRVSample {
    var timestamp:      Date
    var meanBPM:        Float?
    var rmssd:          Float?
    var sdnn:           Float?
    var pnn50:          Float?
    var lfHF:           Float?
    var rsaMs:          Float?
    var rsaIdx:         Float?
    var coherence:      Float?
    var cbi:            Float?
    var breathBPM:      Float?
    var ieRatio:        Float?   // BreathPhases.meanIE
    var dfa1:           Float?
    var signalQuality:  Float?
    var rrInvalidRate:   Float?   // fraction of RR dropped as implausible
    var rrCorrectedRate: Float?   // fraction of RR interpolated (missed/extra beat)
    var ecgQualityTier:  Int?     // SignalQualityTier.rawValue (0 poor…2 good)
    var rcmse:          Float?
    var pip:            Float?
    var ials:           Float?
    var dc:             Float?
    var motion:         Float?   // SD of ACC vector magnitude (mg) — stillness
    /// Body position from the gravity direction (`BodyPosition.rawValue`), and
    /// the confidence of that call. Optional so existing stores migrate without
    /// a schema break; nil on every sample recorded before this existed and on
    /// any window the sensor was moving through.
    var bodyPositionRaw:    Int?
    var positionConfidence: Float?
    var vti:            Float?   // ln(RMSSD)
    var ulfPower:       Float?   // ms²  (ULF < 0.003 Hz)
    var vlfPower:       Float?   // ms²  (VLF 0.003–0.04 Hz)
    var lfPower:        Float?   // ms²
    var hfPower:        Float?   // ms²
    /// `BreathSource.rawValue` — which channel produced `breathBPM` (0 = ACC
    /// measured, 1 = EDR estimated). Optional attribute on a plain @Model, so
    /// SwiftData migrates existing stores automatically. Deliberately not
    /// synced to the server yet; can be added later without a migration.
    var breathSourceRaw: Int?

    init(from tick: MetricsTick) {
        self.timestamp  = tick.timestamp
        self.meanBPM    = tick.meanBPM
        self.rmssd      = tick.rmssd
        self.sdnn       = tick.sdnn
        self.pnn50      = tick.pnn50
        self.lfHF       = tick.lfHF
        self.rsaMs      = tick.rsaMs
        self.rsaIdx     = tick.rsaIdx
        self.coherence  = tick.coherenceScore
        self.cbi        = tick.cbi
        self.breathBPM  = tick.breathBPM
        self.ieRatio    = tick.breathPhases?.meanIE
        self.dfa1          = tick.dfa1
        self.signalQuality = tick.signalQuality
        self.rrInvalidRate   = tick.rrInvalidRate
        self.rrCorrectedRate = tick.rrCorrectedRate
        self.ecgQualityTier  = tick.ecgQuality?.tier.rawValue
        self.rcmse         = tick.rcmse
        self.pip           = tick.pip
        self.ials          = tick.ials
        self.dc            = tick.dc
        self.motion        = tick.motion
        self.bodyPositionRaw    = tick.bodyPosition?.rawValue
        self.positionConfidence = tick.positionConfidence
        self.vti        = tick.vti
        self.breathSourceRaw = tick.breathSource?.rawValue
        self.ulfPower   = tick.ulfPower
        self.vlfPower   = tick.vlfPower
        self.lfPower    = tick.lfPower
        self.hfPower    = tick.hfPower
    }

    /// Restore initializer: exactly the fourteen fields continuous sync
    /// uploads, so a cloud read-back round-trips to the same shape it left in.
    /// Everything sync never carried (powers, quality, motion…) stays nil —
    /// restored history is chart-and-baseline grade, not raw-signal grade.
    init(cloudTs: Date,
         meanBPM: Float?, rmssd: Float?, sdnn: Float?, pnn50: Float?,
         lfHF: Float?, rsaMs: Float?, coherence: Float?, cbi: Float?,
         breathBPM: Float?, dfa1: Float?, rcmse: Float?, pip: Float?,
         dc: Float?, vti: Float?) {
        self.timestamp = cloudTs
        self.meanBPM   = meanBPM
        self.rmssd     = rmssd
        self.sdnn      = sdnn
        self.pnn50     = pnn50
        self.lfHF      = lfHF
        self.rsaMs     = rsaMs
        self.coherence = coherence
        self.cbi       = cbi
        self.breathBPM = breathBPM
        self.dfa1      = dfa1
        self.rcmse     = rcmse
        self.pip       = pip
        self.dc        = dc
        self.vti       = vti

        self.rsaIdx = nil; self.ieRatio = nil; self.signalQuality = nil
        self.breathSourceRaw = nil
        self.rrInvalidRate = nil; self.rrCorrectedRate = nil; self.ecgQualityTier = nil
        self.ials = nil; self.motion = nil
        self.bodyPositionRaw = nil; self.positionConfidence = nil
        self.ulfPower = nil; self.vlfPower = nil; self.lfPower = nil; self.hfPower = nil
    }

    /// Convenience initializer covering the fields the anchor pipeline reads,
    /// mirroring `MetricsHistoryPoint.init(anchorTestTimestamp:)` — so
    /// `AnchorBackfill` can be exercised against a real store without standing
    /// up a whole `MetricsTick`. Unlisted fields stay nil.
    init(
        anchorTestTimestamp: Date,
        meanBPM: Float? = nil,
        vti: Float? = nil,
        rmssd: Float? = nil,
        sdnn: Float? = nil,
        dc: Float? = nil,
        pip: Float? = nil,
        dfa1: Float? = nil,
        breathBPM: Float? = nil,
        motion: Float? = nil,
        signalQuality: Float? = nil,
        rrInvalidRate: Float? = nil,
        ecgQualityTier: Int? = nil
    ) {
        self.timestamp = anchorTestTimestamp
        self.meanBPM   = meanBPM
        self.vti       = vti
        self.rmssd     = rmssd
        self.sdnn      = sdnn
        self.dc        = dc
        self.pip       = pip
        self.dfa1      = dfa1
        self.breathBPM = breathBPM
        self.motion    = motion
        self.signalQuality  = signalQuality
        self.rrInvalidRate  = rrInvalidRate
        self.ecgQualityTier = ecgQualityTier

        self.pnn50 = nil; self.lfHF = nil; self.rsaMs = nil; self.rsaIdx = nil
        self.coherence = nil; self.cbi = nil; self.ieRatio = nil
        self.rrCorrectedRate = nil; self.rcmse = nil; self.ials = nil
        self.breathSourceRaw = nil
        self.ulfPower = nil; self.vlfPower = nil; self.lfPower = nil; self.hfPower = nil
    }
}
