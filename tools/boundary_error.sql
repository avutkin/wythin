-- How wrong the detector's night boundaries are, measured against the sleeper.
--
-- Read-only. Run against production:
--
--   psql "$DATABASE_URL" -qtAX -F',' -f tools/boundary_error.sql
--
-- A correction is the only ground truth this app has for where a night begins
-- and ends: the person who was there, moving the edge. Since 2026-09-06 a
-- corrected night keeps the detector's own answer beside the corrected one, so
-- the pair is recoverable and the error is a number rather than an impression.
--
-- Two things to hold in mind before tuning anything on this output.
--
-- Corrections are not a random sample. Someone corrects a night when it looked
-- wrong, so this table is the tail of the distribution by construction. It
-- bounds how wrong the detector gets when it is wrong; it says nothing about
-- how often it is right. `nights_total` beside `nights_corrected` is the only
-- honest denominator, and it is in the summary below for exactly that reason.
--
-- And a correction is itself a report, not a measurement — nobody knows to the
-- minute when they fell asleep. Treat a two-minute median error as agreement.

\set ON_ERROR_STOP on

-- ── 1. every corrected night, newest first ─────────────────────────────
SELECT
    substr(a.user_id::text, 1, 8)                                  AS usr,
    (a.ended_at AT TIME ZONE 'America/Los_Angeles')::date           AS wake_date,
    to_char(a.started_at AT TIME ZONE 'America/Los_Angeles', 'HH24:MI') AS said_start,
    to_char((a.sleep->>'detected_start')::timestamptz
              AT TIME ZONE 'America/Los_Angeles', 'HH24:MI')        AS detector_start,
    round(extract(epoch FROM
        (a.started_at - (a.sleep->>'detected_start')::timestamptz)) / 60.0) AS start_err_min,
    to_char(a.ended_at AT TIME ZONE 'America/Los_Angeles', 'HH24:MI')   AS said_end,
    to_char((a.sleep->>'detected_end')::timestamptz
              AT TIME ZONE 'America/Los_Angeles', 'HH24:MI')        AS detector_end,
    round(extract(epoch FROM
        (a.ended_at - (a.sleep->>'detected_end')::timestamptz)) / 60.0)     AS end_err_min,
    (a.sleep->>'algorithm_version')                                 AS algo
FROM activities a
WHERE a.activity_type = 'Sleep'
  AND a.sleep ? 'detected_start'
  AND a.sleep->>'detected_start' IS NOT NULL
ORDER BY a.ended_at DESC;

-- ── 2. the summary worth acting on ─────────────────────────────────────
-- Sign matters and must not be averaged away: a detector that is late as often
-- as it is early has a spread problem, one that is always late has a bias, and
-- the fixes are different. Median absolute error alone hides which.
WITH corrected AS (
    SELECT
        extract(epoch FROM (started_at - (sleep->>'detected_start')::timestamptz)) / 60.0 AS s_err,
        extract(epoch FROM (ended_at   - (sleep->>'detected_end')::timestamptz))   / 60.0 AS e_err,
        (sleep->>'algorithm_version') AS algo
    FROM activities
    WHERE activity_type = 'Sleep'
      AND sleep ? 'detected_start' AND sleep->>'detected_start' IS NOT NULL
), totals AS (
    SELECT count(*) AS nights_total FROM activities WHERE activity_type = 'Sleep'
)
SELECT
    (SELECT nights_total FROM totals)                       AS nights_total,
    count(*)                                                AS nights_corrected,
    algo,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY s_err)::numeric, 1)      AS start_bias_min,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(s_err))::numeric, 1) AS start_abs_min,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY e_err)::numeric, 1)      AS end_bias_min,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(e_err))::numeric, 1) AS end_abs_min,
    -- The direction of the misses, because a bias near zero can still be two
    -- large errors in opposite directions cancelling each other out.
    count(*) FILTER (WHERE s_err >  2) AS started_too_early,
    count(*) FILTER (WHERE s_err < -2) AS started_too_late,
    count(*) FILTER (WHERE e_err < -2) AS ended_too_late,
    count(*) FILTER (WHERE e_err >  2) AS ended_too_early
FROM corrected
GROUP BY algo
ORDER BY algo;
