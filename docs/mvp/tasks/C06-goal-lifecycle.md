# C06 · Goal lifecycle, metrics, closing

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Core | C04, G02, M02 | M | 10 |

**Read first:** SPEC-02 §5 (all); SPEC-03 §5.3–§5.4; SPEC-04 §5.1 (paused/closed); SPEC-07 goals rows.
**Paths:** `lib/openmaru/goals/**`, controllers

## Goal
Goals move through active / underfunded / paused / closed exactly as specified, report success metrics, and close through a decision that disposes funds.

## Deliverables
- `Openmaru.Goals.transition(goal, event, actor)` implementing the SPEC-02 §5.2 table (events: `allocation_short`, `topped_up`, `manual_pause`, `manual_resume`, `close_passed`); invalid → `invalid_transition`.
- Hook from G02: allocation shortfall and top-up call `transition/3`.
- `request_close/2` opening a `close_goal` decision (rule close or default `approve(steward, 1) within 7d else deny`); `close_goal` effect registered with C04 performing SPEC-02 §5.3 steps (void holds via `Spend.void`, stop sessions via `Openmaru.Runtime.stop_all/2` if present — no-op behaviour until A05, revoke tokens, cancel tasks, dispose funds, mark closed).
- Metrics: `report_metric/4`, success status computation.
- `GET /goals/:id` with status, `pause_reason`, period funding (G02), success status, and `viewer.permissions` (list of actions the caller is allowed: evaluated with `Mandates.authorize` for ClaimTask, CreateTask, ReviewTask, PauseGoal, ResumeGoal, RequestClose, ManageSecrets, ReportMetric, Spend).

P05 later adds refunds of unspent outside money (cost and unearned margin) to the close effect, before `on_close` (SPEC-05 §8.3), and the `paused(dormant)` transitions (SPEC-02 §5.2).

## Tests to write first
- [ ] **C06-T01** State table: every (state, event) pair from SPEC-02 §5.2 → expected state; all others → `invalid_transition`.
- [ ] **C06-T02** Allocation short with `pause` → `paused(underfunded)`; `authorize(:spend)` → `goal_paused`; events `goal.underfunded`, `goal.paused`.
- [ ] **C06-T03** Allocation short with `continue` → `underfunded`; spend still allowed.
- [ ] **C06-T04** Top-up covering the shortfall → `active`; events `goal.funded`, `goal.resumed` (resumed only if it was paused).
- [ ] **C06-T05** Manual resume with outstanding shortfall → `paused(underfunded)` (pause) or `underfunded` (continue).
- [ ] **C06-T06** `request_close` without a close rule → decision `approve(core, 1)` 7d deny; with lumen's rule → `vote(core, 2/3)` 7d.
- [ ] **C06-T07** Close passes: held spend voided, tokens revoked, open/claimed/in-review tasks cancelled, `return treasury` moves all goal funds to treasury, status `closed`, `closed_at`, `goal.closed`.
- [ ] **C06-T08** `on_close: transfer other` moves funds to the other goal's funds account.
- [ ] **C06-T09** Closed goal: every action → `goal_closed`; new close request → 409.
- [ ] **C06-T10** Metrics: steward reports any name; builder `weekly_active_users` OK; builder other name → 403 `capability_missing`; `"12.5"`, `"-3"` accepted; `"abc"`, `"1e5"` → 422.
- [ ] **C06-T11** Success status (Clock): `met`, `in_progress`, `missed` (deadline passed unmet); values observed after the deadline don't count.
- [ ] **C06-T12** `GET /goals/:id` shape incl. period funding and success; `viewer.permissions` for anonymous = [], for @mina includes ReviewTask/PauseGoal but not Spend, for builder token includes ClaimTask and Spend.
- [ ] **C06-T13** A closed goal later removed from the spec keeps its row, history, and ledger accounts.

## Out of scope
Kill-switch orchestration of sessions/in-flight calls (A06), UI (F06).
