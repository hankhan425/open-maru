# Conventions

## 1. TDD workflow (mandatory)

1. Tests listed in the task are written **first**, committed failing (`test(<ID>): add failing tests`).
2. Implement until green. Small commits.
3. Add tests for any extra edge cases found. Never delete or weaken a listed test; raise conflicts in `docs/mvp/OPEN_QUESTIONS.md`.
4. Every test name starts with its ID: Elixir `test "G01-T04 rejects transfer exceeding credits" do`, Rust `fn g01_t04_rejects_...()` plus `// G01-T04` comment, TS `it("F06-T03 shows tier badges", …)`.
5. Property tests carry IDs too; keep seeds reproducible (log the seed on failure).

## 2. Test tooling

| Layer | Tools | Notes |
|---|---|---|
| Rust | `cargo test`, `insta` snapshots, `proptest` | Snapshots live in `crates/*/tests/snapshots`; review diffs, never blindly accept |
| Elixir | ExUnit, Ecto SQL sandbox, `Mox` for behaviours, `Bypass` for HTTP stubs, `StreamData` | `async: true` unless the test touches global state (Oban, named processes) |
| Oban | `Oban.Testing` with `testing: :manual` | Assert enqueued jobs, then `perform_job/2` |
| Frontend | Vitest, Testing Library, MSW | Pure logic (layout, formatting) tested without DOM; canvas rendering not snapshot-tested |
| E2E | Playwright | Only in H01; runs against Docker Compose stack |

External services are always behind a behaviour (Elixir) or trait (Rust) with a fake for tests: `Openmaru.Payments.StripeClient`, `Openmaru.Gateway.Upstream`, `Openmaru.Runtime.Adapter`, `Openmaru.Storage`, `Openmaru.Clock`.

**Time.** Never call `DateTime.utc_now/0` directly in domain code; use `Openmaru.Clock.now/0` (Mox-able). Tests that depend on periods set the clock explicitly.

**Fixtures.** The canonical example spec is `docs/mvp/specs/examples/lumen.maru` (copied to `crates/maru_core/tests/fixtures/` and `apps/server/test/support/fixtures/`). Tests reuse it; don't invent a new org for every test.

## 3. Checks (all must pass before a PR)

```
cargo fmt --all -- --check && cargo clippy --all-targets -- -D warnings && cargo test --all
cd apps/server && mix format --check-formatted && mix credo --strict && mix test && mix dialyzer
cd web && pnpm lint && pnpm typecheck && pnpm test
```

## 4. Code style

- **Money** is `integer` micro-USD everywhere (`amount_micros`). 1 USD = 1_000_000. No floats, no Decimal in domain logic. JSON exposes money as a **string** of micros plus a display string: `{"amount_micros":"12500000","amount_display":"$12.50"}`.
- **Time** is UTC, ISO-8601 with `Z`. Periods are calendar-based in UTC (day, ISO week starting Monday, month).
- **IDs**: DB `uuid` (v7). API/TypeID prefixes: `usr_ org_ ver_ goal_ circ_ agent_ mand_ mtok_ dec_ task_ lease_ evid_ spend_ xfer_ acct_ don_ sess_ evt_ pat_ upl_`.
- **Errors** (Elixir): domain functions return `{:ok, value} | {:error, %Openmaru.Error{code: atom, message: String.t(), details: map}}`. No raising for expected failures.
- **Error codes** are stable snake_case atoms, documented in SPEC-07 §2. Tests assert on codes, not messages.
- **Rust**: no `unwrap()`/`expect()` outside tests; `thiserror` for error types; public API documented.
- **TypeScript**: `strict: true`; no `any`; server types generated from the OpenAPI document (`pnpm gen:api`).
- **Logs** never contain tokens, secrets, prompt contents, or receipt contents.

## 5. API conventions (summary; full list in SPEC-07)

- JSON only. `snake_case` keys. Cursor pagination: `?cursor=…&limit=…` (max 100) → `{"data":[…],"next_cursor":…}`.
- Mutations accept `Idempotency-Key` header; replays within 24 h return the original response.
- Auth: session cookie (web, with `x-csrf-token` header on mutations), `Authorization: Bearer om_pat_…` (CLI), or `Bearer om_mt_…` (mandate token, restricted routes).
- Errors: `{"error":{"code":"budget_exceeded","message":"…","details":{…}}}`.

## 6. Definition of Done

- All listed tests exist with IDs, and pass. New edge-case tests added where discovered.
- Checks (§3) pass in CI.
- Public functions/types documented; OpenAPI updated for any endpoint change; SPEC updated if behavior was clarified.
- No TODOs without a linked open question.
- Migrations are reversible; ledger tables' immutability triggers intact.
- PR description lists test IDs and status, deviations, and open questions.
