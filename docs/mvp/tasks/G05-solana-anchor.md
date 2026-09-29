# G05 · Solana checkpoint anchor (optional)

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Ledger | G04 | S | 13 |

**Read first:** SPEC-03 §7 (checkpoints, `anchor` column), PRD §6 (Out: crypto rails except anchoring).
**Paths:** `lib/openmaru/ledger/anchor/**`, optional Rust feature `anchor` in `maru_nif`

## Goal
Publish each daily `checkpoint_hash` in a Solana memo transaction so the ledger's history is timestamped outside openmaru's control. Optional for launch; must never block checkpoints.

## Deliverables
- `Openmaru.Ledger.Anchor` behaviour; `Noop` (default) and `Solana` adapters selected by config.
- Memo payload `openmaru:ckpt:<YYYY-MM-DD>:<checkpoint_hash_hex>`.
- Transaction build/sign in Rust (ed25519 + legacy transaction serialization with the Memo program) exposed via NIF; submission via JSON-RPC `sendTransaction` with `Req`; confirmation polling.
- Oban worker after each checkpoint; stores `{chain: "solana", cluster, signature, slot}` in `anchor`; public checkpoint JSON includes it with an explorer URL.

## Tests to write first
- [ ] **G05-T01** Default config uses `Noop`; checkpoint creation unaffected.
- [ ] **G05-T02** Memo payload format for a known checkpoint.
- [ ] **G05-T03** Transaction serialization for a fixed keypair, blockhash, and memo equals a committed vector generated with `@solana/web3.js` (script in `scripts/`).
- [ ] **G05-T04** JSON-RPC submit (Bypass) success → `anchor` stored; RPC error → Oban retry with backoff; checkpoint row otherwise untouched.
- [ ] **G05-T05** Public checkpoint includes `anchor.signature` and explorer URL when anchored, `null` otherwise.

## Out of scope
Wallets, tokens, any fund movement on-chain.
