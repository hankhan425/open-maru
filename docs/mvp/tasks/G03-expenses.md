# G03 · Expense claims & reimbursement records

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Ledger | M02, A02 | M | 11 |

**Read first:** SPEC-03 §6; SPEC-04 §5.2 (wait_for_approval path); SPEC-09 §4–§5; SPEC-07 spend rows.
**Paths:** `lib/openmaru/spend/expenses.ex`, controllers

## Goal
People (and agents, if a spec allows) claim expenses against a goal; claims go through mandates and approval rules, post with the right provenance tier, and reimbursement is recorded with proof.

## Deliverables
- `Openmaru.Spend.Expenses.claim(actor, goal, attrs)` → `Spend.request(category: :expense, source: :expense_claim, wait_for_approval?: true, hold_timeout_secs: 0)`; on allow posts immediately.
- Tier: `evidenced` when a stored `receipt` upload of the same org is attached, else `attested`.
- `mark_reimbursed(actor, spend, proof_upload)` for org administrators or steward holders.
- `POST /goals/:id/expenses` (201 posted, 202 pending approval with `decision_ids`), `GET /spend/:id` (public vs member fields), `POST /spend/:id/reimbursed`.

## Tests to write first
- [ ] **G03-T01** @jo claims $100 under lumen → 202, record `pending_approval`, hold placed, one decision (expense rule) with eligible [mina].
- [ ] **G03-T02** Decision passes → record `posted`, tier `attested`, ledger posted; `spend.posted` event.
- [ ] **G03-T03** With a stored receipt upload → tier `evidenced`; receipt from another org or wrong purpose → 422.
- [ ] **G03-T04** Decision fails or expires → hold voided, record `denied`, `spend.denied`.
- [ ] **G03-T05** $600 claim → two decisions; posts only after both pass; one fail voids.
- [ ] **G03-T06** Claim over remaining monthly budget → 402 `budget_exceeded`, record `denied`.
- [ ] **G03-T07** builder (no expense line) → 403 `category_not_permitted`.
- [ ] **G03-T08** Custom spec without an expense rule → 201 posted immediately.
- [ ] **G03-T09** Validation: amount > 0 and whole micros; memo required ≤ 500 chars; `task_id` must belong to the goal.
- [ ] **G03-T10** Mark reimbursed by administrator with proof → `reimbursed_at`; by an ordinary member → 403.
- [ ] **G03-T11** `GET /spend/:id`: anonymous sees amount/category/tier/memo/status; members additionally see receipt and proof presigned URLs.
- [ ] **G03-T12** Approval arrives while the goal is paused → re-authorization `goal_paused` → hold voided, `denied`.
- [ ] **G03-T13** Agent mandate token with an expense line (custom spec) can claim via M route.

## Out of scope
Paying reimbursements (off-platform by design), UI (F05/F06).
