#!/usr/bin/env bash
#
# mayhem/build.sh — builds libmodbus (sanitized, DWARF 3), the three fuzz harnesses with their
# standalone reproducers, and upstream's unit-test server/client (normal flags) for mayhem/test.sh.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Leak detection is off in every ASan binary (lsan_off.c, linked below); configure's own probe
# programs also run under ASan, so silence LSan for the build step.
export ASAN_OPTIONS=detect_leaks=0

FUZZ_DIR="$SRC/mayhem/build-fuzz"
TEST_DIR="$SRC/mayhem/build-test"

# 1) Generate configure (idempotent; autotools and libtool ship in the base image).
./autogen.sh

# 2) The library itself, sanitized and with DWARF 3, built out of tree. The build directories are
#    gitignored by mayhem/.gitignore so `git clean -ffdX` removes them.
mkdir -p "$FUZZ_DIR"
(cd "$FUZZ_DIR" \
  && "$SRC/configure" CC="$CC" CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
       --disable-shared --enable-static --disable-maintainer-mode \
  && make -C src -j"$MAYHEM_JOBS")

# 3) Each harness twice: libFuzzer binary and run-once standalone reproducer.
INCS="-I$SRC/src -I$FUZZ_DIR/src -I$FUZZ_DIR/tests -I$FUZZ_DIR"
LIB="$FUZZ_DIR/src/.libs/libmodbus.a"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$FUZZ_DIR/lsan_off.o"
for h in FuzzClient FuzzServer mayhem_fuzzer; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INCS "$SRC/mayhem/harnesses/$h.c" "$FUZZ_DIR/lsan_off.o" "$LIB" \
      $LIB_FUZZING_ENGINE -o "/mayhem/$h"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INCS "$STANDALONE_FUZZ_MAIN" "$SRC/mayhem/harnesses/$h.c" \
      "$FUZZ_DIR/lsan_off.o" "$LIB" -o "/mayhem/$h-standalone"
done

# 4) The project's own functional suite (unit-test-server + unit-test-client), with normal flags, so
#    mayhem/test.sh only runs it.
mkdir -p "$TEST_DIR"
(cd "$TEST_DIR" \
  && "$SRC/configure" CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
       --disable-shared --enable-static --disable-maintainer-mode \
  && make -C src -j"$MAYHEM_JOBS" \
  && make -C tests -j"$MAYHEM_JOBS" unit-test-server unit-test-client)

# 5) Test-time shim: lets the offline unit-test-client see 1.2.3.4 as a blackhole (see the file).
$CC -O2 -fPIC -shared "$SRC/mayhem/blackhole_connect.c" -o "$TEST_DIR/blackhole_connect.so" -ldl
