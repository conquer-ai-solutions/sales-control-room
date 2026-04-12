# Closing Zone — Briefing

Status as of April 2026. This document brings a new conversation up to speed on the Closing Zone feature in the Sales Control Room, the reasoning behind its design, the schema changes made to support it, and what's still open.

## Why it exists

The single most important question asked of the commercial team — by the founder, by investors, by the board — is **"which accounts are close to closing?"** Before Closing Zone, the Control Room had no first-class answer to that question. You had to scan the Board view, filter by stage, and eyeball it. The Closing Zone is a dedicated top-level view that answers the question directly, surfaces the evidence behind the answer, and makes it shareable as a URL or a copy-pasted briefing.

It lives in the nav next to Board, Audit, Admin, Initiatives, and Clients. Board stays as the default landing page. Closing Zone is deep-linkable at `#closing` and has a stripped-down board-member view at `#closing?board=1`.

## The stage model — Decision Phase, not Procurement

The most important conceptual change in the Control Room's life to date. The stage between Proposal and Contract Signed used to be called "Procurement" — the founder admitted the name was a placeholder chosen before the team had field experience with what actually happens in that phase.

What actually happens: after the proposal is delivered, the client hands it to whoever controls their money. For PE-backed clients this is the PE firm's finance function. For bigger clients it's an internal finance board or committee. The deal sits there, and progress is defined by **what signal you're picking up from that decision-maker**, not by contract paperwork. Procurement-the-traditional-thing (legal, signatures, vendor onboarding) only kicks in after this approval phase, and is comparatively fast.

The stage was renamed from `procurement` to `decision_phase` to reflect this. The label in the UI is **"Decision Phase"**. This rename touches every view in the Control Room that renders the stage (Kanban, filters, Client view, deal cards, Closing Zone) — they all read from the `STAGE_MAP` constant so the change propagates automatically.

## The decision signal ladder

Within Decision Phase, deals are differentiated by a new field called `decision_signal` with four values:

1. **Submitted** — proposal is with the decision-maker, nothing heard back
2. **Engaged** — they're asking questions, champion reports positive movement, active process but no commitment
3. **Positive signal** — direct feedback from the decision-maker's side suggests they're leaning yes *(e.g. SAI Med, where the PE firm is giving direct positive feedback)*
4. **Verbal commit** — explicit "we're doing this, paperwork coming"

Four levels is deliberately tight. Each level represents a genuinely different place on the road to closing, not a nuance of the same place. The field is editable in AccountView, and the dropdown only appears when a deal is in Decision Phase — it stays hidden for other stages to avoid form clutter.

"Close to closing" in the Closing Zone headline specifically means **Positive signal + Verbal commit** — the deals where there's a real, direct signal from the money decider. Submitted and Engaged deals are shown but framed as "also in Decision Phase, awaiting stronger signal." This was a deliberate choice: the founder pushed back on the previous version where every Decision Phase deal was counted as "close to closing," because some are sitting on nothing more than hope.

## What Closing Zone actually renders

**Top bar** (hidden in board mode):
- "My deals / All deals" toggle, appearing only if the logged-in user owns any commercial-territory deals (matched via `team_members.user_id === app_users.id`). Defaults to "My deals" for owners, "All deals" for everyone else.
- Region filter dropdown
- **Copy briefing** button that generates a plain-text snapshot ready to paste into Slack or email — includes headline numbers, forecast, and a list of Decision Phase deals with their signal tags

**Headline card** — money first, not counts. Three tiers stacked:
1. Big number: `£X truly close to closing · N accounts with positive or verbal signal` (strong-signal subset)
2. Secondary: `£Y also in Decision Phase · M awaiting stronger signal` (the rest)
3. Tertiary: `£Z in active commercial negotiation · K at Proposal`
4. Forecast subline: `£A expected to close by end of [month] · £B by end of quarter` — computed from `expected_close_date`. Falls back to `"Add expected close dates..."` when none are set.
5. `Total commercial pipeline: £T`

