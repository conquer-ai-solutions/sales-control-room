# Initiatives — Briefing for Tom

*Sales Control Room subsystem · April 2026*

## TL;DR

The Sales Control Room contains a feature called **Initiatives** — a place to track things the team is working on that need visibility but don't have a natural home elsewhere in the system. Some of it relates to deals (and gets linked many-to-many), some of it doesn't relate to deals at all (advisor relationships, partnerships, ops work, anything that needs a home but isn't a commercial outcome). It has a clean data model, a working UI, and three years of conceptual room to run. **It is built infrastructure, not a feature with adoption**: the schema is sound, the components exist, but the team's working rhythm hasn't formed around it yet. The same is true of most of the Sales Control Room — these are deliberate scaffolds put in ahead of demand.

This briefing covers what Initiatives is, the lane it occupies, the data model, and the surface area where Initiatives could plausibly read from or write to Conquer Intel if integration becomes useful later. **No recommendations are made about whether integration should happen** — that is a call for you and Bolaji to make once you've seen the shape of what exists.

One thing to flag upfront: Initiatives is not the only Sales Control Room subsystem with potential overlap with Intel. The `deals` table itself uses free-text `account_name` strings with no canonical foreign key to anything Intel knows about. If Intel becomes the golden source for accounts, Initiatives is the *second* reconciliation problem — the first is deals. The integration framing in this doc is therefore deliberately scoped to "what would the seams look like" rather than "should we wire this up now."

---

## What Initiatives is

An **Initiative** is a record representing *something the team is working on that needs to be tracked but doesn't have a natural home elsewhere in the system*. The defining characteristic isn't that initiatives are "strategic" or "long-arc" — it's that they're **homeless**. The deal pipeline tracks commercial outcomes. The clients view tracks accounts. Initiatives is what catches everything else that someone needs to remember about.

Examples of what an initiative could represent (none of these are real records — they're illustrative of the intended use case):
- An advisor relationship that needs ongoing care but isn't a deal
- A partnership being explored with a third party
- A piece of internal work the team has committed to (e.g. building out a new pitchbook, standing up a vertical)
- Something a deal is contributing to that's bigger than the deal itself (e.g. "validate the M&A workflow with three real customers" — a workstream that several deals support)

Some initiatives will link to deals (the schema supports many-to-many — one initiative can have multiple supporting deals, one deal can contribute to multiple initiatives). Others won't link to anything, because the work has nothing to do with the commercial pipeline. The optionality is the point: the system doesn't enforce a parent or assume a relationship to deals, because the whole reason Initiatives exists is to give a home to work that wouldn't otherwise have one.

**Each initiative carries:**
- A title and description
- A status (`not_started | in_progress | on_hold | done`)
- A priority (`low | medium | high`)
- A target date (optional)
- Tags (free-form array)
- A team — one owner, multiple contributors, multiple watchers
- An activity feed of free-text updates from team members
- Zero or more links to deals, each link optionally annotated with a note

It is, structurally, a lightweight tracker with an optional many-to-many bridge to the commercial pipeline. It is not OKRs. It is not a Kanban board. It is closer to "Linear projects, but loose enough that a record can exist without belonging to anything else."

## The lane it occupies

The Sales Control Room has three top-level concerns the team currently tracks:

1. **Deals** — the commercial pipeline. Stage-based (Intro → Discovery → POC → Proposal → Decision Phase → Contract Signed). Heavy structure. Driven by money and close dates. Lives in the `deals` table.
2. **Clients** — the account-level rollup of deals. Lives as a derived view over `deals` grouped by account name. No first-class table.
3. **Initiatives** — the strategic workstream layer. First-class table. Cross-references deals via the `initiative_deal_links` junction table.

Initiatives is the only layer in the Sales Control Room that is *intentionally not* organised around money or commercial stage. It exists so that the team has a place to capture *anything else* that needs visibility — work that's adjacent to deals, work that's adjacent to clients, and work that's adjacent to neither but still matters. Pipeline reports cannot answer "what else are we working on right now" because the pipeline only knows about deals; that's the gap Initiatives is meant to fill.

In practice today: this layer is dormant. It is fully built and queryable, but the working habit of *"if a piece of work doesn't fit elsewhere, open Initiatives and create a record"* has not yet been adopted by the team. Acknowledging this directly because Tom will see it in the data: there are very few real initiatives in the system and the activity feed on the ones that exist is sparse.

## Logical architecture

Initiatives is a self-contained subsystem inside the single-page React app at `index.html`. It does not have its own service, microservice, or background workers. All reads and writes go directly from the browser to Supabase via the JS client.

```
┌─────────────────────────────────────────────────────────┐
│                    React SPA (index.html)                │
│                                                          │
│  ┌─────────────────────┐    ┌─────────────────────┐    │
│  │  InitiativesScreen  │───▶│  InitiativeDetail   │    │
│  │  (list view)        │    │  (single view)      │    │
│  └─────────────────────┘    └─────────────────────┘    │
│           │                          │                  │
│           │                          ├──▶ InitiativeModal│
│           │                          │    (create/edit) │
│           │                          │                  │
│           │                          └──▶ LinkDealModal │
│           │                               (link to deal)│
│           │                                              │
│  ┌─────────────────────┐                                │
│  │     AccountView     │  reads initiative_deal_links   │
│  │     (deal page)     │  to show "Linked Initiatives"  │
│  └─────────────────────┘                                │
└─────────────────────────────────────────────────────────┘
                       │
                       │ supabase-js
                       ▼
┌─────────────────────────────────────────────────────────┐
│                      Supabase                            │
│                                                          │
│  initiatives ◀──┐                                        │
│       │         │                                        │
│       │         │ FK                                     │
│       │         │                                        │
│       ▼         │                                        │
│  initiative_members ──▶ app_users                        │
│       │                                                  │
│       │                                                  │
│       ▼                                                  │
│  initiative_updates ──▶ app_users (author)               │
│       │                                                  │
│       │                                                  │
│       ▼                                                  │
│  initiative_deal_links ──▶ deals                         │
│                            (account_name is free text,   │
│                             no FK to any account entity) │
└─────────────────────────────────────────────────────────┘
```

**Key components, with their responsibilities:**

- `InitiativesScreen` — list view. Loads `initiatives` and `initiative_members` in parallel, filters by status / priority / search, displays an `InitiativeCard` grid. Handles route at `#initiatives`.
- `InitiativeDetail` — single initiative view. Loads `initiative_updates`, `initiative_members`, and `initiative_deal_links` (with embedded `deals` rows). Displays the activity feed, the team, the linked deals, and a description. Routes at `#initiative/<uuid>`.
- `InitiativeModal` — create and edit form. Writes to `initiatives`, then upserts `initiative_members` rows for owner/contributors/watchers. Handles the entire form-to-multiple-tables save flow client-side.
- `LinkDealModal` — search-and-pick UI for linking an existing deal to an initiative. Inserts a row into `initiative_deal_links` with optional note and `linked_by` user ID. Loads up to 50 most-recently-created deals — pagination is not yet implemented.
- `AccountView` — the deal detail page. Queries `initiative_deal_links` filtered by `deal_id` to render a "Linked Initiatives" section, allowing navigation back to the relevant initiative. This is the only place outside the Initiatives subsystem that reads initiative data.

There is no background sync, no event bus, no webhook, no API layer. It is a thin client over Postgres via PostgREST. Realtime subscriptions are used for the deals table elsewhere in the app but are **not** currently wired to the initiatives tables.

## Data model

Six tables touch Initiatives. Three of them are core to Initiatives (`initiatives`, `initiative_members`, `initiative_updates`), one is the bridge to deals (`initiative_deal_links`), and two are referenced from those (`deals`, `app_users`).

### `initiatives`

The core record.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `title` | text | required |
| `description` | text | optional |
| `status` | text | one of: `not_started`, `in_progress`, `on_hold`, `done` |
| `priority` | text | one of: `low`, `medium`, `high` |
| `target_date` | date | optional |
| `tags` | text[] | optional, free-form |
| `created_by` | uuid | FK to `app_users.id` |
| `created_at` | timestamptz | default `now()` |
| `updated_at` | timestamptz | written by client on update |

Note: `status` and `priority` are stored as `text`, not enums. This is inconsistent with the `deals` table (where `stage` and `status` are enums). Worth flagging — the lighter typing here makes integration easier but is a mild integrity risk.

### `initiative_members`

Junction table assigning users to initiatives with a role.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `initiative_id` | uuid | FK to `initiatives.id` |
| `user_id` | uuid | FK to `app_users.id` |
| `role` | text | one of: `owner`, `contributor`, `watcher` |

There is a unique constraint on `(initiative_id, user_id)` (used by the upsert in `InitiativeModal`). The "one owner per initiative" rule is enforced softly in the application code, not by a constraint on the table.

### `initiative_updates`

Append-only activity feed. Functionally a microblog per initiative.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `initiative_id` | uuid | FK to `initiatives.id` |
| `author_id` | uuid | FK to `app_users.id` |
| `content` | text | the update body |
| `created_at` | timestamptz | default `now()` |

There is no edit history, no soft-delete, no thread/reply structure. Updates are immutable from the application's perspective.

### `initiative_deal_links`

The bridge between Initiatives and the deal pipeline.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `initiative_id` | uuid | FK to `initiatives.id` |
| `deal_id` | uuid | FK to `deals.id` |
| `linked_by` | uuid | FK to `app_users.id` — who created the link |
| `note` | text | optional context for why this deal supports this initiative |
| `linked_at` | timestamptz | default `now()` |

The `note` field is more important than it looks. It means the relationship is **annotated** — when a user links a deal to an initiative they can capture the rationale ("this deal validates the pharma hypothesis", "this is the first paying customer for the M&A workflow"). This is the closest thing the Sales Control Room has to qualitative reasoning attached to a relationship, and it's worth knowing about because it's the layer most likely to be valuable to anything downstream that wants context.

### `deals` (relevant subset only)

Already documented in the Closing Zone briefing — for Initiatives' purposes the only relevant fields are:

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK, referenced by `initiative_deal_links.deal_id` |
| `account_name` | text | **free text**, no FK to any account table |
| `project_name` | text | free text |
| `stage` | enum `deal_stage` | the pipeline stage |
| `deal_value` | numeric | optional |

The free-text `account_name` is the friction point for any future Intel integration. More on this below.

### `app_users`

Already documented in the Closing Zone briefing. Referenced from Initiatives via `created_by`, `initiative_members.user_id`, `initiative_updates.author_id`, and `initiative_deal_links.linked_by`.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `email` | text | login identifier |
| `display_name` | text | human-readable name |
| `role` | text | one of: `admin`, `editor`, `viewer` (app-level permissions) |
| `permitted_screens` | text[] | which screens the user can access |
| `is_active` | boolean | login gate |
| `password_hash` | text | bcrypt hash, used by custom `verify_password` RPC |

Authentication is handled by a custom `verify_password` Postgres function — **not Supabase Auth**. This matters for any integration where Conquer Intel might want to share a session, federate identity, or trust the same user across both apps. Right now, the Sales Control Room's user identities are local to its own `app_users` table and have no relationship to Conquer Intel's user model.

## Integration surface area with Conquer Intel

This section catalogues the places where Initiatives could plausibly read from or write to Conquer Intel, on the assumption that Intel is the prospective golden source for accounts, contacts, and meetings. **No recommendations are made.** The intent is to surface where the seams are so an integration decision can be made with full information.

### Surface 1 — Initiatives ↔ Intel accounts

**The opportunity.** An Initiative is currently a free-floating workstream record with no account association except via linked deals. If Intel is the canonical source for accounts, an Initiative could carry a list of "primary accounts this initiative is targeting" as foreign keys to Intel's account entities.

**What would need to change.**
- Add an `initiative_accounts` junction table, or an `intel_account_ids` array column on `initiatives`
- Decide whether the link is by Intel UUID, by some other Intel-side identifier, or by a denormalised name + ID pair
- Decide who owns the canonical account entity — if Intel is golden source, the Sales Control Room should never create an account, only reference one

**The bigger problem this exposes.** The same exercise needs to happen on the `deals` table, which currently uses free-text `account_name`. Reconciling Initiatives with Intel without first reconciling deals would create an asymmetric model where strategic workstreams are tied to canonical accounts but the deals contributing to them are not. This is solvable but should be a deliberate choice, not an accidental one.

### Surface 2 — Initiative updates ↔ Intel meeting transcripts

**The opportunity.** `initiative_updates` is an append-only feed of human-written context about how an initiative is progressing. Conquer Intel holds meeting transcripts. There is an obvious bridge: meetings *about* an initiative could automatically post a summary update to the initiative's feed, or the feed could pull a list of related transcripts on demand.

**What would need to change.**
- A way to associate an Intel meeting with an initiative — either explicit user action ("link this meeting to this initiative") or automatic via shared account/contact references
- Either a webhook from Intel into the Sales Control Room (Intel writes to `initiative_updates` directly, with an `author_id` pointing at a system user, or with a new `source` column tracking provenance)
- Or a periodic pull from Intel into a denormalised cache (lower coupling, higher staleness)

**Schema implication.** `initiative_updates` would benefit from new columns: `source` (`human | intel_meeting | other`), `external_ref` (Intel's meeting ID), and possibly `transcript_excerpt` for the actual quoted content. None of these exist yet.

### Surface 3 — Initiative team ↔ Intel users

**The opportunity.** Both systems have a concept of users. Right now they are entirely separate identity stores. If Intel users and Sales Control Room users are the same humans, federating identity would let "watchers" on an initiative receive notifications from Intel events, and let Intel surface "which initiatives is this user contributing to" in its own UI.

**What would need to change.**
- A canonical user identity store — either Intel becomes the source and the Sales Control Room references it, or vice versa, or a third identity provider sits above both
- Either way, `app_users.id` would need either a stable mapping to Intel's user ID, or replacement with a shared identifier
- The custom `verify_password` flow would likely need to be retired in favour of a shared auth mechanism — non-trivial for a live app

This is the most expensive of the three surfaces but unlocks the most over time.

### Surface 4 — Linked deals ↔ Intel meeting context

**The opportunity.** The most valuable existing data in `initiative_deal_links` is the optional `note` field — a human's annotation of why a particular deal supports a particular initiative. If Intel holds meeting transcripts for the same accounts, that note could be enriched with "and here's the meeting where this came up" — turning a flat annotation into a navigable reference.

**What would need to change.**
- A `meeting_id` foreign key on `initiative_deal_links` (nullable, references Intel)
- A read API from Intel that takes a meeting ID and returns enough metadata to render a summary inline in the Sales Control Room
- Decision on direction of arrow: does the Sales Control Room call out to Intel on render, or does the link table cache the meeting summary at write time?

### Surface 5 — Tags ↔ Intel topics or themes

**The opportunity.** `initiatives.tags` is a free-form text array. Conquer Intel may have its own concept of topics, themes, or content categories derived from meeting transcripts. If those are first-class entities in Intel, the Sales Control Room could pull a controlled vocabulary instead of letting users type free-form tags.

**What would need to change.**
- A way to fetch tag/topic vocabulary from Intel
- A migration of existing free-form tags to whichever scheme Intel uses (or a hybrid where free tags are allowed but suggested ones come from Intel)
- This is the smallest and most optional of the surfaces — flagging it for completeness

## What's currently broken or unfinished

Listing this honestly so Tom doesn't discover it under his own steam.

- **Initiatives is barely used.** The schema is populated lightly, the activity feed on most initiatives is empty, and the working rhythm hasn't formed. This is true of most of the Sales Control Room — these are scaffolds put in ahead of demand on purpose. Tom should not interpret an empty database as a broken feature.
- **`LinkDealModal` loads only 50 most-recent deals**, with no pagination or full-text search across the whole table. With more deals this will become a usability problem.
- **The "one owner per initiative" rule is enforced in application code, not the schema.** A direct SQL insert could create an initiative with multiple owners or no owner.
- **`initiatives.status` and `initiatives.priority` are text, not enums.** Inconsistent with the `deals` table. Mild integrity risk; no current bug.
- **No realtime subscriptions on the initiatives tables.** Two users editing the same initiative simultaneously will produce last-write-wins behaviour with no notification. Realtime is wired up for `deals` elsewhere in the app and could be added if collaborative editing becomes real.
- **No audit log for initiative changes.** The `audit_log` table used elsewhere in the app is not written to from the initiative save handlers. There is no record of who changed what when. (Compare: `deals` writes to `audit_log` on every update.)
- **The `verify_password` custom auth means there's no bridge to Supabase Auth.** Any integration with Intel that wants to share session or identity will hit this immediately.
- **There is no "add user" UI.** Users are added by direct SQL insert into `app_users`. This affects Initiatives only insofar as Initiatives needs users to function, but it's worth knowing if Tom's evaluation involves "could we let X person into the system."
- **A separate save-failure bug exists in the `deals` AccountView edit flow** — addressed in a recent fix but worth knowing about because the same anti-pattern (silent error swallowing) was present and may exist elsewhere in older code.

## Open questions for Tom

These are the things only Tom can answer, and the answers will shape any future integration work.

1. **Is Intel actually intended to become the canonical account source?** "Becoming regarded as the potential golden source" is directional language. A concrete answer changes whether the Sales Control Room should refactor to reference Intel or stay parallel.
2. **What is Intel's identity model?** Specifically: do Intel users have stable IDs, can they be looked up by email, and is there a notion of teams or workspaces above the user level?
3. **Does Intel expose a read API today?** REST, GraphQL, direct DB access, or none? This determines whether integration is "we make HTTP calls" or "we ship events between two databases."
4. **Does Intel write outbound events or webhooks?** If yes, the cleanest integration pattern is Intel → Sales Control Room push (e.g. "new meeting transcript referencing Account X" → write an `initiative_update` if any initiative is tied to that account).
5. **Are Intel's meeting transcripts addressable by URL?** Even without an API, a stable URL per transcript would unlock the simplest possible Surface 4 integration: link table stores the URL, Sales Control Room renders it as a hyperlink.
6. **How does Tom feel about coupling vs. independence?** Some teams want everything wired together; others deliberately keep parallel systems decoupled because it gives them room to iterate independently. There's no right answer, but the answer here determines whether the integration surfaces above are "things to build soon" or "things to know exist for later."

---

## File / code reference

For Tom or anyone digging into the code, all of the above lives in a single file: **`index.html`** at the root of the `sales-control-room` GitHub repo. Relevant landmarks:

- `function InitiativesScreen` — the list view component
- `function InitiativeDetail` — the single-initiative view
- `function InitiativeModal` — create/edit form, including the multi-table save flow
- `function LinkDealModal` — search-and-pick UI for linking deals
- `function AccountView` — search for `initiative_deal_links` to find the inbound reference from the deal page
- CSS classes prefixed `.initiative-` and `.initiatives-` for styling

There are no migration files specific to Initiatives in the repo — the tables were created directly in Supabase before the migration discipline started. The closest reference for the table shapes is this document plus a `SELECT column_name FROM information_schema.columns WHERE table_name LIKE 'initiative%'` query in the Supabase SQL Editor.
