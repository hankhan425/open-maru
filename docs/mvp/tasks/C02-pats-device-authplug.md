# C02 · Personal access tokens, device login, API auth plug

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Core | C01 | M | 3 |

**Read first:** SPEC-09 §1 (PATs, device flow), SPEC-07 §1 (auth column), SPEC-04 §4 (token prefix only), CONVENTIONS §5.
**Paths:** `lib/openmaru/accounts/{pat,device}.ex`, `lib/openmaru_web/plugs/api_auth.ex`, controllers, migrations

## Goal
CLI and scripts authenticate with PATs obtained through a device flow; one plug resolves any credential into a `current_actor` and enforces which routes mandate tokens may reach.

## Deliverables
- Migrations `personal_access_tokens`, `device_codes`.
- `Openmaru.Accounts.PAT`: `create/2 → {:ok, plaintext, record}`, `verify/1`, `revoke/2`, `list/1`.
- Device flow endpoints (`/auth/device/code`, `/auth/device/token`, `/auth/device/approve`) with RFC 8628-style error codes in our envelope: `authorization_pending`, `slow_down`, `expired_token`, `access_denied`, `invalid_grant`.
- `OpenmaruWeb.Plugs.ApiAuth`: precedence Bearer header > session cookie. `om_pat_…` → person; `om_mt_…` → `Openmaru.Mandates.TokenVerifier` behaviour (default impl returns `{:error, :not_implemented}` until M01; Mox in tests). Assigns `current_actor`:
  - `{:person, %User{}}`, `{:agent, %Agent{}, claims}`, `{:person_mandate, %User{}, claims}`.
- Route pipeline flag `:mandate_ok` marking routes where mandate tokens are allowed (SPEC-07 **M**); mandate token elsewhere → 403 `forbidden`.
- `GET /api/v1/socket-token` → 5-minute signed token for Channels (`Phoenix.Token`), plus `verify_socket_token/1`.

## Tests to write first
- [ ] **C02-T01** `POST /me/tokens` returns `om_pat_…` once; DB stores SHA-256 hash and last4 only.
- [ ] **C02-T02** Bearer PAT authenticates `GET /me`; revoked → 401 `invalid_token`; expired (Clock) → 401.
- [ ] **C02-T03** `last_used_at` written at most once per minute (two calls within 60 s → one update).
- [ ] **C02-T04** `GET /me/tokens` lists name, last4, created, last used, expiry — never the token.
- [ ] **C02-T05** `POST /auth/device/code` → `device_code`, `user_code` (8 chars, alphabet `BCDFGHJKLMNPQRSTVWXZ23456789`, formatted `XXXX-XXXX`), `verification_uri`, `interval: 5`, `expires_in: 600`.
- [ ] **C02-T06** Polling before approval → `authorization_pending`; two polls < 5 s apart → `slow_down`.
- [ ] **C02-T07** Approval by a signed-in user → next poll returns a PAT named `CLI (<user agent>)`; a further poll → `invalid_grant`.
- [ ] **C02-T08** Expired code → `expired_token`; denied → `access_denied`; unknown user code on approve → 404.
- [ ] **C02-T09** Bearer header takes precedence over a valid session cookie.
- [ ] **C02-T10** `om_mt_` token (verifier mocked OK) on a `:mandate_ok` route → `current_actor` agent; on another route → 403 `forbidden`.
- [ ] **C02-T11** Malformed `Authorization` header, unknown prefix, or empty bearer → 401 `invalid_token`.
- [ ] **C02-T12** Socket token: valid within 5 min; expired or tampered → `{:error, :invalid}`.

## Out of scope
Mandate token minting/verification (M01), Channels (C05).
