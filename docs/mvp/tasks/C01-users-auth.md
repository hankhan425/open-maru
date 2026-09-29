# C01 · Users & authentication

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Core | T02 | L | 2 |

**Read first:** SPEC-02 §2 (users, passkeys, oauth_identities, user_sessions), SPEC-09 §1, §6, §7; SPEC-07 §1 "Auth & account".
**Paths:** `lib/openmaru/accounts/**`, `lib/openmaru_web/controllers/auth/**`, `lib/openmaru_web/plugs/{session,csrf}.ex`, migrations

## Goal
People can sign up and sign in with passkeys, GitHub, or Google, pick an immutable handle, and hold a secure web session.

## Deliverables
- Migrations: `users`, `passkeys`, `oauth_identities`, `user_sessions`, `audit_log` (append-only trigger; H02 extends usage).
- `Openmaru.Accounts`: `begin_passkey_registration/1`, `finish_passkey_registration/2`, `begin_passkey_login/0`, `finish_passkey_login/1`, `oauth_callback/3`, `set_handle/2`, `create_session/1`, `get_session_user/1`, `revoke_session/1`.
- WebAuthn via `wax_` (rp id from config; user verification required; challenges stored server-side, 5-minute TTL, single use).
- OAuth via `assent` (GitHub, Google), state/nonce protection; linking rule per SPEC-09 §1.
- Session plug (cookie `_om_session`, `HttpOnly; Secure; SameSite=Lax`, 30-day sliding), CSRF plug (`x-csrf-token` required on mutating cookie-authenticated requests; token from `GET /api/v1/auth/csrf`).
- Handle rules: `^[a-z0-9][a-z0-9_-]{1,29}$`, case-insensitive unique, reserved list (`admin api app auth help mcp openmaru root settings support system www gw`), **immutable once set**.
- Hammer limit 10/min/IP on auth endpoints. Audit entries for sign-in success/failure.
- A test helper `Openmaru.Test.FakeAuthenticator` producing valid WebAuthn attestations/assertions for tests.

## Tests to write first
- [ ] **C01-T01** Registration options: rp id/name set, random 32-byte user handle, `userVerification: "required"`, challenge persisted.
- [ ] **C01-T02** Valid attestation (fake authenticator) → user created with `handle: nil`, passkey stored, session cookie set.
- [ ] **C01-T03** Replayed or expired (> 5 min, Clock) challenge → 400 `invalid_request`.
- [ ] **C01-T04** Login with valid assertion → session cookie with correct attributes; `sign_count` and `last_used_at` updated.
- [ ] **C01-T05** Assertion with sign-count regression → 401 and an audit row `passkey.sign_count_regression`.
- [ ] **C01-T06** Unknown credential id → 401 `unauthenticated`.
- [ ] **C01-T07** OAuth GitHub (provider stubbed with Bypass): new identity → new user; same identity again → same user.
- [ ] **C01-T08** OAuth, not signed in, provider email equals an existing user's email → no linking, 409 `account_exists` (redirect with that error for browser flow).
- [ ] **C01-T09** OAuth while signed in with a provider-verified email → identity linked to the current user.
- [ ] **C01-T10** `PATCH /me {handle}`: valid handle set; invalid pattern → 422; reserved → 422; taken (case-insensitive) → 409 `handle_taken`.
- [ ] **C01-T11** Changing an already-set handle → 422 `invalid_request` (`handle_immutable` in details).
- [ ] **C01-T12** `GET /me` without session → 401 `unauthenticated`; with session → user JSON (no email for other users; own email included).
- [ ] **C01-T13** Logout revokes the session; reusing the cookie → 401.
- [ ] **C01-T14** Sliding expiry (Clock): activity on day 29 extends; 31 idle days → 401.
- [ ] **C01-T15** Suspended user: sign-in → 403 `forbidden`; existing sessions rejected.
- [ ] **C01-T16** CSRF: cookie-authenticated POST without/with wrong `x-csrf-token` → 403; with correct token → OK; GET unaffected.
- [ ] **C01-T17** 11th auth request in a minute from one IP → 429 `rate_limited`.
- [ ] **C01-T18** `audit_log` rejects UPDATE/DELETE (trigger); sign-in success and failure rows written with hashed IP.

## Out of scope
PATs and device flow (C02), web UI (F01).
