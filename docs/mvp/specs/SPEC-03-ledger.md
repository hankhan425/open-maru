# SPEC-03 — Ledger, budgets, spend records

## 1. Principles

- Double-entry, single asset in MVP: **ledger 1 = USD in micro-dollars** (1 USD = 1_000_000).
- Modeled on TigerBeetle (ADR-1): two tables (accounts, transfers), fixed fields, integer amounts, immutable transfers, client-generated IDs, two-phase transfers, linked chains, balance-constraint flags, balancing transfers. Only `Openmaru.Ledger` touches these tables.
- The ledger is an **earmarking and accounting mirror**. Real money sits in the org's Stripe account (ADR-2). Reconciliation (SPEC-05 §6) proves the mirror matches.
- Descriptive metadata (memos, models, receipts) lives in `spend_records` and other control-plane tables keyed by transfer IDs, never in ledger rows.

## 2. Tables

### `ledger_accounts`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid | client-generated |
| `key` | text unique | human key, e.g. `goal:<uuid>:funds` |
| `ledger` | int | 1 |
| `code` | int | account kind (§3) |
| `flags` | int | bit 0 `debits_must_not_exceed_credits` (DMNEC), bit 1 `credits_must_not_exceed_debits` |
| `debits_pending`, `debits_posted`, `credits_pending`, `credits_posted` | bigint | ≥ 0, maintained by `create_transfers` |
| `inserted_at` | timestamptz | |

Trigger: rows cannot be deleted; only the four balance columns may be updated.

### `ledger_transfers`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid | client-generated; idempotency key |
| `debit_account_id`, `credit_account_id` | uuid | |
| `amount` | bigint | > 0 except post/void rules (§4.3); for balancing transfers, the *actual* amount moved |
| `requested_amount` | bigint | for balancing transfers, the requested maximum; else = amount |
| `pending_id` | uuid null | set on post/void |
| `flags` | int | bit 0 `linked`, 1 `pending`, 2 `post_pending`, 3 `void_pending`, 4 `balancing_debit`, 5 `balancing_credit` |
| `timeout_secs` | int | pending only; 0 = never |
| `ledger`, `code` | int | ledger is taken from the accounts (not an input); code = purpose (§3) |
| `user_data_128` | uuid null | reference (spend record, donation, allocation) |
| `user_data_64` | bigint null | period key (§5.2) |
| `timestamp` | bigint | server-assigned µs since epoch, strictly increasing |
| `seq` | bigint unique | chain position, gapless from 1 |
| `prev_hash`, `hash` | bytea(32) | §7 |

Triggers reject UPDATE and DELETE. A partial unique index on `pending_id` (for rows with post/void flags) guarantees a pending transfer resolves at most once.

### `ledger_pending_expiries`
`pending_id` (PK), `expires_at` (bigint µs = pending `timestamp` + `timeout_secs` × 10⁶). Derived index for the expiry sweeper (§4.3): a row is written with each pending transfer that has a timeout and deleted when that transfer resolves, so the sweeper never scans resolved history. Not part of the hash chain; rebuildable from `ledger_transfers`.

### `ledger_checkpoints`
`date` (unique), `first_seq`, `last_seq`, `count`, `head_hash`, `prev_checkpoint_hash`, `checkpoint_hash`, `anchor` jsonb null (G05). A trigger rejects UPDATE, DELETE and TRUNCATE, except setting `anchor` once while it is null.

### `goal_allocations`
`goal_id`, `period_key`, `requested_micros`, `allocated_micros`, `shortfall_micros`; unique(`goal_id`,`period_key`).

### `spend_records` (owned by `Openmaru.Spend`)
`org_id`, `goal_id`, `mandate_id null`, `principal_*`, `category` (`llm/compute/expense/fee_stripe/fee_platform`), `source` (`gateway/runtime/expense_claim/stripe`), `tier` (`verified/evidenced/attested`), `status` (`pending_approval/held/posted/voided/denied`), `requested_micros`, `held_micros`, `posted_micros`, `hold_transfer_ids uuid[]`, `resolve_transfer_ids uuid[]`, `decision_id null`, `task_id null`, `session_id null`, `memo` (≤500), `meta jsonb`, `receipt_upload_id null`, `reimbursed_at null`, `reimbursement_proof_upload_id null`, `posted_at null`.

## 3. Account and transfer codes

