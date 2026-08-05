# Practice states and Box Breathing — design

**Date:** 2026-08-04
**Status:** approved, ready to implement

## Problem

The Practice hub organizes content by *modality* — Breathwork, Meditation, Movement,
Recovery. That answers "what is this?" but not "what do I need right now?", which is
the question a person actually opens the app with. The catalog is also thin: ten
practices, only one of which (Resonance) is an interactive session. Everything else is
a description and a "Log it" button.

## What we're building

Two changes, related but separable:

1. **States replace categories as the hub's organizing axis.** Four intent states —
   Sharpen Focus, Manage Stress, Reduce Anxiety, Improve Sleep — become the capsule
   filter. Every practice is tagged with one or more. Seven new practices fill the
   states out.
2. **Box Breathing becomes a guided session** — a 6-6-6-6 pacer with a fixed 60 BPM
   metronome and a visual that makes inhale–hold–exhale–hold legible at a glance.

## 1 · States

### Model

`PracticeState` is a new enum in `Practice.swift`:

```swift
enum PracticeState: String, CaseIterable, Identifiable {
    case focus, stress, anxiety, sleep
}
```

Each case carries a `label` ("Sharpen Focus"), a `chip` for the capsule bar ("FOCUS"),
and an SF Symbol `icon`.

`Practice` gains `let states: [PracticeState]`. The array is non-empty and its first
entry is the practice's primary state. `PracticeCatalog.practices(for:)` filters on
membership and sorts primary-first, so a state leads with practices that exist for it
and trails with ones it merely borrows.

State membership is many-to-many by design: Wind-Down Breath honestly serves both
sleep and anxiety, and forcing a single tag would hide it from one of them.

### Hub

`PracticeHubView.filter` changes type from `PracticeCategory?` to `PracticeState?`, and
the capsule bar renders `PracticeState.allCases` instead of `PracticeCategory.allCases`.
Nothing else in the hub changes — the featured card, the three-up grid, the teachers
strip and the history list are untouched.

`PracticeCategory` is not deleted. It still labels the art and still renders in the
detail screen's meta row; it simply stops driving navigation.

The grid tile badge gains a third case: `.pacer` practices show a metronome badge,
alongside the existing star (featured) and ECG (biofeedback) badges.

### Detail

A state row — icon plus label per state — sits between the meta row and the tag row.

### Content

The ten existing practices are tagged; seven new ones are added. No new teachers.

| State | Practices (primary first) |
|---|---|
| Sharpen Focus | Box Breathing\* · Coherent Calm · Morning Stillness · Focus Reset\* · Walking Focus\* · Resonance · Zone 2 Run |
| Manage Stress | Resonance · Grounding Flow · Slow Mobility · Strength Set · Zone 2 Run · Box Breathing\* · Physiological Sigh\* |
| Reduce Anxiety | Loving-Kindness · Body Scan · Grounding 5-4-3-2-1\* · Physiological Sigh\* · Wind-Down Breath · Grounding Flow |
| Improve Sleep | Wind-Down Breath · Yoga Nidra\* · Evening Unwind\* · Body Scan · Slow Mobility |

\* new.

Every new practice reuses an existing `ActivityType` subtype so the logging pipeline
keeps working unchanged:

| Practice | Type / subtype | Teacher | Mins |
|---|---|---|---|
| Box Breathing | breathwork / Box Breathing | Mara Quinn | 6 |
| Focus Reset | meditation / Open Awareness | Elias Vance | 5 |
| Walking Focus | exercise / Nature Walk | Noor Haddad | 20 |
| Physiological Sigh | breathwork / Pranayama | Mara Quinn | 3 |
| Grounding 5-4-3-2-1 | meditation / Guided | Elias Vance | 5 |
| Yoga Nidra | meditation / Yoga Nidra | Elias Vance | 25 |
| Evening Unwind | exercise / Stretching | Noor Haddad | 12 |

## 2 · Box Breathing

### Kind

`PracticeKind` gains `case pacer(BreathPattern)`, where `BreathPattern` holds four
phase lengths in seconds. `BreathPattern.box` is 6-6-6-6. Making it data-driven rather
than hardcoding a `.boxBreathing` case costs nothing now and lets Wind-Down Breath
(4-7-8) become a pacer later without new view code.

