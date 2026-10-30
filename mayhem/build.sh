#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
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

# All build state lives under /_build (gitignored upstream), so a `git clean -ffdX` removes it.
B="$SRC/_build"
mkdir -p "$B/include"
# miniz.h includes miniz_export.h, which upstream's CMake generates; provide the same stub out of tree.
printf '#ifndef MINIZ_EXPORT\n#define MINIZ_EXPORT\n#endif\n' > "$B/include/miniz_export.h"

# Two instrumented flavours of the project and of each harness: "fuzz" adds libFuzzer's SanitizerCoverage
# (-fsanitize=fuzzer-no-link — without it libFuzzer sees zero edges), "sa" is the plain sanitized build
# that links the run-once standalone driver and needs no libFuzzer runtime.
COMMON="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -I$SRC -I$B/include"
FUZZ_FLAGS="$COMMON -fsanitize=fuzzer-no-link"
SA_FLAGS="$COMMON"

# 1) The project itself, sanitized, with DWARF 3.
for flavour in fuzz sa; do
  flags="$SA_FLAGS"; [ "$flavour" = fuzz ] && flags="$FUZZ_FLAGS"
  mkdir -p "$B/$flavour"; objs=()
  for f in miniz miniz_tdef miniz_tinfl miniz_zip; do
    $CC $flags -c "$SRC/$f.c" -o "$B/$flavour/$f.o"
    objs+=("$B/$flavour/$f.o")
  done
  rm -f "$B/$flavour/libminiz.a"
  ar rcs "$B/$flavour/libminiz.a" "${objs[@]}"
done

# LeakSanitizer off at build time (SPEC §6.2 item 15).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"
# Run-once driver is C: compile it as C so its LLVMFuzzerTestOneInput reference keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

# 2) Every OSS-Fuzz harness (tests/*_fuzzer.c) plus the in-tree C++ validate harness
#    (miniz_tdefl_fuzzer.cc and miniz_zip_writer_fuzzer.cc do not compile against upstream's headers).
HARNESSES="add_in_place_fuzzer checksum_fuzzer compress_fuzzer flush_fuzzer large_fuzzer small_fuzzer
  uncompress_fuzzer uncompress2_fuzzer zip_fuzzer miniz_zip_validate_fuzzer"
for t in $HARNESSES; do
  for flavour in fuzz sa; do
    flags="$SA_FLAGS"; [ "$flavour" = fuzz ] && flags="$FUZZ_FLAGS"
    if [ -f "$SRC/tests/$t.c" ]; then
      $CC $flags -c "$SRC/tests/$t.c" -o "$B/$flavour/$t.o"
    else
      $CXX $flags -c "$SRC/tests/$t.cc" -o "$B/$flavour/$t.o"
    fi
  done
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/fuzz/$t.o" "$B/fuzz/libminiz.a" "$B/lsan_off.o" -o "/mayhem/$t"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$B/standalone_main.o" "$B/sa/$t.o" "$B/sa/libminiz.a" "$B/lsan_off.o" -o "/mayhem/$t-standalone"
done

# 3) Upstream's Catch2 suite (tests/main.cpp) with NORMAL flags — no sanitizers, no inherited CFLAGS.
env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake -S "$SRC" -B "$B/tests" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DBUILD_TESTS=ON -DBUILD_EXAMPLES=OFF -DBUILD_FUZZERS=OFF -DINSTALL_PROJECT=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake --build "$B/tests" -j"$MAYHEM_JOBS" --target catch_tests
