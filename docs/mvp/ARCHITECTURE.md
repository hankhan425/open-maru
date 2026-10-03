# Architecture — openmaru MVP

## 1. System overview

```
 Clients:   Web SPA (React + PixiJS)   maru CLI (Rust)   MCP clients   Public pages
                 │  HTTPS/JSON + Phoenix Channels  │           │
 ┌───────────────▼──────────────────────────────────▼───────────▼──────────────┐
 │ Phoenix (API-only) — OpenmaruWeb: REST /api/v1, /socket, /mcp, /gw, /webhooks│
 │ ───────────────────────────── Elixir/OTP contexts ─────────────────────────  │
 │ Accounts  Orgs  Specs  Decisions  Goals  Tasks  Mandates  Ledger  Payments   │
 │ Gateway  Runtime  Activity  Public                                           │
 │      │ Rustler NIF (dirty CPU)                                               │
 │  maru_core (Rust): parse · fmt · check → IR · charter · diff · Cedar decide  │
 │  maru_token (Rust): Biscuit mint / attenuate / verify                        │
 └──────┬──────────────┬───────────────┬──────────────┬──────────────┬─────────┘
   Postgres        Object store     Stripe API     LLM providers     E2B (via Port
 (+ Oban jobs)    (S3-compatible)  (Connect)      (BYOK)            sidecar or HTTP)
```

The same `maru_core` crate compiles to: a Rustler NIF (server), WASM (browser editor), and the native `maru` CLI. One implementation of the language, three targets, zero drift.

## 2. Tech stack (pinned choices; do not substitute without an ADR)

| Area | Choice |
|---|---|
| Backend | Elixir 1.17+, OTP 27+, Phoenix 1.7+ (API only, no LiveView), Ecto + Postgres 16 |
| Jobs / scheduling | Oban (+ Cron plugin) |
| HTTP client | Req on Finch (streaming via `Finch.stream/5` for the gateway) |
| NIFs | Rustler (`schedule = "DirtyCpu"` for all maru_core calls) |
| Language core | Rust stable, crates: `cedar-policy`, `serde`/`serde_json`, `sha2`, `thiserror`; tests: `insta`, `proptest` |
| Tokens | `biscuit-auth` (Rust) exposed via NIF |
| WebAuthn | `wax_` |
| OAuth | `assent` (GitHub, Google) |
| Encryption at rest | `cloak_ecto` (AES-GCM, key from env) |
| Stripe | `stripity_stripe` |
| Rate limiting | `hammer` |
| Object storage | `ex_aws_s3` (S3-compatible; MinIO locally) |
| IDs | UUIDv7 in DB; exposed as TypeIDs (`org_…`, `goal_…`) via `typeid_elixir` |
| Frontend | TypeScript, React 19, Vite, React Router, TanStack Query, Zustand, PixiJS v8, CodeMirror 6, `phoenix` JS client |
| Frontend tests | Vitest, Testing Library, MSW; Playwright for E2E |
| CLI | Rust, `clap`, `reqwest` (rustls), `tokio`, `serde`, `directories` |
| Observability | OpenTelemetry (Elixir + JS), structured JSON logs |
| Local dev | Docker Compose: Postgres, MinIO, stripe-mock or Stripe test mode, provider stub |

## 3. Repository layout

```
openmaru/
  apps/server/                 # Phoenix app "openmaru"
    lib/openmaru/              # contexts (see §4)
    lib/openmaru_web/          # controllers, channels, plugs, MCP, gateway, webhooks
    native/                    # symlinks or path deps to crates used by Rustler
    test/
  crates/
    maru_core/                 # language: lexer, parser, ast, fmt, check, ir, charter, diff, cedar
    maru_token/                # biscuit mandate tokens
    maru_nif/                  # Rustler bindings for maru_core + maru_token
    maru_wasm/                 # wasm-bindgen bindings for maru_core
    maru_cli/                  # `maru` binary
  web/                         # React SPA
    src/{app,routes,features,components,lib,styles}
    tests/                     # Vitest; e2e/ for Playwright
  runtime/
    templates/claude-code/     # E2B template: Dockerfile + entrypoint
    e2b_sidecar/               # (only if needed) Node JSON-lines Port sidecar
  docs/mvp/                    # this folder
  compose.yaml
  .github/workflows/ci.yml
```

## 4. Backend contexts (bounded modules)

