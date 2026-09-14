# Roadmap and priorities

The standing agenda for customer-development sessions. Each section is meant to be rewritten as the evidence changes; keep the old version in git, not in the file.

## 1. The value we are building right now

_Draft to be agreed with Alex. What the app does today, in one paragraph, from the user's point of view._

Wythin turns a Polar H10 chest strap into a continuous read of the nervous system. It shows, live, how the body is responding right now (heart rate, variability, breath, and derived scores such as Throttle, Brake Bias, Rhythm Stability, and Repolarisation Stability), it guides breathing practices with sound and pacing, it tags every practice, workout, nap, and night with a before, during, and after, and it scores how each one changed the person's state. Nights are tracked whole. Everything syncs to a server the user can query from Claude Code with their own token.

What the roster says about who finds that valuable today:

- The two most engaged outside users are a daily meditator (Gus, 80 practices in three weeks) and a breathwork practitioner who logs everything from meetings to face massage (Natalia).
- Sleep is the single most common onboarding goal (Alex, Gus, Igor, Mikhail, Yuri) and Igor uses the app almost only for nights.
- Anxiety is the second (Natalia, Maxim, Kate, Mike, Yulia).
- Five of thirteen people already own a ring or wrist wearable (Oura, Whoop, Garmin, Apple Watch, Fitbit). The strap is an addition for them, not a first tracker.
- Three people created a Claude Code token (Natalia, Yuri, Sasha). Yuri created three.

## 2. Making it short-term

_How a person gets value in the first session and the first week, before any baseline exists._

Questions to answer from interviews:

- What did you see in the first ten minutes that made you keep the strap on?
- What did you expect the app to tell you that it did not?
- Which practice did you try first, and did the after-score make sense?

Hypotheses to test:

- A guided practice with a visible before/after is the fastest "aha".
- The live screen alone is not enough without an explanation of one number.

## 3. Making it long-term

_Why someone still wears the strap in month three._

Questions to answer from interviews:

- Yuri, Mike, and Kate each synced ten or more days and then stopped. What changed?
- What would you want the app to have learned about you after a month?
- Would you pay, and for which part?

Hypotheses to test:

- The value compounds through trends and personal baselines (recovery kinetics, sleep across nights), which the app is only beginning to show.
- Strap comfort and charging, not the software, end most streaks.

## 4. What users are telling us

_Synthesis across `feedback-log.md` and `interviews/`. Empty until the first round._

| Theme | Who said it | Evidence | What we did |
|---|---|---|---|
| The value is the after-the-fact readout: do something, then see what the nervous system did | Natalia | Crying by the ocean read as high Adaptive Capacity with normal Stress Balance; shaking dropped Stress Balance 75 → 32. "Without the device you'd never guess." | Feeds section 1 |
| Claude Code over their own data is a value driver, not a developer feature | Natalia (also Yuri, 3 tokens; Sasha, 1) | Token used daily 08-29 to 09-05; both notes credit it with the insight | Consider surfacing the same reading in-app |
| Individual scores do not add up: an evening of stacked interventions scored well piece by piece and wrecked the night | Natalia | 09-01: run, hot bath, 20 min breath holds; no sleep; morning all red | Later card: chain evening to night to morning |
| Overnight recording is fragile for outside users | Natalia (Igor and Gus are the other night users) | No samples 22:57 to 08:29 on 09-01 after trying at midnight | Now card: investigate |

## 5. The roadmap we are working on

_As of 2026-09-06, from the specs in `docs/superpowers/specs`, the backlog in `docs/BACKLOG.md`, and recent commits on main._

Shipped in the last two weeks (builds 110 to 120):

- Coherent Breathing rebuilt with tempo and counts; Resonance back to six per minute; Relaxing Breathing 4×6; Breath Stacking and Breath Retention 15×15 as scripted practices with sounds.
- Live screen: Throttle, Brake Bias, Rhythm Stability, Repolarisation Stability with the app's first beat delineator; nervous-system balance card removed.
- Exercise recovery card leads with the index; curves end at the return.
- Sleep: nights scored against minutes rather than ticks; whole-night sync to the server with the dashboard showing the night the way the app does (on this branch, not yet on main).

In flight:

- Self check-ins (spec 2026-09-13): a moment ask 10 to 15 minutes into a wear and a previous-day review on the first open, five unlabelled sliders each, stored in `felt_state_logs` and shown on the dashboard's Check-ins panel. Collecting now; the correlation against the metrics comes once there are a few weeks of answers.
- Sleep night sync and dashboard montage (branch `worktree-exercise-response-phase-1`).
- Recovery kinetics model (spec 2026-08-20).
- MADLOOP breathing-signature tool for Polar H10 (spec 2026-09-03), a research tool, not the app.
- Anchor cadence fix (branch `fix/anchor-cadence`, unmerged, backfill check owed).

Backlog: raw ECG capture (SP6), activity MCP tools (SP5a), encryption at rest, Apple Sign-In, App Privacy questionnaire.

## 6. Top priorities for the next two weeks

_To be set in the next session after the first interviews. Placeholder ordering from the roster alone:_

1. Talk to the four active users before they lapse; every one of them is a source of the "value right now" answer.
2. Talk to Yuri about why he left after the longest outside history.
3. Get whole-night sleep sync onto main and the phone so the sleep-goal users (Igor, Gus) are seeing the current version.
4. Decide what the first-session experience should show, from the interview answers to section 2.
