# SPEC-09 — Security, privacy, abuse

## 1. Authentication
- Passkeys (WebAuthn, `wax_`): discoverable credentials, user verification required, `none` attestation; challenges stored server-side (5 minutes, single use). Sign-count regression rejects the assertion: the counter must increase unless both the stored and the reported value are 0 (authenticators without a counter).
- OAuth (GitHub, Google) via `assent`, with `state` (and the OIDC `nonce` for Google) stored server-side for 5 minutes and bound to the browser by a cookie. Account linking only when the email is verified by the provider **and** the user is signed in. Signed out, a provider-verified email that belongs to an existing user is refused with `account_exists` (no linking). An unverified provider email is ignored: never stored, never matched against existing users (so it cannot block a sign-up or reveal that an account exists).
- Web sessions: opaque random token (32 bytes) in an `HttpOnly; Secure; SameSite=Lax` cookie; stored hashed; 30-day sliding expiry (moved at most hourly); revocable. A suspended user's sessions are rejected with 403 `forbidden`. Cookie-authenticated mutating requests require `x-csrf-token` (from `GET /api/v1/auth/csrf`, bound to the session).
- PATs: `om_pat_` + 32 random bytes base64url; stored as SHA-256 plus the last four characters; shown once (a response carrying a new token is never kept for `Idempotency-Key` replays); optional expiry (`ttl_days` 1–365); `last_used_at` updated at most once per minute. Minting and revoking a PAT need a web session: a PAT cannot mint PATs.
- Device flow: `user_code` 8 chars from the unambiguous alphabet `BCDFGHJKLMNPQRSTVWXZ23456789`, shown as `XXXX-XXXX`; device code stored as SHA-256; 10-minute expiry, polling interval 5 s (`slow_down` if faster; every poll restarts the interval), single use. Approval issues a PAT for the approving user named `CLI (<user agent>)`. Approvals and denials are audited.
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

Account deletion: removes PII (email, OAuth identities, passkeys; display name cleared), revokes the user's sessions, PATs and mandate tokens, and sets `users.deleted_at`. It first makes the user leave every org they belong to, with every effect of leaving (SPEC-02 §3.6): their seats, mandates and operator roles end; nobody has to hand anything over first (OQ-16). The handle is kept and stays taken; the API and web show the account as deleted. Ledger, votes, and activity remain with that pseudonymous handle (immutable history; OQ-7).

## 5. Uploads
Presigned PUT to private bucket; max 10 MB; allowed types: `application/pdf`, `image/png`, `image/jpeg`, `image/webp`, `text/plain`; SHA-256 verified on `complete`; object keys are random; no server-side fetching of user-provided URLs (no SSRF surface).

## 6. Abuse and limits
- Rate limits (Hammer): auth 10/min/IP; spec check 60/min/IP; checkout 10/min/IP; API 600/min/principal; gateway 600/min/mandate; MCP 300/min/token. Limits live in one config table and can be set per environment (e.g. `AUTH_RATE_LIMIT_PER_MINUTE` for e2e runs).
- Client IP: "IP" means an IPv4 address or an IPv6 /64. Behind a load balancer, `x-forwarded-for` is believed only when the TCP peer is a configured trusted proxy (`TRUSTED_PROXIES`); the client is the right-most hop that is not a trusted proxy. With none configured, the header is ignored.
- Holder consent (SPEC-02 §3.2) prevents unconsented association.
- Joining to sway a vote: member-wide votes count only members of at least 30 days (SPEC-01 §4.7). People silent for 90 days and suspended users don't count toward decisions (SPEC-02 §3.4).
- Outside money is protected by funding tiers, caps, waiting periods and dormancy (SPEC-05 §8). No one grants a funding tier by hand in production.
- Platform admins can suspend orgs (read-only public page with a notice, all spend denied `forbidden`, checkout and pledge charges disabled) and users (who then stop counting toward decisions, and whose agents are refused with `operator_unavailable`).
- Webhooks verify Stripe signatures and tolerance window (5 min).

## 7. Audit
`audit_log` (append-only, trigger-protected): security-relevant actions — sign-ins, token mint/revoke, secret writes, pause/resume/stop, admin actions, spec activations — with actor, IP, user agent, and target. The IP is never stored raw: `ip_hash` is HMAC-SHA-256 of the client address (§6) under a random key for the current UTC day, and `ip_hash_key_id` names that key (OQ-6). Day keys are stored in `audit_ip_hash_keys`, sealed (AES-256-GCM) under `AUDIT_IP_HASH_KEY` (required in production, at least 32 bytes, not derived from `SECRET_KEY_BASE`). An hourly job destroys a key 30 days after its day ends, so an address in the log can be linked to its hashes for at most 31 days and never after. Within that window, an address is looked up across days by hashing it under each live key (`Openmaru.Audit.hashes_for_ip/1`). Rotating `AUDIT_IP_HASH_KEY` makes every earlier hash unlinkable at once: keys sealed under the old value cannot be used and are destroyed on the next run. A database backup keeps the sealed keys it contains until the backup expires, so the backup retention (H02's runbook) extends the window for anyone who also holds `AUDIT_IP_HASH_KEY`.

## 8. Web hardening
CSP: `default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self' wss://<host> https://*.stripe.com; frame-src https://*.stripe.com; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self'`. HSTS, `X-Content-Type-Options`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` minimal. CORS: web origin only for `/api/v1`; gateway and `/mcp` accept any origin but only token auth (no cookies).
