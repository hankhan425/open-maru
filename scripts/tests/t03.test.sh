#!/usr/bin/env bash
# Tests for task T03 (Rust workspace & binding scaffolds). Run: scripts/tests/t03.test.sh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ci="$ROOT/.github/workflows/ci.yml"

# T03-T09 CI job builds maru_wasm for wasm32-unknown-unknown with authz disabled
test_T03_T09_ci_builds_maru_wasm_for_wasm32() {
  grep -q 'cargo build -p maru_wasm --target wasm32-unknown-unknown' "$ci" \
    || { echo "CI does not build maru_wasm for wasm32-unknown-unknown"; exit 1; }
  grep -q 'wasm-pack build' "$ci" || { echo "CI does not run wasm-pack"; exit 1; }
  grep -q 'scripts/tests/t03.test.sh' "$ci" || { echo "CI does not run the T03 script tests"; exit 1; }
}

test_T03_T09_ci_runs_wasm_node_tests() {
  grep -q 'node --test' "$ci" || grep -q 'maru-wasm.*test' "$ci" \
    || { echo "CI does not run the @openmaru/maru-wasm Node tests"; exit 1; }
}

test_T03_T09_maru_wasm_resolves_maru_core_without_authz() {
  command -v cargo >/dev/null || skip "cargo not installed"
  cd "$ROOT" || exit 1
  local wasm_features nif_features
  wasm_features="$(cargo tree -q -p maru_wasm --target wasm32-unknown-unknown -e features -i maru_core)"
  nif_features="$(cargo tree -q -p maru_nif -e features -i maru_core)"
  # Control: the grep does detect the feature where it is enabled.
  grep -q 'maru_core feature "authz"' <<<"$nif_features" \
    || { echo "control failed: maru_nif should enable authz"; echo "$nif_features"; exit 1; }
  if grep -q 'maru_core feature "authz"' <<<"$wasm_features"; then
    echo "maru_wasm enables maru_core/authz:"; echo "$wasm_features"; exit 1
  fi
}

test_T03_T09_maru_wasm_builds_for_wasm32() {
  command -v cargo >/dev/null || skip "cargo not installed"
  cd "$ROOT" || exit 1
  cargo build -q -p maru_wasm --target wasm32-unknown-unknown
}

run_tests
