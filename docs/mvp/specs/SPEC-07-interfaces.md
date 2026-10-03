# SPEC-07 — Interfaces: REST, realtime, MCP, CLI

## 1. REST API (`/api/v1`)

Auth column: **S** session cookie, **P** personal access token, **M** mandate token, **—** public. Every endpoint is also described in the OpenAPI document (`/api/v1/openapi.json`, generated with `open_api_spex`). Owner = task that implements it.

An `Authorization` header takes precedence over the session cookie: when it is present the cookie is not read, so the request is not cookie-authenticated and needs no `x-csrf-token`. A header that is not one `Bearer <token>`, an unknown token prefix, or a refused token is 401 `invalid_token` on any route, public ones included. A credential a route does not accept is 403 `forbidden`: a PAT on an S route (`details.reason: "session_required"`), a mandate token on a route not marked M (`"mandate_token_not_allowed"`). Routes marked "— / S" (passkey and OAuth sign-in) refuse bearer credentials the same way, so a PAT cannot add a passkey or link an identity.

### Auth & account
| Method & path | Auth | Owner |
|---|---|---|
| `POST /auth/passkey/register/options`, `POST /auth/passkey/register` | — / S | C01 |
| `POST /auth/passkey/login/options`, `POST /auth/passkey/login` | — | C01 |
| `GET /auth/oauth/:provider`, `GET /auth/oauth/:provider/callback` | — | C01 |
| `GET /auth/csrf` → `{csrf_token}` (send as `x-csrf-token` on cookie-authenticated mutations) | S | C01 |
| `POST /auth/logout` | S | C01 |
| `GET /me`, `PATCH /me` (handle, display name) | S P | C01 |
| `POST /auth/device/code` → `{device_code, user_code, verification_uri, verification_uri_complete, expires_in, interval}` · `POST /auth/device/token {device_code}` → new PAT (as `POST /me/tokens`) | — | C02 |
| `POST /auth/device/approve {user_code, decision?: approve\|deny}` → `{status}` | S | C02 |
| `GET /me/tokens?cursor=&limit=` · `POST /me/tokens {name, ttl_days?}` → token shown once · `DELETE /me/tokens/:id` | S | C02 |
| `GET /socket-token` → `{token, expires_in}` (5 minutes, for `/socket`) | S P | C02 |
| `GET /me/inbox` (open decisions I can vote on, pending holder acceptances, tasks in review for my goals) | S P | C04 |

### Orgs, specs, decisions
| Method & path | Auth | Owner |
|---|---|---|
| `POST /specs/check {source, now?}` → `{diagnostics, ir, charter}` | — (rate-limited) | C03 |
| `POST /orgs {slug, source}` | S P | C03 |
| `GET /orgs/:slug` (org, active version summary, circles with effective holders, goals, member count) | — | C03 |
| `GET /orgs/:slug/spec` (source, ir, charter, hash, version) · `GET /orgs/:slug/spec/versions[/:n]` | — | C03 |
| `POST /orgs/:slug/holders/accept`, `POST /orgs/:slug/holders/decline` | S P | C03 |
| `POST /orgs/:slug/membership` · `DELETE /orgs/:slug/membership` (leaving; holders and operators too, SPEC-02 §3.6) · `POST /orgs/:slug/sponsorships {handle}` | S P | C03, C07 |
| `POST /orgs/:slug/forks {slug, source}` → new org (SPEC-02 §3.7) | S P | C07 |
| `POST /orgs/:slug/proposals {source, base_version, title, rationale}` | S P | C04 |
| `GET /orgs/:slug/proposals?status=` · `GET /decisions/:id` | — | C04 |
| `POST /decisions/:id/ballots {choice}` · `POST /decisions/:id/cancel` | S P | C04 |

