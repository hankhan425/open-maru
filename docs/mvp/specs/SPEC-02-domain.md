# SPEC-02 — Domain: orgs, specs, decisions, goals, tasks

## 1. Principals

A principal is `{kind: person|agent|system, id}`. Stored as `(principal_kind, principal_id uuid)` column pairs. `system` is used for scheduled jobs (allocations, sweeps). Every write that changes state records its principal.

## 2. Tables (Postgres, all `id uuid` v7, `inserted_at/updated_at utc_datetime_usec`)

| Table | Key columns |
|---|---|
| `users` | `handle citext unique`, `display_name`, `email citext unique null`, `platform_role` (`user`/`admin`), `suspended_at` |
| `passkeys` | `user_id`, `credential_id bytea unique`, `cose_key bytea`, `sign_count`, `transports text[]`, `last_used_at` |
| `oauth_identities` | `user_id`, `provider` (`github`/`google`), `provider_uid`, unique(`provider`,`provider_uid`) |
| `user_sessions` | `user_id`, `token_hash unique`, `expires_at`, `revoked_at` |
| `personal_access_tokens` | `user_id`, `name`, `token_hash unique`, `last4`, `expires_at null`, `revoked_at`, `last_used_at` |
| `device_codes` | `device_code_hash unique`, `user_code unique`, `status` (`pending/approved/denied/expired/consumed`), `user_id null`, `expires_at`, `interval_secs` |
| `orgs` | `slug citext unique` (`[a-z0-9-]{3,40}`), `name`, `active_version_id`, `status` (`active/suspended`), `created_by` |
| `memberships` | `org_id`, `user_id`, `source` (`creator/open/invite/holder/operator`), `joined_at`, `left_at null`; unique active (`org_id`,`user_id`) |
| `sponsorships` | `org_id`, `candidate_user_id`, `sponsor_user_id`; unique triple |
| `spec_versions` | `org_id`, `number` (1..), `source_text`, `source_hash`, `ir jsonb`, `charter jsonb`, `parent_version_id null`, `decision_id null`, `created_by`, `activated_at null`; unique(`org_id`,`number`) |
| `circles` | `org_id`, `ident`, `seats`, `term_secs bigint null`, `active bool`; unique(`org_id`,`ident`) |
| `circle_holders` | `circle_id`, `user_id`, `accepted_at null`, `appointed_at`, `removed_at null` |
| `agents` | `org_id`, `ident`, `operator_user_id`, `runtime` (`byo/hosted`), `active bool`; unique(`org_id`,`ident`) |
| `goals` | `org_id`, `ident`, `title`, `status`, `pause_reason null` (`manual/underfunded`), `adopted_version_id`, `closed_at null`; unique(`org_id`,`ident`) |
| `mandates` | `goal_id`, `principal_kind`, `agent_id null`, `user_id null`, `status` (`active/revoked`), `terms jsonb` (IR mandate), `revoked_at` |
| `decisions` | `org_id`, `goal_id null`, `kind` (`amend/spend/close_goal`), `procedure jsonb`, `eligible_user_ids uuid[]`, `required_yes int`, `status`, `deadline_at`, `default_outcome` (`deny/allow`), `spec_version_id`, `rule_id null`, `effect jsonb`, `created_by_*`, `resolved_at` |
| `ballots` | `decision_id`, `user_id`, `choice` (`yes/no`), `cast_at`; unique(`decision_id`,`user_id`) |
| `proposals` | `decision_id unique`, `org_id`, `base_version_id`, `source_text`, `source_hash`, `ir jsonb`, `diff jsonb`, `title`, `rationale` |
| `goal_metrics` | `goal_id`, `name`, `value numeric`, `observed_at`, `reported_by_*` |
| `tasks` | `goal_id`, `title` (≤200), `body` (≤20k, markdown), `status`, `created_by_*`, `claimed_by_* null`, `current_lease_id null` |
| `leases` | `task_id`, `principal_*`, `ttl_secs`, `expires_at`, `released_at null`, `end_reason null` (`released/expired/submitted/cancelled/goal_paused`) |
| `evidence` | `goal_id`, `task_id null`, `kind` (`commit/pull_request/deploy/url/file/note`), `url null`, `upload_id null`, `summary` (≤2k), `posted_by_*` |
| `reviews` | `task_id`, `reviewer_user_id`, `verdict` (`accept/reject`), `comment` |
| `uploads` | `org_id`, `purpose` (`receipt/evidence/proof`), `object_key`, `content_type`, `byte_size`, `sha256`, `status` (`pending/stored`), `uploaded_by_*` |
| `activity_events` | `org_id`, `goal_id null`, `kind`, `actor_*`, `subject_type`, `subject_id`, `payload jsonb`, `visibility` (`public/members`), `occurred_at`; append-only |

