# SPEC-02 — Domain: orgs, specs, decisions, goals, tasks

## 1. Principals

A principal is `{kind: person|agent|system, id}`. Stored as `(principal_kind, principal_id uuid)` column pairs. `system` is used for scheduled jobs (allocations, sweeps). Every write that changes state records its principal.

## 2. Tables (Postgres, all `id uuid` v7, `inserted_at/updated_at utc_datetime_usec`)

| Table | Key columns |
|---|---|
| `users` | `handle citext unique null` (picked after sign-up, lower-cased, `^[a-z0-9][a-z0-9_-]{1,29}$`, not reserved and not starting with `deleted-user-`, immutable once set), `display_name`, `email citext unique null` (provider-verified only), `platform_role` (`user`/`admin`), `suspended_at`, `deleted_at` (account deletion, SPEC-09 §4; added by H02), `last_active_at` (set at sign-up, then by any request authenticated with a web session or PAT, at most hourly; mandate tokens and public requests don't count; §3.4), `webauthn_user_handle bytea unique null` (WebAuthn `user.id`, 32 random bytes) |
| `passkeys` | `user_id`, `credential_id bytea unique`, `cose_key bytea`, `sign_count`, `transports text[]`, `last_used_at` |
| `oauth_identities` | `user_id`, `provider` (`github`/`google`), `provider_uid`, unique(`provider`,`provider_uid`) |
| `user_sessions` | `user_id`, `token_hash unique`, `expires_at`, `revoked_at` |
| `auth_challenges` | `kind` (`passkey_registration`/`passkey_login`/`oauth`), `challenge bytea null`, `user_id null`, `data jsonb` (user handle or OAuth state/nonce), `expires_at` (5 min), `consumed_at` (single use) |
| `audit_log` | `action`, `actor_kind`/`actor_id`, `target_type`/`target_id`, `ip_hash` (keyed hash, OQ-6), `ip_hash_key_id` (the `audit_ip_hash_keys` row), `user_agent`, `metadata jsonb`, `occurred_at`; append-only (trigger rejects UPDATE/DELETE/TRUNCATE), SPEC-09 §7 |
| `audit_ip_hash_keys` | `day date` (UTC day it hashes), `wrapping_key_id` (fingerprint of the `AUDIT_IP_HASH_KEY` that sealed it), `sealed_key bytea null` (null once destroyed), `destroyed_at null`; SPEC-09 §7 |
| `personal_access_tokens` | `user_id`, `name`, `token_hash unique`, `last4`, `expires_at null`, `revoked_at`, `last_used_at` |
| `device_codes` | `device_code_hash unique`, `user_code unique` (8 characters, stored without the hyphen), `status` (`pending/approved/denied/expired/consumed`), `user_id null` (who approved or denied), `user_agent null` (the requesting client's; names the token), `expires_at`, `interval_secs`, `last_polled_at null` |
| `orgs` | `slug citext unique` (`[a-z0-9-]{3,40}`), `name`, `active_version_id`, `status` (`active/suspended`), `created_by`, `forked_from_org_id null`, `forked_from_version_id null` (§3.7) |
| `memberships` | `org_id`, `user_id`, `source` (`creator/open/invite/holder/operator`), `joined_at`, `left_at null`; unique active (`org_id`,`user_id`) |
| `sponsorships` | `org_id`, `candidate_user_id`, `sponsor_user_id`; unique triple |
| `spec_versions` | `org_id`, `number` (1..), `source_text`, `source_hash`, `ir jsonb`, `charter jsonb`, `parent_version_id null`, `decision_id null`, `created_by`, `activates_at null` (a passed amendment waiting, SPEC-05 §8.5), `activated_at null`; unique(`org_id`,`number`) |
| `circles` | `org_id`, `ident`, `seats`, `term_secs bigint null`, `active bool`; unique(`org_id`,`ident`) |
| `circle_holders` | `circle_id`, `user_id`, `accepted_at null`, `appointed_at`, `removed_at null` |
| `agents` | `org_id`, `ident`, `operator_user_id`, `runtime` (`byo/hosted`), `active bool`; unique(`org_id`,`ident`) |
| `goals` | `org_id`, `ident`, `title`, `status`, `pause_reason null` (`manual/underfunded/dormant`), `dormant_at null` (SPEC-05 §8.7), `adopted_version_id`, `closed_at null`; unique(`org_id`,`ident`) |
| `mandates` | `goal_id`, `principal_kind`, `agent_id null`, `user_id null`, `status` (`active/revoked`), `terms jsonb` (IR mandate), `revoked_at` |
| `decisions` | `org_id`, `goal_id null`, `kind` (`amend/spend/close_goal`), `procedure jsonb` (as run, after §4.1's adjustments), `eligible_count int`, `required_yes int` (circle procedures; for a member-wide vote the yes count needed if every eligible member voted), `min_turnout int null` (member-wide votes), `status`, `deadline_at`, `default_outcome` (`deny/allow`), `spec_version_id`, `rule_id null`, `effect jsonb`, `created_by_*`, `resolved_at` |
| `decision_voters` | `decision_id`, `user_id`; the eligibility snapshot, one row per voter (§4.1); unique(`decision_id`,`user_id`) |
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
   - **E501** every `@handle` resolves to an existing user who is neither suspended nor deleted.
   - **E502** creator is a declared holder of at least one circle.
   - **E504** the `amend` procedure is satisfiable by *accepted* holders (at genesis: only the creator is accepted). E.g. `approve(core, 2)` at genesis is rejected; start with `approve(core, 1)` and tighten after others accept.
   - **E505–E507** only for an org with a goal at funding tier 2: money-safety checks (SPEC-05 §8.6).
3. In one transaction: insert org, version 1 (activated now), project IR (§3.3), create memberships (creator; holders and operators as `holder`/`operator`), create ledger accounts (SPEC-03), emit `org.created` and `spec.version_activated`.
4. The creator's holder rows are `accepted_at = now`. Other listed holders are pending until they accept.

### 3.2 Holder acceptance
- A listed holder who hasn't accepted is **not** an effective holder. They receive an inbox item; `accept` sets `accepted_at`, `decline` records a decline and emits an event (the spec still lists them until amended).
- Anti-abuse: no one gains public association or powers without consent.

### 3.3 Projection (IR → tables)
Runs in the activation transaction of each version:
- Upsert circles/agents/goals by `ident`; mark missing circles/agents `active=false`.
- Holders: for each listed holder of each circle — if listed in the previous active version, not lapsed and not departed, keep `appointed_at`; if newly listed or lapsed, set `appointed_at = activation time`. A departed holder (§3.6) who is still listed gets a new row that is pending until they accept again. Unlisted holders get `removed_at`.
- Goals: new goals are adopted (`status=active`, funding per SPEC-03 §5). A goal missing from the new IR must already be `closed` (**E503** at proposal time otherwise).
- Mandates: upsert by (goal, principal) with new `terms`; mandates missing from the IR become `revoked` (all their tokens become invalid).
- Store `ir` and rendered `charter` on the version.

### 3.4 Effective holders
`effective_holders(circle, at)` = holders with `accepted_at` set, `removed_at` null, (`term_secs` null or `appointed_at + term_secs > at`), whose user is neither suspended nor **silent**.

A person is **silent** when their `last_active_at` is more than **90 days** before `at`. One sign-in makes them count again. A silent person keeps every right to act, and any action makes them active again; while silent they only stop counting toward decisions and funding-tier conditions (SPEC-05 §8.1). A suspended person counts again once unsuspended (OQ-16).

**Holdover rule** (prevents term-lapse deadlock): when opening an **amend** decision, if the effective holders of the procedure's circle cannot satisfy it, holders whose terms lapsed (but are still listed and accepted, and are neither silent nor suspended) are also eligible, for amend decisions only.

### 3.5 Membership
- `open()`: `POST /orgs/:slug/membership` joins immediately.
- `invite(sponsors: N)`: members sponsor a candidate (`POST /orgs/:slug/sponsorships {handle}`); when distinct sponsors ≥ N the candidate becomes a member (`member.joined`). Candidates can't sponsor themselves.
- Leaving: `DELETE /orgs/:slug/membership`. Anyone may leave at any time, holders and operators included (§3.6).

### 3.6 Departure
A person **departs** an org when they leave it or their account is deleted (deletion leaves every org first, SPEC-09 §4). In one transaction:
- the membership gets `left_at`; holder rows get `removed_at`, so they no longer count anywhere (`member.left`, `holder.departed`);
- their person mandates in the org are revoked with every token;
- each agent they operate is stopped (SPEC-06 `stop_agent`: tokens revoked, in-flight requests aborted, sessions stopped);
- they can no longer vote in decisions they were eligible for (`not_eligible`).

The spec keeps naming them until an amendment changes it, and the org page marks them as departed. A later version that still names them gives roles back only the usual way: a seat must be accepted again, and a mandate is granted as to anyone.

An agent whose operator has departed, is suspended or deleted, or is silent may not act: its requests, and `IssueToken`/`StartSession` for it, are refused with `operator_unavailable` until a version names an operator who is an active member (SPEC-04 §5.1).

There is no owner role: the creator has no powers beyond the spec. When people leave or go silent, the org keeps working through §4.1's rules, or its members fork it (§3.7).

### 3.7 Forks
Any signed-in user may fork an org: `POST /orgs/:slug/forks {slug, source}` creates a new org through §3.1 (E501/E502/E504 apply, so the forker usually edits the source first) and records `forked_from_org_id` and `forked_from_version_id`. Only the spec is copied: no funds, members, holders' consent, Stripe account or history. Both org pages show the link; the original lists the forks made by people who were its members when they forked it, and its pledges may follow those (SPEC-05 §8.9).

## 4. Decisions engine

One engine for amendments, gated spend, and goal closure.

### 4.1 Opening
`open(kind, org, procedure, timeout, effect, spec_version, author)`:
- Eligible snapshot, one `decision_voters` row each, counted in `eligible_count`: `approve(C, N)` / `vote(C, T)` → effective holders of C (§3.4; plus holdover for amend); `vote(members, T)` → members with an active membership who joined at least 30 days before the decision opens and are neither silent nor suspended (SPEC-01 §4.7).
- **Spend decisions exclude the requesting principal and, for agents, its operator** from eligibility (no self-approval).
- **An amend decision always has a way through** (OQ-16). After holdover:
  - if an `approve(C, N)` circle has eligible holders but fewer than N, the decision needs all of them (N becomes the eligible count);
  - if the procedure's circle has no eligible holders, the decision runs as `vote(members, 2/3)` with the same timeout and `else` outcome.

  Spend and close decisions never shrink. They fail as below, and the org amends its spec first. `decisions.procedure` stores the procedure as run.
- `required_yes`: approve → N; vote → `ceil(num × eligible / den)` (integer arithmetic). For a member-wide vote this is the yes count needed if every eligible member voted, and `min_turnout = ceil(eligible / 5)` (20%).
- Immediate failure: eligible = 0 → `failed` reason `no_eligible_voters`; required > eligible → `failed` reason `insufficient_eligible`. Effects of failure run immediately (e.g. spend voided).
- `deadline_at = now + within.secs`. Schedule an Oban job at the deadline.

### 4.2 Ballots
- Only snapshot-eligible users who have not departed (§3.6) may vote (`not_eligible`). One ballot each, final (`already_voted`). Only while `open` (`decision_closed`).
- Circle procedures, after each ballot: yes ≥ required → `passed`; no > eligible − required → `failed`.
- A member-wide vote ends early only when the outcome can no longer change:
  - `passed` when yes ≥ max(`required_yes`, `min_turnout`);
  - `failed` when no > eligible − `required_yes`, and either yes + no ≥ `min_turnout` or the `else` outcome is `deny`.

  Once every eligible member has voted, it is decided as at the deadline.

### 4.3 Deadline
- A circle procedure still open at `deadline_at`: default `deny` → `expired_failed`; `allow` → `expired_passed` (effect executes).
- A member-wide vote still open at `deadline_at`: if yes + no ≥ `min_turnout`, it is `passed` when yes ≥ `ceil(num × (yes + no) / den)` and `failed` otherwise; below the turnout it takes the `else` outcome (`expired_passed` or `expired_failed`).
- Deadline jobs are idempotent (resolving an already-resolved decision is a no-op).

### 4.4 Effects (run in the same transaction as the status change)
| Kind | On pass | On fail/cancel |
|---|---|---|
| `amend` | If org's active version ≠ proposal's base → status `stale`, no effect. Else, if the org holds outside money and the diff has a change that is not `tightens`, create the version **scheduled** (`activates_at` = now + 14 days, `spec.version_scheduled`; SPEC-05 §8.5). An Oban job activates it then, unless the active version changed in the meantime (the version is `stale`). Otherwise activate now. Activating projects, emits events, and makes every other open amend decision of the org `stale`. | nothing |
| `spend` | Execute the held spend (SPEC-04 §5) | Void the hold; spend record `denied` |
| `close_goal` | Close the goal (§5.3) | nothing |

- Cancel: the author may cancel an open decision → `cancelled`.
- Amendment proposal creation re-runs server validation (E501–E507) against the proposal IR and computes `diff` vs the base version.

## 5. Goals

### 5.1 States
`active` → normal. `underfunded` → operational but short this period (`on_underfunded: continue`). `paused` (`pause_reason`: `underfunded`, `manual` or `dormant`) → all mandates of the goal are suspended: authorization denies with `goal_paused`, holds are voided, leases end, sessions stop. `closed` → terminal.

### 5.2 Transitions
| From | Event | To |
|---|---|---|
| (new) | goal appears in an activated version | `active` (+ adoption allocation) |
| active | period allocation short, `pause` | paused(underfunded) |
| active | period allocation short, `continue` | underfunded |
| underfunded / paused(underfunded) | shortfall fully topped up | active |
| active / underfunded | steward holder pauses (kill switch) | paused(manual) |
| paused(manual) | steward holder resumes | active, or underfunded/paused(underfunded) if a shortfall remains |
| active / underfunded | 60 days without steward activity while holding outside money or pledges (SPEC-05 §8.7) | paused(dormant); `dormant_at` set at day 90 |
| paused(dormant) | steward holder resumes | as for paused(manual); `dormant_at` cleared |
| any non-closed | close decision passes | closed |

### 5.3 Closing
`request_close(goal, principal)` opens a `close_goal` decision using the goal's `rule close` or, if none, `approve(<steward>, 1) within 7d else deny`. On pass, in order: void all holds; stop sessions; revoke mandate tokens; cancel open/claimed/in-review tasks (`task.cancelled`); refund unspent outside money (SPEC-05 §8.9), then dispose the rest per `on_close` (SPEC-03 §5.4); `status=closed`, `closed_at`; emit `goal.closed`.

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

Kinds: `org.created`, `org.forked`, `spec.version_scheduled`, `spec.version_activated`, `member.joined`, `member.left`, `holder.departed`, `member.sponsored`, `holder.accepted`, `holder.declined`, `holder.lapsed`, `decision.opened`, `decision.ballot_cast`, `decision.resolved`, `goal.adopted`, `goal.funded`, `goal.underfunded`, `goal.paused`, `goal.resumed`, `goal.dormancy_warning`, `goal.dormant`, `goal.closed`, `funds.contributed`, `pledge.created`, `pledge.charged`, `pledge.cancelled`, `donation.exited`, `goal.metric_reported`, `mandate.token_issued`, `mandate.token_revoked`, `spend.held`, `spend.posted`, `spend.voided`, `spend.denied`, `donation.received`, `donation.refunded`, `task.created`, `task.claimed`, `task.released`, `task.lease_expired`, `task.submitted`, `task.accepted`, `task.rejected`, `task.cancelled`, `evidence.posted`, `session.started`, `session.stopped`, `ledger.checkpoint`.

All are `public` except `mandate.token_issued`/`mandate.token_revoked` (`members`). Donor identity is never in a public payload unless the donor opted in. Events are emitted inside the same transaction as the change they describe and broadcast after commit.
