# W01 · Goal secrets, provider endpoints & price catalog

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Gateway | C02, C03 | M | 8 |

**Read first:** SPEC-06 §1–§2; SPEC-05 §8.2 (honest meter); SPEC-09 §3, §5, §7; SPEC-07 secrets, public and admin rows.
**Paths:** `lib/openmaru/gateway/{secrets,endpoints,prices}.ex`, `lib/openmaru/vault.ex`, controllers, migrations

## Goal
Goals hold their own provider keys (BYOK), encrypted and write-only. The platform keeps the list of provider endpoints the gateway may reach, and the prices of each, so every metered call goes to a real provider at a known price.

## Deliverables
- `Openmaru.Vault` (Cloak, AES-256-GCM, key id tagging); migrations `goal_secrets`, `provider_endpoints` (seeded `anthropic` and `openai`), `goal_endpoints`, `model_prices`, `server_tool_prices` (both keyed by endpoint).
- `Openmaru.Gateway.Secrets`: `put/4` (authorize `ManageSecrets`), `delete/3`, `list/1`, `fetch!/2` (internal only).
- `Openmaru.Gateway.Endpoints`: `for_goal(goal, wire_format)` (the chosen endpoint, else the seeded one), `choose/4` (authorize `ManageSecrets`), admin CRUD.
- `Openmaru.Gateway.Prices`: `lookup(endpoint_id, model, at)`, `cost(tokens, price_per_mtok)`, admin CRUD.
- Endpoints for secrets, goal endpoints, `/public/provider-endpoints`, `/admin/provider-endpoints` and `/admin/prices`; audit rows for secret writes/deletes and endpoint choices.

## Tests to write first
- [ ] **W01-T01** Steward holder PUTs `anthropic_api_key` → ciphertext ≠ plaintext, decrypts back, `last4` stored; response contains no value.
- [ ] **W01-T02** Non-steward → 403 `not_steward`; unknown name (including `openai_base_url`) → 422.
- [ ] **W01-T03** List returns name, last4, updated_at, updated_by only.
- [ ] **W01-T04** DELETE removes; subsequent `fetch!` raises/returns `:not_found`.
- [ ] **W01-T05** Captured logs during PUT contain neither the value nor its prefix.
- [ ] **W01-T06** Key rotation: rows written with key A readable after adding key B as default; re-encrypt task rewrites them under B.
- [ ] **W01-T07** Admin price CRUD; non-admin → 403 `not_admin`; `lookup` picks the row effective at the given time, and the same model on two endpoints has two prices.
- [ ] **W01-T08** `cost/2` vectors: 1 token @ 3_000_000 → 3; 333_333 @ 3_000_000 → 999_999; 1 token @ 250_000 → 1 (ceil of 0.25); 0 tokens → 0.
- [ ] **W01-T09** Unknown model → `{:error, :model_not_priced}`.
- [ ] **W01-T10** Audit log rows for secret put/delete (without values).
- [ ] **W01-T11** Provider endpoints:
  - The seeds hold `anthropic` and `openai`. An admin adds an `openai_chat` endpoint; a non-admin → 403 `not_admin`; an `http://` base URL in `prod` → 422.
  - `GET /public/provider-endpoints` lists active endpoints only.
- [ ] **W01-T12** Goal endpoints:
  - Without a choice, `for_goal` returns the seeded endpoint of each format.
  - A steward holder chooses an active `openai_chat` endpoint → used from then on. An `anthropic_messages` endpoint for `openai_chat`, an inactive one or an unknown id → 422. A non-steward → 403.
  - Deactivating the chosen endpoint makes `for_goal` return `{:error, :endpoint_inactive}`.

## Out of scope
Using secrets in the proxy (W02/W03) and runtime (A05).
