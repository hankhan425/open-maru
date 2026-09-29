# T02 · Phoenix API skeleton

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Foundation | T01 | M | 1 |

**Read first:** ARCHITECTURE §2, §4; CONVENTIONS (all); SPEC-07 §1 intro, §2; SPEC-09 §3 (log scrubbing).
**Paths:** `apps/server/**`

## Goal
A Phoenix 1.7 API-only app with the plumbing every later task relies on: Repo with UUIDv7, TypeIDs, error envelope, idempotency, clock, Oban, OpenAPI, log scrubbing, and test support.

## Deliverables
- `mix phx.new server --app openmaru --no-html --no-assets --no-live --no-mailer --no-dashboard --binary-id` adapted to UUIDv7 primary keys (`Openmaru.Schema` macro).
- `Openmaru.TypeID`: encode/decode with the prefixes in CONVENTIONS §4; `Ecto.Type` for API-facing ids.
- `Openmaru.Error` struct + `OpenmaruWeb.FallbackController` + `ErrorJSON` rendering `{"error":{"code","message","details"}}` with HTTP status from `Openmaru.Error.status/1` (full table in SPEC-07 §2).
- `Openmaru.Clock` behaviour + default impl; Mox mock `Openmaru.ClockMock` in test.
- `OpenmaruWeb.Plugs.Idempotency` + `idempotency_keys` table (`key`, `principal`, `request_hash`, `status`, `body`, `expires_at`).
- Oban with queues `default, ledger, webhooks, gateway, runtime, scheduled`, Cron plugin (no jobs yet), `testing: :manual` in test.
- `GET /healthz` (checks DB). `open_api_spex` with `/api/v1/openapi.json`.
- JSON logger with a scrubbing formatter/filter (SPEC-09 §3).
- Test support: `DataCase`, `ConnCase`, `Openmaru.Factory` (plain functions, no ExMachina), `fixture!/1` loading `test/support/fixtures/*` (copy `lumen.maru` from docs).
- Credo strict + Dialyzer configured.

## Interfaces
```elixir
%Openmaru.Error{code: atom(), message: String.t(), details: map()}
Openmaru.Error.new(code, message \\ nil, details \\ %{})
Openmaru.Error.status(code) :: 400..599
Openmaru.TypeID.encode(prefix :: String.t(), uuid) :: String.t()
Openmaru.TypeID.decode(String.t(), expected_prefix) :: {:ok, uuid} | {:error, :invalid_id}
Openmaru.Clock.now() :: DateTime.t()
```

## Tests to write first
- [ ] **T02-T01** `GET /healthz` → 200 `{"status":"ok","db":"ok"}`; with the repo check stubbed to fail → 503 `{"status":"degraded","db":"error"}`.
- [ ] **T02-T02** Table-driven: every error code in SPEC-07 §2 renders the envelope with the specified HTTP status.
- [ ] **T02-T03** Unknown route → 404 `not_found` envelope.
- [ ] **T02-T04** Malformed JSON body → 400 `invalid_request` envelope.
- [ ] **T02-T05** TypeID round-trip for every prefix; wrong prefix or garbage → `{:error, :invalid_id}`.
- [ ] **T02-T06** Property: UUIDv7 ids generated later sort after earlier ones (StreamData, clock-independent monotonic check within one process).
- [ ] **T02-T07** `Openmaru.Clock.now/0` returns UTC `DateTime`; Mox override is visible in an async test.
- [ ] **T02-T08** Idempotency: same key + same body twice → identical status/body, controller action executed once.
- [ ] **T02-T09** Idempotency: same key + different body → 409 `idempotency_conflict`.
- [ ] **T02-T10** Idempotency keys expire after 24 h (Clock-controlled): replay after expiry executes again.
- [ ] **T02-T11** Log scrubbing: logging metadata/maps containing `authorization`, `x-api-key`, `cookie`, `api_token`, `client_secret`, `private_key` emits `[REDACTED]` for their values.
- [ ] **T02-T12** `/api/v1/openapi.json` is served and passes `OpenApiSpex` schema validation.
- [ ] **T02-T13** Oban is configured with the six queues; jobs are not executed automatically in tests.
- [ ] **T02-T14** `fixture!("lumen.maru")` equals `docs/mvp/specs/examples/lumen.maru` byte-for-byte.

## Acceptance criteria
- `mix test`, `mix credo --strict`, `mix dialyzer`, `mix format --check-formatted` pass in CI.

## Out of scope
Auth (C01), any domain tables.