The detail screen dispatches `.pacer` to a "Start Box Breathing" primary button with
"Log it" beneath, mirroring how `.biofeedback` already works.

### Timing — fixed, not configurable

60 BPM, six beats per phase, four phases. One beat is one second; a full cycle is 24
seconds, or 2.5 breaths a minute. None of this is user-adjustable. Because a phase is
exactly six beats, the accented beat that opens each phase *is* the phase change —
the count can never drift against the box.

### The visual

Clockwise around a rounded square: top edge is inhale, right is hold, bottom is
exhale, left is hold. Four things move, all driven off one clock:

- **The perimeter** — the active side lights and fills over its six seconds with a dot
  at the leading edge; completed sides stay dim-lit until the cycle resets. This answers
  *where am I in the cycle*, and shows all four phases at once.
- **An inner circle** — scales up through inhale, sits large through the first hold,
  shrinks through exhale, sits small through the second hold. This answers *what do my
  lungs do*. Without it a dot sliding along an edge can't distinguish inhale from hold.
- **The count** — a large numeral 1…6 inside the box over six pips, resetting each
  phase. This answers *how long left*.
- **The click** — every beat, accented on beat one, so the cycle is followable with
  your eyes closed.

Below the box: cycle number and elapsed time. The nav bar carries the title, a mute
toggle and Stop.

### Architecture

`BoxBreathEngine` is an `@Observable`, UI-free type owning the single timebase. A
`DispatchSourceTimer` fires beats on absolute deadlines computed from the session start
rather than by repeatedly adding an interval, so a twenty-minute session doesn't
accumulate drift. It publishes `phase`, `beatInPhase` (1…6), `cycleCount` and
`elapsed`; the view animates *between* those transitions rather than per frame, so no
display link is needed. The same transitions drive the cue.

One clock is the point: the pips, the perimeter sweep and the click cannot desync
because there is nothing to keep in sync.

The engine's beat arithmetic is a pure function of elapsed seconds, exposed as a static
`state(at:pattern:)`, so tests can assert phase and beat mapping without waiting on
real time.

`MetronomeCue` owns the audible and haptic side: two short click buffers synthesized
in code (the project has no audio assets and no existing `AVFoundation` usage), played
through a persistent `AVAudioEngine` — a higher pitch for the accent, lower for plain
beats — plus `UIImpactFeedbackGenerator`, `.rigid` on the accent and `.light` otherwise.
The audio session uses `.playback` with `.mixWithOthers` so the metronome works with the
ringer off and doesn't stop the user's music.

On Stop the session logs a `breathwork` / "Box Breathing" `ActivityLog` via
`ActivityLogging.logPast`, exactly as `ResonanceSessionView` does.

### New files

```
ios/Wythin/Models/BreathPattern.swift
ios/Wythin/UI/Resonate/BoxBreathEngine.swift
ios/Wythin/UI/Resonate/MetronomeCue.swift
ios/Wythin/UI/Resonate/BoxPacerView.swift
ios/Wythin/UI/Resonate/BoxBreathingSessionView.swift
ios/WythinTests/BoxBreathEngineTests.swift
```

The Xcode project has no file-system-synchronized groups, so each file also needs a
`PBXFileReference`, a `PBXBuildFile` and group/build-phase membership in
`project.pbxproj`.

## Testing

`PracticeCatalogTests` gains: every practice has at least one state; no practice repeats
a state; every state has at least one practice (mirroring the existing per-category
test); the pacer practice's subtype is a valid breathwork subtype (already covered by
the general subtype invariant, which now also covers the seven new practices).

`BoxBreathEngineTests` covers the pure timing function: phase and beat at t = 0, 5.9,
6.0, 23.9 and 24.0; that the accent falls only on beat one of a phase; and that the
cycle count increments every 24 seconds.

## Out of scope

- Configurable tempo, pattern or cue. Explicitly rejected — the practice is fixed.
- Turning the other breathwork practices into pacers. The `BreathPattern` shape makes
  it cheap later; nothing needs it now.
- Recommending a state from live metrics. States are browsed, not inferred.
