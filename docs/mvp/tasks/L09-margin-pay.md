# L09 · Margin and pay rules in maru

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Language | L05, L06 | M | 6 |

**Read first:** OPEN_QUESTIONS OQ-16; SPEC-01 §2 (`PERCENT`, keywords), §3 (`margin`, `pay`), §4.9, §5 (E305, E326–E328, W409, spans), §6 (`margin_percent`, `pay`), §7, §8 (`## Earnings`), §9 (`margin_changed`, `pay_*`).
**Paths:** `crates/maru_core/src/{lexer,parser,ast,check,ir,fmt,charter,human,diff}.rs`, `crates/maru_core/schema/ir.v1.json`, `crates/maru_core/tests/**`, `docs/mvp/specs/examples/earnings.{maru,charter.md}`

## Goal
An org states in its spec what supporters pay above cost and who gets a share of it: `margin: 15%` and `pay @mina 40% <= usd 4_000 / month`. Both are checked, formatted, rendered in the charter and diffed like every other construct (ADR-8: SPEC-05 §8.10 enforces them).

## Deliverables
- Keywords `margin` and `pay`. The parser reads `margin: P%` and `pay @h P% <= usd X / month` as org items, with the usual error recovery.
- Checker:
  - E305 for a second `margin`, E326 for a percentage out of range, E327 for shares over 100%, E328 for a second pay rule for one person, W409 for pay rules without a margin;
  - spans and suppression as in SPEC-01 §5.
- IR fields `margin_percent` and `pay`, in `ir.v1.json` and every IR fixture. Cedar `compile` accepts them and generates no policies from them.
- Formatter: `margin: 15%`, `pay @mina 40% <= usd 4_000 / month`, with grouping and spacing as SPEC-01 §7.
- Charter: the `## Earnings` section and its structured form. New golden pair `specs/examples/earnings.maru` / `earnings.charter.md` (lumen is unchanged).
- Differ: `margin_changed`, `pay_added`, `pay_removed`, `pay_changed`, with SPEC-01 §9's effects and sentences.
- Shared vectors regenerated where outputs change.

## Tests to write first
- [ ] **L09-T01** Parse and format: `margin: 015%` → `margin: 15%`; `pay @mina 40% <= usd 4000 / month` → `usd 4_000`. Formatting is idempotent and AST-preserving (extend the L02 property strategies).
- [ ] **L09-T02** Parse errors: `pay @mina 40% <= usd 10 / week` → E201 (expected `month`); `pay mina 40% …` → E201; `margin: 15` → E201.
- [ ] **L09-T03** Checks:
  - `margin: 0%` and `margin: 1001%` → E326, while `margin: 1000%` passes; `pay @a 101% …` → E326.
  - Shares 60% + 50% → E327 on the second rule. With a repeat of @a, E328 is reported at the second rule and that rule is left out of the total.
  - A second `margin` → E305. Pay rules without a margin → W409 on the first.
- [ ] **L09-T04** IR: `margin_percent` and `pay` (payee without `@`, `share_percent`, `max_micros`), and `null` / `[]` when absent. The schema validates every fixture.
- [ ] **L09-T05** Charter: the golden `earnings.charter.md`; the section is omitted for lumen. With pay rules but no margin, it reads "There is no margin, so the org has no earnings."
- [ ] **L09-T06** Diff:
  - 10% → 15% is `loosens` with "The margin rises from 10% to 15%."; removing the margin is `tightens`.
  - Adding a pay rule is `loosens`; removing one is `tightens`.
  - A share up with the max down is `loosens`, with the `pay_changed` sentence.
  - Changes are ordered as SPEC-01 §9.
- [ ] **L09-T07** `decide` vectors are unchanged for IRs that gain `margin_percent` and `pay`.

## Out of scope
Earning and paying (P04, P06). Server check E505 (C03).
