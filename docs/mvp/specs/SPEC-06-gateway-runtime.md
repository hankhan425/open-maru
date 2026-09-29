# SPEC-06 — Metered gateway, hosted runtime, kill switch

## 1. Goal secrets (BYOK)

Table `goal_secrets(goal_id, name, ciphertext, last4, updated_by_user_id, updated_at)`; unique(`goal_id`,`name`). Encrypted with Cloak (AES-256-GCM, key from `OPENMARU_VAULT_KEY`, key id stored for rotation).

Allowed names: `anthropic_api_key`, `openai_api_key`, `openai_base_url` (https only), `e2b_api_key`, `github_token`. Write-only over the API (`PUT`, `DELETE`, list returns names + last4 + updated_at). Requires `ManageSecrets` (steward holders). Secrets are decrypted only inside the gateway/runtime process that uses them and are never logged.

## 2. Price catalog

`model_prices(provider, model, input_per_mtok_micros, output_per_mtok_micros, cache_write_per_mtok_micros, cache_read_per_mtok_micros, max_output_tokens, effective_from, effective_to null)` and `server_tool_prices(provider, tool_type, per_use_micros)`. Prices are micro-USD per million tokens (e.g. $3/MTok = `3_000_000`). Managed by platform admins (`/api/v1/admin/prices`). No prices are hardcoded; tests use fixtures.

`cost(tokens, price) = ceil(tokens × price / 1_000_000)` computed per component, then summed.

## 3. Gateway

Routes (Phoenix, streaming-capable controller outside the JSON API pipeline):
- `POST /gw/anthropic/v1/messages`
- `POST /gw/anthropic/v1/messages/count_tokens` (proxied, never billed, still requires a valid token)
- `POST /gw/openai/v1/chat/completions`
- `GET /gw/health`

Agents configure e.g. Claude Code with `ANTHROPIC_BASE_URL=<host>/gw/anthropic` and `ANTHROPIC_AUTH_TOKEN=<mandate token>` (sent as `Authorization: Bearer`) or `ANTHROPIC_API_KEY` (sent as `x-api-key`). The gateway accepts either header. OpenAI-compatible clients use `base_url=<host>/gw/openai/v1`.

### 3.1 Request pipeline
1. Extract token (`x-api-key` or `Authorization: Bearer`); verify as mandate token with `operation("gateway")`; optional `x-openmaru-task` must be a task of the token's goal (`task_not_in_goal`).
2. Rate limit per mandate (default 600 req/min) → `rate_limited`.
3. Load provider secret for the goal → else `provider_credentials_missing`.
4. Parse body; model must be priced (`model_not_priced`). Validate features (§3.2, §3.3).
5. Compute **hold** (upper bound, §3.2/§3.3).
6. `Spend.request(category=llm, amount=hold, source=gateway, wait_for_approval?=false, hold_timeout=900)`. Denials map to errors (§3.5).
7. Register the request in `Gateway.InFlight` (keys `{:goal, id}`, `{:mandate, id}`) for kill-switch aborts.
8. Forward upstream with the provider key; stream the response to the client as it arrives while tapping usage.
9. On completion: `Spend.post(actual_cost, meta)`; add `x-openmaru-spend-id` response header (non-stream) or trailer comment (stream: an SSE comment line `: openmaru-spend-id <id>` before close). On upstream error without usage: `Spend.void`.

### 3.2 Anthropic Messages
- `max_tokens` required (`invalid_request`).
- Hold = `ceil(body_bytes × max(input, cache_write) / 1e6) + ceil(max_tokens × output / 1e6) + server_tool_hold`. Body bytes bound input tokens (every token is ≥ 1 byte), so the hold is a true upper bound.
- Server tools: entries in `tools` with a `type` other than a custom tool. `web_search_*` is allowed if priced: if `max_uses` is absent the gateway injects `max_uses: 5`; `server_tool_hold = max_uses × per_use`. Any other server tool → `unsupported_feature`.
- Usage: non-stream from `usage`; stream from `message_start.message.usage` (input, cache creation, cache read) and the last `message_delta.usage` (cumulative output; server tool use counts). Cost = input×input_price + cache_creation×cache_write + cache_read×cache_read_price + output×output_price + web_search_requests×per_use.
- Forward headers: `anthropic-version`, `anthropic-beta`, `content-type`. Upstream auth: `x-api-key: <goal secret>`. Strip client auth headers and hop-by-hop headers.

### 3.3 OpenAI Chat Completions
- Output cap = `max_completion_tokens` ‖ `max_tokens` ‖ catalog `max_output_tokens`; multiplied by `n` (default 1, max 4 → else `invalid_request`).
- Hold = `ceil(body_bytes × input / 1e6) + ceil(cap × n × output / 1e6)`.
- `web_search_options` present → `unsupported_feature`.
- Streaming: the gateway sets `stream_options.include_usage = true`. If the client did not request it, the final usage-only chunk is consumed and **not** forwarded.
- Cost = (prompt − cached)×input + cached×cache_read + completion×output (`completion_tokens` includes reasoning tokens).
- Upstream base URL: goal secret `openai_base_url` or `https://api.openai.com`. Auth `Authorization: Bearer <goal secret>`.

### 3.4 Failure handling
| Situation | Behavior |
|---|---|
| Upstream 4xx/5xx before any output | pass status + body through; void hold |
| Upstream connect timeout (10 s) | `gateway_timeout` 504; void |
| Stream ends without terminal event | post the full hold, `meta.estimated = true` |
| Client disconnects mid-stream | keep reading upstream (max 15 min total) to learn usage; post actual |
| Kill-switch abort | close upstream; post usage known so far, or the hold if unknown (`estimated`) |
| Post fails (e.g. hold expired) | record `meta.post_error`, alert; never retry upstream |