Ledger, spend, payments, gateway, runtime tables are in SPEC-03/05/06.

## 3. Orgs and spec versions

### 3.1 Creation (genesis)
`create_org(creator, slug, source)`:
1. `Lang.check(source)` must return no errors.
2. Server validation (codes E5xx, returned in the same diagnostic shape with `span` of the offending token):
   - **E501** every `@handle` resolves to an existing, non-suspended user.
   - **E502** creator is a declared holder of at least one circle.
   - **E504** the `amend` procedure is satisfiable by *accepted* holders (at genesis: only the creator is accepted). E.g. `approve(core, 2)` at genesis is rejected; start with `approve(core, 1)` and tighten after others accept.
3. In one transaction: insert org, version 1 (activated now), project IR (§3.3), create memberships (creator; holders and operators as `holder`/`operator`), create ledger accounts (SPEC-03), emit `org.created` and `spec.version_activated`.
4. The creator's holder rows are `accepted_at = now`. Other listed holders are pending until they accept.

### 3.2 Holder acceptance
- A listed holder who hasn't accepted is **not** an effective holder. They receive an inbox item; `accept` sets `accepted_at`, `decline` records a decline and emits an event (the spec still lists them until amended).
- Anti-abuse: no one gains public association or powers without consent.

### 3.3 Projection (IR → tables)
Runs in the activation transaction of each version:
- Upsert circles/agents/goals by `ident`; mark missing circles/agents `active=false`.
- Holders: for each listed holder of each circle — if listed in the previous active version and not lapsed, keep `appointed_at`; if newly listed or lapsed, set `appointed_at = activation time`. Unlisted holders get `removed_at`.
- Goals: new goals are adopted (`status=active`, funding per SPEC-03 §5). A goal missing from the new IR must already be `closed` (**E503** at proposal time otherwise).
- Mandates: upsert by (goal, principal) with new `terms`; mandates missing from the IR become `revoked` (all their tokens become invalid).
- Store `ir` and rendered `charter` on the version.

### 3.4 Effective holders
`effective_holders(circle, at)` = holders with `accepted_at` set, `removed_at` null, and (`term_secs` null or `appointed_at + term_secs > at`).

**Holdover rule** (prevents term-lapse deadlock): when opening an **amend** decision, if the effective holders of the procedure's circle cannot satisfy it, holders whose terms lapsed (but are still listed and accepted) are also eligible, for amend decisions only.

### 3.5 Membership
- `open()`: `POST /orgs/:slug/membership` joins immediately.
- `invite(sponsors: N)`: members sponsor a candidate (`POST /orgs/:slug/sponsorships {handle}`); when distinct sponsors ≥ N the candidate becomes a member (`member.joined`). Candidates can't sponsor themselves.
- Leaving: `DELETE /orgs/:slug/membership`; holders/operators cannot leave while listed (`must_be_removed_by_amendment`).

## 4. Decisions engine

One engine for amendments, gated spend, and goal closure.

### 4.1 Opening
`open(kind, org, procedure, timeout, effect, spec_version, author)`:
- Eligible snapshot: `approve(C, N)` / `vote(C, T)` → effective holders of C (plus holdover for amend); `vote(members, T)` → all active members.
- **Spend decisions exclude the requesting principal and, for agents, its operator** from eligibility (no self-approval).
- `required_yes`: approve → N; vote → `ceil(num × eligible / den)` (integer arithmetic).
- Immediate failure: eligible = 0 → `failed` reason `no_eligible_voters`; required > eligible → `failed` reason `insufficient_eligible`. Effects of failure run immediately (e.g. spend voided).
- `deadline_at = now + within.secs`. Schedule an Oban job at the deadline.

### 4.2 Ballots
- Only snapshot-eligible users may vote (`not_eligible`). One ballot each, final (`already_voted`). Only while `open` (`decision_closed`).
- After each ballot: yes ≥ required → `passed`; no > eligible − required → `failed`.

### 4.3 Deadline
- If still open at `deadline_at`: default `deny` → `expired_failed`; `allow` → `expired_passed` (effect executes).
- Deadline jobs are idempotent (resolving an already-resolved decision is a no-op).

