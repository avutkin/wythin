-- Overnight captures, for profiling real Polar H10 nights.
--
-- Read-only. Set :uid to a single user before running — the sleep model is
-- per-person by design (individual sleep need varies by roughly ±0.7 h and
-- vulnerability to short sleep is a stable personal trait), so a pooled
-- extract answers nothing the model would actually be asked.
--
--   psql "$DATABASE_URL" -v uid="'<user-uuid>'" -qtAX -F',' -f tools/nights.sql > night.csv
--   python3 tools/profile_night.py night.csv

\set ON_ERROR_STOP on

-- ── 1. which users have overnight data at all, and how much ────────────
-- Run this first with the \echo below uncommented to pick a user.
--
-- \echo 'users with samples between 23:00 and 06:00 local:'
-- SELECT user_id,
--        count(*)                                  AS overnight_samples,
--        count(DISTINCT (ts AT TIME ZONE 'UTC')::date) AS nights_touched,
--        min(ts)::date                             AS first_night,
--        max(ts)::date                             AS last_night
-- FROM metric_samples
-- WHERE extract(hour FROM ts) >= 23 OR extract(hour FROM ts) < 6
-- GROUP BY user_id
-- HAVING count(*) > 200
-- ORDER BY overnight_samples DESC;

-- ── 2. the samples themselves, for one user ────────────────────────────
-- Every column the profiler reads. Ordered oldest-first, which is what the
-- detector's run-splitting expects.
SELECT
    ts,
    mean_bpm,
    rmssd,
    sdnn,
    lf_hf,
    coherence,
    breath_bpm,
    -- Carried since 2026-09-06. Null for every sample uploaded before that,
    -- so a night older than the change still has a blind wake channel and will
    -- over-report sleep — check that motion is actually present before reading
    -- stage output from an old extract.
    motion
FROM metric_samples
WHERE user_id = :uid::uuid
ORDER BY ts;