### Goals, tasks, evidence
| Method & path | Auth | Owner |
|---|---|---|
| `GET /orgs/:slug/goals` · `GET /goals/:id` (status, period funding, success status, `viewer.permissions` for the caller) | — | C06 |
| `POST /goals/:id/metrics {name, value, observed_at}` | S P M | C06 |
| `POST /goals/:id/close` (opens decision) | S P | C06 |
| `POST /goals/:id/pause` · `POST /goals/:id/resume` | S P | A06 |
| `GET /goals/:id/tasks?status=` · `POST /goals/:id/tasks` · `GET /tasks/:id` | — / S P M | A01 |
| `POST /tasks/:id/{claim,heartbeat,release,submit,accept,reject,cancel}` | S P M | A01, A02 |
| `POST /tasks/:id/evidence` · `POST /goals/:id/evidence` · `GET /tasks/:id/evidence` | S P M / — | A02 |
| `POST /uploads {purpose, content_type, byte_size, sha256}` → presigned PUT · `POST /uploads/:id/complete` | S P M | A02 |

### Spend, mandates, secrets, sessions
| Method & path | Auth | Owner |
|---|---|---|
| `GET /goals/:id/budget` (per mandate/category: limit, consumed, held, available, period) | — | G02 |
| `POST /goals/:id/expenses {amount_micros, memo, receipt_upload_id?, task_id?}` | S P M | G03 |
| `GET /spend/:id` · `POST /spend/:id/reimbursed {proof_upload_id}` | — / S | G03 |
| `GET /goals/:id/mandates` | — | M01 |
| `POST /mandates/:id/tokens {label, ttl_days}` → token shown once · `GET /mandates/:id/tokens` · `DELETE /mandate-tokens/:id` | S P | M01 |
| `GET /goals/:id/secrets` · `PUT /goals/:id/secrets/:name {value}` · `DELETE /goals/:id/secrets/:name` | S P | W01 |
| `POST /tasks/:id/sessions {agent}` · `GET /sessions/:id` · `POST /sessions/:id/stop` · `GET /goals/:id/sessions` | S P / — | A05 |
| `POST /agents/:org_slug/:ident/stop` | S P | A06 |

### Payments
| Method & path | Auth | Owner |
|---|---|---|
| `POST /orgs/:slug/payments/onboarding` (also a replacement account, SPEC-05 §8.8) · `GET /orgs/:slug/payments/status` · `GET /orgs/:slug/payments/reconciliation` | S | P01, P03, P05 |
| `POST /orgs/:slug/contributions {goal_id?, amount_micros, memo}` (own funds, administrators; SPEC-03 §5.6) | S P | G02 |
| `GET /orgs/:slug/funding` → what supporters see (SPEC-05 §8.11): per goal whether it takes pledges and donations (and why not), unspent outside money, cap and starting allowance, liveness; the margin, recipient, review, track record and rule flags | — | P04, P05 |
| `GET /orgs/:slug/earnings` → pay rules, earnings and pay owed and recorded by month (SPEC-05 §8.10) · `POST /orgs/:slug/payouts/:id/paid {proof_upload_id}` · `POST /orgs/:slug/earnings/retain {amount_micros}` (administrators) | — / S P | P06 |
| `POST /donations/checkout` · `GET /donations/:id/receipt?t=` | — | P02, P04 |
| `POST /donations/:id/exit?t=` (during a waiting period, SPEC-05 §8.6) | — | P05 |
| `POST /pledges/setup {goal_id, monthly_cap_micros, donor_display_name?, donor_public}` → `{setup_url, pledge_id}` · `GET /pledges/:id?t=` · `POST /pledges/:id/cancel?t=` · `POST /pledges/:id/reconfirm?t=` (adopts the current margin) | — (rate-limited like checkout) | P04 |
| `POST /webhooks/stripe` · `POST /webhooks/stripe/connect` (outside `/api/v1`) | signature | P01, P02 |

### Public read models (cacheable, no auth)
| Method & path | Owner |
|---|---|
| `GET /public/world` → orgs (id, slug, name, member count, goal summaries), shared-member edges | C03, F02 |
| `GET /public/goals/:id/summary` → period funding, totals by category/tier/source, 90-day series | G04 |
| `GET /public/goals/:id/ledger?cursor=` → spend entries | G04 |
| `GET /public/goals/:id/activity?cursor=` | C05 |
| `GET /public/ledger/checkpoints?cursor=` · `GET /public/ledger/transfers?from_seq=&to_seq=` (max 10,000) | G04 |
| `GET /public/token-key` | M01 |