| Context | Owns | Public API style |
|---|---|---|
| `Openmaru.Accounts` | users, handles, passkeys, OAuth identities, sessions, PATs, device codes | `get_user!/1`, `register_passkey/2`… |
| `Openmaru.Orgs` | orgs, memberships, sponsorships, spec versions, IR projection (circles, holders, agents, goals, mandates) | `create_org/2`, `active_spec/1`, `effective_holders/2` |
| `Openmaru.Lang` | thin Elixir wrapper over the NIF; the only module that calls `maru_nif` | `check/1`, `format/1`, `render/1`, `diff/2`, `decide/3` |
| `Openmaru.Decisions` | decisions, ballots, deadlines, effects | `open/1`, `cast/3`, `resolve/1` |
| `Openmaru.Goals` | goal state machine, funding schedule, metrics, closure, pause/resume | `pause/2`, `allocate_period/2` |
| `Openmaru.Tasks` | tasks, leases, evidence, reviews | `claim/2`, `heartbeat/2`, `submit/2` |
| `Openmaru.Mandates` | mandate tokens (issue/revoke), authorization service, spend requests | `authorize/2`, `request_spend/2` |
| `Openmaru.Ledger` | accounts, transfers, balances, hash chain, checkpoints. **No other module touches ledger tables.** | `create_accounts/1`, `create_transfers/1`, `lookup_*` |
| `Openmaru.Spend` | spend records (control-plane metadata over ledger transfers), provenance, expense claims | `record/1`, `post/2`, `void/2` |
| `Openmaru.Payments` | Stripe accounts, donations, webhooks, refunds, reconciliation | `onboarding_link/1`, `checkout/1`, `handle_event/1` |
| `Openmaru.Gateway` | price catalog, provider adapters, metering, goal secrets | `price/2`, `proxy/…` |
| `Openmaru.Runtime` | sessions, runtime adapters (E2B), compute metering, supervision | `start_session/2`, `stop_session/2` |
| `Openmaru.Activity` | append-only activity events + PubSub broadcast | `emit/1`, `list/2` |
| `Openmaru.Public` | read models for public pages (aggregations, world graph) | `goal_summary/1`, `world/0` |
| `Openmaru.Audit` | the append-only security audit log (SPEC-09 §7); every context records its security-relevant actions here | `record/1` |

Rules: contexts call each other only through public functions. Cross-context writes that must be atomic use `Ecto.Multi` built by the *owning* context (e.g. `Ledger.multi_create_transfers/2`).

## 5. Key data flows

**Amendment.** Editor (WASM) checks source locally → `POST /proposals` → server re-checks via NIF, computes diff vs active version, opens a decision using the active spec's `amend` procedure → ballots → on pass, new spec version becomes active and the IR projection is rebuilt in the same transaction → activity event.

**Metered model call.** Agent → `/gw/anthropic/v1/messages` with mandate token → verify token (NIF) → load mandate + active IR → `decide` (Cedar, NIF) → compute conservative hold → ledger pending linked transfers (budget + goal funds) → stream provider response through, tapping usage → post actual (≤ hold), void remainder → spend record `verified` → broadcast.

**Own funds.** Administrator → `POST /orgs/:slug/contributions` → ledger: `ext_own` → goal or treasury (attested; no money seen) → activity.

**Pledge.** Donor saves a card on the platform → monthly job (1st of the month): up to 80% of the goal's accepted spend, split by pledge caps → off-session direct charge on the org's connected account → ledger: gross inflow to `goal:<g>:reimbursed` (never spendable), linked fee transfers → activity + broadcast (SPEC-05 §8.3).

**Donation (funding tier 2).** Donor → `POST /donations/checkout` (tier and cap checked) → Stripe Checkout (direct charge on org's connected account, application fee) → webhook → ledger: gross inflow to the goal, linked fee transfers; a new outside-money lot → activity + broadcast.

**Monthly funding.** Oban cron at 00:00 UTC on period start → per goal: allocate `min(fund, treasury available)`; shortfall → `underfunded` → `on_underfunded` (pause or continue); budget accounts reset for the new period.

## 6. Decision records (ADRs)

- **ADR-1 Postgres ledger, TigerBeetle-shaped.** Accounts/transfers mirror TigerBeetle's model (integer amounts, immutable transfers, two-phase, linked, balance-constraint flags, client IDs). Migration later is an adapter + replay, not a rewrite.
- **ADR-2 Non-custodial.** Orgs are Stripe Connect Standard accounts; donations and pledge charges are direct charges. openmaru never holds funds. The ledger is an earmarking and accounting mirror reconciled against Stripe. Because openmaru can't freeze or claw back money, outside money is protected by not taking it before work (pledges), capping what is held, and refunding what is unspent (SPEC-05 §8, OQ-16).
- **ADR-3 In-house narrow gateway, not LiteLLM.** MVP supports exactly two wire formats (Anthropic Messages, OpenAI Chat Completions). Owning the proxy lets holds, mandate-token auth, and ledger posting happen in one process with no second source of budget truth. Revisit if provider count grows beyond ~4.
- **ADR-4 BYOK everywhere.** Provider and E2B keys are goal secrets; providers bill the org. openmaru never fronts or resells usage.
- **ADR-5 Cedar for policy, Biscuit for tokens.** The maru IR compiles to Cedar policies; approval gates are `forbid … unless context.approved_rules.contains(id)`. Period budgets are enforced by ledger constraints, not Cedar.
- **ADR-6 SPA over LiveView.** Canvas-heavy, animation-heavy UI plus in-browser WASM compiler; Phoenix serves JSON + Channels only.
- **ADR-7 Processes are caches.** OTP processes (session servers, goal servers) hold no state that isn't reconstructible from Postgres.
- **ADR-8 Every language construct is enforced.** If the runtime can't enforce it, it isn't in v0.

## 7. Non-functional requirements

| Area | Target |
|---|---|
| Gateway overhead | p95 < 50 ms added before first byte; streaming adds < 5 ms per chunk |
| Authorization (`decide`) | p95 < 2 ms in NIF for specs ≤ 2,000 lines |
| Ledger | ≥ 1,000 linked transfer pairs/s on a single Postgres primary in the benchmark suite |
| Kill switch | all spend for a goal blocked immediately; stop issued to all sessions < 5 s |
| Availability | single region, daily backups, point-in-time recovery enabled |
| Public pages | cacheable GETs; goal page first contentful paint < 1.5 s on 4G |
| Accessibility | WCAG 2.2 AA for all non-canvas UI; canvas has an equivalent list view |
