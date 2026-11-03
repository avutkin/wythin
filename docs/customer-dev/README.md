# Customer development

Everything we learn from the people using Wythin, organized by person, plus the board and roadmap that turn it into work.

## What lives where

| File | Purpose | Who edits |
|---|---|---|
| [KANBAN.md](KANBAN.md) | The board for this effort: interviews to run, feedback to act on, roadmap decisions to make | Alex and Claude, every session |
| [roadmap.md](roadmap.md) | The value we are building now, how it gets shorter-term and longer-term, the roadmap, and the top priorities for the next two weeks | Alex and Claude, revisited each session |
| [feedback-log.md](feedback-log.md) | One running log of every piece of feedback, dated and attributed, across all users | Claude appends whenever feedback arrives |
| [roster.md](roster.md) | Every real user ever, with status and usage numbers from the production database | Generated. Run `tools/customer-dev-roster.sh` to refresh |
| `users/<first-last>.md` | One file per person: profile, usage snapshot, interviews, feedback, open questions | Claude keeps it current; Alex adds colour |
| `interviews/YYYY-MM-DD-<first-last>.md` | Raw interview transcripts and notes, one file per conversation | Dropped in from Zoom, then cleaned up |
| `templates/` | The interview guide and the blank user file | Rarely |

## How feedback gets filed

1. Alex pastes feedback into the session (chat message, screenshot, Zoom transcript, in-app message).
2. Claude appends a dated entry to `feedback-log.md` and the same entry to the person's file under `users/`.
3. If the feedback implies work, Claude adds a card to `KANBAN.md` that links back to the person.
4. If the person is new, Claude creates `users/<first-last>.md` from `templates/user-file.md` and adds the id to `KNOWN` in `tools/customer_dev_roster.py`.

## Recordings and Zoom

- Drop audio or video into `~/Code/Wythin/CustDev/` (outside git; it holds voice notes and Zoom recordings). Then run `tools/customer-dev-transcribe.sh <file>` and it writes the transcript to `interviews/<date>-<slug>.md` for Claude to summarise. Transcription runs locally with whisper-large-v3-turbo on this Mac; nothing is uploaded.
- Zoom: set the meeting to record to the cloud with audio transcript on, or record locally (files land in `~/Documents/Zoom/`). Either way, copy the recording or the `.vtt` transcript into `CustDev/` and it gets filed the same way. There is no live Zoom connector in this session yet.

## Zoom sweeps

Zoom is connected through the claude.ai connector (2026-09-06). At the start of a session, ask for a sweep ("check Zoom for interviews since <date>"). For every meeting with a transcript or recording in the window, Claude reads the transcript and classifies it by content, not by title:

| Classification | Test | Where it goes |
|---|---|---|
| **Wythin** | The conversation is about the app, the Polar strap, HRV, breathwork, sleep, recovery, a user's data, or the product's direction; or a participant is on the [roster](roster.md) and talks about their use | This folder: `interviews/`, the person's file, `feedback-log.md`, board cards |
| **Circles** | The conversation is about the Circles app, its decks and questions, the portal, its testers, or its strategy | `~/Code/circles/docs/customer-dev/`, same structure |
| **Other** | Anything else, or mixed calls where neither product is the point | Listed in [zoom-triage.md](zoom-triage.md) with date, participants, a one-line summary, and Claude's guess. Alex classifies; nothing else is written until he does |

A call that covers both products is filed in both, with only the relevant part summarised in each. Once a meeting is filed or triaged, its Zoom meeting id is recorded in `zoom-triage.md` so the next sweep skips it.


1. Transcript lands in `interviews/YYYY-MM-DD-<first-last>.md` with the raw text at the bottom and a summary at the top: who, what they use the app for, what they value, what frustrates them, quotes worth keeping, what we promised.
2. The person's file gets a one-line entry under Interviews linking the transcript.
3. Each distinct piece of feedback from the interview also goes into `feedback-log.md`.
4. Themes that recur across people go into `roadmap.md` under "What users are telling us".

## Conventions

- One person, one file, named `first-last.md`. Unknown surname: first name only.
- Dates are ISO, newest first inside every list.
- Quote people in their own words when it matters; paraphrase otherwise.
- This folder holds names, emails, and phone numbers. It is for Alex and the team only. Do not paste it into anything external.
- User ids are quoted as their first eight characters; the full id is in the database.
