# F06 · Goal page & ledger

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | F03, G04, A02, C06, P04 | L | 13 |

**Read first:** SPEC-08 §1, §3 (Goal, Goal ledger, Public ledger), §5; SPEC-03 §9; SPEC-07 goal/public rows, `public:goal:*`.
**Paths:** `web/src/features/goal/**`

## Goal
The page supporters and contributors live on: status, money in and out by provenance, live work and evidence, and the rules — every number traceable to ledger entries.

## Deliverables
- `/o/:slug/g/:goal`: header/status, funding meter, success progress, spend by category × tier, live ledger feed, tasks board with evidence and review actions, activity, charter section, whether the goal takes pledges and donations (or why not), unspent outside money and its cap, and the margin (`GET /orgs/:slug/funding`, P04), Pledge/Donate entry point (F07 wires it).
- `/o/:slug/g/:goal/ledger` with filters, pagination, CSV export; `/ledger` checkpoints page.

## Tests to write first
- [ ] **F06-T01** Header shows title, status chip (incl. pause reason), steward, success progress state.
- [ ] **F06-T02** Funding meter segments allocated/spent/held/available sum to allocated; shortfall shown when > 0.
- [ ] **F06-T03** Category × tier breakdown with badges; clicking a segment opens the ledger filtered accordingly.
- [ ] **F06-T04** Live `ledger` events prepend entries inside a fixed-height region (no layout shift); entries show principal, model/tokens, tier, task link.
- [ ] **F06-T05** Tasks board columns by status; evidence per task with kind icons; Accept/Reject visible only when `viewer.permissions` includes ReviewTask.
- [ ] **F06-T06** Activity feed paginates with a cursor.
- [ ] **F06-T07** Governance section renders the goal's charter section through `MarkdownInline` (SPEC-08 §4).
- [ ] **F06-T08** Ledger page filters (category, tier, principal, date range) map to query params; CSV export contains the filtered rows (≤ 10,000) with money as decimal strings.
- [ ] **F06-T09** Checkpoints page lists checkpoints and shows the `maru ledger verify` command.
- [ ] **F06-T10** Every money figure links to a filtered ledger URL.
- [ ] **F06-T11** Axe: no violations.