### 4.4 Effects (run in the same transaction as the status change)
| Kind | On pass | On fail/cancel |
|---|---|---|
| `amend` | If org's active version ≠ proposal's base → status `stale`, no effect. Else create and activate the new version, project, emit events; all other open amend decisions of the org become `stale`. | nothing |
| `spend` | Execute the held spend (SPEC-04 §5) | Void the hold; spend record `denied` |
| `close_goal` | Close the goal (§5.3) | nothing |

- Cancel: the author may cancel an open decision → `cancelled`.
- Amendment proposal creation re-runs server validation (E501–E504) against the proposal IR and computes `diff` vs the base version.

## 5. Goals

### 5.1 States
`active` → normal. `underfunded` → operational but short this period (`on_underfunded: continue`). `paused` (`pause_reason`: `underfunded` or `manual`) → all mandates of the goal are suspended: authorization denies with `goal_paused`, holds are voided, leases end, sessions stop. `closed` → terminal.

### 5.2 Transitions
| From | Event | To |
|---|---|---|
| (new) | goal appears in an activated version | `active` (+ adoption allocation) |
| active | period allocation short, `pause` | paused(underfunded) |
| active | period allocation short, `continue` | underfunded |
| underfunded / paused(underfunded) | shortfall fully topped up | active |
| active / underfunded | steward holder pauses (kill switch) | paused(manual) |
| paused(manual) | steward holder resumes | active, or underfunded/paused(underfunded) if a shortfall remains |
| any non-closed | close decision passes | closed |

### 5.3 Closing
`request_close(goal, principal)` opens a `close_goal` decision using the goal's `rule close` or, if none, `approve(<steward>, 1) within 7d else deny`. On pass, in order: void all holds; stop sessions; revoke mandate tokens; cancel open/claimed/in-review tasks (`task.cancelled`); dispose funds per `on_close` (SPEC-03 §5.4); `status=closed`, `closed_at`; emit `goal.closed`.

### 5.4 Metrics
`report_metric(goal, principal, name, value, observed_at)`: allowed for steward holders or principals with `report_metric:<name>`. `value` is a decimal string. Success status computed on read: `met` if the latest value satisfies the comparator (and was observed before the deadline if any), `missed` if the deadline passed unmet, else `in_progress`.

## 6. Tasks, leases, evidence

### 6.1 Permissions
| Action | Who |
|---|---|
| create task | steward holders; principals with `create_tasks` |
| claim / heartbeat / release / submit | principals with `claim_tasks`; steward holders |
| post evidence on a task | the current claimant; steward holders |
| post goal-level evidence (no task) | principals with `post_evidence`; steward holders |
| accept / reject | steward holders, **not** the claimant (and not the claimant agent's operator) |
| cancel | steward holders; the task creator while `open` |

### 6.2 State machine
| From | Action | To | Notes |
|---|---|---|---|
| open | claim | claimed | creates lease, `ttl_secs` default 1800, max 14400 |
| claimed | heartbeat (claimant) | claimed | `expires_at = now + ttl` |
| claimed | release (claimant) / lease expiry | open | sweeper runs every 60 s; emits `task.lease_expired` |
| claimed | submit (claimant; ≥1 evidence on task) | in_review | lease ends `submitted` |
| in_review | accept | done | review row |
| in_review | reject (comment required) | open | review row |
| open/claimed/in_review | cancel | cancelled | lease ends `cancelled` |

A principal may hold at most 5 active leases per goal (`lease_limit_reached`). Invalid transitions return `invalid_transition` with `from`/`action`.

### 6.3 Evidence
URLs must be `https://` (≤ 2,048 chars). `file` evidence references a `stored` upload. Evidence is immutable; corrections are new evidence.

## 7. Activity events

Kinds: `org.created`, `spec.version_activated`, `member.joined`, `member.sponsored`, `holder.accepted`, `holder.declined`, `holder.lapsed`, `decision.opened`, `decision.ballot_cast`, `decision.resolved`, `goal.adopted`, `goal.funded`, `goal.underfunded`, `goal.paused`, `goal.resumed`, `goal.closed`, `goal.metric_reported`, `mandate.token_issued`, `mandate.token_revoked`, `spend.held`, `spend.posted`, `spend.voided`, `spend.denied`, `donation.received`, `donation.refunded`, `task.created`, `task.claimed`, `task.released`, `task.lease_expired`, `task.submitted`, `task.accepted`, `task.rejected`, `task.cancelled`, `evidence.posted`, `session.started`, `session.stopped`, `ledger.checkpoint`.

All are `public` except `mandate.token_issued`/`mandate.token_revoked` (`members`). Donor identity is never in a public payload unless the donor opted in. Events are emitted inside the same transaction as the change they describe and broadcast after commit.
