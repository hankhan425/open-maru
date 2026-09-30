# SPEC-09 — Security, privacy, abuse

## 1. Authentication
- Passkeys (WebAuthn, `wax_`): discoverable credentials, user verification required, `none` attestation; challenges stored server-side (5 minutes, single use). Sign-count regression rejects the assertion: the counter must increase unless both the stored and the reported value are 0 (authenticators without a counter).
- OAuth (GitHub, Google) via `assent`, with `state` (and the OIDC `nonce` for Google) stored server-side for 5 minutes and bound to the browser by a cookie. Account linking only when the email is verified by the provider **and** the user is signed in. Signed out, a provider email that belongs to an existing user is refused with `account_exists` (no linking); a new user keeps the provider email only if verified.
- Web sessions: opaque random token (32 bytes) in an `HttpOnly; Secure; SameSite=Lax` cookie; stored hashed; 30-day sliding expiry (moved at most hourly); revocable. A suspended user's sessions are rejected with 403 `forbidden`. Cookie-authenticated mutating requests require `x-csrf-token` (from `GET /api/v1/auth/csrf`, bound to the session).
- PATs: `om_pat_` + 32 random bytes base64url; stored as SHA-256; shown once; optional expiry; `last_used_at` updated at most once per minute.
- Device flow: `user_code` 8 chars from an unambiguous alphabet, 10-minute expiry, polling interval 5 s (`slow_down` if faster), single use.
- Mandate tokens: SPEC-04 §4.

## 2. Authorization
- Governance/goal actions: Cedar via `Mandates.authorize` (SPEC-04). Org administration: administrators (SPEC-05 §2). Platform admin: `platform_role = admin`.
- Every controller action has an authorization test (allowed + denied) — enforced in code review.
- Mandate tokens can reach only: gateway routes, `/mcp`, and the API routes marked **M** in SPEC-07.

## 3. Secrets
- Goal secrets and Stripe/webhook secrets encrypted at rest (Cloak, AES-256-GCM); keys from env; rotation supported via key IDs.
- Never logged, never returned after write, never included in error messages or telemetry. Log scrubbing covers headers `authorization`, `x-api-key`, `cookie`, and fields named `*token*`, `*secret*`, `*key*`, `value` (secrets API).
- Prompts and completions passing through the gateway are never stored. Only usage metadata is.

## 4. Privacy
| Data | Visibility |
|---|---|
| Specs, charters, versions, decisions, ballots (who voted how) | public |
| Goals, tasks, evidence URLs/summaries, ledger entries, activity | public |
| Receipts, reimbursement proofs, file evidence marked private | members only (presigned GET, 5-minute expiry) |
| Donor identity | private unless the donor opts in (display name only) |
| Emails | private; never in public payloads |
| Mandate token metadata | members only |

Account deletion: removes PII (email, OAuth identities, passkeys, display name → `deleted-user-<n>`); ledger, votes, and activity remain with the pseudonymous handle (immutable history).

## 5. Uploads
Presigned PUT to private bucket; max 10 MB; allowed types: `application/pdf`, `image/png`, `image/jpeg`, `image/webp`, `text/plain`; SHA-256 verified on `complete`; object keys are random; no server-side fetching of user-provided URLs (no SSRF surface).

## 6. Abuse and limits
- Rate limits (Hammer): auth 10/min/IP; spec check 60/min/IP; checkout 10/min/IP; API 600/min/principal; gateway 600/min/mandate; MCP 300/min/token.
- Holder consent (SPEC-02 §3.2) prevents unconsented association.
- Platform admins can suspend orgs (read-only public page with a notice, all spend denied `forbidden`, checkout disabled) and users.
- Webhooks verify Stripe signatures and tolerance window (5 min).

## 7. Audit
`audit_log` (append-only, trigger-protected): security-relevant actions — sign-ins, token mint/revoke, secret writes, pause/resume/stop, admin actions, spec activations — with actor, IP (hashed after 30 days; C01 hashes at write time, see OQ-6), user agent, and target.

## 8. Web hardening
CSP: `default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self' wss://<host> https://*.stripe.com; frame-src https://*.stripe.com; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self'`. HSTS, `X-Content-Type-Options`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` minimal. CORS: web origin only for `/api/v1`; gateway and `/mcp` accept any origin but only token auth (no cookies).
