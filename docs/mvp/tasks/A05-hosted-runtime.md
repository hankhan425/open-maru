# A05 · Hosted runtime (E2B) & sessions

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Agents | A01, W01, W02, M01 | L | 11 |

**Read first:** SPEC-06 §4 (all); SPEC-04 §2.1 (StartSession), §4 (attenuation); SPEC-03 §5.1 (hold timeouts); ARCHITECTURE ADR-4, ADR-7.
**Paths:** `lib/openmaru/runtime/**`, `runtime/templates/claude-code/**`, `runtime/e2b_sidecar/**` (only if needed), controllers, migrations

## Goal
Operators and stewards start a sandboxed agent session for a task; openmaru claims the task, gives the agent a narrowly attenuated token, meters compute each minute, and stops the session when work ends or budget runs out.

## Deliverables
- `Openmaru.Runtime.Adapter` behaviour; `Openmaru.Runtime.E2B` adapter using the goal's `e2b_api_key` (decide HTTP API vs Node sidecar after reading E2B docs; record the decision in the PR); `Openmaru.Runtime.FakeAdapter` for tests.
- Migrations `sessions`, `runtime_templates`; admin endpoints for templates.
- `start_session/3`, `stop_session/3`, `stop_all(goal | agent, reason)`; `SessionServer` + `DynamicSupervisor` + `Registry`; boot recovery.
- Template `runtime/templates/claude-code/`: Dockerfile, `openmaru-agent-run` entrypoint (bash), prompt template.
- Endpoints per SPEC-07 (sessions); events `session.started`, `session.stopped`.

## Tests to write first
- [ ] **A05-T01** Authorization: operator OK; steward holder OK; other member 403; `byo` agent → 409 `agent_not_hosted`; no compute line → 409 `no_compute_budget`; missing `e2b_api_key` → 424.
- [ ] **A05-T02** Start: task claimed for the agent with lease TTL = `max_duration_secs`; attenuated token (task-bound, ops api/gateway/mcp, expiry max + 600 s); 60 s compute hold; `create` called with the exact env map (incl. `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `GH_TOKEN` only when set); `exec` entrypoint; status `running`.
- [ ] **A05-T03** Compute hold denied → start aborted, lease released, adapter never called.
- [ ] **A05-T04** Tick (Clock + manual tick message): posts `elapsed × rate` for the previous interval, holds the next 60 s, updates `metered_secs`.
- [ ] **A05-T05** Tick hold denied → `kill`, final post, status `killed` with `budget_exhausted`.
- [ ] **A05-T06** Adapter reports stopped → final post, `exited` (`completed`), token revoked.
- [ ] **A05-T07** `max_duration_secs` reached → stopped with `max_duration`.
- [ ] **A05-T08** `stop_session` manual by operator; second call is a no-op returning the same session.
- [ ] **A05-T09** Boot recovery: adapter says running → server restarted; unknown/stopped → `failed` (`lost`), elapsed posted, outstanding hold voided.
- [ ] **A05-T10** `create` error → `failed` (`error`), hold voided, lease released.
- [ ] **A05-T11** E2B adapter contract tests (Bypass for HTTP, or a stub sidecar process for the Port) covering create/exec/status/kill and error mapping.
- [ ] **A05-T12** Template: Docker build in CI; `shellcheck` clean; entrypoint test with fake `maru` and `claude` on PATH verifies heartbeat loop started, `claude -p` invoked with the rendered prompt, final `note` evidence posted with exit code, and the script exits with Claude's exit code.
- [ ] **A05-T13** `GET /sessions/:id`, `GET /goals/:id/sessions` (public: status, agent, task, duration, metered cost; no env/token).

## Out of scope
Kill-switch fan-out (A06), sessions UI (F08).