**What Changed this week** — reads from the `deal_events` table (last 7 days). Surfaces:
- Stage changes (deal moved into/within commercial territory)
- Close-date changes (with a "slipped to" vs "set to" distinction)
- Value changes (raised vs revised)
- Champion changes
- **Signal changes** — strengthened (green dot), weakened (orange), or sideways (neutral). This is the most important event type for a CRO to see.

If `deal_events` is empty (brand new migration, no changes yet) it falls back to showing stage entries derived from `stage_entered_at`, so the strip is never broken.

**Decision Phase section** — the hero. Cards show:
- Account name + project
- Deal value (prominent, purple)
- **Signal pill** — colour-coded, always visible. Verbal commit = bright green glow, positive signal = green, engaged = blue, submitted = grey, unset = amber dashed outline ("Signal not set") as a prompt to act.
- Close date strip (if set) — purple accent, shows date and "in Nd" or "overdue"
- Facts grid: days in Decision Phase (benchmarked "on track" if ≤21d, "stretching" after), last activity, champion, owner
- Next action text
- "Slipping" tag on the account name if the close date has moved backwards in the last 14 days (detected from `deal_events`)

**Sort order within Decision Phase:**
1. Signal strength desc (verbal_commit → positive_signal → engaged → submitted → unset)
2. Close date asc (soonest first)
3. Deal value desc (fallback)

**Proposal section** — subordinate. Compact rows, not cards. Clearly "behind them" in the visual hierarchy. Sorted by value desc. This is intentional: the founder was explicit that within commercial territory the useful distinction is proximity to close, not health. A deal in Proposal is by definition further from close than one in Decision Phase.

**Board mode** — triggered by `#closing?board=1`. Strips the page to headline card + Decision Phase grid only. Hides filters, What Changed, and the Proposal section. Max-width constrained to 720px for phone reading. Share this link with investors or board members who want a 30-second summary they can skim on mobile.

## What was deliberately NOT built

- **No health or "needs attention" framing on commercial-territory deals.** The founder rejected this early on, and correctly. Every deal in Decision Phase has cleared the POC gate and is credible by definition. What the cards do surface is **factual position signals** (days in stage, last activity, signal strength, close-date slippage). These describe *where* a deal is, not *whether* it's worthy. This is important: a `stalled` flag on a Decision Phase deal would undermine the credibility framing of the whole section.
- **No manual confidence scores set by reps.** Confidence scores are a trap — they get gamed optimistically or sandbagged, and people stop trusting them. The decision signal ladder is better because each level is tied to something factual ("did you get direct feedback from the decision-maker?") rather than a feeling.
- **No separate Signature stage.** After Decision Phase concludes with Verbal commit, the deal moves straight to Contract Signed. If signatures start routinely getting stuck we can add a dedicated stage later, but right now it would be false precision.
- **No forecast for Proposal deals.** Only Decision Phase deals contribute to the "expected to close by end of month/quarter" numbers. Proposal is too early to commit.

## Schema changes made to Supabase

Two migrations, both applied to the live database. Files are in `/migrations/` in the repo.

### Migration 001 (`001_closing_zone.sql`) — applied

- `deals.expected_close_date` column (nullable date)
- `deal_events` table — append-only change log with `deal_id`, `event_type`, `from_value`, `to_value`, `user_id`, `created_at`
- `log_deal_event()` trigger function on `deals` — writes an event row when tracked fields change
- `deals_log_event` AFTER UPDATE trigger attaching the function
- RLS enabled on `deal_events` with a policy granting SELECT to `authenticated` — **if the app uses the anon key from the client and What Changed comes back empty, this policy needs to be switched to `anon`**

### Migration 002 (`002_decision_phase.sql`) — applied

Had to be split into two steps because `deals.stage` is a Postgres enum (`deal_stage`), not a text column, and `ALTER TYPE ... ADD VALUE` must run outside a transaction.

