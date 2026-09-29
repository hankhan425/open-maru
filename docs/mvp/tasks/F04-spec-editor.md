# F04 · Spec editor, proposals, create org

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Web | F03, L07, C04 | L | 9 |

**Read first:** SPEC-08 §3 (Spec editor, Create org), §4; SPEC-01 §5, §8, §9; SPEC-07 proposals, `/orgs`; L07 WASM API.
**Paths:** `web/src/features/editor/**`, `web/src/lib/maru/**`

## Goal
Writing rules feels like a good IDE: instant diagnostics, a live charter, and a plain-English diff of what the change does before proposing it.

## Deliverables
- CodeMirror 6 editor with a maru `StreamLanguage` (or Lezer) mode, lint source backed by WASM `check`, format command, charter preview, Diff tab (loosens/tightens/neutral markers + limits change), Propose form.
- Lazy WASM loading on editor routes only.
- `/new` create-org flow with starter template and slug check.

## Tests to write first
- [ ] **F04-T01** The WASM module is dynamically imported by the editor route and not by the app entry (assert on route module imports / mocked dynamic import).
- [ ] **F04-T02** Typing debounces 50 ms then shows diagnostics as lint markers with code, message, and notes.
- [ ] **F04-T03** Format command (`Shift+Alt+F`) replaces the doc with formatted source; invalid source leaves it unchanged and shows a toast.
- [ ] **F04-T04** Charter preview updates on valid input; on errors it keeps the last valid render with a "stale" badge.
- [ ] **F04-T05** Diff tab lists change sentences with effect markers and the limits line (fixture: raise builder llm limit).
- [ ] **F04-T06** Propose requires a title; sends source + `base_version`; success navigates to the decision page.
- [ ] **F04-T07** 409 `stale_proposal` → message with an action to diff against the new active version.
- [ ] **F04-T08** Server 422 diagnostics (E501–E504) appear inline like local ones.
- [ ] **F04-T09** Tokenizer unit tests: keywords, identifiers, handles, strings, numbers, durations, comments get the expected classes.
- [ ] **F04-T10** `/new`: template prefilled, slug availability feedback, create navigates to the new org.
- [ ] **F04-T11** Unsaved-changes guard on navigation.

## Out of scope
Voting UI (F05).