| Account code | Key pattern | Flags | Purpose |
|---|---|---|---|
| 100 | `org:<id>:ext_donations` | none | Source of donations (goes debit-heavy) |
| 110 | `org:<id>:ext_refunds` | none | Sink for refunds |
| 200 | `org:<id>:treasury` | DMNEC | Unearmarked funds |
| 210 | `org:<id>:fees_stripe`, `org:<id>:fees_platform` | none | Fees on treasury donations |
| 300 | `goal:<id>:funds` | DMNEC | Goal's available funds |
| 400 | `goal:<id>:spend:<category>` for `llm, compute, expense, fees_stripe, fees_platform` | none | Consumption sinks |
| 500 | `mandate:<id>:budget:<category>` | DMNEC | Period allowance |
| 600 | `system:allowance_source` | none | Source of allowance grants |
| 610 | `system:allowance_sink` | none | Sink of consumed/reset allowance |

Accounts are created with their owner: org creation creates 100, 110, 200, 210×2; goal adoption creates 300 and 400×5; mandate creation creates one 500 per spend category (new categories later create new accounts). System accounts are created by a migration, with id = `uuidv5(key)` (`13a8b848-795e-5365-8aab-dcb51235c51d` for 600, `3dd63a3b-7c4c-520f-ae03-92e4f528ac2a` for 610).

`create_accounts/1` returns one result per account, like `create_transfers/1`: `{:ok, :created}`, `{:ok, :exists}` (same id, identical `key`, `ledger`, `code`, `flags`), or `{:error, code}` checked in this order: `id_must_not_be_zero` · `exists_with_different_fields` · `flags_are_mutually_exclusive` (both balance flags) · `ledger_must_not_be_zero` · `code_must_not_be_zero` · `key_must_not_be_empty` · `key_exists` (another id holds the key).

| Transfer code | Meaning |
|---|---|
| 1 donation · 2 fee_stripe · 3 fee_platform · 4 refund | Stripe flows |
| 10 allocation · 11 close_disposition | Treasury ↔ goal |
| 20 spend_llm · 21 spend_compute · 22 spend_expense | Goal consumption |
| 30 budget_grant · 31 budget_consume · 32 budget_reset | Allowance |

## 4. `create_transfers/1` semantics

Input: list of transfer maps. Output: list of `{:ok, :created | :exists}` or `{:error, code}` in input order. One DB transaction per call.

### 4.1 Ordering and locking
All ledger writes (`create_accounts` included) take `pg_advisory_xact_lock(<ledger constant>)` (`0x6F6D4C4544474552`, "omLEDGER") as their first statement, under READ COMMITTED. This serializes writes, gives a total order for `seq`/`timestamp`/hash chain, and removes deadlock risk. A row's `timestamp` is `max(Clock µs, previous timestamp + 1)`; failed transfers consume no `seq` or timestamp. Target ≥ 1,000 linked pairs/s (ARCHITECTURE §7).

### 4.2 Validation (checked in this order; first failure wins)
`id_must_not_be_zero` (null or all-zero id) · `exists` (same id and identical fields → `{:ok, :exists}`, no effect) · `exists_with_different_fields` · shape checks: `flags_are_mutually_exclusive` (post with void; post or void with pending or balancing), `pending_id_must_not_be_zero` and `pending_id_must_be_different` (post/void), `pending_id_must_be_zero` (others), `code_must_not_be_zero` · `accounts_must_be_different` · `debit_account_not_found` · `credit_account_not_found` · `accounts_must_have_the_same_ledger` · `amount_must_not_be_zero` (except post: see below) · `timeout_reserved_for_pending_transfer` · pending-specific checks (post/void: `pending_transfer_not_found` · `pending_transfer_not_pending` · `pending_transfer_has_different_debit_account_id` · `pending_transfer_has_different_credit_account_id` · `pending_transfer_has_different_code` · `exceeds_pending_transfer_amount` (post) · `pending_transfer_has_different_amount` (void) · `pending_transfer_already_posted` · `pending_transfer_already_voided` · `pending_transfer_expired`) · `overflows` (a balance, or pending + posted on one side, above 2^63 − 1) · `exceeds_credits` (debit account DMNEC: `debits_pending + debits_posted + amount > credits_posted`) · `exceeds_debits` (credit account CMNED, symmetric).

For `exists`, omitted post/void fields compare as their values taken from the pending transfer, and a balancing transfer compares its request with `requested_amount`. Malformed input (a non-UUID id, an unknown flag, a negative or out-of-range integer, an unknown field) is a programming error and raises instead of returning a code.

