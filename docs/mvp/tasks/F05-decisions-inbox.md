# F05 · Decisions & inbox

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | F04, G03 | M | 12 |

**Read first:** SPEC-02 §4; SPEC-08 §3 (Decisions); SPEC-07 decisions, inbox, `org:*`/`user:*` channels.
**Paths:** `web/src/features/decisions/**`

## Goal
People with a say see what needs them, understand exactly what they're approving, and vote in one click.

## Deliverables
- `/inbox`, `/o/:slug/proposals`, `/decisions/:id` for amend and spend decisions; holder acceptance items; live updates.

## Tests to write first
- [ ] **F05-T01** Inbox lists eligible open decisions by deadline and pending holder acceptances; empty state.
- [ ] **F05-T02** Amendment page: title, rationale, change sentences with effects, charter before/after toggle, ballots, required count, countdown.
- [ ] **F05-T03** Spend page: requester, amount, category, memo, tier, receipt link (members), triggering rule sentence(s).
- [ ] **F05-T04** Vote yes/no updates optimistically; `not_eligible`/`already_voted` roll back with a message.
- [ ] **F05-T05** `decision` channel events update ballots and resolution live.
- [ ] **F05-T06** Countdown shows relative time and switches to "deadline passed — resolving" at zero.
- [ ] **F05-T07** Cancel visible only to the author.
- [ ] **F05-T08** Accept/decline holder appointment from the inbox.
- [ ] **F05-T09** Axe: no violations.
