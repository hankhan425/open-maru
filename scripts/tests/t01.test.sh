#!/usr/bin/env bash
# Tests for task T01 (monorepo, toolchains, CI). Run: scripts/tests/t01.test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# T01-T01 verify-layout exits 0 and checks every ARCHITECTURE §3 directory
test_T01_T01_verify_layout_passes_on_repo() {
  "$ROOT/scripts/verify-layout" "$ROOT"
}

test_T01_T01_verify_layout_fails_when_architecture_dir_missing() {
  local tmp; tmp="$(copy_tree)"
  rm -rf "$tmp/crates/maru_core"
  expect_fail "$tmp/scripts/verify-layout" "$tmp"
  grep -q "crates/maru_core" <<<"$FAIL_OUT" || { echo "missing dir not named: $FAIL_OUT"; exit 1; }
}

test_T01_T01_verify_layout_covers_every_architecture_dir() {
  local dir
  for dir in apps/server apps/server/lib/openmaru apps/server/lib/openmaru_web apps/server/native \
    apps/server/test crates/maru_core crates/maru_token crates/maru_nif crates/maru_wasm crates/maru_cli \
    web web/src/app web/src/routes web/src/features web/src/components web/src/lib web/src/styles \
    web/tests web/tests/e2e runtime/templates/claude-code runtime/e2b_sidecar docs/mvp .github/workflows; do
    local tmp; tmp="$(copy_tree)"
    rm -rf "${tmp:?}/$dir"
    expect_fail "$tmp/scripts/verify-layout" "$tmp" || { echo "not checked: $dir"; exit 1; }
    rm -rf "$tmp"
  done
}

# T01-T02 verify-layout checks every file in the README layout table (negative test on a temp copy)
test_T01_T02_verify_layout_fails_when_readme_listed_file_missing() {
  local tmp; tmp="$(copy_tree)"
  rm "$tmp/docs/mvp/specs/SPEC-03-ledger.md"
  expect_fail "$tmp/scripts/verify-layout" "$tmp"
  grep -q "SPEC-03-ledger.md" <<<"$FAIL_OUT" || { echo "missing file not named: $FAIL_OUT"; exit 1; }
}

test_T01_T02_verify_layout_fails_when_tasks_glob_empty() {
  local tmp; tmp="$(copy_tree)"
  rm "$tmp"/docs/mvp/tasks/*.md
  expect_fail "$tmp/scripts/verify-layout" "$tmp"
}

# T01-T03 `just check` exits 0 on a fresh clone with no stack manifests present
test_T01_T03_just_check_passes_without_manifests() {
  command -v just >/dev/null || { echo "just not installed"; exit 1; }
  local tmp; tmp="$(copy_tree)"
  [ ! -e "$tmp/Cargo.toml" ] && [ ! -e "$tmp/apps/server/mix.exs" ] && [ ! -e "$tmp/web/package.json" ] \
    || { echo "manifests present"; exit 1; }
  (cd "$tmp" && just check)
}

test_T01_T03_justfile_has_required_recipes() {
  local r
  for r in setup check check-rust check-elixir check-web test services-up; do
    (cd "$ROOT" && just --show "$r" >/dev/null) || { echo "missing recipe $r"; exit 1; }
  done
}

# T01-T04 `just services-up && scripts/wait-for-services` succeeds within 60 s (needs Docker; CI job `layout`)
test_T01_T04_services_come_up_within_60s() {
  docker info >/dev/null 2>&1 || skip "docker daemon not running (covered by CI job layout)"
  cd "$ROOT" && just services-up && timeout 60 scripts/wait-for-services
}

test_T01_T04_compose_defines_postgres_and_minio() {
  cd "$ROOT"
  grep -q 'postgres:16' compose.yaml
  grep -q 'openmaru_dev' compose.yaml
  grep -q 'openmaru_test' compose.yaml
  grep -qi 'minio' compose.yaml
  grep -q 'openmaru-dev' compose.yaml
  docker compose config -q 2>/dev/null || skip "docker compose unavailable for config validation"
}

# T01-T05 actionlint passes on all workflow files
test_T01_T05_actionlint_passes() {
  command -v actionlint >/dev/null || { echo "actionlint not installed"; exit 1; }
  cd "$ROOT"
  ls .github/workflows/*.yml >/dev/null
  actionlint .github/workflows/*.yml
}

test_T01_T05_ci_has_required_jobs_and_triggers() {
  cd "$ROOT"
  local job
  for job in rust elixir web layout; do
    grep -Eq "^  ${job}:" .github/workflows/ci.yml || { echo "missing job $job"; exit 1; }
  done
  grep -q 'push:' .github/workflows/ci.yml
  grep -q 'pull_request:' .github/workflows/ci.yml
}

# T01-T06 toolchain pins exist and CI reads them rather than hardcoding versions
test_T01_T06_verify_toolchain_passes_on_repo() {
  "$ROOT/scripts/verify-toolchain" "$ROOT"
}

test_T01_T06_verify_toolchain_fails_without_tool_versions() {
  local tmp; tmp="$(copy_tree)"
  rm "$tmp/.tool-versions"
  expect_fail "$tmp/scripts/verify-toolchain" "$tmp"
}

test_T01_T06_verify_toolchain_fails_without_rust_toolchain() {
  local tmp; tmp="$(copy_tree)"
  rm "$tmp/rust-toolchain.toml"
  expect_fail "$tmp/scripts/verify-toolchain" "$tmp"
}

test_T01_T06_verify_toolchain_fails_when_ci_hardcodes_version() {
  local tmp; tmp="$(copy_tree)"
  printf '\n# injected\n      - uses: actions/setup-node@v4\n        with:\n          node-version: 22\n' >> "$tmp/.github/workflows/ci.yml"
  expect_fail "$tmp/scripts/verify-toolchain" "$tmp"
}

test_T01_T06_rust_toolchain_has_wasm_target_and_components() {
  cd "$ROOT"
  grep -q 'wasm32-unknown-unknown' rust-toolchain.toml
  grep -q 'rustfmt' rust-toolchain.toml
  grep -q 'clippy' rust-toolchain.toml
  grep -Eq '^(erlang|elixir|nodejs|pnpm) ' .tool-versions
  local t
  for t in erlang elixir nodejs pnpm; do grep -q "^$t " .tool-versions || { echo "missing $t"; exit 1; }; done
}

run_tests
