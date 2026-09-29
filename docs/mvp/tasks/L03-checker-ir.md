# L03 · Checker, IR, limits analysis

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Language | L01 | L | 3 |

**Read first:** SPEC-01 §4 (all semantics), §5 (every E3xx/W4xx), §6 (IR + limits).
**Paths:** `crates/maru_core/src/{check,ir,limits,suggest}.rs`, `crates/maru_core/schema/ir.v1.json`, tests

## Goal
Validate a parsed spec and produce the normalized IR (defaults materialized, rule ids computed, limits analysed). The IR is the only thing runtimes consume.

## Deliverables
- `pub struct CheckOptions { pub now: Option<DateTime<Utc>> }`
- `pub fn check(src: &str, opts: &CheckOptions) -> CheckOutput { diagnostics, ir: Option<Ir> }` (IR only when no errors). If `parse` reports any error, return its diagnostics alone and run no semantic checks (SPEC-01 §5).
- `Ir` serde types exactly as SPEC-01 §6 (`ir_version: 1`), JSON Schema `schema/ir.v1.json`.
- Rule ids: `<goal>:r_<first 8 hex of sha256(formatted rule line)>`.
- Limits analysis per SPEC-01 §6.1.
- "Did you mean" suggestions (Levenshtein ≤ 2) for unknown references.
- Golden `tests/snapshots/lumen.ir.json`.

## Tests to write first
- [ ] **L03-T01** `lumen.maru` → no diagnostics; IR equals the golden JSON (incl. rule ids and `unapproved_monthly_max_micros = 5000000000`).
- [ ] **L03-T02** Minimal org (amend + one circle + one goal with steward) → IR has defaults: membership invite(1), amend timeout 7d/deny, `term: null`, runtime byo, on_underfunded pause, on_close return_treasury, rule timeouts 7d/deny, `fund: null`, `success: null`.
- [ ] **L03-T03** E301 for duplicate circle, agent, and goal ids; span on the second; note points to the first.
- [ ] **L03-T04** E302 unknown circle in `steward`, `approve`, `vote`, and `amend`; `cor` suggests `core`; `xyz` has no suggestion.
- [ ] **L03-T05** E303 mandate for undeclared agent ident.
- [ ] **L03-T06** E304 for each missing required field: org `amend`, circle `seats`, agent `operator`, goal `steward`.
- [ ] **L03-T07** E305 for duplicate `seats`, `term`, `holders`, `operator`, `runtime`, `fund`, `steward`, `per_request`, `expires`.
- [ ] **L03-T08** E306 holders > seats; E323 duplicate holder.
- [ ] **L03-T09** E307 approve count 0 and count > seats; count == seats ok.
- [ ] **L03-T10** E308: `0/3`, `4/3`, `1/0`, `0%`, `101%` error; `1/1`, `100%`, `1%` ok.
- [ ] **L03-T11** E309 `usd 0` from the checker; E310 `2^53` micros + 1 and E311 7 decimals come from the parser, and `check` reports exactly one diagnostic for each.
- [ ] **L03-T12** E312 duplicate mandate (same agent twice; same `@handle` twice).
- [ ] **L03-T13** E313 two `spend llm` lines in one mandate.
- [ ] **L03-T14** E314 two rules with the same subject (identical, and same subject with different procedure).
- [ ] **L03-T15** E315 `on_close: transfer` to itself and to an unknown goal.
- [ ] **L03-T16** E316: `amend: approve(core, 3)` with 2 holders; `amend: vote(core, …)` with 0 holders; `amend: vote(members, 1/2)` never errors.
- [ ] **L03-T17** E317 steward circle with no holders.
- [ ] **L03-T18** E319 `0d` in `term` and in `within`.
- [ ] **L03-T19** E322 `approve(members, 1)`.
- [ ] **L03-T20** W401 when `opts.now` ≥ expiry date; no W401 when `now` omitted.
- [ ] **L03-T21** W402 on rule `else allow` and on amend `else allow`.
- [ ] **L03-T22** W403: fund `usd 1_000 / month`, spend `usd 50 / day` (×31 = 1,550) warns; spend `usd 900 / month` doesn't; `fund … once` never warns.
- [ ] **L03-T23** W404, W405, W406, W408 each triggered by a minimal example.
- [ ] **L03-T24** Warnings-only specs still return IR; any error → `ir: None`.
- [ ] **L03-T25** Rule ids: reordering rules doesn't change ids; changing a rule's procedure changes its id; format matches `^[a-z][a-z0-9_]*:r_[0-9a-f]{8}$`.
- [ ] **L03-T26** Thresholds stored unreduced (`60%` → 60/100, `2/4` → 2/4); durations keep unit (`48h` → value 48, unit h, secs 172800).
- [ ] **L03-T27** Limits table: (a) lumen → 5,000,000,000; (b) lumen without the `spend expense` rule → 5,500,000,000; (c) `rule spend llm requires …` (no threshold, deny) excludes llm lines; (d) a thresholded rule excludes nothing; (e) an `else allow` rule excludes nothing; (f) week ×6, day ×31; (g) goal with no mandates → 0.
- [ ] **L03-T28** Diagnostics sorted by span start; checking the same source twice yields byte-identical JSON.
- [ ] **L03-T29** Every IR produced in this test suite validates against `schema/ir.v1.json` (dev-dependency `jsonschema`).
- [ ] **L03-T30** Property: generated sources never panic the checker; result is IR xor ≥ 1 error.
- [ ] **L03-T31** Parse errors stop semantic checks: `seats: 3x` gives only E103 (no E304); a steward circle with `holders: @A` gives only E106 (no E317); `fund: usd 9_007_199_255 / month from treasury` with `on_underfunded: pause` gives only E310 (no W404).

## Acceptance criteria
- All tests pass; the JSON Schema is complete enough to reject an IR missing any required field (add one negative schema test).

## Out of scope
Server-side checks E5xx (C03/C04), rendering (L04).
