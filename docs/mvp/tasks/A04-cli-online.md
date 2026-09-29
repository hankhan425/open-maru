# A04 · CLI online commands

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Agents | A02, G03, G04, C06, M01 | L | 13 |

**Read first:** SPEC-07 §5 (online commands, exit codes), §1, §2; SPEC-03 §7 (encoding for `ledger verify`); SPEC-04 §4 (attenuation forms); SPEC-06 §3 (setup snippet).
**Paths:** `crates/maru_cli/src/{api,auth,commands/*}.rs`, `crates/maru_cli/tests/`

## Goal
Humans and agents drive openmaru from a terminal: log in, propose spec changes, work tasks, post evidence, claim expenses, mint/attenuate tokens, follow activity, and verify the ledger independently.

## Deliverables
- API client (`reqwest` + rustls) with error-envelope mapping to exit codes (401→5, 402/403/423→3, 422 spec errors→4, other→1).
- Credentials: `~/.config/openmaru/credentials.toml` (0600) via `directories`; `OPENMARU_TOKEN`, `OPENMARU_API_URL` env.
- All online commands in SPEC-07 §5; `--json` everywhere; tables for humans.
- `log --follow` over Phoenix Channels (websocket, V2 JSON serializer, heartbeat, reconnect with backoff).
- `ledger verify` implementing SPEC-03 §7 in Rust, reading public endpoints.
- `token attenuate` using `maru_token` offline.

## Tests to write first
(`httpmock`/`wiremock` server; `assert_cmd`)
- [ ] **A04-T01** `login`: prints code + URL, polls at `interval`, honors `slow_down`, writes credentials with mode 0600.
- [ ] **A04-T02** `OPENMARU_TOKEN` overrides the credentials file; `--api` overrides `OPENMARU_API_URL`.
- [ ] **A04-T03** `whoami` human and `--json`.
- [ ] **A04-T04** Unauthenticated call → exit 5 with `run: maru login`.
- [ ] **A04-T05** `spec pull` writes the active source; `spec propose` runs local check first (errors → exit 4, no HTTP call), then POSTs and prints decision id + change sentences.
- [ ] **A04-T06** `decision vote <id> yes` OK; `not_eligible` → exit 3.
- [ ] **A04-T07** `goal show`, `budget` render tables; `--json` prints raw API JSON.
- [ ] **A04-T08** `task list/show/create/claim/heartbeat/release/submit` hit the right endpoints; claim denied `goal_paused` → exit 3 with the code.
- [ ] **A04-T09** `evidence add --file`: presign → PUT with checksum → complete → post evidence, in that order.
- [ ] **A04-T10** `expense request --amount 12.50` sends `"12500000"`; `--amount 1.2345678` → exit 2; 202 prints decision ids.
- [ ] **A04-T11** `metric report` posts decimal string value.
- [ ] **A04-T12** `token mint` prints the token once plus a setup snippet with `ANTHROPIC_BASE_URL=<api>/gw/anthropic` and `ANTHROPIC_AUTH_TOKEN=<token>`, an OpenAI `base_url`, and an MCP config block; `token revoke`.
- [ ] **A04-T13** `token attenuate --operation gateway --task t --max-request-usd 5` (stdin token) produces a token that `maru_token::verify` accepts only under those constraints.
- [ ] **A04-T14** `log --follow` joins `public:goal:<id>`, prints events, reconnects after a dropped socket.
- [ ] **A04-T15** `ledger verify` against fixtures built from `ledger_vectors.json` → ok; a tampered amount → exit 1 naming the first bad seq.
- [ ] **A04-T16** Error envelope → human message; exit-code mapping table-driven over status codes.

## Out of scope
Offline language commands (L08).