### 3.5 Error envelopes
Anthropic routes: `{"type":"error","error":{"type":"<anthropic type>","message":"openmaru: <code>: <detail>"}}` plus header `x-openmaru-error: <code>`. OpenAI routes: `{"error":{"message":"…","type":"openmaru_error","code":"<code>"}}`.

| Code | HTTP | Anthropic `type` |
|---|---|---|
| `invalid_token` | 401 | `authentication_error` |
| `budget_exceeded`, `goal_funds_insufficient` | 402 | `permission_error` |
| `approval_required`, `no_mandate`, `category_not_permitted`, `per_request_exceeded`, `mandate_expired`, `mandate_revoked`, `task_not_in_goal` | 403 | `permission_error` |
| `goal_paused` | 423 | `permission_error` |
| `model_not_priced`, `unsupported_feature`, `invalid_request` | 400 | `invalid_request_error` |
| `provider_credentials_missing` | 424 | `api_error` |
| `rate_limited` | 429 | `rate_limit_error` |
| `gateway_timeout` | 504 | `api_error` |

### 3.6 Performance
p95 added latency before first byte < 50 ms (token verify, authorize, hold). Chunks are forwarded without buffering beyond one SSE event.

## 4. Hosted runtime (E2B, BYOK)

### 4.1 Adapter
```elixir
@callback create(template_id :: String.t(), env :: map(), opts :: keyword()) :: {:ok, external_id} | {:error, term}
@callback exec(external_id, cmd :: String.t(), opts :: keyword()) :: :ok | {:error, term}   # detached
@callback status(external_id) :: {:ok, :running | :stopped} | {:error, term}
@callback kill(external_id) :: :ok | {:error, term}
```
`Openmaru.Runtime.E2B` implements it with the goal's `e2b_api_key`. Use E2B's HTTP API where it covers these operations; otherwise use a minimal Node sidecar (`runtime/e2b_sidecar`) with the official `e2b` SDK over an Erlang Port speaking JSON lines (`{"id","op","args"}` → `{"id","ok"|"error"}`). Tests use a fake adapter.

### 4.2 Templates
`runtime_templates(name unique, e2b_template_id, vcpu, memory_mb, rate_micros_per_sec)`, admin-managed. MVP ships `claude-code` built from `runtime/templates/claude-code/` (Debian slim, Node LTS, Claude Code CLI, git, `maru` binary, entrypoint `openmaru-agent-run`).

Entrypoint: fetch task and goal charter via `maru`; start a background heartbeat (`maru task heartbeat` every 5 min); run Claude Code headless (`claude -p "<prompt>"`) with a prompt that includes the task, the goal's charter section, and instructions to post evidence and submit via `maru`; on exit, post a `note` evidence with exit code and tail of the log (≤ 2 KB) and exit with the same code.

### 4.3 Sessions
Table `sessions(goal_id, task_id, agent_id, mandate_id, token_id, template, external_id, status, stop_reason, max_duration_secs, rate_micros_per_sec, metered_secs, started_at, ended_at)`. Status: `starting → running → stopping → exited | failed | killed`. Stop reasons: `completed`, `budget_exhausted`, `goal_paused`, `agent_stopped`, `manual`, `max_duration`, `error`, `lost`.

`start_session(actor, task, agent)`:
1. `authorize(actor, :start_session, agent, goal: task.goal)`; agent `runtime` must be `hosted` (`agent_not_hosted`); its mandate must have a `compute` spend line (`no_compute_budget`); `e2b_api_key` present.
2. Claim the task for the agent (lease TTL = `max_duration_secs`; default 3600, max 14400).
3. Mint an attenuated token: operations api/gateway/mcp, bound to the task, expiring at `max_duration + 600 s`.
4. First compute hold for 60 s (`Spend.request(category=compute, source=runtime, hold_timeout=120)`); denial aborts start.
5. `adapter.create` with env `OPENMARU_API_URL`, `OPENMARU_TOKEN`, `OPENMARU_GOAL_ID`, `OPENMARU_TASK_ID`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and `GH_TOKEN` if `github_token` is set; then `exec` the entrypoint. Emit `session.started`.

`SessionServer` (GenServer per session, `DynamicSupervisor` + `Registry`) ticks every 60 s: post the previous interval (`elapsed_secs × rate`), hold the next 60 s; hold denied → stop `budget_exhausted`; `status` = stopped → final post, `exited` (`completed`); `max_duration` reached → stop. On node boot, sessions in `starting/running/stopping` are recovered: adapter says running → restart server; stopped/unknown → final post of elapsed, `failed` (`lost`).

`stop_session(actor, session, reason)`: kill, final post, revoke session token, end lease if still active, emit `session.stopped`. Idempotent.

## 5. Kill switch

- `pause_goal(actor, goal)` (`PauseGoal`): set `paused(manual)` and emit `goal.paused` in one transaction; then, synchronously: abort all in-flight gateway requests for the goal (they post their own usage per §3.4), stop all running sessions (`goal_paused`), end all active leases (`goal_paused`, tasks back to `open`). New spend is denied from the moment the transaction commits. Target: all stop signals issued < 5 s.
- `resume_goal(actor, goal)` (`ResumeGoal`): back to `active`, or to `underfunded`/`paused(underfunded)` if a shortfall remains.
- `stop_agent(actor, agent)` (operator, or a steward holder of any goal where the agent holds a mandate): revoke all tokens of the agent's mandates, abort its in-flight gateway requests, stop its sessions (`agent_stopped`). Goal state unchanged.
- Pending-approval expense claims are left alone; if approved while paused, re-authorization denies with `goal_paused` and the hold is voided.
