# M01 · Biscuit mandate tokens

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Mandates | T03, C02, C03 | L | 8 |

**Read first:** SPEC-04 §4 (all), §2.1 (IssueToken policies); SPEC-07 mandates/tokens rows; SPEC-09 §1–§3.
**Paths:** `crates/maru_token/**`, `crates/maru_nif/src/token.rs`, `lib/openmaru/mandates/tokens.ex`, controllers, migrations

## Goal
Agents prove their authority with attenuable, revocable Biscuit tokens minted by the platform for a specific mandate. Verification is fast and gives precise failure reasons.

## Deliverables
- Rust `maru_token`: `mint`, `attenuate` (only the four allowed check forms), `verify`, `revocation_ids`, `TokenError {Malformed, BadSignature, Revoked, Expired, CheckFailed(String)}`; `om_mt_` + base64url encoding.
- NIF functions `token_mint/2`, `token_verify/3`, `token_revocation_ids/1` (DirtyCpu).
- Migration `mandate_tokens`; `revoked_token_ids` lookup (set of revocation ids of revoked tokens).
- `Openmaru.Mandates.Tokens`: `issue(actor, mandate, opts)`, `revoke(actor, token_id)`, `verify(token, request_facts)` implementing the `TokenVerifier` behaviour from C02 (full verification order in SPEC-04 §4).
- Projection hook: revoked mandates revoke all their tokens.
- Endpoints: mint (token returned once), list, revoke, `GET /goals/:id/mandates`, `GET /public/token-key`.
- Root key from `OPENMARU_TOKEN_ROOT_KEY` (hex ed25519); dev/test generate one.

## Tests to write first
Rust:
- [ ] **M01-T01** mint → verify round-trip returns claims (token id, mandate, org, goal, principal, expiry).
- [ ] **M01-T02** Token signed by another root → `BadSignature`.
- [ ] **M01-T03** `time` after expiry → `Expired`.
- [ ] **M01-T04** Attenuated `operation ∈ [gateway]`: verify with `api` fails; with `gateway` passes.
- [ ] **M01-T05** Attenuated task binding: missing task fact fails; matching passes; other task fails.
- [ ] **M01-T06** Attenuated `request_amount ≤ N`: above N fails; at N passes.
- [ ] **M01-T07** Attenuated shorter expiry enforced; attenuating a *later* expiry doesn't extend validity.
- [ ] **M01-T08** `request_goal` ≠ token goal → `CheckFailed`.
- [ ] **M01-T09** Derived tokens share the authority revocation id; revoking it rejects all derivatives.
- [ ] **M01-T10** Wrong prefix / bad base64 / truncated bytes → `Malformed`.
- [ ] **M01-T11** `attenuate` rejects any check outside the four allowed forms.

Elixir:
- [ ] **M01-T12** Operator mints for builder → token shown once; row stored without the token; TTL default 30 d, capped at 90 d and at mandate `expires`; `mandate.token_issued` (members).
- [ ] **M01-T13** Non-operator → 403 `not_operator`; @jo mints for their own person mandate → OK.
- [ ] **M01-T14** Revoke → subsequent verify fails with `invalid_token` / `revoked`.
- [ ] **M01-T15** Mandate revoked by a new spec version → its tokens fail with `mandate_revoked`.
- [ ] **M01-T16** Auth plug with real verifier: token on an M route → `{:agent, agent, claims}`; non-M route → 403.
- [ ] **M01-T17** `last_used_at` updated at most once per minute.
- [ ] **M01-T18** `GET /public/token-key` returns the hex public key; `GET /goals/:id/mandates` lists mandates with IR terms.
- [ ] **M01-T19** Bench (`@tag :bench`): verify p95 < 1 ms.

## Out of scope
Using tokens for authorization decisions (M02), CLI attenuate command (A04).
