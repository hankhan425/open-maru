# L05 · Semantic differ

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Language | L04 | M | 5 |

**Read first:** SPEC-01 §9 (kinds, effects, sentences, ordering), §6.1.
**Paths:** `crates/maru_core/src/diff.rs`, tests, fixtures `tests/fixtures/diff/*.maru`

## Goal
Explain what an amendment *does*: a list of typed changes, each marked loosens/tightens/neutral with a human sentence, plus per-goal change in unapproved monthly spend. Voters read this instead of a text diff.

## Deliverables
- `pub fn diff(before: &Ir, after: &Ir) -> Diff { changes: Vec<Change>, limits: Vec<LimitChange> }` with serde output.
- Fixture pairs under `tests/fixtures/diff/` (each a small edit of lumen).

## Tests to write first
- [ ] **L05-T01** `diff(lumen, lumen)` → no changes; limits before == after.
- [ ] **L05-T02** builder llm 4,000 → 6,000: one `mandate_limit_changed`, `loosens`, sentence exactly `builder's AI-model limit on Open cloud image editor rises from $4,000 to $6,000 per month.`; limits 5,000,000,000 → 7,000,000,000.
- [ ] **L05-T03** Decrease → `falls`, `tightens`.
- [ ] **L05-T04** New category line → `… is set to $X per month.`, `loosens`; removed line → `… is removed.`, `tightens`.
- [ ] **L05-T05** `mandate @carol {…}` added → `@carol gets a new mandate on Open cloud image editor.`, `loosens`; removal `tightens`.
- [ ] **L05-T06** Removing `rule spend > usd 500 …` → `Open cloud image editor no longer requires approval for any spend over $500.`, `loosens`; adding a rule `tightens`.
- [ ] **L05-T07** `rule_changed`: approve(core,1)→approve(core,2) tightens; →approve(core,1) with `else allow` loosens; approve→vote (kind change) neutral.
- [ ] **L05-T08** Reordering rules or mandates produces no changes.
- [ ] **L05-T09** `holder_added` `@sam joins core.`; `holder_removed` `@jo leaves core.`; both neutral.
- [ ] **L05-T10** `amend_changed`: 2/3→3/4 tightens; 2/3→1/2 loosens; different circle neutral; deny→allow loosens.
- [ ] **L05-T11** Membership invite→open loosens; sponsors 1→2 tightens.
- [ ] **L05-T12** Capabilities: add only → loosens; remove only → tightens; add + remove → loosens.
- [ ] **L05-T13** Expiry later or removed → loosens; earlier or newly added → tightens.
- [ ] **L05-T14** per_request up or removed → loosens; down or added → tightens.
- [ ] **L05-T15** Period change compares monthly-normalized limits: 4,000/month → 150/day (4,650) loosens; → 500/week (3,000) tightens.
- [ ] **L05-T16** goal/circle/agent added/removed and field changes are neutral with `<Thing> changes from <before> to <after>.`-style sentences; agent runtime byo→hosted loosens.
- [ ] **L05-T17** Ordering: a diff touching org fields, a circle, an agent, and two goals lists changes in SPEC-01 §9 order (removed items last).
- [ ] **L05-T18** JSON output shape snapshot for a multi-change diff.
- [ ] **L05-T19** Property: `diff(a, a)` is empty for generated IRs; `diff(a, b)` empty ⇒ IRs equal ignoring `source_hash`.

## Acceptance criteria
- Every change kind in SPEC-01 §9 is produced by at least one test.

## Out of scope
UI presentation (F04/F05).
