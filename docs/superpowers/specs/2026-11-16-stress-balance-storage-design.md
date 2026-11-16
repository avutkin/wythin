# Stress Balance persistence

The user requests the same Stress Balance shown in Wythin to be saved and available in exports and the Wythin connector. This continues the data-reliability work; it does not change the metric formula or replace LF/HF.

Use an optional `stressBalance` snapshot on local samples/history and `stress_balance` on the wire and in both PostgreSQL sample tables. New samples use the existing AutonomicCompute balance with no training baseline, matching LiveMetric. Readers prefer the saved value, with the existing computation as a legacy fallback. Continuous and session uploads, cloud restore, JSON export, session CSV, dashboard series and all connector metric tools carry the distinct field. Connector session summaries also expose existing before/during/after stress values.

The server accepts finite 0–100 values and preserves saved values on retry. Older clients omit the field; a PostgreSQL function derives the existing absolute RMSSD dial (vagal index clamped to 0.05–0.95). With RMSSD unavailable, normal/unknown breathing and a valid nonnegative LF/HF ratio permit the same spectral fallback as the app. Slow breathing never uses that fallback. Missing/invalid evidence stays null. Backfill only missing server values, in bounded batches, leaving timestamps, receipt times and other measurements intact.

Considered server-only derivation (would lose the exact captured value if formulas change) and aliasing to LF/HF (wrong units and semantics). Chosen: explicit stored snapshot with backwards-compatible derivation. No UI redesign, medical interpretation changes, tester roster changes or unrelated metric renaming.

Verify upload/export/connector round trips, per-sample-before-average behavior, finite and missing inputs, repeated backfill, re-upload preservation, scoped reads and SwiftData persistence/cloud restore. Use the existing isolated checkout, full server and iOS suites, and independent review. Production and TestFlight publication follow the authorization and release workflow already established in this chat; use tools/ship.sh for the iOS release.
