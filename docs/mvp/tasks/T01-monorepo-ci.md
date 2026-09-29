# T01 · Monorepo, toolchains, CI

| Epic | Depends on | Size | Wave |
|---|---|---|---|
| Foundation | — | S | 0 |

**Read first:** ARCHITECTURE §2–§3, CONVENTIONS §3, README.
**Paths:** repo root, `.github/workflows/`, `scripts/`, `compose.yaml`, `justfile`, `docs/mvp/`

## Goal
Create the empty monorepo with pinned toolchains, local services, and a CI pipeline that later tasks fill in without touching CI again.

## Deliverables
- Directory layout from ARCHITECTURE §3 (placeholders with a one-line README where empty).
- `.tool-versions` (Erlang, Elixir, Node LTS, pnpm) and `rust-toolchain.toml` (stable + `wasm32-unknown-unknown` target, rustfmt, clippy).
- `compose.yaml`: Postgres 16 (db `openmaru_dev`, `openmaru_test`), MinIO with bucket `openmaru-dev`.
- `justfile` recipes: `setup`, `check` (= `check-rust`, `check-elixir`, `check-web`), `test`, `services-up`. Each stack recipe is a successful no-op if its manifest doesn't exist yet (`Cargo.toml`, `apps/server/mix.exs`, `web/package.json`).
- `scripts/verify-layout` and `scripts/wait-for-services`.
- CI workflow: jobs `rust`, `elixir`, `web`, `layout`; caches for cargo, deps/_build, pnpm store; services container for Postgres/MinIO in `elixir` job; `actionlint` step.
- Copy this `docs/mvp/` folder into the repo; create empty `docs/mvp/OPEN_QUESTIONS.md` with a template entry format.
- `.editorconfig`, `.gitignore` covering all stacks.

## Tests to write first
- [ ] **T01-T01** `scripts/verify-layout` exits 0 and checks every directory in ARCHITECTURE §3 exists.
- [ ] **T01-T02** `scripts/verify-layout` checks every file listed in `docs/mvp/README.md`'s layout table exists (fails if one is removed — verify by a negative test that runs it against a temp copy missing a file).
- [ ] **T01-T03** `just check` exits 0 on a fresh clone with no stack manifests present.
- [ ] **T01-T04** `just services-up && scripts/wait-for-services` succeeds within 60 s (CI job `layout`).
- [ ] **T01-T05** `actionlint` passes on all workflow files.
- [ ] **T01-T06** A script asserts toolchain pins exist and CI reads them (workflow uses `.tool-versions` / `rust-toolchain.toml`, not hardcoded versions).

## Acceptance criteria
- CI green on the PR; all four jobs run on push and pull_request.
- No application code yet.

## Out of scope
Phoenix app (T02), Rust crates (T03), web app (F01).
