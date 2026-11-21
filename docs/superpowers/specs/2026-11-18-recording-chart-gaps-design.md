# Recording gaps in metric charts

The Live screenshot joins isolated recordings with hours-long lines and shaded areas. The current chart rule treats any intermediate metric bucket as evidence of continuous recording; it also loses gaps inside or between adjacent 12-minute buckets.

Split each metric into runs using its original, usable sample timestamps before averaging. Keep the existing five-minute tolerance: a gap of at least 300 seconds starts another run. Other metrics cannot fill a missing interval for this metric. A shared recording outage therefore breaks every affected chart, while a metric that remains unavailable also leaves its own honest gap. Brief interruptions remain joined.

Average by run and time bucket, so separate recordings in the same bucket never merge. Keep plotted dates inside the contributing samples' time range; an isolated reading stays at its actual timestamp. Preserve averages, quality and estimated-source handling, transform-after-average, full-day/DST domains, and smoothing within each run. Lines and shaded fills use the same series boundary. Reference thresholds remain unchanged.

Scope: the shared MetricChartCard used by all Live history metrics and sleep detail charts, all three zoom levels and pinned spans. This changes presentation of stored history, not capture, upload, Bluetooth or aggregate Track charts. Existing activity-specific charts use separate presentations outside the reported screen.

Implementation and release proceed under the user's correction and ongoing TestFlight authorization. Validate realistic continuous recordings, isolated intermediate readings, same/adjacent-bucket gaps, nil metrics despite other ongoing metrics, exact threshold, unordered input, day/night bounds and metadata. Run the signed full suite and one independent final review, then the sanctioned release pipeline.

Released as externally approved **TestFlight 159**. See [verification and release record](../plans/2026-11-18-recording-chart-gaps.md#released--testflight-159).