### 4.3 Two-phase
- **Pending** (`pending` flag): increments `debits_pending`/`credits_pending`. `timeout_secs > 0` sets an expiry.
- **Post** (`post_pending`, `pending_id`): `amount` null or omitted ⇒ full pending amount; otherwise must be ≤ pending amount (`exceeds_pending_transfer_amount`). Moves the pending amount out of pending balances and adds the posted amount to posted balances. Debit/credit accounts and `code` may be omitted (taken from the pending transfer); if given they must match (`pending_transfer_has_different_debit_account_id`, `…_credit_account_id`, `…_code`). Omitted `user_data_128`/`user_data_64` are also taken from the pending transfer; given ones replace them. An `amount` of 0 is allowed and releases the hold without posting.
- **Void** (`void_pending`, `pending_id`): releases the full pending amount; `amount` must be null or equal (`pending_transfer_has_different_amount`).
- Errors: `pending_transfer_not_found`, `pending_transfer_not_pending` (not a pending transfer), `pending_transfer_already_posted`, `pending_transfer_already_voided`, `pending_transfer_expired`.
- Expiry: a pending transfer expires once `timestamp + timeout_secs × 10⁶ ≤` the resolving transfer's timestamp. From then on posts and voids get `pending_transfer_expired` (also after the sweep), and only the sweeper resolves it: Oban, every 30 s (a minute cron plus a follow-up 30 s later), voids expired pending transfers with deterministic IDs `uuidv5("expire:<pending_id>")` and `user_data_64 = -1`; a rerun is a no-op.

### 4.4 Linked chains
A transfer with `linked` is atomic with the next one; a chain ends at the first transfer without `linked`. If any transfer in a chain fails, none apply: the failing transfer gets its code, the others get `linked_event_failed`. A batch ending with an open chain → every transfer of that chain gets `linked_event_chain_open`, without being evaluated. An `exists` member counts as success (a replayed chain returns `exists` for every member). Members after a failing one are not evaluated.

### 4.5 Balancing transfers
`balancing_debit`: actual amount = `min(requested, debit available)` where available = `credits_posted − debits_posted − debits_pending`. `balancing_credit` symmetric. Actual may be 0 (allowed only for balancing). Stored in `amount`; request in `requested_amount`.

### 4.6 Lookups
`lookup_accounts(ids)`, `lookup_transfers(ids)` (input order; unknown ids skipped), `account_transfers(account_id, filter)` (either side, by `seq`; filters `code` (one or list), `period_key`, `from` inclusive / `to` exclusive, `order`, `limit` 1–1000 (default 100), opaque `cursor`; returns `{:ok, %{data, next_cursor}}`), `balance(account_id)` → `%{debits_pending, debits_posted, credits_pending, credits_posted, available}` (available as in §4.5 on the debit side; for CMNED accounts `debits_posted − credits_posted − credits_pending`). `verify_chain(from_seq, to_seq)` → `:ok | {:error, {:hash_mismatch | :seq_gap, seq}}`; `verify_balances()` → `:ok | {:error, [{account_id, expected, actual}]}`.

## 5. Flows (exact transfer patterns)

`uuidv5(x)` means UUIDv5 in the openmaru namespace `7075e138-6378-557c-ad88-8dd8ed95be90` (= UUIDv5 of `https://openmaru.org/` in the RFC 9562 URL namespace); deterministic IDs make scheduled and webhook-driven transfers idempotent. `apps/server/test/fixtures/ledger_vectors.json` lists reference values.

### 5.1 Spend (hold → post/void)
Hold (linked pair, both `pending`, timeout 900 s for gateway, 120 s for runtime ticks, 0 for decisions):
1. `mandate:<m>:budget:<cat>` → `system:allowance_sink`, code 31, `user_data_64 = period_key`, `linked`
2. `goal:<g>:funds` → `goal:<g>:spend:<cat>`, code 20/21/22, `user_data_128 = spend_record_id`

Error mapping: (1) `exceeds_credits` → `budget_exceeded`; (2) `exceeds_credits` → `goal_funds_insufficient`.
Post: linked pair of `post_pending` with the actual amount (≤ held). Void: linked pair of `void_pending`.

### 5.2 Period keys and budget grants
Period key (`user_data_64`): month `1YYYYMM`, ISO week `2YYYYWW`, day `3YYYYMMDD` (e.g. `1202609`, `2202640`, `320260928`).
At each period start for each active mandate and spend line (Oban cron every 5 min; idempotent by ID):
1. reset: `budget` → `allowance_sink`, `balancing_debit`, requested = i64 max, code 32, id `uuidv5("reset:<m>:<cat>:<pk>")`, `linked`
2. grant: `allowance_source` → `budget`, amount = limit, code 30, id `uuidv5("grant:<m>:<cat>:<pk>")`
Pending holds from the previous period stay reserved and post against it.
On mandate creation or limit change mid-period: reset, then grant `max(new_limit − consumed_this_period, 0)` where consumed = posted + pending code-31 debits with the current period key (IDs include the spec version: `uuidv5("grant:<m>:<cat>:<pk>:v<n>")`).

