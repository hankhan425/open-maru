# L08 · CLI language commands

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Language | L02, L04, L05, L06 | M | 6 |

**Read first:** SPEC-07 §5 (offline commands, exit codes), SPEC-01 §5 (diagnostics).
**Paths:** `crates/maru_cli/src/{main,lang}.rs`, `crates/maru_cli/tests/`

## Goal
Offline `maru` commands for authors and agents: check, format, render, diff, explain, policy. Agents can validate a proposed spec change locally before submitting.

## Deliverables
- Commands: `fmt [--check] <files…>`, `check <file> [--now <ts>] [--json]`, `render <file> [--format md|json]`, `diff <old> <new> [--json]`, `explain <file> --principal <agent|@handle> --action <action> --goal <id> [--category c] [--amount usd] [--metric m] [--approved <id>…] [--now ts] [--holders circle=@a,@b…]`, `policy <file>`.
- `-` reads from stdin. Human diagnostics rustc-style (`file:line:col`, code, message, source line with carets, notes). Colors only on TTY, disabled by `NO_COLOR`.
- Exit codes per SPEC-07 §5.
- Amounts parsed from decimal strings to micros without floats.

## Tests to write first
(`assert_cmd` + `insta` snapshots of stdout/stderr)
- [ ] **L08-T01** `maru check lumen.maru` → exit 0, `ok (0 warnings)`.
- [ ] **L08-T02** `maru check bad.maru` (3 errors, 1 warning) → exit 4; rustc-style output snapshot.
- [ ] **L08-T03** `maru check --json` prints `{diagnostics, ir}`; exit 4 when errors.
- [ ] **L08-T04** `--now 2027-02-01T00:00:00Z` produces W401 for lumen's builder mandate.
- [ ] **L08-T05** `maru fmt messy.maru` rewrites in place; rerun changes nothing; `--check` exits 1 listing files needing changes, 0 when clean.
- [ ] **L08-T06** `maru fmt a.maru broken.maru` formats `a`, reports `broken`, exits 4.
- [ ] **L08-T07** `maru render lumen.maru` stdout == golden charter; `--format json` prints sections.
- [ ] **L08-T08** `maru diff` human output marks each change `+` (loosens), `−` (tightens), `·` (neutral) followed by the sentence, then limits lines; `--json` prints the diff.
- [ ] **L08-T09** `maru explain` allow → exit 0 `allow`; requires approval → exit 3 listing rule ids and their charter sentences; deny → exit 3 with reason code and a one-line human explanation.
- [ ] **L08-T10** `maru policy lumen.maru` equals the L06 Cedar snapshot.
- [ ] **L08-T11** `-` stdin works for `check`, `fmt` (prints to stdout), `render`.
- [ ] **L08-T12** Missing file → exit 1 with `cannot read <path>`; bad flags → exit 2.
- [ ] **L08-T13** No ANSI codes when stdout isn't a TTY or `NO_COLOR` is set.
- [ ] **L08-T14** `--amount 12.50` → 12,500,000 micros; `12.5000001` → exit 2 (too many decimals).

## Out of scope
Online commands (A04).
