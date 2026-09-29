# A06 · Kill switch

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Agents | A05, C06 | M | 12 |

**Read first:** SPEC-06 §5; SPEC-02 §5.2; ARCHITECTURE §7 (kill switch target).
**Paths:** `lib/openmaru/goals/kill_switch.ex`, controllers

## Goal
A steward can stop a goal — or an operator an agent — instantly: spend blocked at commit, in-flight model calls aborted (with their usage still recorded), sessions stopped, leases released.

## Deliverables
- `Openmaru.Goals.KillSwitch`: `pause_goal/2`, `resume_goal/2`, `stop_agent/2` orchestrating C06 transitions, `Gateway.InFlight` aborts, `Runtime.stop_all/2`, lease endings, token revocation (stop_agent).
- Parallel fan-out (`Task.async_stream`, bounded) with per-target timeouts; result summary `{sessions_stopped, requests_aborted, leases_ended, tokens_revoked}`.
- Endpoints `POST /goals/:id/pause`, `/resume`, `POST /agents/:org_slug/:ident/stop`; audit rows.

## Tests to write first
- [ ] **A06-T01** Steward holder pauses → `paused(manual)` committed; a spend request right after → `goal_paused`.
- [ ] **A06-T02** In-flight gateway requests of the goal receive abort and post their known usage (reuse W02 harness).
- [ ] **A06-T03** Running sessions stop with `goal_paused`; active leases end `goal_paused`; tasks back to `open`.
- [ ] **A06-T04** 20 sessions + 20 in-flight requests with 100 ms fake latency each → all stop signals issued within 5 s (parallel), summary counts correct.
- [ ] **A06-T05** Non-steward → 403 `not_steward`.
- [ ] **A06-T06** Resume → `active`; with outstanding shortfall → `paused(underfunded)` / `underfunded` per `on_underfunded`.
- [ ] **A06-T07** `stop_agent` by operator: tokens of all the agent's mandates revoked, its in-flight requests aborted, sessions stopped `agent_stopped`; goal status unchanged.
- [ ] **A06-T08** `stop_agent` by a steward holder of a goal where the agent has a mandate → OK; unrelated member → 403.
- [ ] **A06-T09** Expense pending approval, approved during pause → voided with `goal_paused`.
- [ ] **A06-T10** Events `goal.paused`, `goal.resumed`, `session.stopped` and audit rows written.

## Out of scope
UI controls (F08).
