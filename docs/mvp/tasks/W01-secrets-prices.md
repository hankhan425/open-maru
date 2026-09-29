# W01 · Goal secrets & price catalog

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Gateway | C02, C03 | M | 8 |

**Read first:** SPEC-06 §1–§2; SPEC-09 §3, §7; SPEC-07 secrets and admin rows.
**Paths:** `lib/openmaru/gateway/{secrets,prices}.ex`, `lib/openmaru/vault.ex`, controllers, migrations

## Goal
Goals hold their own provider keys (BYOK), encrypted and write-only; the platform maintains model prices used to meter every call.

## Deliverables
- `Openmaru.Vault` (Cloak, AES-256-GCM, key id tagging); migrations `goal_secrets`, `model_prices`, `server_tool_prices`.
- `Openmaru.Gateway.Secrets`: `put/4` (authorize `ManageSecrets`), `delete/3`, `list/1`, `fetch!/2` (internal only).
- `Openmaru.Gateway.Prices`: `lookup(provider, model, at)`, `cost(tokens, price_per_mtok)`, admin CRUD.
- Endpoints for secrets and `/admin/prices`; audit rows for secret writes/deletes.

## Tests to write first
- [ ] **W01-T01** Steward holder PUTs `anthropic_api_key` → ciphertext ≠ plaintext, decrypts back, `last4` stored; response contains no value.
- [ ] **W01-T02** Non-steward → 403 `not_steward`; unknown name → 422; `openai_base_url` must be `https://` → else 422.
- [ ] **W01-T03** List returns name, last4, updated_at, updated_by only.
- [ ] **W01-T04** DELETE removes; subsequent `fetch!` raises/returns `:not_found`.
- [ ] **W01-T05** Captured logs during PUT contain neither the value nor its prefix.
- [ ] **W01-T06** Key rotation: rows written with key A readable after adding key B as default; re-encrypt task rewrites them under B.
- [ ] **W01-T07** Admin price CRUD; non-admin → 403 `not_admin`; `lookup` picks the row effective at the given time.
- [ ] **W01-T08** `cost/2` vectors: 1 token @ 3_000_000 → 3; 333_333 @ 3_000_000 → 999_999; 1 token @ 250_000 → 1 (ceil of 0.25); 0 tokens → 0.
- [ ] **W01-T09** Unknown model → `{:error, :model_not_priced}`.
- [ ] **W01-T10** Audit log rows for secret put/delete (without values).

## Out of scope
Using secrets in the proxy (W02/W03) and runtime (A05).
