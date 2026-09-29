# T03 · Rust workspace & binding scaffolds

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Foundation | T01 | M | 1 |

**Read first:** ARCHITECTURE §1–§3; CONVENTIONS §2–§4.
**Paths:** `Cargo.toml`, `crates/*`, `apps/server/lib/openmaru/lang/native.ex`, `web/packages/maru-wasm/`

## Goal
One Cargo workspace producing the five crates and proving all three targets (NIF, WASM, CLI) call the same core function with identical output. This harness is reused by every language task.

## Deliverables
- Workspace with `maru_core` (lib), `maru_token` (lib), `maru_nif` (Rustler cdylib), `maru_wasm` (wasm-bindgen cdylib), `maru_cli` (bin `maru`).
- `maru_core::version()` and `maru_core::echo_json(&str) -> Result<String, CoreError>` (parse JSON, re-serialize with sorted keys, no whitespace).
- `maru_core` feature `authz` (default on) reserved for Cedar code; `maru_wasm` depends on `maru_core` with `default-features = false`.
- NIF: `version/0`, `echo_json/1`, all `schedule = "DirtyCpu"`; test-only `panic_test/0` behind a cargo feature enabled in `MIX_ENV=test`.
- `Openmaru.Lang.Native` (`use Rustler, otp_app: :openmaru, crate: "maru_nif", path: "../../crates/maru_nif"`) and `Openmaru.Lang.version/0`, `Openmaru.Lang.echo_json/1`.
- `wasm-pack build --target web` output packaged as `@openmaru/maru-wasm` in `web/packages/maru-wasm` with a Node-based test.
- `maru --version`, `maru --help` via clap.
- Vector file `crates/maru_core/tests/vectors/echo.json` (`[{"input": "...", "output": "..."}]`) consumed by Rust, Elixir, and Node tests.
- CI: build all targets; run Rust, NIF (via `mix test`), and WASM Node tests.

## Tests to write first
- [ ] **T03-T01** Rust: `version()` equals `env!("CARGO_PKG_VERSION")`.
- [ ] **T03-T02** Rust: `echo_json` vectors pass; invalid JSON → `CoreError::InvalidJson`.
- [ ] **T03-T03** Elixir: `Openmaru.Lang.version/0` equals the Rust version string.
- [ ] **T03-T04** Elixir: every `echo.json` vector through the NIF produces the exact expected output.
- [ ] **T03-T05** Elixir: 50 concurrent processes calling `echo_json/1` all get correct results.
- [ ] **T03-T06** Elixir: `panic_test/0` returns `{:error, :panic}` (or raises `ErlangError` wrapped by `Openmaru.Lang` into `{:error, :panic}`) without crashing the VM.
- [ ] **T03-T07** Node: `@openmaru/maru-wasm` `version()` and `echo_json` vectors match.
- [ ] **T03-T08** CLI (assert_cmd): `maru --version` prints `maru <version>`; `maru --help` exits 0; `maru nope` exits 2.
- [ ] **T03-T09** CI job builds `maru_wasm` for `wasm32-unknown-unknown` with `authz` disabled.

## Acceptance criteria
- `cargo clippy --all-targets -- -D warnings` clean; all three targets built in CI.

## Out of scope
Any language logic (L01+), tokens (M01).
