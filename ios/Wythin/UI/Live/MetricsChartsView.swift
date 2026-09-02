import Charts
import SwiftUI

// MARK: - Time Window

enum TimeWindow: String, CaseIterable, Identifiable {
    case m30 = "30m"
    case h2  = "2h"
    case h24 = "24h"

    var id: String { rawValue }

    /// Duration in seconds shown from 00:00 of the selected day.
    var seconds: TimeInterval {
        switch self {
        case .m30: return 1_800
        case .h2:  return 7_200
        case .h24: return 86_400
        }
    }

    /// Target ~120 bucketed points per window for good granularity.
    var bucketSeconds: TimeInterval { seconds / 120 }

    var bucketLabel: String {
        let secs = Int(bucketSeconds)
        if secs < 60 { return "\(secs)s avg" }
        return "\(secs / 60) min avg"
    }
}

// MARK: - Reference Line

struct RefLine {
    let value: Double
    let label: String
    let color: Color
}

// MARK: - Chart Segmenter

/// Assigns a contiguous-run id ("segment") to each bucket that carries a value.
/// Each run is drawn as a separate `LineMark` series, and Swift Charts draws no
/// line *between* series — so segment breaks are what make the line break across
/// genuine sensor-off gaps.
///
/// Extracted from `MetricChartCard.points` purely so the gap rule is unit
/// testable. It regressed once, silently, and only at the 24h window — a
/// one-token error that no other window could expose.
enum ChartSegmenter {

    /// - Parameters:
    ///   - valueKeys:       bucket keys carrying a value for this metric, ascending.
    ///   - presentKeys:     every bucket with any sample at all (sensor on), across all metrics.
    ///   - bucketSeconds:   width of one bucket.
    ///   - gapBreakSeconds: empty span that counts as the sensor being off.
    /// - Returns: one segment id per entry of `valueKeys`, in the same order.
    static func segments(valueKeys: [Int],
                         presentKeys: Set<Int>,
                         bucketSeconds: TimeInterval,
                         gapBreakSeconds: TimeInterval) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(valueKeys.count)
        var segment = 0
        var prevKey: Int?

        for key in valueKeys {
            if let pk = prevKey {
                // The empty span between two PRESENT buckets is the number of
                // buckets MISSING between them — `key - pk - 1` — not their
                // index distance. Adjacent buckets have an empty span of zero
                // and must stay joined.
                //
                // The earlier `key - pk` form made every adjacent pair look
                // like a full bucket-width gap. Harmless at 30m (bucket 15s)
                // and 2h (60s), both under the 300s threshold — but at 24h the
                // bucket is 720s, so the test was true on EVERY point, every
                // point became its own segment, and the line rendered as
                // isolated dots. Keep the `- 1`.
                let emptySpan = Double(key - pk - 1) * bucketSeconds
                if emptySpan >= gapBreakSeconds {
                    let sensorOnBetween = (pk + 1 ..< key).contains { presentKeys.contains($0) }
                    if !sensorOnBetween { segment += 1 }   // sensor truly off across the gap
                }
            }
            out.append(segment)
            prevKey = key
        }
        return out
    }
}

// MARK: - Bucketed Data Point

struct ChartPoint: Identifiable {
    let id:      Int    // bucket key — stable across re-renders
    let date:    Date
    let val:     Double
    let quality: Float? // average signal quality in this bucket (nil = no quality data)
    let segment: Int    // contiguous-run id; increments across data gaps so the line breaks
    /// More than half this bucket's samples were estimated (EDR) rather than
    /// measured. Folded into `segment`, so a source change starts a new line
    /// series and the dashed style cannot bleed across the boundary.
    var estimated: Bool = false
}

// MARK: - Anomaly Band

/// A contiguous time span where raw ticks existed but every tick failed the quality filter —
/// indicating sensor removal or severe contact noise.
struct AnomalyBand: Identifiable {
    let id:    Int    // index
    let start: Date
    let end:   Date
}

// MARK: - Metric Info

struct MetricInfo {
    let description: String
    let calculation: String?   // the actual method, in plain words
    let physical:    String
    let physiology:  String
    let training:    String
    let sensitivity: String
    let levels:      String
    let notes:       String?

    init(_ description: String, calculation: String? = nil, physical: String,
         physiology: String, training: String, sensitivity: String,
         levels: String, notes: String? = nil) {
        self.description = description
        self.calculation = calculation
        self.physical    = physical
        self.physiology  = physiology
        self.training    = training
        self.sensitivity = sensitivity
        self.levels      = levels
        self.notes       = notes
    }
}

// MARK: - Metric Info Sheet

struct MetricInfoSheet: View {
    let title: String
    let color: Color
    let info:  MetricInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        row("DESCRIPTION",             info.description)
                        if let c = info.calculation {
                            row("HOW IT'S CALCULATED", c)
                        }
                        row("PHYSICAL MEANING",        info.physical)
                        row("PHYSIOLOGICAL MEANING",   info.physiology)
                        row("TRAINING ASPECTS",        info.training)
                        row("SENSITIVITY",             info.sensitivity)
                        row("REFERENCE LEVELS",        info.levels)
                        if let n = info.notes { row("NOTES", n) }
                    }
                    .padding()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Theme.monoBody)
                        .foregroundStyle(color)
                }
            }
        }
    }

    private func row(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .tracking(2)
            Text(body)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.text.opacity(0.82))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - Generic Chart Card

/// Shared, despite living here. Sleep needs the *same* card, not one that
/// merely looks like it: the ask was to press a night's charts and read the
/// numbers off "the same charts I have in Live", and behaviour parity written
/// twice is behaviour parity until the next change to one of them. It stays in
/// this file because moving it means a hand-edited `project.pbxproj`, and a
/// bad merge of that file is what left `main` uncompilable once already.
///
/// Two modes, selected by `night`:
///
/// - **nil** — Live's own: a `TimeWindow` slid over a day via `panOffset`.
/// - **set** — a fixed span with no panning, so every chart in a sleep detail
///   shares one clock with the hypnogram above it.

struct MetricChartCard: View {
    let title:         String   // consumer name — shown in white
    let technicalName: String   // short technical name — shown in gray after title
    let technicalFull: String   // spelled-out technical name — its own line under the title
    let subtitle:      String   // description — shown on second line
    let yLabel:        String
    let color:      Color
    let windows:    [TimeWindow]
    let refs:       [RefLine]
    let yDomain:    ClosedRange<Double>
    let history:    [MetricsHistoryPoint]   // quality-filtered
    let rawHistory: [MetricsHistoryPoint]   // unfiltered — used for anomaly detection
    let date:       Date
    let smooth:     Bool
    let dynamicY:   Bool
    /// Dim the line where the underlying window is low-confidence (high artifact
    /// rate). Purely visual — no value is changed. Off for the signal-quality
    /// charts themselves (they must stay fully visible when artifacts are high).
    let flagUnreliable: Bool
    let info:       MetricInfo?
    /// Marks a sample as estimated rather than measured (dashed rendering +
    /// caption). Only Breath Rate passes this; default nil leaves the other
    /// cards untouched.
    let isEstimated: ((MetricsHistoryPoint) -> Bool)?
    let extract:          (MetricsHistoryPoint) -> Double?
    /// Optional transform applied to each bucket mean after averaging.
    /// Used for metrics like VTI where ln() must be applied AFTER averaging
    /// the underlying linear values (RMSSD), not before.
    let bucketTransform:  ((Double) -> Double)?

    let win: TimeWindow                    // shared window, chosen at the Today header
    /// A fixed span to draw instead of `win` — set by callers that own their
    /// own clock. A night is the case that forced it: `TimeWindow` offers 30 m,
    /// 2 h and 24 h anchored to midnight, and a night crosses midnight, so
    /// none of the three can frame one.
    let night: ClosedRange<Date>?
    @Binding var selectedX: Date?
    @Binding var panOffset: TimeInterval   // seconds the window is panned from its newest edge (≤ 0)
    @State private var showInfo = false

    init(title: String, technicalName: String = "", technicalFull: String = "",
         subtitle: String, yLabel: String,
         color: Color, windows: [TimeWindow], refs: [RefLine],
         yDomain: ClosedRange<Double>,
         win: TimeWindow,
         night: ClosedRange<Date>? = nil,
         selectedX: Binding<Date?>,
         panOffset: Binding<TimeInterval>,
         smooth: Bool = false,
         dynamicY: Bool = false,
         flagUnreliable: Bool = true,
         info: MetricInfo? = nil,
         isEstimated: ((MetricsHistoryPoint) -> Bool)? = nil,
         history: [MetricsHistoryPoint],
         rawHistory: [MetricsHistoryPoint] = [],
         date: Date,
         bucketTransform: ((Double) -> Double)? = nil,
         extract: @escaping (MetricsHistoryPoint) -> Double?) {
        self.title           = title
        self.technicalName   = technicalName
        self.technicalFull   = technicalFull
        self.subtitle        = subtitle
        self.yLabel          = yLabel
        self.color           = color
        self.windows         = windows
        self.refs            = refs
        self.yDomain         = yDomain
        self.smooth          = smooth
        self.dynamicY        = dynamicY
        self.flagUnreliable  = flagUnreliable
        self.info            = info
        self.isEstimated     = isEstimated
        self.history         = history
        self.rawHistory      = rawHistory
        self.date            = date
        self.bucketTransform = bucketTransform
        self.extract         = extract
        self.win   = win
        self.night = night
        _selectedX = selectedX
        _panOffset = panOffset
    }

    // MARK: Anomaly bands

