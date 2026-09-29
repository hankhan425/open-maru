# L07 · NIF + WASM bindings

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Language | T02, L02, L04, L05, L06 | M | 6 |

**Read first:** ARCHITECTURE §1, §4 (`Openmaru.Lang`), SPEC-04 §3 (performance, caching), SPEC-08 §4 (WASM usage).
**Paths:** `crates/maru_nif/`, `crates/maru_wasm/`, `apps/server/lib/openmaru/lang.ex`, `apps/server/lib/openmaru/lang/*`, `web/packages/maru-wasm/`

## Goal
Expose the language to Elixir (NIF) and the browser (WASM) with identical behavior, proven by shared vectors.

## Deliverables
- NIF functions (all DirtyCpu): `check(src, opts_json)`, `format(src)`, `source_hash(src)`, `render(ir_json)`, `diff(ir_a_json, ir_b_json)`, `compile(ir_json) -> ResourceArc`, `decide(resource, request_json)`, `cedar_text(ir_json)`.
- `Openmaru.Lang` (the only module allowed to call `Openmaru.Lang.Native`):
  - `check(source, opts \\ []) :: {:ok, %{diagnostics: [map], ir: map | nil}}`
  - `format/1 :: {:ok, String.t()} | {:error, [diagnostic]}`, `source_hash/1`, `render/1 :: {:ok, %{markdown, sections}}`, `diff/2`, `cedar_text/1`
  - `compile(version_id, ir)` cached in `:persistent_term` (key `{Openmaru.Lang, version_id}`); `decide(version_id | handle, request) :: :allow | {:deny, atom} | {:requires_approval, [String.t()]}`
  - All errors normalized to `{:error, :invalid_input | :panic | term}`; telemetry events `[:openmaru, :lang, fun, :stop]`.
- WASM exports: `check`, `format`, `sourceHash`, `render`, `diff` (no `authz`), hand-written `index.d.ts` with IR, Diagnostic, Diff, Section types.

## Tests to write first
- [ ] **L07-T01** `Lang.check(lumen)` IR equals the golden `lumen.ir.json`.
- [ ] **L07-T02** `Lang.check` of an invalid source returns `ir: nil` and diagnostics with codes and spans intact (maps with string keys matching SPEC-01 §5).
- [ ] **L07-T03** `format`, `source_hash`, `render`, `diff` outputs equal the Rust outputs for the fixture set (compare with files produced by Rust tests).
- [ ] **L07-T04** `compile` + `decide` pass every case in `tests/vectors/decide.json`.
- [ ] **L07-T05** Cross-target equivalence: for every vector in `crates/maru_core/tests/vectors/*.json` that WASM supports, NIF and WASM (invoked through Node from the Elixir test or a separate Node test reading the same vectors) produce byte-identical JSON.
- [ ] **L07-T06** 100 concurrent `decide` calls on one compiled handle return correct results.
- [ ] **L07-T07** Invalid JSON to `render`/`diff`/`decide` → `{:error, :invalid_input}`; VM stays up.
- [ ] **L07-T08** While a 256 KiB `check` runs, a ping-pong between two normal processes completes in < 10 ms (dirty scheduling works).
- [ ] **L07-T09** `compile(version_id, ir)` called twice compiles once (count telemetry events); a different version id compiles again.
- [ ] **L07-T10** Vitest in `web/packages/maru-wasm`: check/format/render/diff on lumen; `tsc --noEmit` on a usage sample passes.
- [ ] **L07-T11** WASM bundle (`.wasm` gzipped) < 1 MB; test fails above.

## Acceptance criteria
- No other Elixir module references `Openmaru.Lang.Native` (add an `xref`-based test).

## Out of scope
Using these functions in domain logic (C03+), editor UI (F04).
