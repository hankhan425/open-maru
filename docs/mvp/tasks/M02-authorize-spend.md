# M02 · Authorization service & spend flow

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Mandates | M01, L07, C04, G02 | L | 9 |

**Read first:** SPEC-04 §3, §5 (all); SPEC-03 §5.1, §6, `spend_records`; SPEC-02 §4.1 (spend exclusions); SPEC-07 §2.
**Paths:** `lib/openmaru/mandates/authorize.ex`, `lib/openmaru/spend/**`, migrations

## Goal
A single `authorize/4` used everywhere, and a `Spend` context that turns authorized requests into atomic ledger holds, approvals, posts, and voids with a spend record for each.

## Deliverables
- `Openmaru.Mandates.authorize(actor, action, target, context)` per SPEC-04 §5.1.
- Migration `spend_records`.
- `Openmaru.Spend`: `request/1`, `post/3`, `void/2`, `get/1`; atomic record + ledger writes via `Ledger.multi_create_transfers/3`.
- `spend` decision effect registered with C04 (all rule decisions must pass; re-authorize under the recorded spec version; then continue).
- Events `spend.held`, `spend.posted`, `spend.voided`, `spend.denied`.

## Tests to write first
- [ ] **M02-T01** Every case in `decide.json` produces the matching `authorize` result through real projection of the fixture IR.
- [ ] **M02-T02** Goal paused → Spend/ClaimTask/StartSession `goal_paused`; ReviewTask still allowed.
- [ ] **M02-T03** Goal closed → `goal_closed` for all actions.
- [ ] **M02-T04** Agent token whose mandate is no longer the active mandate for (goal, principal) → `mandate_revoked`.
- [ ] **M02-T05** Lapsed holder loses steward actions (effective holders from C03).
- [ ] **M02-T06** `request` allow → linked pending pair + `held` record; budget exhausted → `budget_exceeded` + `denied` record; goal funds exhausted → `goal_funds_insufficient`.
- [ ] **M02-T07** Requires approval with `wait_for_approval?: false` → `{:error, :approval_required}`, `denied` record with rule ids, no hold.
- [ ] **M02-T08** `wait_for_approval?: true` → hold + `pending_approval` + one decision per rule; all pass → `held` (then caller may post); any fail → void + `denied`.
- [ ] **M02-T09** `post` with actual ≤ held → `posted`; > held → `exceeds_hold`; repeated post idempotent; post after void → error; void idempotent.
- [ ] **M02-T10** Atomicity: forcing the record insert to fail leaves no ledger transfer (and vice versa).
- [ ] **M02-T11** Approval is evaluated under the spec version recorded at request time even if an amendment activates in between.
- [ ] **M02-T12** 20 concurrent $1 requests against $10 remaining → exactly 10 held.
- [ ] **M02-T13** Events emitted with public payloads (principal, category, amount, tier, reason) and no memo for denied requests.

## Out of scope
Gateway/runtime callers (W02, A05), expense API (G03).
