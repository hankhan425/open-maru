# G02 · Goal accounts, allocation, budgets

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Ledger | G01, C03 | L | 8 |

**Read first:** SPEC-03 §3, §5.1–§5.3, §2 (`goal_allocations`); SPEC-02 §3.3 (projection), §5.2; SPEC-07 `/goals/:id/budget`.
**Paths:** `lib/openmaru/ledger/flows/**`, `lib/openmaru/goals/funding.ex`, projection hook module, Oban workers, migrations

## Goal
Money reaches goals and mandates on schedule: goal accounts exist, periodic and one-time allocations run idempotently, shortfalls are tracked and topped up, and per-mandate period budgets reset and adjust correctly.

## Deliverables
- Projection hook `Openmaru.Ledger.ProjectionHook` (registered in config): creates goal accounts (300, 310 and 400×5) on adoption, budget accounts (500) per mandate category, allocation on adoption, budget regrant on mandate creation/change, zero-out on revocation.
- `Openmaru.Goals.Funding`: `period_key(period, datetime)`, `allocate_period/2`, `top_up/1` (called after any treasury credit), `period_funding/1` → `%{allocated, spent, held, available, shortfall}`.
- Migration `goal_allocations`.
- Oban cron every 5 min: allocations and budget grants for periods that have started (idempotent via deterministic ids).
- Callback to goal lifecycle: `Openmaru.Goals.transition/3` is called on shortfall/top-up if available (C06); until then a configurable no-op.
- `GET /goals/:id/budget`.
- **Own funds** (SPEC-03 §5.6): `Openmaru.Goals.Funding.contribute/3` and `POST /orgs/:slug/contributions {goal_id?, amount_micros, memo}` for administrators (`Orgs.administrators/1`). It writes code 5 from `org:<o>:ext_own` to the goal or treasury, then a top-up after a treasury credit, and emits `funds.contributed` (public, shown as `attested`). This is how a self-funded org gets money to spend; outside money comes later (P04).

## Tests to write first
- [ ] **G02-T01** Adoption creates goal accounts (300, 310, 400×5) with correct codes/flags; each mandate spend category gets a DMNEC budget account.
- [ ] **G02-T02** Adoption with `fund usd 12_000 / month`, treasury 20k → immediate allocation id `uuidv5("alloc:<g>:<pk>")`, goal funds 12k, `goal_allocations` row shortfall 0.
- [ ] **G02-T03** `fund … once` → `alloc:<g>:once`; subsequent periods allocate nothing.
- [ ] **G02-T04** Cron at 2026-10-01T00:00Z allocates each funded goal once; rerun → `:exists`, no change.
- [ ] **G02-T05** Treasury short (5k of 12k) → allocated 5k, shortfall 7k, lifecycle callback invoked with `allocation_short`.
- [ ] **G02-T06** Top-up after a 10k treasury credit covers shortfalls in adoption order; insufficient credit tops up partially; callback `topped_up` only when fully covered.
- [ ] **G02-T07** Period keys: month `1202609`; day `320260928`; ISO week edge cases: 2026-12-31 → `2202653`, 2027-01-01 → `2202653`, 2027-01-04 → `2202701`.
- [ ] **G02-T08** Budget grant at period start: reset (balancing) + grant = limit; rerun idempotent.
- [ ] **G02-T09** A hold placed before midnight survives the reset; after reset `available` = new limit; posting the old hold succeeds and counts in the old period.
- [ ] **G02-T10** Mid-period change after consuming 1,000: limit 4,000→6,000 → available 5,000; limit → 500 → available 0; ids include `:v<n>` so each version's regrant is distinct.
- [ ] **G02-T11** New spend category mid-period → account created and granted the full limit.
- [ ] **G02-T12** Revoked mandate → budget reset to 0 and no further grants.
- [ ] **G02-T13** `GET /goals/:id/budget` returns per mandate/category: limit, consumed (posted), held, available, period key, period end; money as strings + display.
- [ ] **G02-T14** `period_funding/1` equals ledger balances for a scenario with allocation, holds, and posts.
- [ ] **G02-T15** Own funds:
  - An administrator contributes $500 to the treasury → code-5 transfer from `ext_own`, treasury credited, shortfalls topped up, `funds.contributed`.
  - $200 to a goal → goal funds credited.
  - A non-administrator member → 403. Zero, fractional micros or a closed goal → 422.
  - Replaying the same contribution id → `:exists`.

## Out of scope
Spend holds (M02), donations (P02), goal state machine (C06).