### Admin (platform role `admin`)
`GET/POST /admin/prices`, `GET/POST /admin/runtime-templates`, `POST /admin/orgs/:slug/suspend`, `POST /admin/users/:handle/suspend` (W01, A05, H02).

## 2. Error codes (stable)

Envelope: `{"error":{"code","message","details"}}`. Validation errors carry `details.diagnostics` (SPEC-01 §5 shape).

Choosing between the generic codes: `invalid_request` (400) is a malformed request or a failed protocol step (unparseable body, unknown or expired challenge or OAuth state); `validation_failed` (422) is a well-formed request refused by a rule, with `details.fields` for field errors and `details.reason` for a machine-readable subtype (e.g. `handle_immutable`, `no_changes`); a 409 code is a conflict with another resource or a concurrent change (`handle_taken`, `stale_proposal`).

| Code | HTTP | Code | HTTP |
|---|---|---|---|
| `unauthenticated` | 401 | `invalid_token` | 401 |
| `forbidden`, `not_steward`, `not_operator`, `not_admin` | 403 | `no_mandate`, `category_not_permitted`, `capability_missing` | 403 |
| `mandate_expired`, `mandate_revoked`, `per_request_exceeded` | 403 | `approval_required`, `not_eligible`, `not_claimant`, `self_review_forbidden` | 403 |
| `budget_exceeded`, `goal_funds_insufficient` | 402 | `goal_paused` | 423 |
| `not_found` | 404 | `invalid_request` | 400 |
| `validation_failed` | 422 | `goal_closed`, `invalid_transition`, `stale_proposal` | 409 |
| `already_voted`, `decision_closed`, `lease_limit_reached`, `lease_expired` | 409 | `evidence_required`, `exceeds_hold`, `idempotency_conflict` | 409 |
| `handle_taken`, `slug_taken`, `account_exists`, `exit_not_open` | 409 | `payments_not_enabled`, `agent_not_hosted`, `no_compute_budget` | 409 |
| `model_not_priced`, `unsupported_feature` | 400 | `provider_credentials_missing` | 424 |
| `rate_limited` | 429 | `provider_error` | 502 |
| `gateway_timeout` | 504 | `task_not_in_goal`, `operator_unavailable`, `custom_upstream_not_allowed` | 403 |
| `not_accepting_money`, `outside_money_cap_reached` | 409 | | |
| `authorization_pending`, `slow_down`, `expired_token` | 400 | `access_denied`, `invalid_grant` | 400 |
| `not_acceptable` | 406 | `request_timeout` | 408 |
| `conflict` | 409 | `payload_too_large` | 413 |
| `uri_too_long` | 414 | `unsupported_media_type` | 415 |
| `internal_error` | 500 | `service_unavailable` | 503 |

`not_accepting_money` carries `details.reason`: `no_recent_work`, `dormant` or `connector_unavailable` (SPEC-05 §8.7, §8.8). `custom_upstream_not_allowed` is a gateway call through a custom `openai_base_url` while the goal holds unspent outside money (SPEC-05 §8.2).

A code always determines the HTTP status, including for errors raised before or outside a controller (OQ-1). Such an error gets the code of its status: the generic `invalid_request`, `unauthenticated`, `forbidden`, `not_found`, `validation_failed` and `rate_limited` for theirs, and the last four rows of the table for the others. `conflict` is a concurrent change the server did not handle (retry the request); `internal_error` is a bug, never a domain outcome; `service_unavailable` is a dependency that is down.

The `authorization_pending` row is the device login (`/auth/device/*`, RFC 8628 §3.5): `authorization_pending` (not approved yet), `slow_down` (polled less than `interval` seconds after the previous poll; the interval restarts), `expired_token` (code older than 10 minutes), `access_denied` (denied, or the approver is suspended), `invalid_grant` (unknown device code, or its token was already issued; on approve, a code already decided). An unknown user code on approve is 404 `not_found`.

