# W02 · Anthropic Messages gateway

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Gateway | W01, M02 | L | 10 |

**Read first:** SPEC-06 §3 (all, esp. §3.1, §3.2, §3.4–§3.6); SPEC-04 §4 (token verification), §5.2; SPEC-09 §3.
**Paths:** `lib/openmaru/gateway/{proxy,anthropic,usage,in_flight}.ex`, `lib/openmaru_web/controllers/gateway/**`

## Goal
Any Anthropic-compatible client (e.g. Claude Code with `ANTHROPIC_BASE_URL` pointed at openmaru) makes model calls that are authorized by mandate, held against budget, streamed through untouched, and posted at exact cost as *verified* spend.

## Deliverables
- Streaming reverse proxy (Finch `stream/5`, chunked Plug response) at `/gw/anthropic/v1/messages` and pass-through `/gw/anthropic/v1/messages/count_tokens`.
- `Openmaru.Gateway.Upstream` behaviour (for Bypass in tests / real Finch in prod).
- SSE tap parsing `message_start` / `message_delta` / `message_stop` usage without buffering beyond one event.
- Hold computation, web-search `max_uses` injection, server-tool rejection.
- `Openmaru.Gateway.InFlight` Registry (`{:goal, id}`, `{:mandate, id}`) + abort message handling.
- Error envelopes and status mapping per SPEC-06 §3.5; per-mandate rate limit.
- `x-openmaru-spend-id` header / SSE comment.

## Tests to write first
(Upstream stubbed with Bypass; price fixtures; lumen org with builder token.)
- [ ] **W02-T01** Non-stream via `x-api-key`: upstream receives the goal key in `x-api-key`, `anthropic-version` forwarded, client token absent; body passed through; spend posted at exact cost; `x-openmaru-spend-id` present.
- [ ] **W02-T02** Same via `Authorization: Bearer`.
- [ ] **W02-T03** Hold amount = SPEC-06 §3.2 formula (asserted while Bypass holds the upstream response).
- [ ] **W02-T04** Streaming: events forwarded byte-identical and in order; usage from `message_start` + last `message_delta` including cache creation/read tokens; spend-id SSE comment before close.
- [ ] **W02-T05** Missing `max_tokens` → 400 `invalid_request` in Anthropic envelope with `x-openmaru-error`.
- [ ] **W02-T06** Unpriced model → 400 `model_not_priced`.
- [ ] **W02-T07** `web_search` tool without `max_uses` → upstream sees `max_uses: 5`; hold includes 5 × per-use; `server_tool_use.web_search_requests` priced; other server tool type → 400 `unsupported_feature`.
- [ ] **W02-T08** Denials, each with correct status + envelope: no token 401; revoked 401; budget 402; goal funds 402; per-request 403; approval required (custom rule `spend llm > usd 1`) 403; paused 423; missing provider key 424.
- [ ] **W02-T09** Upstream 500/529 before output → status/body passed through; hold voided.
- [ ] **W02-T10** Stream ends without `message_stop` → full hold posted with `meta.estimated = true`.
- [ ] **W02-T11** Client disconnects mid-stream → upstream drained; actual usage posted.
- [ ] **W02-T12** `count_tokens` proxied; no ledger activity; invalid token → 401.
- [ ] **W02-T13** `x-openmaru-task`: task of the goal → record `task_id`; task of another goal → 403 `task_not_in_goal`; task-bound attenuated token without the header → 401.
- [ ] **W02-T14** Per-mandate rate limit exceeded → 429 `rate_limited`.
- [ ] **W02-T15** In-flight registration under goal and mandate; `abort` closes upstream and posts known usage (or hold with `estimated`).
- [ ] **W02-T16** No prompt/completion content in spend meta, DB, or captured logs.
- [ ] **W02-T17** Bench (`@tag :bench`): local stub upstream, p95 added latency before first byte < 50 ms.
- [ ] **W02-T18** Integration (`@tag :integration`): official `@anthropic-ai/sdk` in Node with `baseURL` at the gateway streams a response and the spend posts.

## Out of scope
OpenAI format (W03), kill-switch orchestration (A06).
