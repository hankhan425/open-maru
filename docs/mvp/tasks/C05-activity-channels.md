# C05 · Activity log, PubSub, channels

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Core | C03 | M | 8 |

**Read first:** SPEC-02 §7; SPEC-07 §3; SPEC-09 §4 (privacy); C02 (socket token).
**Paths:** `lib/openmaru/activity/**`, `lib/openmaru_web/channels/**`, `lib/openmaru_web/user_socket.ex`, migrations

## Goal
Every state change produces an append-only activity event, broadcast in real time to the right audiences after commit.

## Deliverables
- Migration `activity_events` (append-only trigger).
- `Openmaru.Activity.emit(multi, attrs) :: Ecto.Multi.t()` — inserts in the transaction and broadcasts only after commit (use `Ecto.Multi.run` + an after-commit mechanism, e.g. `Openmaru.Repo.after_commit/1`).
- Kind whitelist from SPEC-02 §7; visibility defaults; payload sanitizer that drops `email` and donor names unless `donor_public`.
- `UserSocket` (socket token or PAT), channels `public:goal:*`, `public:world`, `org:*`, `user:*` with join authorization per SPEC-07 §3.
- `public:world` pulse throttling (≤ 10 pushes/s globally, coalescing).
- `GET /public/goals/:id/activity` with cursor pagination.

## Tests to write first
- [ ] **C05-T01** `emit` inside a committed Multi inserts and broadcasts; inside a rolled-back Multi neither inserts nor broadcasts.
- [ ] **C05-T02** Public event → broadcast on `public:goal:<id>` and `org:<id>`; members-only event → only `org:<id>`.
- [ ] **C05-T03** Sanitizer: donation payload without opt-in has no name; `email` keys removed at any depth.
- [ ] **C05-T04** Unknown kind → `{:error, :unknown_event_kind}`.
- [ ] **C05-T05** `/public/goals/:id/activity`: newest first, cursor pagination stable under concurrent inserts, members-only excluded.
- [ ] **C05-T06** Join `public:goal:<id>` anonymously OK; `org:<id>` as non-member → `{:error, %{reason: "unauthorized"}}`; as member OK; `user:<id>` only for that user.
- [ ] **C05-T07** Socket connect with valid socket token / PAT OK; expired or tampered → refused.
- [ ] **C05-T08** 100 pulses within 1 s → ≤ 10 pushes on `public:world`, none lost from the coalesced counts.
- [ ] **C05-T09** UPDATE/DELETE on `activity_events` raise.

## Out of scope
Specific events are emitted by the tasks that own the state change.
