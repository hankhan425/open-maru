# L02 · Formatter

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Language | L01 | M | 3 |

**Read first:** SPEC-01 §1 (spec hash), §7.
**Paths:** `crates/maru_core/src/fmt.rs`, `crates/maru_core/tests/fmt*.rs`, fixtures

## Goal
A canonical, idempotent formatter. The canonical form defines the spec hash, so formatting-only edits never change a spec's identity.

## Deliverables
- `pub fn format(src: &str) -> Result<String, Vec<Diagnostic>>`
- `pub fn source_hash(src: &str) -> Result<String, Vec<Diagnostic>>` → `"sha256:<hex>"` of `format(src)`.
- Fixture `tests/fixtures/lumen.messy.maru` (same AST as lumen, ugly layout: mixed indentation, several items per line, extra blank lines, `usd 12000`, `2 / 3`, `@a,@b`).

## Tests to write first
- [ ] **L02-T01** `format(lumen.maru)` is byte-identical to the input.
- [ ] **L02-T02** `format(lumen.messy.maru)` == `lumen.maru`.
- [ ] **L02-T03** Numeric vectors: `500`→`500`, `4000`→`4_000`, `12000`→`12_000`, `1_0`→`10`, `1234567`→`1_234_567`, `12.5`→`12.50`, `3.000100`→`3.0001`, `7.00`→`7`, `0.000125`→`0.000125`, metric `10000`→`10_000`, `-1500.5` → `-1_500.5`.
- [ ] **L02-T04** Blank-line rules (table of input→output): blank before/after each block item; blank before the first rule after a non-rule item; none at block start/end; never two in a row.
- [ ] **L02-T05** Comments: leading comment stays above its item at the item's indentation; trailing comment stays on the line after exactly one space; comment before `}` stays inside the block.
- [ ] **L02-T06** Lists normalize to `a, b, c` (holders and capabilities).
- [ ] **L02-T07** Item order is preserved (rule before mandate stays in that order).
- [ ] **L02-T08** Input with syntax errors → `Err(diagnostics)`.
- [ ] **L02-T09** Property: `format(format(x)) == format(x)` for generated valid sources.
- [ ] **L02-T10** Property: `parse(format(x))` AST equals `parse(x)` AST ignoring spans and trivia.
- [ ] **L02-T11** Output uses LF, has no trailing whitespace, and ends with exactly one newline; CRLF input normalized.
- [ ] **L02-T12** Strings re-emitted with canonical escapes (`\"`, `\\`, `\n`), content unchanged.
- [ ] **L02-T13** `source_hash` equal for `lumen.maru` and `lumen.messy.maru`; differs when a comment changes.

## Acceptance criteria
- Tests pass; formatter never panics on any input (reuse L01's fuzz strategy).

## Out of scope
CLI wiring (L08), editor integration (F04).
