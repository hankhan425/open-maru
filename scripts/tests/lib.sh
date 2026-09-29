#!/usr/bin/env bash
# Tiny test harness for repo scripts. Source it, define `test_*` functions
# whose names start with the task test ID (e.g. test_T01_T01_...), then call run_tests.
set -uo pipefail
# shellcheck disable=SC2034  # FAIL_OUT is read by the sourcing test files

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASSED=0
FAILED=0
SKIPPED=0

skip() {
  echo "SKIP: $1"
  exit 77
}

# Run a script expecting a non-zero exit; the script must exist (guards against vacuous passes).
# Usage: expect_fail <script> [args...]; prints combined output on stdout via $FAIL_OUT.
expect_fail() {
  [ -x "$1" ] || { echo "script not executable/missing: $1"; return 1; }
  # shellcheck disable=SC2034
  if FAIL_OUT="$("$@" 2>&1)"; then echo "expected failure but exited 0"; return 1; fi
}

# Copy the working tree (tracked + untracked, minus ignored) into a fresh temp dir.
copy_tree() {
  local dest
  dest="$(mktemp -d)"
  (cd "$ROOT" && git ls-files -co --exclude-standard -z | xargs -0 -I{} cp --parents {} "$dest" 2>/dev/null) \
    || (cd "$ROOT" && git ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- ./ "$dest/")
  echo "$dest"
}

run_tests() {
  local fn rc
  for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
    ( set -e; "$fn" ) >"/tmp/${fn}.out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "PASS ${fn#test_}"; PASSED=$((PASSED + 1))
    elif [ "$rc" -eq 77 ]; then
      echo "SKIP ${fn#test_}: $(cat "/tmp/${fn}.out")"; SKIPPED=$((SKIPPED + 1))
    else
      echo "FAIL ${fn#test_}"; sed 's/^/    /' "/tmp/${fn}.out"; FAILED=$((FAILED + 1))
    fi
    rm -f "/tmp/${fn}.out"
  done
  echo "passed=$PASSED failed=$FAILED skipped=$SKIPPED"
  [ "$FAILED" -eq 0 ]
}
