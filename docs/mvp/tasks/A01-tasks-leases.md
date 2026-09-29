# A01 · Tasks & leases

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Agents | C03, C05, M01 | M | 9 |

**Read first:** SPEC-02 §6.1–§6.2; SPEC-04 §2 (ClaimTask, CreateTask, CancelTask); SPEC-07 tasks rows.
**Paths:** `lib/openmaru/tasks/**`, controllers, workers, migrations

## Goal
Work on a goal is broken into tasks that people and agents claim with time-limited, heartbeat-renewed leases, so everyone can see who is doing what and abandoned work returns to the pool.

## Deliverables
- Migrations `tasks`, `leases`.
- `Openmaru.Tasks`: `create/3`, `claim/3`, `heartbeat/2`, `release/2`, `cancel/2`, `list/2`, `get/1`; transitions per SPEC-02 §6.2 (submit/accept/reject in A02).
- Lease sweeper (Oban, every 60 s).
- Endpoints (M routes for claim/heartbeat/release/create); events and broadcasts.

## Tests to write first
- [ ] **A01-T01** Create: steward holder OK; @jo (`create_tasks`) OK; builder → 403 `capability_missing`; title ≤ 200 and body ≤ 20,000 chars enforced (422).
- [ ] **A01-T02** builder claims → `claimed`, lease TTL 1800 default; `ttl_secs` 14400 OK, 14401 → 422.
- [ ] **A01-T03** Claiming a claimed task → 409 `invalid_transition` (details `from`, `action`).
- [ ] **A01-T04** Heartbeat extends `expires_at`; non-claimant → 403 `not_claimant`; after expiry → 409 `lease_expired`.
- [ ] **A01-T05** Release → `open`; lease `end_reason: released`.
- [ ] **A01-T06** Sweeper: expired lease → task `open`, `task.lease_expired`; second run no-op.
- [ ] **A01-T07** 6th concurrent lease by one principal in a goal → 409 `lease_limit_reached`.
- [ ] **A01-T08** Goal paused → claim 423 `goal_paused`.
- [ ] **A01-T09** Cancel: steward holder any time; creator only while `open`; others 403; active lease ends `cancelled`.
- [ ] **A01-T10** Transition table: every (state, action) pair in SPEC-02 §6.2 handled; all others → `invalid_transition`.
- [ ] **A01-T11** `GET /goals/:id/tasks?status=` public, paginated; `GET /tasks/:id` includes current lease and claimant.
- [ ] **A01-T12** Mandate-token actor can create (if capable), claim, heartbeat, release via M routes.
- [ ] **A01-T13** Events `task.created/claimed/released/lease_expired/cancelled` emitted and broadcast on `public:goal:<id>`.

## Out of scope
Evidence, submission, review (A02), sessions (A05).