## 3. Realtime (Phoenix Channels, `/socket`)

| Topic | Join | Events pushed |
|---|---|---|
| `public:goal:<goal_id>` | anyone | `activity` (public events), `ledger` (spend posted/voided, donation received), `funding` (period funding changed), `task` (state changes) |
| `public:world` | anyone | `pulse` `{org_id, goal_id, kind}` throttled to ≤ 10/s globally |
| `org:<org_id>` | members | `activity` (incl. members-only), `decision` (opened/ballot/resolved) |
| `user:<user_id>` | that user | `inbox` changes |

Payloads use the same JSON shapes as REST. Socket auth: session cookie via signed token (`GET /api/v1/socket-token`) or PAT.

## 4. MCP server (`/mcp`)

Streamable HTTP transport; the server answers `initialize`, `tools/list`, `tools/call` with `application/json` responses (no server-initiated streams in MVP). Auth: `Authorization: Bearer` mandate token or PAT. Tool errors return `isError: true` with `{code, message}` text content.

| Tool | Input | Output |
|---|---|---|
| `openmaru_get_goal` | `{goal_id?}` (defaults to token goal) | goal, status, period funding, success |
| `openmaru_get_charter` | `{goal_id?}` | goal's charter section (markdown) + mandate of caller |
| `openmaru_get_budget` | `{goal_id?}` | caller's per-category limit/consumed/held/available |
| `openmaru_list_tasks` | `{goal_id?, status?}` | tasks |
| `openmaru_create_task` | `{title, body}` | task |
| `openmaru_claim_task` | `{task_id, ttl_secs?}` | lease |
| `openmaru_heartbeat` | `{task_id}` | lease |
| `openmaru_release_task` | `{task_id}` | task |
| `openmaru_submit_task` | `{task_id}` | task |
| `openmaru_post_evidence` | `{task_id?, kind, url?, summary}` | evidence |
| `openmaru_request_expense` | `{amount_usd, memo, task_id?}` | spend record |
| `openmaru_report_metric` | `{name, value}` | metric |

## 5. CLI (`maru`)

Global flags: `--api <url>` (default `https://openmaru.org`, env `OPENMARU_API_URL`), `--json`, `--quiet`. Credentials: env `OPENMARU_TOKEN` (PAT or mandate token) overrides `~/.config/openmaru/credentials.toml` (mode 0600). Exit codes: 0 ok · 1 error · 2 usage · 3 denied / approval required · 4 spec check failed · 5 not authenticated.

**Offline language commands (L08):**
`maru fmt [--check] <files…>` · `maru check <file> [--now <ts>]` · `maru render <file> [--format md|json]` · `maru diff <old> <new>` · `maru explain <file> --principal <agent|@handle> --action spend --goal <id> --category llm --amount 30 [--approved <rule_id>…]` · `maru policy <file>` (prints Cedar)

**Online commands (A04):**
`maru login` (device flow) · `maru logout` · `maru whoami`
`maru org show <slug>` · `maru spec pull <slug> [-o file]` · `maru spec propose <slug> <file> --title <t> [--rationale <r>]` · `maru decision list [--mine]` · `maru decision vote <id> yes|no`
`maru goal show <org>/<goal>` · `maru budget <org>/<goal>`
`maru task list <org>/<goal> [--status s]` · `maru task show <id>` · `maru task create <org>/<goal> --title <t> [--body-file f]` · `maru task claim|heartbeat|release|submit <id>`
`maru evidence add [--task <id>] [--goal <org>/<goal>] --kind <k> [--url <u>] [--file <path>] --summary <s>`
`maru expense request <org>/<goal> --amount 12.50 --memo <m> [--receipt <file>] [--task <id>]`
`maru metric report <org>/<goal> <name> <value>`
`maru token mint <org>/<goal> --principal <agent|@handle> [--ttl-days n] [--label l]` · `maru token revoke <id>` · `maru token attenuate [--operation gateway] [--task <id>] [--expires <ts>] [--max-request-usd n]` (reads token from stdin)
`maru log <org>/<goal> [--follow]` · `maru ledger verify [--from-date d]`
