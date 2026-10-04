# F08 · Agents, mandates, tokens, secrets, kill switch UI

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | F06, A05, A06, W01 | M | 14 |

**Read first:** SPEC-04 §4; SPEC-06 §1, §2.1, §4, §5; SPEC-08 §3 (Settings); SPEC-07 mandates/tokens/secrets/sessions/pause rows.
**Paths:** `web/src/features/settings/{agents,secrets,sessions}/**`, `web/src/features/goal/KillSwitch.tsx`

## Goal
Operators and stewards connect agents safely (scoped tokens with copy-paste setup), manage BYOK secrets, watch sessions, and hit the brakes.

## Deliverables
- Mandates panel, token mint/list/revoke, setup snippets, secrets form with the model endpoint picker, sessions list with start/stop, Pause/Resume goal and Stop agent flows.

## Tests to write first
- [ ] **F08-T01** Mandates list shows each mandate's charter sentence(s) and token count.
- [ ] **F08-T02** Mint (operator only): label + TTL; token shown once with copy; snippet tabs: Claude Code (`ANTHROPIC_BASE_URL=<origin>/gw/anthropic`, `ANTHROPIC_AUTH_TOKEN`), OpenAI SDK (`base_url=<origin>/gw/openai/v1`), MCP config (`<origin>/mcp`); closing the dialog clears the token from state.
- [ ] **F08-T03** Token list with revoke confirmation → revoked state.
- [ ] **F08-T04** Secrets form is write-only; after save shows last4; delete confirmation. The model endpoint picker lists active endpoints of each format (`/public/provider-endpoints`), shows the current choice, and saves a new one.
- [ ] **F08-T05** Sessions list updates live; "Start session" offers only hosted agents with a compute line; Stop button.
- [ ] **F08-T06** Pause goal requires typing the goal ident; afterwards a banner and Resume button; errors surfaced.
- [ ] **F08-T07** Stop agent confirmation; result summary (tokens revoked, sessions stopped, requests aborted).
- [ ] **F08-T08** Controls hidden or disabled according to `viewer.permissions`.
- [ ] **F08-T09** Axe: no violations.
