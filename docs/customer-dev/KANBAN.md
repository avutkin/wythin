# Customer development board

Move cards between columns by cutting and pasting. Every card that came from a person links to their file. Done cards keep the date they finished.

## Now

- [ ] **Reply to [Natalia Leroux](users/natalia-leroux.md)** on her two voice notes (filed 2026-09-06). Ask the five open questions in her file, starting with what the screen showed when the night measurement stopped on 2026-09-01.
- [ ] **Investigate Natalia's missing night, 2026-09-01.** Last sample 22:57 local, next 08:29; she says she tried to measure at midnight. Check the server for that user around 14:57 to 16:30 UTC and the app's overnight recording path.
- [ ] **Confirm identities on the roster.** Ask who owns `631a651b` (box breathing, opens the app most days, no Polar) and `be8af3ce` (Breath Stacking). Candidates are [Dmitry](users/dmitry.md) and [Ivan](users/ivan.md). Confirm `a861e2c1` is Alex's second device.
- [ ] **Connect Zoom.** Needs a paid Zoom plan with cloud recording, Smart Recording, and Meeting Summary on. Then claude.ai → Settings → Connectors → Zoom → Connect (OAuth). In a new session Claude can list meetings, pull transcripts and summaries, and file them by person. No end-of-call trigger exists: ask for a sweep each session or set a weekly scheduled run. Free-plan fallback: local recording → `~/Code/Wythin/CustDev/` → `tools/customer-dev-transcribe.sh`.
- [ ] **Book the first four interviews with active users:** [Gus Tai](users/gus-tai.md), [Natalia Leroux](users/natalia-leroux.md), [Maxim Sleptsov](users/maxim-sleptsov.md), [Igor Kamenev](users/igor-kamenev.md). Use `templates/interview-guide.md`.
- [ ] **Write the "value right now" statement** in `roadmap.md`. One paragraph Alex agrees with, then test it in every interview.

## Next

- [ ] **Interview the lapsed users about why they stopped:** [Yuri Vedenin](users/yuri-vedenin.md) first (24 sync days, then gone), then [Mike Yang](users/mike-yang.md), [Kate Shestak](users/kate-shestak.md), [Yulia Skidan](users/yulia-skidan.md), [Valeriya Bobyleva](users/valeriya-bobyleva.md).
- [ ] **Ask [Mikhail Pavlov](users/mikhail-pavlov.md) what blocked him.** Installed 2026-08-12, five stated goals, almost no usage.
- [ ] **Synthesize the first round** into "What users are telling us" in `roadmap.md`.
- [ ] **Set the top priorities for the next two weeks** in `roadmap.md` from that synthesis.

## Later

- [ ] **Chain an evening's activities to the night and the next morning** (from Natalia: run + bath + breath holds each scored well, the night was bad, nothing in the app connects them). Belongs with the recovery kinetics work.
- [ ] **Somatic category** (shaking, TRE) alongside Breathwork and Meditation. Natalia's biggest after-effect is logged as Exercise "shake".
- [ ] **Add the app build number to usage events** so the roster can say which version each person runs. Today there is no way to tell.
- [ ] **Long-term value:** what Wythin is in a year, written down and argued from interview evidence.
- [ ] **Public-link installs:** six anonymous TestFlight installs have no name at all. Decide whether onboarding should ask for a name and email before anything else.

## Done

- [x] 2026-09-06 — Natalia's two voice notes transcribed locally (mlx-whisper), translated, filed; `tools/customer-dev-transcribe.sh` added for the next recording.
- [x] 2026-09-06 — Folder created. Roster pulled from production and TestFlight: 13 named people, 2 TestFlight-only names, 2 unattributed active devices, 177 noise rows.