    /// Buckets where signal quality is poor (artifact rate > 20%) but data exists.
    /// Rendered as a subtle amber tint, distinct from full anomaly (gray = no signal).
    private var poorQualityBands: [AnomalyBand] {
        guard !history.isEmpty else { return [] }
        let (wStart, wEnd) = windowDates
        let bucket = bucketSeconds

        // Accumulate per-bucket quality sums
        var sums:   [Int: Float] = [:]
        var counts: [Int: Int]   = [:]
        for pt in history where pt.timestamp >= wStart && pt.timestamp < wEnd {
            guard let q = pt.signalQuality else { continue }
            let key = Int(pt.timestamp.timeIntervalSince1970 / bucket)
            sums[key]   = (sums[key]   ?? 0) + q
            counts[key] = (counts[key] ?? 0) + 1
        }

        let poorKeys = sums.keys
            .filter { key in
                guard let n = counts[key], n > 0, let s = sums[key] else { return false }
                return (s / Float(n)) < 0.80    // < 80% quality = > 20% artifact rate
            }
            .sorted()

        // Merge consecutive buckets into bands
        var bands: [AnomalyBand] = []
        var prevKey: Int? = nil
        for key in poorKeys {
            let bStart = Date(timeIntervalSince1970: Double(key)     * bucket)
            let bEnd   = Date(timeIntervalSince1970: Double(key + 1) * bucket)
            if let pk = prevKey, pk == key - 1, !bands.isEmpty {
                bands[bands.count - 1] = AnomalyBand(id: bands.last!.id, start: bands.last!.start, end: bEnd)
            } else {
                bands.append(AnomalyBand(id: bands.count, start: bStart, end: bEnd))
            }
            prevKey = key
        }
        return bands
    }

    /// Buckets where raw ticks existed but ALL failed the quality filter.
    /// Adjacent bad buckets are merged into a single continuous span.
    private var anomalyBands: [AnomalyBand] {
        guard !rawHistory.isEmpty else { return [] }
        let (wStart, wEnd) = windowDates
        let bucket = bucketSeconds

        var rawCounts: [Int: Int]  = [:]
        var qualCounts: [Int: Int] = [:]

        for pt in rawHistory where pt.timestamp >= wStart && pt.timestamp < wEnd {
            let key = Int(pt.timestamp.timeIntervalSince1970 / bucket)
            rawCounts[key] = (rawCounts[key] ?? 0) + 1
        }
        for pt in history where pt.timestamp >= wStart && pt.timestamp < wEnd {
            let key = Int(pt.timestamp.timeIntervalSince1970 / bucket)
            qualCounts[key] = (qualCounts[key] ?? 0) + 1
        }

        // Flag buckets with ≥2 raw ticks but 0 passing quality (sensor noise/removal).
        let badKeys = rawCounts.keys
            .filter { (rawCounts[$0] ?? 0) >= 2 && (qualCounts[$0] ?? 0) == 0 }
            .sorted()

        // Merge consecutive bucket keys into continuous bands.
        var bands: [AnomalyBand] = []
        var prevKey: Int? = nil
        for key in badKeys {
            let bStart = Date(timeIntervalSince1970: Double(key)     * bucket)
            let bEnd   = Date(timeIntervalSince1970: Double(key + 1) * bucket)
            if let pk = prevKey, pk == key - 1, !bands.isEmpty {
                bands[bands.count - 1] = AnomalyBand(
                    id: bands.last!.id, start: bands.last!.start, end: bEnd)
            } else {
                bands.append(AnomalyBand(id: bands.count, start: bStart, end: bEnd))
            }
            prevKey = key
        }
        return bands
    }

