#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's Catch2 suite (tests/main.cpp), built by mayhem/build.sh with normal
# flags. Each test case runs on its own and must print Catch's "All tests passed (N assertions ...)"
# line with N>0, so a program that exits 0 without running any assertion is counted as a failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/bin/catch_tests"   # upstream CMake writes executables to <src>/bin (gitignored)
[ -x "$RUNNER" ] || { echo "catch_tests missing: mayhem/build.sh should have built it" >&2; emit_ctrf catch2 0 1; exit 1; }

# Catch2 runs from a scratch dir: some tests create files in the cwd.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
mapfile -t names < <("$RUNNER" --list-tests -v quiet | sed '/^$/d')
[ "${#names[@]}" -gt 0 ] || { echo "no Catch2 test cases listed" >&2; emit_ctrf catch2 0 1; exit 1; }
for n in "${names[@]}"; do
  out="$(cd "$WORK" && "$RUNNER" "$n" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && grep -Eq 'All tests passed \(([1-9][0-9]*) assertions? in 1 test case\)' <<<"$out"; then
    passed=$((passed+1)); echo "PASS $n"
  else
    failed=$((failed+1)); echo "FAIL $n (rc=$rc)"; printf '%s\n' "$out" | tail -15
  fi
done
emit_ctrf catch2 "$passed" "$failed"