### 5.3 Goal funding
- Adoption (`fund … / period`): allocate the full amount for the current period immediately. Adoption (`once`): allocate once, id `uuidv5("alloc:<g>:once")`.
- Period start: `treasury` → `goal:<g>:funds`, `balancing_debit`, requested = fund, code 10, id `uuidv5("alloc:<g>:<pk>")`. Write `goal_allocations` with shortfall = requested − actual. Shortfall > 0 triggers the goal's `on_underfunded` transition (SPEC-02 §5.2).
- Top-up: after any credit to a treasury, for goals of that org with shortfall > 0 in their current period, ordered by adoption time: balancing transfer for the shortfall; update the allocation row; fully covered goals return to `active`.

### 5.4 Closing a goal
After voiding holds: `goal:<g>:funds` → `org:<o>:treasury` (or `goal:<other>:funds` for `transfer`), `balancing_debit`, requested = i64 max, code 11, id `uuidv5("close:<g>")`.

### 5.5 Donations, fees, refunds
See SPEC-05 §4. Linked chain: `ext_donations` → destination (goal funds or treasury), code 1, gross; destination → fee account, code 2; destination → fee account, code 3. IDs `uuidv5("donation:<charge_id>")`, `uuidv5("fee_stripe:<charge_id>")`, `uuidv5("fee_platform:<charge_id>")`. Refund: destination → `ext_refunds`, code 4, id `uuidv5("refund:<refund_id>")`; if it fails with `exceeds_credits`, retry from treasury; if that fails, mark the donation `refund_unfunded` and alert stewards.

## 6. Spend records and provenance

`Openmaru.Spend` owns the lifecycle and always writes the spend record and its ledger transfers in one `Ecto.Multi`.

| Source | Tier | Meta |
|---|---|---|
| gateway | verified | provider, model, input/output/cache tokens, provider request id, `estimated` bool |
| runtime | verified | session id, seconds, rate |
| stripe fees | verified | charge id |
| expense_claim with receipt | evidenced | receipt upload id |
| expense_claim without receipt | attested | — |

Status transitions: `pending_approval → held | denied`; `held → posted | voided`. Reimbursement of expenses happens off-platform; `mark_reimbursed(spend, proof_upload)` records it (members only).

## 7. Hash chain and checkpoints

- Each transfer row gets `seq` (previous + 1) and `hash = SHA-256(prev_hash ‖ encode(transfer))`, genesis `prev_hash` = 32 zero bytes.
- `encode` is fixed-width big-endian, in this order: `id`(16) `debit_account_id`(16) `credit_account_id`(16) `amount`(i64) `requested_amount`(i64) `pending_id`(16, zeros if null) `flags`(u32) `timeout_secs`(u32) `ledger`(u32) `code`(u32) `user_data_128`(16, zeros if null) `user_data_64`(i64, 0 if null) `timestamp`(i64) `seq`(i64). The Rust CLI implements the same encoding for independent verification.
- Daily checkpoint at 00:05 UTC for the previous UTC day: `checkpoint_hash = SHA-256(date_ascii ‖ last_seq(i64) ‖ head_hash ‖ prev_checkpoint_hash)`. Empty days still get a checkpoint (count 0, same head hash).
- `verify_chain(from_seq, to_seq)` and `verify_balances()` detect tampering and drift.
- Public endpoints (SPEC-07) expose checkpoints and transfers by seq range with account keys, so anyone can recompute.

## 8. Invariants (property-tested)

1. Every account's balances equal the sums of its transfers.
2. Σ over all accounts of `credits_posted − debits_posted` = 0; same for pending.
3. DMNEC accounts never exceed: `debits_pending + debits_posted ≤ credits_posted`.
4. A pending transfer resolves (post, void, or expiry) at most once.
5. Replaying any batch returns `exists` for every transfer and changes nothing.
6. The chain verifies from seq 1; checkpoints verify from the first.

## 9. Public read models

Per goal: current period `{allocated, held, spent, available, shortfall}`; totals by category, tier, and source; daily series (90 days); paginated entries `{spend_id, occurred_at, principal, category, tier, amount, memo, model/tokens, task link}`. Receipts, reimbursement proofs, and donor identities are never public.