    /// Data bucketing range — always loads the full day so selection-based
    /// panning can reach any point without a data gap.
    private var bucketDates: (start: Date, end: Date) {
        if let night { return (night.lowerBound, night.upperBound) }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return (cal.startOfDay(for: date), Date())
        }
        let s = cal.startOfDay(for: date)
        return (s, s.addingTimeInterval(86_400))
    }

    /// Newest edge the window can reach (right edge at pan 0): now for today,
    /// end-of-day for a past day.
    private var anchorEnd: Date {
        if let night { return night.upperBound }
        let cal = Calendar.current
        return cal.isDateInToday(date)
            ? Date()
            : cal.startOfDay(for: date).addingTimeInterval(86_400)
    }

    /// How wide the drawn window is. `win.seconds` unless a caller pinned a
    /// span of its own.
    private var spanSeconds: TimeInterval {
        night.map { $0.upperBound.timeIntervalSince($0.lowerBound) } ?? win.seconds
    }

    /// Same target as `TimeWindow.bucketSeconds` — about 120 points across
    /// whatever is being shown — so a pinned span gets the same granularity
    /// per pixel that the live windows do.
    private var bucketSeconds: TimeInterval {
        night == nil ? win.bucketSeconds : max(1, spanSeconds / 120)
    }

    /// Allowed pan range in seconds (≤ 0). Panning back is bounded by the
    /// earliest data; you can't pan past the newest edge (0).
    private var panBounds: ClosedRange<TimeInterval> {
        // A pinned span is already exactly the thing being looked at; there is
        // nothing to pan to, and allowing it would slide the sleep charts out
        // of register with the hypnogram they sit under.
        if night != nil { return 0...0 }
        let span = anchorEnd.timeIntervalSince(bucketDates.start) - spanSeconds
        return min(0, -span)...0
    }

    /// Visible chart domain. The window is a fixed `win.seconds` wide and is
    /// dragged through time via `panOffset` (0 = newest edge). Selecting a
    /// point only shows an inspection cursor; it no longer moves the window.
    private var windowDates: (start: Date, end: Date) {
        let clamped = min(max(panOffset, panBounds.lowerBound), panBounds.upperBound)
        let end     = anchorEnd.addingTimeInterval(clamped)
        return (end.addingTimeInterval(-spanSeconds), end)
    }

    private var windowLabel: String {
        if night != nil {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            let mins = Int(bucketSeconds / 60)
            let grain = mins < 1 ? "\(Int(bucketSeconds))s avg" : "\(mins) min avg"
            return "\(fmt.string(from: windowDates.start))–\(fmt.string(from: windowDates.end))  ·  \(grain)"
        }
        // Panned back from the newest edge → show the window's start time.
        if panOffset < -1 {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            return "\(fmt.string(from: windowDates.start))  ·  \(win.bucketLabel)"
        }
        if Calendar.current.isDateInToday(date) {
            return "last \(win.rawValue)  ·  \(win.bucketLabel)"
        }
        return "00:00 + \(win.rawValue)  ·  \(win.bucketLabel)"
    }

    private var points: [ChartPoint] {
        let (start, end) = bucketDates
        let bucket = bucketSeconds
        var sums:    [Int: Double] = [:]
        var counts:  [Int: Int]    = [:]
        var qualSum: [Int: Float]  = [:]
        var qualCnt: [Int: Int]    = [:]
        var estCnt:  [Int: Int]    = [:]
        var presentKeys = Set<Int>()   // buckets with ANY valid sample (sensor on)
        for pt in history where pt.timestamp >= start && pt.timestamp < end {
            let key = Int(pt.timestamp.timeIntervalSince1970 / bucket)
            presentKeys.insert(key)          // record sensor-on regardless of this metric
            guard let v = extract(pt) else { continue }
            sums[key]   = (sums[key]   ?? 0) + v
            counts[key] = (counts[key] ?? 0) + 1
            if isEstimated?(pt) == true { estCnt[key] = (estCnt[key] ?? 0) + 1 }
            if let q = pt.signalQuality {
                qualSum[key] = (qualSum[key] ?? 0) + q
                qualCnt[key] = (qualCnt[key] ?? 0) + 1
            }
        }
        // Segment breaks are driven by the SHARED sensor-on timeline, not this
        // metric's own nil pattern — so gaps line up across every chart. The
        // line breaks only where the sensor delivered no data at all for
        // ≥ gapBreakSeconds (strap off). A metric that's momentarily
        // uncomputable while the sensor is on stays connected (bridged), and
        // brief (< 5 min) sensor dropouts stay connected too.
        let valueKeys = sums.keys.sorted().filter { (counts[$0] ?? 0) > 0 }
        let segs = ChartSegmenter.segments(valueKeys:       valueKeys,
                                           presentKeys:     presentKeys,
                                           bucketSeconds:   bucket,
                                           gapBreakSeconds: gapBreakSeconds)
        var result: [ChartPoint] = []
        result.reserveCapacity(valueKeys.count)
        for (i, key) in valueKeys.enumerated() {
            let mid = Double(key) * bucket + bucket / 2
            var val = sums[key]! / Double(counts[key]!)
            if let transform = bucketTransform { val = transform(val) }
            let q: Float? = qualCnt[key].map { (qualSum[key] ?? 0) / Float($0) }
            // A bucket is estimated when STRICTLY more than half its samples
            // are — an even split resolves to measured.
            let est = (estCnt[key] ?? 0) * 2 > counts[key]!
            result.append(ChartPoint(id: key, date: Date(timeIntervalSince1970: mid),
                                     val: val, quality: q, segment: segs[i],
                                     estimated: est))
        }
        // Deliberately NOT re-segmented on `estimated`. Splitting the series
        // at every source change looked right in principle and was wrong on
        // screen: the two channels swap back and forth tick to tick, so each
        // swap produced a one-point series — a scatter of orphan dots with no
        // line between them. Continuity of the trace matters more than never
        // sharing a series, so the run stays whole and estimated samples are
        // distinguished by their symbol alone.
        return result
    }

    /// Minimum gap between two dots before the connecting line breaks. Dots
    /// closer than this stay joined even if a bucket or two is missing.
    private var gapBreakSeconds: TimeInterval { 300 }   // 5 minutes

    /// The x-domain actually drawn. For the 24h view, clamp to the data envelope
    /// (first→last sample, small padding) so off-body stretches with no data
    /// aren't shown as dead space; the shorter live windows keep their sliding
    /// window unchanged.
    private var visibleDates: (start: Date, end: Date) {
        // A pinned span is drawn exactly as given. Clamping it to each metric's
        // own data envelope is what would break the alignment the sleep detail
        // is built on: heart rate and breath rate start and stop at different
        // ticks, so each chart would silently get a slightly different
        // x-domain and the crosshair would point at a different moment in each.
        if night != nil { return windowDates }
        guard win == .h24 else { return windowDates }
        let pts = points
        guard let first = pts.first?.date, let last = pts.last?.date, last > first else {
            return windowDates
        }
        let pad = last.timeIntervalSince(first) * 0.02
        return (first.addingTimeInterval(-pad), last.addingTimeInterval(pad))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chartBody
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(Theme.border, lineWidth: 0.5))
        .sheet(isPresented: $showInfo) {
            if let i = info {
                MetricInfoSheet(title: title, color: color, info: i)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // One flowing line: marketing name, then the spelled-out
                    // measure with its abbreviation in brackets — wraps as a
                    // unit instead of truncating.
                    (Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                     + Text(technicalName.isEmpty ? "" : "  \(technicalName)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim))
                        .lineLimit(2)
                    if info != nil {
                        Button { showInfo = true } label: {
                            Text("?")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                                .frame(width: 15, height: 15)
                                .background(Theme.border)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.7))
                }
            }
            Spacer()
        }
    }

    // MARK: Chart

    /// 3-point centred rolling average — keeps date/id of the centre point.
    private func smoothed(_ pts: [ChartPoint]) -> [ChartPoint] {
        guard pts.count >= 3 else { return pts }
        return pts.indices.map { idx in
            let seg = pts[idx].segment
            // Only blend neighbours within the same contiguous segment so
            // smoothing never bridges a data gap.
            let lo  = (idx - 1 >= 0            && pts[idx - 1].segment == seg) ? idx - 1 : idx
            let hi  = (idx + 1 <= pts.count - 1 && pts[idx + 1].segment == seg) ? idx + 1 : idx
            let avg = pts[lo...hi].reduce(0.0) { $0 + $1.val } / Double(hi - lo + 1)
            return ChartPoint(id: pts[idx].id, date: pts[idx].date, val: avg,
                              quality: pts[idx].quality, segment: seg)
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        let raw = points
        let pts = smooth ? smoothed(raw) : raw
        // Auto-fit the y-axis to whatever is actually visible in the current
        // x-window (plus any reference lines) with a little padding, so the
        // whole curve is always in frame rather than clipped by a fixed domain.
        let domain: ClosedRange<Double> = {
            let (wStart, wEnd) = visibleDates
            let vals = pts.filter { $0.date >= wStart && $0.date <= wEnd }.map(\.val)
                     + refs.map(\.value)
            guard let lo = vals.min(), let hi = vals.max() else { return yDomain }
            let span = hi - lo
            let pad  = span > 0 ? span * 0.12 : max(abs(lo) * 0.1, 1)
            return (lo - pad)...(hi + pad)
        }()
        if pts.isEmpty {
            noDataPlaceholder
        } else {
            chart(pts, domain: domain)
        }
    }

    private var noDataPlaceholder: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title3)
                    .foregroundStyle(Theme.dim.opacity(0.4))
                Text("No data for this window")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
        }
        .frame(height: 110)
    }

    /// Line/point colour for a bucket: faded when the window is low-confidence
    /// (artifact rate > 30%), so unreliable stretches read as uncertain without
    /// altering the plotted value. Full colour when flagging is off or quality
    /// is unknown.
    private func markColor(_ pt: ChartPoint) -> Color {
        guard flagUnreliable, let q = pt.quality, q < 0.70 else { return color }
        return color.opacity(0.22)
    }

    private func chart(_ pts: [ChartPoint], domain: ClosedRange<Double>) -> some View {
        let (start, end) = visibleDates
        let bands        = anomalyBands
        let poorBands    = poorQualityBands

        return HStack(alignment: .center, spacing: 4) {
            Text(yLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .frame(width: 14)

            Chart {
                // Poor quality: amber tint (artifact rate > 20%, signal present but noisy)
                ForEach(poorBands) { band in
                    RectangleMark(
                        xStart: .value("poor start", band.start),
                        xEnd:   .value("poor end",   band.end)
                    )
                    .foregroundStyle(Color.orange.opacity(0.12))
                }
                // No signal: gray (sensor removed or severe contact failure)
                ForEach(bands) { band in
                    RectangleMark(
                        xStart: .value("anomaly start", band.start),
                        xEnd:   .value("anomaly end",   band.end)
                    )
                    .foregroundStyle(Color.gray.opacity(0.22))
                }

                ForEach(pts) { pt in
                    AreaMark(
                        x: .value("time", pt.date),
                        yStart: .value("base", domain.lowerBound),
                        yEnd: .value(yLabel, pt.val),
                        series: .value("seg", pt.segment)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(pt.estimated ? 0.08 : 0.22),
                                     color.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                }

                ForEach(refs.indices, id: \.self) { i in
                    let r = refs[i]
                    RuleMark(y: .value(r.label, r.value))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .foregroundStyle(r.color.opacity(0.6))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text(r.label)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(r.color.opacity(0.85))
                                .fixedSize()
                        }
                }

                ForEach(pts) { pt in
                    LineMark(
                        x: .value("time", pt.date),
                        y: .value(yLabel, pt.val),
                        series: .value("seg", pt.segment)
                    )
                    .foregroundStyle(markColor(pt))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                ForEach(pts) { pt in
                    PointMark(
                        x: .value("time", pt.date),
                        y: .value(yLabel, pt.val)
                    )
                    .foregroundStyle(markColor(pt).opacity(pt.estimated ? 0.45 : 1))
                    .symbolSize(pt.estimated ? 12 : 18)
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: domain)
            // Native selection: scroll-safe (a plain swipe scrolls the list; a
            // press-drag scrubs), and it drives the crosshair via `selectedX`.
            .chartXSelection(value: $selectedX)
            .onChange(of: selectedX) { _, sel in edgePanIfNeeded(sel) }
            .chartOverlay { proxy in chartOverlay(pts: pts, proxy: proxy) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
            .chartPlotStyle { plot in
                plot.background(Color.black.opacity(0.2))
            }
            .frame(height: 130)
        }
    }

    // MARK: Selection overlay

    /// Purely visual crosshair for the current selection. It never participates
    /// in hit-testing (`allowsHitTesting(false)`), so it can't block the vertical
    /// ScrollView or the chart's own native selection gesture. The selection
    /// itself is driven by `.chartXSelection` (see `chart(_:domain:)`), which is
    /// scroll-safe: a plain swipe scrolls the list, a press-drag scrubs the line.
    private func chartOverlay(pts: [ChartPoint], proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let pf = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                if let selX = selectedX,
                   let nearest = pts.min(by: {
                       abs($0.date.timeIntervalSince(selX)) < abs($1.date.timeIntervalSince(selX))
                   }) {
                    let xPt = (proxy.position(forX: nearest.date) ?? 0) + pf.origin.x
                    let yPt = (proxy.position(forY: nearest.val)  ?? 0) + pf.origin.y
                    Rectangle()
                        .fill(color.opacity(0.35))
                        .frame(width: 1, height: pf.height)
                        .offset(x: xPt - 0.5, y: pf.origin.y)
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .position(x: xPt, y: yPt)
                    selectionBubble(nearest)
                        .fixedSize()
                        .position(
                            x: min(max(xPt, 44), geo.size.width - 44),
                            y: pf.origin.y + 18
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// When the selection is dragged to the far edge of the visible window,
    /// nudge the shared window through time so the chart scrolls left/right —
    /// this is the "move the chart with the line" behaviour, and it only happens
    /// while actively scrubbing (selection non-nil), never during a plain scroll.
    private func edgePanIfNeeded(_ selection: Date?) {
        guard let sel = selection else { return }
        let (wStart, wEnd) = windowDates
        let span   = wEnd.timeIntervalSince(wStart)
        guard span > 0 else { return }
        let margin = span * 0.06
        let step   = span * 0.04
        if sel > wEnd.addingTimeInterval(-margin) {
            let next = min(panOffset + step, panBounds.upperBound)
            if next != panOffset { panOffset = next }
        } else if sel < wStart.addingTimeInterval(margin) {
            let next = max(panOffset - step, panBounds.lowerBound)
            if next != panOffset { panOffset = next }
        }
    }

    private func selectionBubble(_ pt: ChartPoint) -> some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return HStack(spacing: 5) {
            Text(fmt.string(from: pt.date)).foregroundStyle(Theme.dim)
            Text(String(format: "%.1f", pt.val)).foregroundStyle(Theme.text)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Theme.card.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: - MetricsChartsView

/// `Equatable` so callers can wrap it in `.equatable()` and skip re-rendering
/// all 9 charts when the underlying history hasn't changed. The comparison is
/// cheap by design — count + newest timestamp + date — never a deep compare of
/// the (up to 43k-element) arrays. Append-only day history means count and the
/// last timestamp fully capture "did the data change".
struct MetricsChartsView: View, Equatable {
    let history:    [MetricsHistoryPoint]   // quality-filtered
    let rawHistory: [MetricsHistoryPoint]   // unfiltered — for anomaly highlighting
    let date:       Date
    let window:     TimeWindow              // shared across all charts, set at the Today header

    static func == (lhs: MetricsChartsView, rhs: MetricsChartsView) -> Bool {
        lhs.date == rhs.date
            && lhs.window == rhs.window
            && lhs.history.count == rhs.history.count
            && lhs.rawHistory.count == rhs.rawHistory.count
            && lhs.history.last?.timestamp == rhs.history.last?.timestamp
    }

    init(history: [MetricsHistoryPoint],
         rawHistory: [MetricsHistoryPoint] = [],
         date: Date,
         window: TimeWindow) {
        self.history    = history
        self.rawHistory = rawHistory
        self.date       = date
        self.window     = window
    }

    @State private var sharedSelectedX: Date? = nil
    @State private var sharedPanOffset: TimeInterval = 0
    @State private var showSignalQuality = false

    var body: some View {
        // `LiveMetric`'s declaration order — the app's canonical display
        // order, shared with the Track charts and the Live metric tiles.
        // This is the charts' original stack, restored by request.
        VStack(spacing: 10) {
            dcCard            // Vagal Tone
            rcmseCard         // Adaptive Capacity
            pipCard           // Inner Noise
            dfa1Card          // Harmony
            lfhfCard          // Stress Balance
            breathRateCard
            rsaCard           // Conscious Breathing
            rmssdCard         // Calm Power
            hrCard            // Pulse
            sdnnCard          // Overall Variability
            acCard            // Throttle
            hraCard           // Brake Bias
            rhythmStabilityCard

            signalQualitySection
        }
        .onChange(of: date)   { _, _ in resetPan() }
        .onChange(of: window) { _, _ in resetPan() }
    }

    private func resetPan() {
        sharedPanOffset = 0
        sharedSelectedX = nil
    }

    // MARK: Signal-quality section (collapsible)

    /// Signal-integrity diagnostics — share the same timeline as the metric
    /// charts so artifacts correlate with any anomaly. Grouped in a dropdown so
    /// they stay out of the way until you want to inspect signal quality.
    private var signalQualitySection: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSignalQuality.toggle() }
            } label: {
                HStack {
                    Text("SIGNAL QUALITY")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                    Text("· artifacts · corrected · ECG")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim.opacity(0.6))
                    Spacer()
                    Image(systemName: showSignalQuality ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                }
                .padding(.vertical, 4)
                // Make the whole row tappable, not just the text/chevron —
                // the Spacer gap is otherwise not hit-testable.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSignalQuality {
                signalArtifactsCard
                rrCorrectedCard
                ecgSignalCard
            }
        }
    }

    // MARK: Signal quality / artifacts

    /// Total RR artifact rate = % of beats invalid (dropped) or corrected
    /// (interpolated), from the persisted signalQuality (= 1 − artifactRate).
    private var signalArtifactsCard: some View {
        MetricChartCard(
            title:    "Signal Artifacts",
            technicalName: "dropped + repaired beats (%)",
            subtitle: "% of beats invalid or corrected",
            yLabel:   "%",
            color:    Theme.warn,
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value:  5, label:  "5%  acceptable", color: Theme.coh),
                RefLine(value: 20, label: "20%  poor",       color: Theme.warn),
            ],
            yDomain: 0...25,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            flagUnreliable: false,
            info: MetricInfo(
                "How much of the heartbeat signal was messy and had to be cleaned up. Think of it as a static meter for your recording — lower means a cleaner, more trustworthy reading.",
                calculation: "Every RR interval is screened for plausibility — impossibly short or long beats, or jumps too far from their neighbours. This is the share of beats in the window that failed: dropped plus repaired.",
                physical:    "Your chest strap catches each heartbeat. If it slips, dries out, or you move a lot, it can miss a beat or catch a false one — and those bad beats show up here.",
                physiology:  "This one isn't about your body — it's about signal quality. When it's high, the other numbers on this screen can't be trusted, because they're built on a shaky signal.",
                training:    "If it creeps up, it's almost always the strap. Dampen the electrode pads, snug the strap just under your chest muscles, and stay still. That drives it back toward 0%.",
                sensitivity: "Reacts instantly to movement or a loose strap — so keep an eye on it live while you're getting set up.",
                levels:      "Great: under 2%\nFine: 2–5%\nShaky: 5–20%\nUnreliable: over 20% (fix the strap)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { pt in
            guard let inv = pt.rrInvalidRate else { return nil }
            return Double(inv + (pt.rrCorrectedRate ?? 0)) * 100
        }
    }

    /// Fraction of beats that were interpolated (missed/extra), as opposed to
    /// dropped. Invalid % = Signal Artifacts − RR Corrected.
    private var rrCorrectedCard: some View {
        MetricChartCard(
            title:    "RR Corrected",
            technicalName: "interpolated beats (%)",
            subtitle: "% of beats replaced (missed / extra beat)",
            yLabel:   "%",
            color:    Theme.rsa,
            windows:  TimeWindow.allCases,
            refs: [],
            yDomain: 0...10,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            flagUnreliable: false,
            info: MetricInfo(
                "The share of heartbeats that were repaired rather than dropped — a missed or double-counted beat rebuilt from its neighbours.",
                calculation: "The repairable slice of Signal Artifacts: a missed or doubled beat is rebuilt by interpolating its neighbours instead of being thrown away. Signal Artifacts minus this line is what was dropped outright.",
                physical:    "The strap occasionally misses a beat or counts one twice — usually from a moment of poor contact. Those beats are reconstructed so one glitch doesn't poison the metrics built on the series.",
                physiology:  "About the recording, not your body. A small repaired share is routine; a large one means the metrics are leaning on reconstructed beats.",
                training:    "Nothing to train — if it climbs, treat it like Signal Artifacts: dampen the pads and snug the strap.",
                sensitivity: "Tracks strap contact moment to moment, like the other signal-quality charts.",
                levels:      "Routine: under 2%\nWatch: 2–5%\nShaky: over 5% (fix the strap)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rrCorrectedRate.map { Double($0) * 100 } }
    }

    /// ECG waveform fault from the raw 130 Hz trace: 0% clean, 50% clipping/noise
    /// (movement), 100% lead-off (flatline → bad electrode contact/positioning).
    private var ecgSignalCard: some View {
        MetricChartCard(
            title:    "ECG Signal",
            technicalName: "waveform fault (%)",
            subtitle: "contact & motion  ·  higher = worse",
            yLabel:   "%",
            color:    Theme.breathe,
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value:  50, label: "clipping / noise", color: Theme.rsa),
                RefLine(value: 100, label: "lead-off",         color: Theme.warn),
            ],
            yDomain: 0...100,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            flagUnreliable: false,
            info: MetricInfo(
                "A second signal-quality check that looks at the raw heartbeat waveform itself. 0% is clean; 100% means the strap has lost contact with your skin.",
                calculation: "Electrode contact and movement are graded each tick from the raw ECG waveform's noise floor and the accelerometer: good, fair or poor. It grades the recording, not your body.",
                physical:    "A flat line means an electrode isn't touching your skin. A spiky, maxed-out line means you were moving. Either way, the strap needs attention.",
                physiology:  "This is about the sensor, not you. A strap that's lost contact can look 'quiet' while actually being unusable — that's what this catches.",
                training:    "If it's high, fix the hardware: dampen the electrode pads, tighten and reposition the strap just under your chest muscles, and move less. It falls to 0% once contact is solid.",
                sensitivity: "Reacts fast to contact and movement. Nothing to do with your stress or fitness — purely signal quality.",
                levels:      "Clean: 0%\nMoving / noisy: around 50%\nStrap not connected: 100% (reseat it)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.ecgQualityTier.map { Double(2 - $0) / 2 * 100 } }
    }

    // MARK: Heart Rate

    private var hrCard: some View {
        MetricChartCard(
            title:    metricDef(.hr).label,
            technicalName: metricDef(.hr).techFull,
            subtitle: "Your heart rate",
            yLabel:   "bpm",
            color:    Theme.warn,
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 60,  label: "60 bpm  resting",  color: Theme.coh),
                RefLine(value: 80,  label: "80 bpm  moderate", color: Theme.dim),
                RefLine(value: 100, label: "100 bpm  elevated", color: Theme.warn),
            ],
            yDomain: 40...160,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            info: MetricInfo(
                "Your heart rate — how many times your heart beats per minute, averaged over the time window you're viewing.",
                calculation: "60,000 divided by the average RR interval (in ms) across the current window, recomputed every ~2 seconds.",
                physical:    "Each beat pushes blood around your body. At rest, a lower number usually means your heart is working efficiently.",
                physiology:  "Your heart speeds up under stress, caffeine, or effort, and slows when you're calm and rested. Over time, a lower resting pulse is a good sign of fitness and recovery.",
                training:    "Check it first thing after waking as a recovery gauge. If it's 5+ beats above your usual, your body may still be recovering, run-down, or fighting something off. Regular cardio lowers it over weeks.",
                sensitivity: "Changes within seconds — posture, stress, caffeine, a warm room, or a big breath all move it. For a clean baseline, measure at rest.",
                levels:      "Very fit: under 50 bpm\nExcellent: 50–60 bpm\nGood: 60–70 bpm\nAverage: 70–80 bpm\nHigh for rest: over 80 bpm (measured fully at rest)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.meanBPM.map(Double.init) }
    }

    // MARK: RR Interval History

    private var rrHistoryCard: some View {
        MetricChartCard(
            title:    "RR Interval",
            technicalName: "mean beat-to-beat interval (RR)",
            subtitle: "mean beat-to-beat  ·  60000 / BPM",
            yLabel:   "ms",
            color:    Theme.hrv,
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value:  600, label: "100 bpm", color: Theme.warn),
                RefLine(value:  750, label:  "80 bpm", color: Theme.dim),
                RefLine(value: 1000, label:  "60 bpm", color: Theme.coh),
            ],
            yDomain: 350...1500,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "The exact gap between two heartbeats, in milliseconds. It's just your pulse viewed up close — one beat at a time instead of an average.",
                calculation: "The mean time between consecutive heartbeats in the window, in milliseconds — the same number Pulse shows, seen from the other side (60,000 ÷ BPM).",
                physical:    "Your heart never beats like a metronome; the tiny gaps between beats constantly shift. Those shifts are the raw material behind every other number here.",
                physiology:  "Longer, freely-changing gaps at rest are a sign of a calm, adaptable nervous system. Short, rigid, unchanging gaps point to stress or strain.",
                training:    "A great live signal while breathing: watch the gap stretch on each exhale and shrink on each inhale. Big, smooth waves mean you've found your rhythm.",
                sensitivity: "Changes with every breath and every shift in posture or stress. Very live.",
                levels:      "60 bpm: about 1000 ms\n70 bpm: about 860 ms\n80 bpm: about 750 ms\nVery fit (50 bpm): about 1200 ms"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) {
            guard let bpm = $0.meanBPM, bpm > 0 else { return nil }
            return Double(60_000.0 / bpm)
        }
    }

    // MARK: I:E Ratio

    private var ieRatioCard: some View {
        MetricChartCard(
            title:   "Breathing I:E Ratio",
            technicalName: "exhale ÷ inhale (I:E)",
            subtitle: "exhale / inhale",
            yLabel:  "I:E ratio",
            color:   Theme.accent,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 1.0, label: "balanced  1.0",       color: Theme.warn),
                RefLine(value: 1.5, label: "mild vagal  ≥ 1.5",   color: Theme.coh),
                RefLine(value: 2.0, label: "strong vagal  ≥ 2.0", color: Theme.coh),
            ],
            yDomain: 0...2.8,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "How long your exhale is compared with your inhale. A longer out-breath is the simplest lever you have for calming your body down.",
                calculation: "The chest accelerometer traces each breath; every cycle is split into inhale and exhale, and this is mean exhale time divided by mean inhale time.",
                physical:    "Breathing in gently speeds the heart; breathing out slows it. So the longer your exhale, the more you engage your body's natural brake.",
                physiology:  "When your exhale is longer than your inhale, your nervous system shifts toward 'rest and recover' — heart rate drops and stress eases.",
                training:    "Aim for an exhale about 1.5–2× your inhale. Try 4 seconds in and 6 out (that's 1.5), or 4 in and 8 out (that's 2.0). Ease into it — don't strain for a long exhale.",
                sensitivity: "Fully in your control — even a half-second longer exhale shows up here right away.",
                levels:      "Even:            1.0 (in = out)\nCalming:         1.5 or more\nDeeply calming:  2.0 or more\nSweet spot:      2.0–2.5"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.ieRatio.map(Double.init) }
    }

    // MARK: RMSSD

    private var rmssdCard: some View {
        MetricChartCard(
            title:   metricDef(.rmssd).label,
            technicalName: metricDef(.rmssd).techFull,
            subtitle: "Total strength of your recovery drive",
            yLabel:  "ms",
            color:   Theme.breathe,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 20, label: "low",      color: Theme.warn),
                RefLine(value: 40, label: "moderate", color: Theme.rsa),
                RefLine(value: 65, label: "healthy",  color: Theme.coh),
            ],
            yDomain: 0...120,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "The strength of your body's calm-and-recover system, in raw milliseconds of beat-to-beat variability. Higher means a stronger ability to relax and bounce back.",
                calculation: "Root Mean Square of Successive Differences (RMSSD): each beat-to-beat change is squared, the squares averaged over the window, and the root taken. Only vagal activity produces large beat-to-beat differences.",
                physical:    "It's built from how much your heartbeat naturally varies from beat to beat — a hallmark of a relaxed, well-regulated body.",
                physiology:  "A higher number means your 'brakes' are strong: you handle stress better, recover faster, and tend to sleep and feel better. A low number is a nudge to rest and downshift.",
                training:    "Check it each morning after a few minutes of rest as a recovery score. A sharp drop means you're not fully recovered. It climbs over months with regular cardio and slow-breathing practice.",
                sensitivity: "Live and personal — big swings within a day are normal; compare against your own usual range, not other people's.",
                levels:      "Low:      under 20 ms\nModerate: 20–40 ms\nHealthy:  40–65 ms\nHigh:     65+ ms\nHigher is better — against your own baseline."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rmssd.map(Double.init) }
    }

    // MARK: SDNN

    /// Overall Variability. Track charts SDNN as a *daily* average, where it
    /// approximates the classic 24-hour clinical measure; here it is the raw
    /// per-window spread, which is a different — smaller — number, so the
    /// reference lines below are short-window ones and the info sheet says so.
    /// Both screens take the name from `sdnnMetricDef`.
    private var sdnnCard: some View {
        MetricChartCard(
            title:   sdnnMetricDef.label,
            technicalName: sdnnMetricDef.techFull,
            subtitle: "The full spread of your beat-to-beat intervals",
            yLabel:  "ms",
            color:   Theme.ulf,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value:  20, label: "20  narrow",  color: Theme.warn),
                RefLine(value:  50, label: "50  typical", color: Theme.rsa),
                RefLine(value: 100, label: "100  broad",  color: Theme.coh),
            ],
            yDomain: 0...150,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            info: MetricInfo(
                "The total spread of your beat-to-beat intervals — every rhythm your heart is running at once, fast and slow, folded into one number. Calm Power (RMSSD) hears only the fast, breath-linked rhythms; this hears all of them.",
                calculation: "Standard deviation of the NN (artifact-free RR) intervals across the current window. Because it is a standard deviation, it grows with the length of the window: slow rhythms only show up once the window is long enough to contain them.",
                physical:    "How much the gap between one heartbeat and the next drifts over the whole stretch you're looking at — not just from beat to beat, but across minutes.",
                physiology:  "A wide spread means your nervous system has room to move: it speeds up, slows down, and responds to what the day asks of it. A narrow one means something is holding the heart to a fixed rhythm — stress, illness, alcohol, or hard training you haven't recovered from.",
                training:    "Read it as range rather than recovery. Calm Power answers “am I recovered right now”; this answers “how much range does my system have”. It is most meaningful over a long window, so prefer 24h — and Track’s daily version, averaged across a whole day of wear, is the one that lines up with the published research.",
                sensitivity: "Window-dependent above all — the same body reads far higher over 24h than over 30 minutes, so only compare like with like. Within a window it moves with posture, breathing, and any burst of effort.",
                levels:      "Over a 30m or 2h window\nNarrow:  under 20 ms\nTypical: 20–80 ms\nBroad:   80+ ms\n\nThe familiar clinical cut-offs (50 ms, 100 ms) are 24-hour numbers and do not apply to a short window.",
                notes:       "A single big artifact inflates it more than any other metric here, since one wrong interval enters the sum squared. Trust it most where the Signal Artifacts chart below is low."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.sdnn.map(Double.init) }
    }

    // MARK: AC

    /// Throttle — Vagal Tone's mirror, and free: the same PRSA pass
    /// that yields DC yields AC, and the engine simply used to drop it.
    ///
    /// Drawn as a magnitude via `activationCapacity`. AC is negative by
    /// definition (Bauer 2006 reports ~-6 ms), but a chart whose line falls as
    /// the thing it measures gets stronger reads backwards against every other
    /// card in this stack, so the sign is flipped for display only — the
    /// stored `ac` keeps it. The reference lines mirror the DC card's for the
    /// same reason the two metrics share a scale: they come off one curve.
    private var acCard: some View {
        MetricChartCard(
            title:    "Throttle",
            technicalName: "Acceleration Capacity (AC)",
            subtitle: "How sharply your heart can speed up",
            yLabel:   "ms",
            color:    Color(red: 0.95, green: 0.45, blue: 0.75),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 4.5,  label: "Reduced",    color: Theme.warn),
                RefLine(value: 6.1,  label: "Developing", color: Color(hex: "#FCD34D")),
                RefLine(value: 10.0, label: "Strong",     color: Theme.coh),
            ],
            yDomain: 0...20,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: true,
            info: MetricInfo(
                "How readily your heart speeds up \u{2014} the accelerating half of the same machinery Vagal Tone measures. Vagal Tone is the brake; this is the throttle.",
                calculation: "Phase-Rectified Signal Averaging (Bauer et al., 2006) \u{2014} the same pass that produces Vagal Tone, anchored on the opposite beats: every beat where the heart sped up becomes an anchor, the beats around all anchors are averaged into one curve, and a Haar wavelet reads the characteristic acceleration from it. The published value is negative (about \u{2212}6 ms); this chart plots its size, so a bigger number means a stronger acceleration.",
                physical:    "Every time your heart nudges itself faster between beats \u{2014} reacting to a breath in, a movement, a thought \u{2014} that is the throttle. This tracks how big and how consistent those pushes are.",
                physiology:  "Acceleration is the vagal brake easing off, plus sympathetic drive on top. A system with range has both a strong brake and a strong throttle. A throttle that is strong while the brake is weak is the signature of a body stuck in go-mode; both weak means range has gone altogether.",
                training:    "Read it beside Vagal Tone rather than on its own \u{2014} the pair is the point. Both climbing over weeks means widening range; the two drifting apart says more than either number does alone.",
                sensitivity: "Moves slowly, like Vagal Tone \u{2014} read it as a trend over days and weeks. It needs a couple of minutes of clean signal, and at least 20 accelerating beats inside the window, before it reports anything at all.",
                levels:      "Building: under 4.5\nTypical:  around 6\nStrong:   10+\nShown as size, so higher = a stronger throttle.\n(Short readings aren\u{2019}t directly comparable to overnight ones.)",
                notes:       "Blank before 2026-08-31: AC was computed and discarded until then, so no earlier history holds a value. It shares Vagal Tone\u{2019}s gate of ~192 clean intervals, so the two appear and disappear together."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.activationCapacity }
    }

    // MARK: HRA

    /// Brake Bias — Heart Rate Asymmetry (Guzik's Index).
    ///
    /// The third member of the brake/throttle set: Vagal Tone is how hard the
    /// brake pulls, Throttle is how hard the accelerator pushes, and this is
    /// which of the two is doing more of the work. Unlike either, it survives
    /// a change in overall variability — a system can halve its RMSSD and keep
    /// the same bias, which is exactly the independence this chart is for.
    ///
    /// 50 is the axis, not the floor, so the domain is centred on it and the
    /// reference lines mark the even point rather than a good/bad boundary.
    private var hraCard: some View {
        MetricChartCard(
            title:    "Brake Bias",
            technicalName: "Heart Rate Asymmetry (Guzik's Index)",
            subtitle: "Which side of the rhythm does the work",
            yLabel:   "%",
            color:    Color(red: 0.45, green: 0.85, blue: 0.75),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 50, label: "50  even", color: Theme.dim),
            ],
            yDomain: 35...65,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: true,
            info: MetricInfo(
                "Your heart does not slow and speed up in equal steps. This is the share of your beat-to-beat variation that comes from slowing down rather than speeding up \u{2014} the balance between the brake and the throttle, rather than the strength of either.",
                calculation: "Guzik\u{2019}s Index: each beat-to-beat change is squared, and the ones where the heart slowed are taken as a percentage of all of them. Squaring is what makes it a share of variance rather than a count \u{2014} one large deceleration counts for more than several small ones.",
                physical:    "Watch your pulse over a minute and it does not wobble evenly: the slowdowns and the speed-ups come in different sizes. This measures which of the two carries more of that wobble.",
                physiology:  "A healthy heart is lopsided on purpose \u{2014} decelerations tend to carry slightly more than half the variance. The asymmetry appears to come from the vagus acting faster than sympathetic drive can. Losing it, and drifting toward a flat 50, is the pattern seen with age and with illness.",
                training:    "Read it beside Vagal Tone and Throttle rather than alone. Those two say how much brake and throttle you have; this says which one is shaping your rhythm. It is a slow measure \u{2014} weeks, not sessions.",
                sensitivity: "Needs at least 100 clean beats before it reports at all, and moves slowly after that. Distance from 50 is the signal; small wanders around it are noise.",
                levels:      "Even:              50\nSlightly braked:   52\u{2013}56  (typical at rest)\nStrongly braked:   56+\nThrottle-led:      under 48\n\nRead the distance from 50, in either direction, rather than a target."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.hra.map(Double.init) }
    }

    // MARK: Rhythm Stability

    /// The fragmentation dimension's other half. Inner Noise (PIP) counts how
    /// often the rhythm changes direction; this counts how much of it is made
    /// of very short runs \u{2014} the difference between a rhythm that wanders and
    /// one that is chopped into pieces.
    ///
    /// Deliberately without reference lines. The literature\u{2019}s cut-offs are
    /// for 24-hour Holter recordings and the source comment\u{2019}s "~62 %" could
    /// not be verified, so drawing bands here would invent a threshold rather
    /// than report one. Personal trend only, like VLF Power \u{2014} bands can be
    /// added once there is enough stored history to know the real spread.
    private var rhythmStabilityCard: some View {
        MetricChartCard(
            title:    "Rhythm Stability",
            technicalName: "Percentage of Short Segments (PSS), inverted",
            subtitle: "How much of the rhythm holds together",
            yLabel:   "%",
            color:    Color(red: 0.6, green: 0.75, blue: 1.0),
            windows:  TimeWindow.allCases,
            refs: [],
            yDomain: 0...100,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: true,
            info: MetricInfo(
                "How much of your heart rhythm runs in sustained stretches rather than being chopped into very short pieces. Higher means the rhythm holds a line; lower means it keeps breaking up.",
                calculation: "The percentage of beats sitting in runs of two or fewer before the rhythm changes direction \u{2014} then flipped, so the number rises as the rhythm steadies. The published measure (PSS) counts the fragmentation itself and runs the other way.",
                physical:    "Between changes of direction, your heart rate travels in short runs. This asks how long those runs are: a steady rhythm moves in long sweeps, a fragmented one in constant tiny reversals.",
                physiology:  "Fragmentation is not the same thing as low variability, which is why it earns its own chart \u{2014} a rhythm can be wide and still be chopped up. It rises with age and with disease of the sinus node, and it is thought to reflect the pacemaker itself misbehaving rather than the nerves that steer it.",
                training:    "Not something to chase in a session. Watch it across weeks, and read it beside Inner Noise \u{2014} the two describe the same dimension from different angles, and they should broadly agree.",
                sensitivity: "Needs a couple of minutes of clean signal. Artifacts inflate fragmentation directly, so trust it least where the Signal Artifacts chart below is high.",
                levels:      "No fixed bands \u{2014} the published cut-offs are for 24-hour recordings and do not transfer to a short window. Compare against your own trend under similar conditions.",
                notes:       "Blank before this shipped: the value was computed and discarded until now, so no earlier history holds one."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rhythmStability }
    }

    // MARK: Breath Rate

    /// Breathing rate from the chest-strap accelerometer (Z-axis Welch PSD).
    /// `yDomain` mirrors `BreathingCompute.breathBand` (0.08–0.50 Hz), the only
    /// range the estimator can report; note it applies only as the empty-window
    /// fallback, since `chartBody` auto-fits the axis to the visible values plus
    /// the reference lines.
    private var breathRateCard: some View {
        MetricChartCard(
            title:   "Breath Rate",
            technicalName: "breaths per minute (br/min)",
            subtitle: "How fast you're breathing",
            yLabel:  "br/min",
            color:   Theme.breathe,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value:  6, label:  "6  resonance", color: Theme.coh),
                RefLine(value: 12, label: "12  rest",      color: Theme.rsa),
                RefLine(value: 20, label: "20  fast",      color: Theme.warn),
            ],
            yDomain: 4...30,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            // The PSD peak jitters between FFT bins even after parabolic
            // interpolation, so smooth it like RSA.
            smooth:  true,
            info: MetricInfo(
                "How many breaths you take per minute. It's the one signal on this screen you can change on purpose, right now, just by breathing differently.",
                calculation: "A Welch power spectrum of the chest accelerometer's Z axis. The dominant peak in the breathing band is your rate, refined between bins by parabolic interpolation; a peak must clearly rise above the band's average power — otherwise no value is shown rather than a guess.",
                physical:    "Your chest rises and falls with each breath, and the strap's motion sensor picks that up. Counting those rises gives your breathing rate.",
                physiology:  "Slower breathing gives your body's brake more time to act on each out-breath. Fast, shallow breathing does the opposite — it keeps you revved up, and it's often the first thing to change when you're stressed.",
                training:    "This is your steering wheel. Most people find their sweet spot near 6 breaths per minute — try settling there and watch Conscious Breathing rise underneath it.",
                sensitivity: "Immediate — it follows your very next breath. It's also the easiest metric here to change deliberately.",
                levels:      "Resonance: around 6 br/min\nRestful:   6–12 br/min\nTypical:   12–16 br/min\nFast:      20+ br/min",
                notes:       "Measured from body movement, so walking, driving, or fidgeting can be mistaken for breathing. Trust it most when you're still."
            ),
            isEstimated: { $0.breathSource == .heart },
            history: history, rawHistory: rawHistory, date: date
        ) { $0.breathBPM.map(Double.init) }
    }

    // MARK: RSA

    private var rsaCard: some View {
        MetricChartCard(
            title:   metricDef(.rsa).label,
            technicalName: metricDef(.rsa).techFull,
            subtitle: "How your breath moves your heart rate",
            yLabel:  "ms",
            color:   Theme.rsa,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 10, label: "low",    color: Theme.warn),
                RefLine(value: 30, label: "mod",    color: Theme.rsa),
                RefLine(value: 60, label: "good",   color: Theme.coh),
                RefLine(value: 90, label: "strong", color: Theme.coh),
            ],
            yDomain: 0...120,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth:  true,
            info: MetricInfo(
                "How much your heart rate rises and falls with each breath. It's the live signature of your breathing actually reaching your nervous system.",
                calculation: "The heart-rate swing at your detected breathing frequency: the RR series' power in a narrow band around the breath peak, expressed as a peak-to-trough amplitude in ms. With no clean breath peak, the standard HF band (0.15–0.40 Hz) stands in.",
                physical:    "Breathe in and your heart speeds up a little; breathe out and it slows. This measures the size of that wave — bigger waves mean your breath is having a bigger calming effect.",
                physiology:  "It's the most direct real-time sign that your calming system is engaged. Big, steady waves are linked to better emotional control and faster recovery.",
                training:    "This is your main feedback signal during slow breathing. Around 6 breaths per minute most people see it peak. Watch it grow as you settle into a rhythm — and it strengthens over weeks of practice.",
                sensitivity: "Very live — it drops quickly if your breathing gets fast, shallow, or irregular.",
                levels:      "Low:       under 10 ms\nModerate:  10–30 ms\nGood:      30–60 ms\nStrong:    60–90 ms\nExcellent: 90+ ms",
                notes:       "Brief dips to near zero are normal — for example right after a breath-hold or a sudden change in posture."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rsaMs.map(Double.init) }
    }


    // MARK: pNN50

    private var pnn50Card: some View {
        MetricChartCard(
            title:   "pNN50",
            technicalName: "beat pairs differing >50 ms (%)",
            subtitle: "% successive RR diff > 50 ms",
            yLabel:  "%",
            color:   Theme.accent,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 3,  label: "low",    color: Theme.warn),
                RefLine(value: 8,  label: "normal", color: Theme.rsa),
                RefLine(value: 20, label: "good",   color: Theme.coh),
            ],
            yDomain: 0...80,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "How often your heartbeat makes a noticeable jump from one beat to the next — a simple, robust sign of an active calming system.",
                calculation: "The share of consecutive beat pairs whose RR intervals differ by more than 50 ms.",
                physical:    "It counts the share of back-to-back beats where the timing changed by more than a blink (50 ms). More of these little jumps means a livelier, more relaxed rhythm.",
                physiology:  "Mostly reflects your calming (vagal) system. It rises during slow breathing, relaxation, and sleep, and falls under stress or exertion.",
                training:    "A nice, noise-resistant companion to your other calm metrics. It should rise during slow-breathing sessions and improve over weeks of practice.",
                sensitivity: "Responsive — moves quickly with your breathing and with sudden stress.",
                levels:      "Very low:  under 3%\nLow:       3–8%\nNormal:    8–20%\nGood:      20–35%\nExcellent: 35%+"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.pnn50.map(Double.init) }
    }

    // MARK: Deceleration Capacity

    private var dcCard: some View {
        MetricChartCard(
            title:    metricDef(.dc).label,
            technicalName: metricDef(.dc).techFull,
            subtitle: "Your relaxation and recovery capacity",
            yLabel:   "ms",
            color:    Color(red: 0.4, green: 0.7, blue: 1.0),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 4.5,  label: "Reduced",    color: Theme.warn),
                RefLine(value: 6.1,  label: "Developing", color: Color(hex: "#FCD34D")),
                RefLine(value: 10.0, label: "Strong",     color: Theme.coh),
            ],
            yDomain: 0...20,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: true,
            info: MetricInfo(
                "How strongly your body can hit the brakes and relax — your heart's ability to slow itself down, which is the engine behind calming, recovering, and winding down.",
                calculation: "Phase-Rectified Signal Averaging (Bauer et al., 2006): every beat where the heart slowed becomes an anchor, the beats around all anchors are averaged into one curve, and a Haar wavelet reads the characteristic deceleration from it, in ms.",
                physical:    "Every time your heart eases off slightly between beats, that's your rest-and-recover system tapping the brake. This tracks how big and consistent those braking moments are.",
                physiology:  "A strong brake means you bounce back faster after stress, fall asleep more easily, and stay calmer under pressure. A weak one is a sign you're stuck in 'go mode' too often.",
                training:    "Slow breathing, good sleep, and regular cardio build it over weeks. Try a few minutes of paced breathing daily and watch it climb.",
                sensitivity: "Changes slowly — read it as a trend over days and weeks. It needs a couple of minutes of clean signal to show a value.",
                levels:      "Building: under 4.5\nTypical:  around 6\nStrong:   10+\nHigher = more calm-and-recover capacity.\n(Short readings aren't directly comparable to overnight ones.)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.dc.map(Double.init) }
    }

    // MARK: RCMSE

    private var rcmseCard: some View {
        MetricChartCard(
            title:    metricDef(.rcmse).label,
            technicalName: metricDef(.rcmse).techFull,
            subtitle: "How flexibly your system adapts across timescales",
            yLabel:   "entropy",
            color:    Color(red: 0.8, green: 0.5, blue: 1.0),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 1.0, label: "Depleted",   color: Theme.warn),
                RefLine(value: 1.5, label: "Recharging", color: Theme.dim),
                RefLine(value: 2.0, label: "Thriving",   color: Theme.coh),
            ],
            yDomain: 0.5...3.0,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: false,
            info: MetricInfo(
                "How rich and flexible your heart rhythm is across many timescales at once. A more intricate, less repetitive pattern is a sign of a healthy, adaptable system.",
                calculation: "Refined Composite Multiscale Sample Entropy (Wu et al., 2014): the beat series is averaged into coarser and coarser timescales and the pattern-richness of each is combined. Needs at least 100 clean beats — hence the gaps.",
                physical:    "A healthy heartbeat isn't perfectly regular — it has layered, ever-shifting patterns. This measures how much of that healthy complexity is present.",
                physiology:  "Higher complexity goes with resilience and good health. When the body is stressed, exhausted, or aging poorly, the rhythm gets simpler and more repetitive — and this drops.",
                training:    "Builds slowly with steady aerobic training and breathing practice — think weeks to months. Best read as a trend, not a single reading.",
                sensitivity: "Fairly steady — needs a few minutes of continuous wear and is far more useful as a trend than a one-off number.",
                levels:      "Stressed / depleted: under 1.2\nTypical healthy:     about 1.4–2.2\nHighly trained:      2.0+\nHigher is better."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.rcmse.map(Double.init) }
    }

    // MARK: PIP (HR Fragmentation)

    private var pipCard: some View {
        MetricChartCard(
            title:    metricDef(.pip).label,
            technicalName: metricDef(.pip).techFull,
            subtitle: "Beat-to-beat fragmentation — rises with stress and fatigue",
            yLabel:   "%",
            color:    Color(red: 1.0, green: 0.7, blue: 0.3),
            windows:  TimeWindow.allCases,
            refs: [
                RefLine(value: 40.0, label: "low fragmentation", color: Theme.coh),
                RefLine(value: 55.0, label: "healthy median",    color: Theme.dim),
                RefLine(value: 70.0, label: "high fragmentation",color: Theme.warn),
            ],
            yDomain: 20...90,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: false,
            info: MetricInfo(
                "How choppy and jittery your heartbeat pattern is. Some choppiness is normal; a lot of it tends to show up with stress, fatigue, or poor recovery. Lower is calmer.",
                calculation: "Heart-rate fragmentation (Costa et al., 2017): the percentage of beats where the RR series flips direction. A flowing rhythm has few inflection points; an erratic one flips constantly. Needs at least 30 clean beats.",
                physical:    "It measures how often your heart keeps flip-flopping between speeding up and slowing down beat to beat. More constant flip-flopping means a more fragmented, less settled rhythm.",
                physiology:  "A moderate amount is completely normal. High choppiness points to a nervous system that isn't coordinating smoothly — often from stress, poor sleep, or being run-down.",
                training:    "You don't train this directly, but it eases as your overall health improves. Chronic stress and short sleep push it up; fitness and recovery bring it down over weeks.",
                sensitivity: "Moderately responsive to your state, and steadier than the complexity metrics on short recordings.",
                levels:      "Calm:     under 45%\nTypical:  around 55%\nElevated: over 70%\nLower is calmer."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.pip.map(Double.init) }
    }

    // MARK: DFA α1

    private var dfa1Card: some View {
        MetricChartCard(
            title:   metricDef(.dfa1).label,
            technicalName: metricDef(.dfa1).techFull,
            subtitle: "How ordered vs random your heart rhythm is",
            yLabel:  "α1",
            color:   Theme.ulf,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 0.75, label: "Drifting",    color: Theme.warn),
                RefLine(value: 1.0,  label: "In Harmony",  color: Theme.coh),
                RefLine(value: 1.5,  label: "Strained",    color: Theme.warn),
            ],
            yDomain: 0.5...1.8,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            smooth: true,
            dynamicY: false,
            info: MetricInfo(
                "How balanced your heart rhythm is between too-random and too-rigid. Right in the middle — around 1.0 — is the sweet spot of a healthy, adaptable heart.",
                calculation: "Detrended Fluctuation Analysis (Peng et al., 1995): the RR series is integrated, cut into boxes of 4–16 beats, each box detrended, and α1 is the slope of fluctuation size versus box size on log–log axes.",
                physical:    "Your heartbeat has a natural 'texture.' Too random (low) or too locked-in (high) both signal strain; a balanced middle is ideal.",
                physiology:  "The middle zone reflects a flexible, well-regulated system. Drifting low is linked to fatigue and poor recovery; running high can show over-strain.",
                training:    "Improves with regular cardio and breathing practice — track it over weeks. Heavy exertion or high stress can pull it out of the ideal band for a while.",
                sensitivity: "Slow and steady — it needs about 2 minutes of wear to appear and settles over 3–5 minutes.",
                levels:      "Drifting (too random): under 0.75\nIn balance:            0.75–1.5  (aim here)\nIdeal:                 around 1.0\nStrained (too rigid):  over 1.5",
                notes:       "Shows '—' until about 2 minutes of data have been collected. That's just how long the math needs — not a sensor problem."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.dfa1.map(Double.init) }
    }

    // MARK: Stress Balance (breathing-robust arousal)

    private var lfhfCard: some View {
        MetricChartCard(
            title:   metricDef(.stressBalance).label,
            technicalName: metricDef(.stressBalance).techFull,
            subtitle: "Balance of activation vs rest",
            yLabel:  "%",
            color:   Theme.rsa,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 45, label: "parasympathetic",  color: Theme.coh),
                RefLine(value: 50, label: "flow · balanced",  color: Theme.accent),
                RefLine(value: 65, label: "sympathetic",      color: Theme.warn),
            ],
            yDomain: 0...100,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "A simple 0–100 stress dial: higher means more revved-up and alert, lower means calmer. It's built so that slow, calming breathing actually reads as calmer.",
                calculation: "Vagal index = RMSSD ÷ (RMSSD + 40), or 0.5 · RMSSD ÷ baseline once your baseline is known. The dial is SNS% = 100 · (1 − vagal index). When RMSSD is unavailable and breathing is at a normal rate, HF ÷ (LF + HF) stands in for the vagal index.",
                physical:    "It's based on how relaxed your heartbeat is moment to moment — a calm, variable heartbeat reads low, a tense, flat one reads high.",
                physiology:  "Most stress scores get fooled by slow breathing and spike as if you were stressed. This one is designed to avoid that trap, so paced breathing correctly shows up as calm.",
                training:    "Watch it fall during slow breathing and recovery, and rise with stress or exercise. A good breathing session should trend it downward.",
                sensitivity: "Moderately responsive — and, unlike older stress ratios, it isn't thrown off by how slowly you breathe.",
                levels:      "Calm:      under 45%\nBalanced:  45–65%\nRevved-up: over 65%\nLower is calmer.",
                notes:       "An old-school 'stress ratio' isn't shown here because it misleads during breathwork — this dial is the app's stress signal."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { pt in
            AutonomicCompute.balance(rmssd: pt.rmssd, lf: pt.lfPower, hf: pt.hfPower,
                                     breathBPM: pt.breathBPM, meanBPM: pt.meanBPM,
                                     baselineRmssd: nil).map { Double($0.sns) * 100 }
        }
    }

    // MARK: VLF

    private var vlfCard: some View {
        MetricChartCard(
            title:   "VLF Power",
            technicalName: "very-low-frequency power (VLF)",
            subtitle: "very low frequency  ·  0.003–0.04 Hz",
            yLabel:  "ms²",
            color:   Theme.breathe,
            windows: TimeWindow.allCases,
            refs: [],
            yDomain: 0...50,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            info: MetricInfo(
                "A slow, background rhythm in your heartbeat that plays out over minutes. It reflects deep, long-running regulation rather than anything you feel moment to moment.",
                calculation: "Welch power spectral density of the evenly resampled RR series, integrated over 0.003–0.04 Hz.",
                physical:    "These are very slow waves — cycles lasting from about half a minute to five minutes — tied to things like your body's internal chemistry and temperature control, not your breathing.",
                physiology:  "Healthy long-term regulation shows up as solid activity here. Persistently low levels can reflect a run-down, poorly-regulated system. Think of it as a background health marker, not a moment-to-moment one.",
                training:    "Not something you change in the moment. It improves over months with consistent exercise, good sleep, and lower chronic stress. Needs 5+ minute recordings to mean anything.",
                sensitivity: "Slow-moving — needs steady, clean recordings of at least 5 minutes.",
                levels:      "These values depend on recording length, so compare only your own trends under similar conditions — not against fixed targets.",
                notes:       "Needs about 5 minutes of data to compute. It reads near zero in short sessions — that's normal, not an error."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.vlfPower.map(Double.init) }
    }

    // MARK: ULF

    private var ulfCard: some View {
        MetricChartCard(
            title:   "ULF Power",
            technicalName: "ultra-low-frequency power (ULF)",
            subtitle: "ultra low frequency  ·  < 0.003 Hz  ·  10 min+ sessions",
            yLabel:  "ms²",
            color:   Theme.dim,
            windows: TimeWindow.allCases,
            refs: [],
            yDomain: 0...50,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            dynamicY: true,
            info: MetricInfo(
                "The very slowest rhythm in your heartbeat, unfolding over many minutes to hours. It only appears in long recordings and reflects deep daily cycles like your body clock and hormones.",
                calculation: "The same Welch spectrum integrated below 0.003 Hz — cycles minutes long, which is why it needs 10+ minutes of data.",
                physical:    "These are ultra-slow waves — one cycle can take from five minutes to a whole day — linked to your sleep-wake cycle, body temperature, and hormone rhythms.",
                physiology:  "Over full-day recordings this is a powerful long-term health signal, capturing daily rhythms no short measurement can. It isn't meaningful for a quick session.",
                training:    "Only shows up in long or overnight recordings. If you wear the sensor for hours, its trend over weeks reflects improving sleep and daily-rhythm health.",
                sensitivity: "Very slow — needs at least ~10 minutes of continuous wear to appear, and hours for a stable read.",
                levels:      "Meaningful values come from long (24-hour) recordings; short-session numbers here aren't comparable to those.",
                notes:       "This chart fills in only after about 10 minutes of continuous recording — a limitation of the math, not the sensor."
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.ulfPower.map(Double.init) }
    }

    // MARK: Coherence Score

    private var coherenceCard: some View {
        MetricChartCard(
            title:   "Coherence Score",
            technicalName: "RR–breathing coherence (0–1)",
            subtitle: "RR–breathing coupling",
            yLabel:  "score",
            color:   Theme.coh,
            windows: TimeWindow.allCases,
            refs: [
                RefLine(value: 0.30, label: "low",       color: Theme.warn),
                RefLine(value: 0.60, label: "good",      color: Theme.coh),
                RefLine(value: 0.80, label: "excellent", color: Theme.coh),
            ],
            yDomain: 0...1,
            win: window, selectedX: $sharedSelectedX, panOffset: $sharedPanOffset,
            info: MetricInfo(
                "How well your heartbeat and your breathing are moving in sync, from 0 to 1. High sync is the 'in the zone' state of a good breathing session.",
                calculation: "Spectral coherence between the RR series and the accelerometer's breathing trace at the breathing frequency: 1.0 means heart rhythm and breath rise and fall in perfect lockstep.",
                physical:    "When your heart rate rises and falls in lockstep with each breath, they're in sync. A score near 1 means they're perfectly in step; near 0 means they're unrelated.",
                physiology:  "High sync is the sweet spot where slow breathing pays off most — the largest, smoothest heart-rate waves and the strongest relaxation response.",
                training:    "This is your main target during slow breathing. It jumps up when you find your natural pace (around 6 breaths/min for most people). Try to hold it above 0.6 for most of a session, and notice how fast you can get there — that improves with practice.",
                sensitivity: "Very live — it responds within a couple of breaths to changes in your pace, depth, or steadiness.",
                levels:      "Low:       under 0.30\nModerate:  0.30–0.60\nGood:      0.60–0.80\nExcellent: 0.80+\nPeak:      0.90+  (rare — perfect sync)"
            ),
            history: history, rawHistory: rawHistory, date: date
        ) { $0.coherence.map(Double.init) }
    }
}

// MARK: - Preview

#Preview("Metrics Charts") {
    ScrollView {
        MetricsChartsView(history: mockHistory(), date: Date(), window: .h24)
            .padding(.horizontal)
    }
    .background(Theme.bg)
}

