# L01 · Lexer & parser → AST

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Language | T03 | L | 2 |

**Read first:** SPEC-01 §1–§3, §5 (diagnostic shape, E1xx, E2xx), §4.8 (duration units).
**Paths:** `crates/maru_core/src/{lexer,parser,ast,diag,span}.rs`, `crates/maru_core/tests/`

## Goal
Turn source text into a typed AST with precise spans and trivia (comments), and report lexical/syntax errors in the SPEC-01 diagnostic shape with good recovery.

## Deliverables
- `Span {start: Pos, end: Pos}`, `Pos {line, col, offset}` (1-based line/col; col counts Unicode scalar values).
- `Diagnostic {code, severity, message, span, notes}` + `serde` serialization matching SPEC-01 §5.
- Lexer producing tokens with spans; keywords per SPEC-01 §2.
- Hand-written recursive-descent parser covering every production in SPEC-01 §3, with recovery (skip to next item keyword or matching `}`).
- AST types mirroring the grammar; durations keep `{value, unit}`; money literals keep their source text and parsed micros; comments attached as leading/trailing trivia.
- `pub fn parse(src: &str) -> ParseOutput { file: Option<ast::File>, diagnostics: Vec<Diagnostic> }`.
- Test-only naive printer for property tests.

## Tests to write first
Unit (table-driven where natural), snapshot (`insta`), property (`proptest`).
- [ ] **L01-T01** `lumen.maru` parses with zero diagnostics; AST snapshot (spans stripped).
- [ ] **L01-T02** Every keyword lexes as a keyword; using any keyword as a circle/agent/goal id → E107.
- [ ] **L01-T03** Identifiers: `a`, `a_1`, 40-char ok; 41 chars, `A`, `aB`, `1a`, `_a` → E107 spanning the word.
- [ ] **L01-T04** Handles: `@mina`, `@a-b_c`, `@ab` ok; `@a`, `@-a`, `@Mina`, 31-char body → E106.
- [ ] **L01-T05** Numbers: `0`, `12_000`, `1_0`, `12.50` ok; `12__000`, `_12`, `12_`, `1._5` → E103.
- [ ] **L01-T06** Money with 7 decimals (`usd 1.1234567`) → E311; 6 decimals ok and micros exact (`usd 0.000001` = 1).
- [ ] **L01-T07** Durations `30m 48h 7d 2w 1y` → AST `{value, unit}` and seconds 1800/172800/604800/1209600/31536000; `7x`, `7mo` → E104.
- [ ] **L01-T08** Dates: `2027-06-30`, `2028-02-29` ok; `2027-02-29`, `2027-13-01`, `1999-01-01`, `3000-01-01`, `2027-6-30` → E105.
- [ ] **L01-T09** Thresholds parse in `vote(...)`: `2/3`, `2 / 3`, `60%` → fraction AST (range errors are L03's job).
- [ ] **L01-T10** Strings: `\"`, `\\`, `\n` decoded; unterminated → E102; raw newline → E108; 501 chars after unescaping → E108; 500 ok.
- [ ] **L01-T11** Comments: leading comments attach to the next item; trailing comments attach to the item on the same line; comment before `}` attaches to the block end.
- [ ] **L01-T12** `$` or `;` in source → E101 with exact line/col.
- [ ] **L01-T13** Columns count Unicode scalars: an error after `"é🦀"` on the same line reports the expected column.
- [ ] **L01-T14** Missing closing `}` → E202 with span at EOF.
- [ ] **L01-T15** `org "A" {} org "B" {}` → E203 on the second `org`.
- [ ] **L01-T16** Recovery: two independent errors in two different goals → exactly two diagnostics.
- [ ] **L01-T17** Recovery: unknown item (`budget: 5`) inside a goal → one E201 listing expected items; the following `mandate` is still in the AST.
- [ ] **L01-T18** CRLF input yields an AST equal to the LF version (spans ignored).
- [ ] **L01-T19** Source > 256 KiB → single E109, no parse attempted.
- [ ] **L01-T20** One minimal snippet per grammar production (membership open/invite; circle seats/term/holders; agent operator/runtime byo/hosted; goal steward/purpose/fund month/week/day/once/on_underfunded both/on_close both/success with and without `by`, each comparator, negative and decimal values; mandate spend each category/per_request/can each capability/expires; rule subjects: `spend`, `spend llm`, `spend > usd 5`, `spend expense > usd 5`, `close`; procedures approve/vote circle/vote members; timeout deny/allow) parses to the expected node kinds.
- [ ] **L01-T21** Property: arbitrary strings (incl. random bytes decoded lossily) never panic lexer or parser (10k cases).
- [ ] **L01-T22** Property: randomly generated ASTs printed with the test printer re-parse to an equal AST.
- [ ] **L01-T23** For `lumen.maru`, every AST node's span slices the source to exactly that node's text.

## Acceptance criteria
- All tests pass; clippy clean; parsing a generated 2,000-line spec takes < 5 ms in `cargo bench` (report, not gate).

## Out of scope
Semantic checks (L03), formatting (L02).

## Notes
Keep the AST free of semantic defaults; the checker materializes defaults in the IR.