**Step 1 (no transaction):**
- `ALTER TYPE deal_stage ADD VALUE IF NOT EXISTS 'decision_phase' AFTER 'procurement'`

**Step 2 (wrapped in BEGIN/COMMIT):**
- `deals.decision_signal` column (nullable text)
- Disable trigger, `UPDATE deals SET stage = 'decision_phase' WHERE stage = 'procurement'`, re-enable trigger (so the rename doesn't flood `deal_events`)
- Extended `log_deal_event()` to also track `signal_changed` events
- Cast enum values to text in the trigger function for safety

**Note:** `'procurement'` is still a valid value in the `deal_stage` enum — not removed. Removing enum values in Postgres is painful and unnecessary. It just sits there unused.

## What's still open

**Data entry is the bottleneck.** Every piece of the architecture is in place, but the feature only becomes powerful once deal owners actually set decision signals and expected close dates. The headline will show `£0 / 0 accounts` until at least one Decision Phase deal has a Positive signal or Verbal commit set. The forecast subline will show the fallback text until at least one has a close date. The What Changed strip becomes richer once signals start flipping between levels. First action after the migration: open each Decision Phase deal and set its signal level based on current field knowledge. SAI Med should be `positive_signal` based on direct PE feedback.

**The days-in-stage benchmarks are guesses.** 21 days for Decision Phase, 30 for Proposal. Once there are ~10 closed deals of history, derive real medians from Supabase and replace them. That's a five-minute follow-up.

**Benchmarking methodology is crude.** "On track" vs "stretching" is binary. Could be made into percentiles once there's enough closed-deal history.

**Expected close date has no validation.** A deal owner could set a date in the past, or 10 years in the future. Nothing in the UI prevents this. Low priority but worth a pass eventually.

**Personalisation is purely owner-based, not role-based.** The `app_users.role` field holds `admin | editor | viewer`, which are permission roles not functional roles, so they can't drive personalisation. "My deals / All deals" instead uses the owner mapping (`team_members.user_id === app_users.id`). This works but means there's no way to build a dedicated "CRO view" or "board view" — the board view is URL-driven via `?board=1` rather than user-driven.

**The trigger's `user_id` column is always null.** The trigger function doesn't know which app user made the change, because the app uses a single service-role connection, not per-user Supabase auth. Fixing this would require passing the user ID through the update payload (e.g. via a session variable or an RPC wrapper). Not urgent.

**No "changes since I was last here" tracking.** What Changed shows the last 7 days universally. A more powerful version would track per-user last-visit timestamps and show "here's what moved since you last opened Closing Zone." Would need `localStorage` tracking or a server-side table. Good follow-up if adoption of the page warrants it.

## The mental model to keep in mind

Closing Zone is not a pipeline report. It's a **weekly-rhythm commercial review tool for the person who has to answer "how's it looking?"** to an investor or board member. Everything in the design flows from that: money-first framing, strong-signal headlines, the copy-briefing button, the board mode URL, the factual-not-judgemental position signals.

The biggest risk to the feature is not that it's insufficiently rich — it's already richer than most CRM pipeline views — but that it becomes a read-only poster nobody opens daily. The "What Changed this week" strip is the single biggest adoption hook and needs to become genuinely informative over time. That requires team members to actually update deals in AccountView, which the trigger will then reflect in Closing Zone automatically.

## File touchpoints

Everything is in `index.html` (single-file React app). Relevant landmarks:

- `STAGES` constant — stage list and colours (line ~815)
- `fmt()`, `daysUntil()`, `initials()` — shared helpers (line ~853-870)
- `/* Closing Zone */` CSS block — search for this comment
- `function ClosingZone({ deals, teamMembers, user, onDealClick })` — the component
- `function AccountView(...)` — holds the edit form with the new `expected_close_date` and `decision_signal` fields, plus the save allowlist at the top of the save handler

Migrations in `/migrations/`:
- `001_closing_zone.sql`
- `002_decision_phase.sql`
