#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS upstream's unit-test server and client (built by mayhem/build.sh) over TCP on
# 127.0.0.1:1502 and asserts on their output. Does not compile.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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


TESTS="$SRC/mayhem/build-test/tests"
for b in unit-test-server unit-test-client; do
  [ -x "$TESTS/$b" ] || { echo "missing $TESTS/$b (mayhem/build.sh should have built it)" >&2; emit_ctrf libmodbus-unit-test 0 1 0; exit $?; }
done

[ -f "$SRC/mayhem/build-test/blackhole_connect.so" ] || { echo "missing blackhole_connect.so (mayhem/build.sh should have built it)" >&2; emit_ctrf libmodbus-unit-test 0 1 0; exit $?; }

LOG_DIR="$(mktemp -d)"
trap 'kill "${SERVER_PID:-0}" 2>/dev/null; rm -rf "$LOG_DIR"' EXIT

cd "$TESTS"
./unit-test-server > "$LOG_DIR/server.log" 2>&1 &
SERVER_PID=$!

# Wait until 127.0.0.1:1502 (0x05DE) is listening. Connecting to probe would use up the
# server's single accept().
for _ in $(seq 1 50); do
  grep -qi ' 0100007F:05DE 00000000:0000 0A ' /proc/net/tcp 2>/dev/null && break
  sleep 0.1
done

LD_PRELOAD="$SRC/mayhem/build-test/blackhole_connect.so${LD_PRELOAD:+:$LD_PRELOAD}" timeout 120 ./unit-test-client > "$LOG_DIR/client.log" 2>&1
client_rc=$?

# Each numbered check prints "<n>/<m> <what>: OK". One check ("1us response timeout") is documented
# upstream as platform-dependent, so it is not part of the count.
passed=$(grep -cE '^[0-9]+/[0-9]+ .*: OK$' "$LOG_DIR/client.log")
failed=$(grep -E '^[0-9]+/[0-9]+ .*FAILED' "$LOG_DIR/client.log" | grep -vc 'can fail on some platforms')
[ "$client_rc" -eq 0 ] || failed=$((failed + 1))
grep -qx 'ALL TESTS PASS WITH SUCCESS.' "$LOG_DIR/client.log" || failed=$((failed + 1))

# Known answer: the server's reply to "read 37 coils at 0x130" carries the bits written by the
# preceding write_bits (UT_BITS_TAB = CD 6B B2 0E 1B), byte for byte.
if ! grep -qF '<FF><01><05><CD><6B><B2><0E><1B>' "$LOG_DIR/client.log"; then
  echo "known-answer reply for read_bits (CD 6B B2 0E 1B) not seen" >&2
  failed=$((failed + 1))
fi
# Known answer: write_bit(0x130, ON) echoes FF 05 01 30 FF 00.
if ! grep -qF '<00><01><00><00><00><06><FF><05><01><30><FF><00>' "$LOG_DIR/client.log"; then
  echo "known-answer echo for write_bit not seen" >&2
  failed=$((failed + 1))
fi
# The suite has 29 numbered passing checks; fewer means part of it did not run.
if [ "$passed" -lt 29 ]; then
  echo "only $passed numbered checks passed (expected >= 29)" >&2
  failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { tail -40 "$LOG_DIR/client.log" >&2; }
emit_ctrf libmodbus-unit-test "$passed" "$failed" 0
