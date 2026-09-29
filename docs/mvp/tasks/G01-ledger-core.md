# G01 · Ledger core

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Ledger | T02 | L | 2 |

**Read first:** SPEC-03 §1–§4, §7, §8 (all); ARCHITECTURE ADR-1.
**Paths:** `lib/openmaru/ledger/**`, migrations, `test/openmaru/ledger/**`, `test/fixtures/ledger_vectors.json`, `scripts/ledger_vector.py`

## Goal
A TigerBeetle-shaped double-entry ledger in Postgres: immutable transfers, two-phase, linked chains, balance constraints, balancing transfers, idempotency, and a verifiable hash chain. Correctness is proven with property tests.

## Deliverables
- Migrations `ledger_accounts`, `ledger_transfers`, `ledger_checkpoints` (table only; job in G04), immutability triggers, partial unique index on `pending_id`, system accounts 600/610.
- `Openmaru.Ledger`: `create_accounts/1`, `create_transfers/1`, `multi_create_transfers(multi, name, transfers)` (for atomic use by other contexts), `lookup_accounts/1`, `lookup_transfers/1`, `account_transfers/2`, `balance/1`, `verify_chain/2`, `verify_balances/0`, `uuidv5/1` (openmaru namespace constant).
- Advisory-lock serialization; strictly increasing µs timestamps; gapless `seq`; hash per SPEC-03 §7.
- Pending-expiry sweeper (Oban, every 30 s).
- `scripts/ledger_vector.py`: independent implementation of the §7 encoding (stdlib only) that generates `ledger_vectors.json` (3+ transfers incl. a pending/post pair, with expected hashes). Also used by A04.

## Interfaces
```elixir
@type transfer :: %{id: Ecto.UUID.t(), debit_account_id: uuid | nil, credit_account_id: uuid | nil,
  amount: non_neg_integer | nil, pending_id: uuid | nil, flags: [:linked | :pending | :post_pending |
  :void_pending | :balancing_debit | :balancing_credit], timeout_secs: non_neg_integer, code: pos_integer,
  user_data_128: uuid | nil, user_data_64: integer | nil}
@spec create_transfers([transfer]) :: [{:ok, :created | :exists} | {:error, atom}]
```

## Tests to write first
- [ ] **G01-T01** `create_accounts`: flags and codes stored; same id + same fields → `:exists`; different fields → `exists_with_different_fields`.
- [ ] **G01-T02** Simple transfer updates `debits_posted`/`credits_posted` on both accounts.
- [ ] **G01-T03** Validation order (table-driven): for each pair of simultaneous violations, the earlier code in SPEC-03 §4.2 wins.
- [ ] **G01-T04** DMNEC violation → `exceeds_credits`; no balance changes, no row, no seq consumed.
- [ ] **G01-T05** Idempotency: the same batch twice → second returns `:exists` for all; balances unchanged.
- [ ] **G01-T06** Pending increments pending balances and counts toward DMNEC for later transfers.
- [ ] **G01-T07** Post full (amount nil) and partial; post above pending → `exceeds_pending_transfer_amount`.
- [ ] **G01-T08** Void releases the full amount; void with a different amount → `pending_transfer_has_different_amount`.
- [ ] **G01-T09** Double resolution: post→post `pending_transfer_already_posted`; post→void same; void→post `pending_transfer_already_voided`; post on a non-pending transfer → `pending_transfer_not_pending`.
- [ ] **G01-T10** Expiry (Clock): post after timeout → `pending_transfer_expired`; sweeper voids with id `uuidv5("expire:<pending_id>")`, `user_data_64 = -1`; sweeper rerun is a no-op.
- [ ] **G01-T11** Linked chain all-or-nothing; failing member gets its code, others `linked_event_failed`; open chain at batch end → `linked_event_chain_open` for its members; independent transfers in the same batch still apply.
- [ ] **G01-T12** Balancing debit: requested 100, available 60 → amount 60, `requested_amount` 100; available 0 → amount 0 accepted; pending debits reduce availability.
- [ ] **G01-T13** Overflow near i64 max → `overflows`.
- [ ] **G01-T14** Raw SQL UPDATE/DELETE on transfers raise; UPDATE of account `flags`/`code`/`key` raises; balance columns updatable.
- [ ] **G01-T15** Hash chain: `seq` gapless from 1; hashes equal `ledger_vectors.json` produced by `scripts/ledger_vector.py`.
- [ ] **G01-T16** `verify_chain` detects a tampered amount (trigger disabled in test) → `{:error, {:hash_mismatch, seq}}`.
- [ ] **G01-T17** `verify_balances` detects a drifted balance column → `{:error, [{account_id, expected, actual}]}`.
- [ ] **G01-T18** Concurrency: 50 tasks each moving 1 unit from a DMNEC account holding 25 → exactly 25 `:created`; `seq` gapless; balances consistent.
- [ ] **G01-T19** Property (StreamData): random sequences of creates, pendings, posts, voids, expiries, balancing and linked batches uphold SPEC-03 §8 invariants 1–5.
- [ ] **G01-T20** Timestamps strictly increase even when the Clock returns the same instant repeatedly.
- [ ] **G01-T21** `balance/1` computes `available`; `account_transfers/2` filters by code, period key, and time range with cursor pagination.
- [ ] **G01-T22** Bench (`@tag :bench`, excluded by default): 10k linked pairs; logs throughput; CI bench job reports it.

## Out of scope
Business flows (G02+), checkpoints job and public APIs (G04).
