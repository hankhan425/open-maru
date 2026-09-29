# G04 · Checkpoints & public ledger APIs

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Ledger | G03 | M | 12 |

**Read first:** SPEC-03 §7, §9; SPEC-07 public read models; SPEC-09 §4.
**Paths:** `lib/openmaru/ledger/checkpoints.ex`, `lib/openmaru/public/**`, controllers

## Goal
Anyone can see where every cent of a goal went and independently verify the ledger's integrity from public endpoints.

## Deliverables
- Daily checkpoint job (00:05 UTC) per SPEC-03 §7; `verify_checkpoints/0`.
- `Openmaru.Public`: `goal_summary/1`, `goal_ledger/2`, `checkpoints/1`, `transfers_range/2`.
- Endpoints `/public/goals/:id/summary`, `/public/goals/:id/ledger`, `/public/ledger/checkpoints`, `/public/ledger/transfers`.
- Cache headers + ETags. Broadcast `ledger` events on `public:goal:<id>` when spend posts/voids or donations arrive (subscribe to activity).

## Tests to write first
- [ ] **G04-T01** Checkpoint for a day with transfers: first/last seq, count, head hash, `checkpoint_hash` per spec; rerun idempotent.
- [ ] **G04-T02** Empty day → count 0, head hash carried from the previous checkpoint.
- [ ] **G04-T03** `prev_checkpoint_hash` links the chain; `verify_checkpoints` detects an altered checkpoint.
- [ ] **G04-T04** `/public/ledger/transfers?from_seq&to_seq` returns every hashed field plus account keys; range > 10,000 → 400.
- [ ] **G04-T05** A test verifier using only the JSON from public endpoints recomputes the chain and checkpoints successfully (mirrors what `maru ledger verify` does).
- [ ] **G04-T06** Summary: current period funding; totals by category, tier, and source; 90-day series zero-filled.
- [ ] **G04-T07** Ledger entries: SPEC-03 §9 fields, newest first, cursor pagination; never includes receipt/proof URLs or donor identity.
- [ ] **G04-T08** Property: after random spends, donations, and refunds, summary totals equal the underlying account balances.
- [ ] **G04-T09** `Cache-Control: public, max-age=10` + ETag on summary/ledger (304 on match); checkpoints `max-age=3600`.
- [ ] **G04-T10** Posting a spend pushes a `ledger` event on `public:goal:<id>`.

## Out of scope
Anchoring (G05), CLI verifier (A04), UI (F06).
