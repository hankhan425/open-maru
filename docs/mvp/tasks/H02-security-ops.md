# H02 · Security & ops hardening

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Hardening | A06, G04, P03, W03, C07, P05 | M | 15 |

**Read first:** SPEC-09 (all); ARCHITECTURE §7; CONVENTIONS §6.
**Paths:** `apps/server/lib/openmaru_web/{endpoint,router}.ex`, plugs, `lib/openmaru/admin/**`, `Dockerfile`, `rel/`, `docs/ops/`

## Goal
Close the gaps a reviewer would find: uniform rate limits, headers, CORS, audit coverage, admin suspension, account deletion, deployable release, restorable backups, and telemetry without leaking content.

## Deliverables
- Rate-limit plug configuration matching SPEC-09 §6 (single table in config; C01 started it with `auth` in `config :openmaru, OpenmaruWeb.Plugs.RateLimit, limits: …`).
- Security headers and CSP (for the endpoint serving `index.html` in production), CORS per path group.
- Audit coverage for every action listed in SPEC-09 §7.
- Admin endpoints: suspend/unsuspend org and user; effects enforced in `authorize`, checkout, and auth.
- Account deletion flow per SPEC-09 §4.
- Multi-stage `Dockerfile` (Rust NIFs compiled in build stage), `Openmaru.Release.migrate/0`, container healthcheck.
- `docs/ops/runbook.md`: deploy, rollback, key rotation (vault, token root key, `AUDIT_IP_HASH_KEY`: rotating it makes every earlier audit IP hash unlinkable, SPEC-09 §7), backup/restore with a stated backup retention (it extends the 31-day audit IP window, SPEC-09 §7), incident kill switch.
- OpenTelemetry spans for API, gateway (attributes: goal_id, mandate_id, model, spend_id), Oban.

## Tests to write first
- [ ] **H02-T01** Each limiter in SPEC-09 §6 has a test hitting limit + 1 → 429 `rate_limited` with `retry-after`.
- [ ] **H02-T02** Security headers and CSP present exactly as specified on the HTML response; HSTS on HTTPS.
- [ ] **H02-T03** CORS: `/api/v1` allows only the web origin with credentials; `/gw` and `/mcp` allow any origin and reject cookie auth.
- [ ] **H02-T04** Audit rows for sign-in, token mint/revoke, secret write/delete, pause/resume/stop, admin actions, spec activation; table is append-only.
- [ ] **H02-T05** Suspended org: public read-only with notice; spend → `forbidden`; checkout → 409; unsuspend restores.
- [ ] **H02-T06** Suspended user: sessions, PATs, and person mandate tokens rejected.
- [ ] **H02-T07** Meta-test: every non-public route in the router has at least one test tagged `@tag authz: "<route>"` covering an allowed and a denied case.
- [ ] **H02-T08** Account deletion removes email, OAuth identities, passkeys and display name, revokes the user's sessions, PATs and mandate tokens, and sets `deleted_at`; it first makes the user leave every org with C07's departure effects (`Orgs.leave_all/1`; SPEC-02 §3.6, OQ-16); the handle is unchanged and a new user cannot take it; the user JSON and web show the account as deleted; votes and ledger history remain (SPEC-09 §4, OQ-7).
- [ ] **H02-T09** CI builds the Docker image, runs migrations, and the container healthcheck passes.
- [ ] **H02-T10** Restore drill: `pg_dump` of a seeded DB restored into a fresh DB; `verify_chain` and `verify_balances` pass.
- [ ] **H02-T11** End-to-end log capture of a gateway call and a secret write contains no token, key, or prompt text.
- [ ] **H02-T12** Telemetry: spans emitted for an API request, a gateway call (with the listed attributes only), and an Oban job.
