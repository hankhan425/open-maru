# P03 · Stripe reconciliation

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Payments | P02 | S | 10 |

**Read first:** SPEC-05 §6; SPEC-03 §1 (ledger as mirror).
**Paths:** `lib/openmaru/payments/reconciliation.ex`, worker, migration, controller

## Goal
Prove daily that the ledger mirrors Stripe for every connected account; surface any mismatch without ever modifying the ledger.

## Deliverables
- Migration `reconciliation_runs`.
- Daily Oban job at 02:00 UTC per connected account, replaced accounts included (SPEC-05 §8.8); pagination over balance transactions; matching by charge/refund ids as SPEC-05 §6 says: a charge's gross against the sum of its inflow transfers (codes 1 and 8 for a donation, 6 and 7 for a pledge charge, which P04 adds), fees against codes 2–3, refunds against code 4.
- Alerts to administrators and platform admins; `GET /orgs/:slug/payments/reconciliation` (administrators).

## Tests to write first
- [ ] **P03-T01** Matching day → `ok`.
- [ ] **P03-T02** Stripe charge without a ledger donation → `mismatch` with `{charge_id, stripe_amount, ledger_amount: null}`.
- [ ] **P03-T03** Fee amount differs → `mismatch` detailing the fee.
- [ ] **P03-T04** Ledger donation without a Stripe counterpart → `mismatch`.
- [ ] **P03-T05** Stripe API error → `error` run, Oban retry; ledger `seq` unchanged in every case.
- [ ] **P03-T06** Mismatch creates administrator inbox alerts.
- [ ] **P03-T07** More than 100 balance transactions are paginated fully.
- [ ] **P03-T08** Endpoint visible to administrators only.