private func mockHistory() -> [MetricsHistoryPoint] {
    let start = Calendar.current.startOfDay(for: Date())
    return (0..<1800).map { i in
        let t = start.addingTimeInterval(Double(i) * 2)
        let phase = Float(i) / 60
        return MetricsHistoryPoint(from: MetricsTick(
            timestamp:      t,
            meanBPM:        Float(65 + 8 * sin(phase)),
            sdnn:           Float(45 + 10 * sin(phase * 0.7)),
            rmssd:          Float(38 + 20 * sin(phase * 0.5)),
            pnn50:          Float(22 + 8 * sin(phase * 0.3)),
            vti:            Float(3.6 + 0.8 * sin(phase * 0.5)),
            ulfPower:       Float(30 + 15 * sin(phase * 0.1)),
            vlfPower:       Float(600 + 300 * sin(phase * 0.4)),
            lfPower:        Float(800 + 400 * sin(phase * 0.8)),
            hfPower:        Float(1200 + 600 * sin(phase * 0.5)),
            lfHF:           Float(0.7 + 0.3 * sin(phase)),
            rsaMs:          Float(45 + 25 * sin(phase * 0.6)),
            rsaIdx:         Float(1.4 + 0.4 * sin(phase * 0.6)),
            breathBPM:      Float(6.0 + 0.5 * sin(phase * 0.2)),
            breathHz:       Float(0.10 + 0.008 * sin(phase * 0.2)),
            regularity:     Float(0.8 + 0.1 * sin(phase * 0.4)),
            coherenceScore: Float(0.7 + 0.2 * sin(phase * 0.3)),
            cbi:            Float(0.75 + 0.1 * sin(phase * 0.3)),
            dfa1:           Float(1.0 + 0.15 * sin(phase * 0.15)),
            signalQuality:  Float(0.95 + 0.05 * sin(phase * 0.2)),
            ecgQuality:     nil,
            rcmse:          Float(1.4 + 0.2 * sin(phase * 0.12)),
            pip:            Float(54.0 + 6.0 * sin(phase * 0.09)),
            ials:           Float(0.51 + 0.04 * sin(phase * 0.11)),
            dc:             Float(7.0 + 1.5 * sin(phase * 0.08)),
            breathPhases: BreathPhases(
                breaths:    [],
                meanIE:     Float(1.4 + 0.4 * sin(phase * 0.4)),
                meanInhale: 4.0, meanExhale: 5.5, meanDepth: 0.5,
                nBreaths:   10, filtered: [], filteredT: []
            ),
            psdFreqs: nil, psdValues: nil,
            coherenceFreqs: nil, coherenceValues: nil
        ))
    }
}
