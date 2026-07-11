#!/usr/bin/env bash
#
# lua-example/mayhem/test.sh -- functional GOLDEN oracle over the fuzzed Lua-eval path.
#
# Which path: luzer does NOT ship a self-contained CLI test suite we can run
# without rebuilding it under CMake ENABLE_TESTING (its tests need a configured
# build tree + the Lua test runner). Instead we assert the END-TO-END behaviour
# of the actual deployed fuzz target -- the same /mayhem/fuzz_basic ELF Mayhem
# fuzzes -- against KNOWN-ANSWER inputs of the fuzzed predicate:
#
#   * the 4-byte input "oops" MUST trip the planted assert(nil) (libFuzzer
#     reports "fuzz target exited" / nonzero) -- proves the FDP -> Lua predicate
#     -> assertion path is wired and instrumented end to end;
#   * benign 4-byte inputs ("AAAA", "oopX", "oxps") MUST run clean (exit 0 with
#     -runs=1) -- proves the predicate does NOT false-trigger.
#
# This is a real oracle, not a no-op stub: a target that swallowed the assert,
# failed to load luzer, or mis-decoded the FDP bytes would flip one of these
# cases and fail the suite. It runs the built binary only; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

OUT="${OUT:-/mayhem}"
BIN="$OUT/fuzz_basic"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$OUT/ctrf-report.json}" <<JSON
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

if [ ! -x "$BIN" ]; then
  echo "missing $BIN -- run mayhem/build.sh first" >&2
  emit_ctrf "lua-example-oracle" 0 1 0; exit 2
fi

PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run_case <name> <expect: crash|clean> <bytes>
run_case() {
  local name="$1" expect="$2" bytes="$3"
  local f="$TMP/$name"
  printf '%s' "$bytes" > "$f"
  # -runs=1 (single execution of the provided input); the launcher forwards it.
  local out rc
  out="$("$BIN" -runs=1 "$f" 2>&1)"; rc=$?
  if [ "$expect" = crash ]; then
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qiE 'assertion failed|fuzz target exited|ERROR'; then
      echo "PASS $name: crashed as expected (rc=$rc)"; PASS=$((PASS+1))
    else
      echo "FAIL $name: expected crash, got rc=$rc"; printf '%s\n' "$out" | tail -4; FAIL=$((FAIL+1))
    fi
  else
    if [ "$rc" -eq 0 ]; then
      echo "PASS $name: clean exit as expected"; PASS=$((PASS+1))
    else
      echo "FAIL $name: expected clean exit, got rc=$rc"; printf '%s\n' "$out" | tail -4; FAIL=$((FAIL+1))
    fi
  fi
}

echo "=== lua-example golden oracle over $BIN ==="
run_case oops_triggers_assert crash 'oops'
run_case benign_AAAA          clean 'AAAA'
run_case benign_near_oopX     clean 'oopX'
run_case benign_oxps          clean 'oxps'

emit_ctrf "lua-example-oracle" "$PASS" "$FAIL" 0
