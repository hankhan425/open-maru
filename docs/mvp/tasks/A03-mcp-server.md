# A03 · MCP server

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Agents | A02, G03, C06 | M | 12 |

**Read first:** SPEC-07 §4; SPEC-04 §4 (token operations `mcp`); SPEC-09 §6 (MCP rate limit).
**Paths:** `lib/openmaru_web/mcp/**`

## Goal
Any MCP-capable agent can discover and use openmaru as tools: read its goal and charter, manage tasks, post evidence, request expenses, report metrics.

## Deliverables
- Plug at `/mcp` implementing JSON-RPC 2.0 over Streamable HTTP (POST with JSON responses; `Mcp-Session-Id` header issued on `initialize`; GET returns 405 in MVP).
- Methods: `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping`.
- The 12 tools of SPEC-07 §4 with JSON Schemas; each delegates to the owning context; results as `structuredContent` + text JSON.
- Auth via mandate token (`operation("mcp")`) or PAT; tool default goal = token goal.

## Tests to write first
- [ ] **A03-T01** `initialize` returns `protocolVersion`, `serverInfo`, `capabilities.tools`, and an `Mcp-Session-Id` header.
- [ ] **A03-T02** `tools/list` snapshot: 12 tools, names and input schemas.
- [ ] **A03-T03** No/invalid token → HTTP 401; PAT → person actor; mandate token → agent actor with default goal.
- [ ] **A03-T04** Table-driven happy path for each of the 12 tools against lumen fixtures.
- [ ] **A03-T05** Domain errors → result `isError: true` with `{code, message}` (e.g. claim while paused → `goal_paused`).
- [ ] **A03-T06** Invalid arguments → JSON-RPC error `-32602`; unknown tool → `-32602`; unknown method → `-32601`.
- [ ] **A03-T07** Notification (no `id`) → HTTP 202, empty body.
- [ ] **A03-T08** `openmaru_request_expense` with `amount_usd: "12.50"` → 12,500,000 micros (string decimal parsing, no floats).
- [ ] **A03-T09** Rate limit 300/min/token → 429.
- [ ] **A03-T10** Integration (`@tag :integration`): the official MCP TypeScript SDK client connects over Streamable HTTP, lists tools, and calls `openmaru_get_budget`.

## Out of scope
Server-initiated streams, resources, prompts.
