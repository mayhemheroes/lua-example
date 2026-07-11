#!/usr/bin/env bash
#
# lua-example/mayhem/build.sh -- build the OSS-Fuzz `lua-example` fuzz target as a
# Mayhem-runnable libFuzzer target.
#
# UPSTREAM repo (this checkout) is ligurio/luzer: a coverage-guided Lua fuzzing
# ENGINE. The OSS-Fuzz `lua-example` project pairs luzer with a tiny Lua fuzz
# target (fuzz_basic.lua) that drives bytes through luzer.FuzzedDataProvider into
# a Lua predicate. luzer is libFuzzer-based: it builds a Lua native module
# (luzer_impl.so) plus a DSO (libfuzzer_with_asan.so) that bundles the libFuzzer
# runtime + ASan. The fuzzer process is the *Lua interpreter* with that DSO
# LD_PRELOAD-ed, running the fuzz target as a script. luzer's debug-hook tracer
# feeds Lua-VM coverage to libFuzzer, and ASan/UBSan instrument the native side.
#
# How this differs from the OSS-Fuzz build.sh:
#   * OSS-Fuzz emits a *bash wrapper* as the fuzz target. Mayhem requires the
#     cmd to be an ELF, so we build a small C launcher (harnesses/launcher.c)
#     that bakes the env and execv()s `lua fuzz_basic.lua`, forwarding argv.
#   * OSS-Fuzz installs luzer via luarocks with OSS_FUZZ=ON (expects unsuffixed
#     libclang_rt.*.a). The mayhemheroes base ships clang with arch-suffixed
#     runtime libs (libclang_rt.asan-x86_64.a, ...), so we build luzer directly
#     with CMake and leave OSS_FUZZ OFF (luzer's Linux branch resolves the
#     suffixed names via `clang -print-file-name`).
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/SRC). The
# Lua interpreter is built PLAIN (no sanitizers): ASan must come solely from the
# preloaded DSO, otherwise the interpreter's own ASan init collides with the
# DSO's and the process segfaults at startup.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' -- must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS

SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT="${OUT:-/mayhem}"
cd "$SRC"

LUA_RELVER="${LUA_RELVER:-5.4.7}"
LUA_NAME="lua-$LUA_RELVER"
WORK="$SRC/mayhem-build"
mkdir -p "$WORK"

# -- 1) Build the Lua interpreter + static lib from source (PLAIN, no sanitizers) ----
#    Vendored fetch from lua.org (same source OSS-Fuzz uses). -fPIC + -rdynamic so
#    the preloaded libFuzzer/ASan DSO can resolve interpreter symbols at runtime.
if [ ! -x "$WORK/$LUA_NAME/src/lua" ]; then
  ( cd "$WORK"
    if [ ! -d "$LUA_NAME" ]; then
      curl -fsSL -O "https://www.lua.org/ftp/$LUA_NAME.tar.gz"
      tar xzf "$LUA_NAME.tar.gz"
    fi
    cd "$LUA_NAME"
    make posix CC="$CC" \
      MYCFLAGS="$DEBUG_FLAGS -O1 -fPIC -DLUA_USE_LINUX -DLUA_USE_DLOPEN" \
      MYLDFLAGS="-rdynamic" \
      MYLIBS="-Wl,-E -ldl" \
      -j"$MAYHEM_JOBS" )
fi
LUA_DIR="$WORK/$LUA_NAME/src"
echo "built Lua interpreter: $LUA_DIR/lua"

# -- 2) Build luzer (the fuzzing engine native module + the libFuzzer+ASan DSO) -----
#    via CMake, pointing at the source Lua we just built. OSS_FUZZ stays OFF.
env -u SANITIZER_FLAGS \
  CFLAGS="$DEBUG_FLAGS $SANITIZER_FLAGS" CXXFLAGS="$DEBUG_FLAGS $SANITIZER_FLAGS" \
  cmake -S "$SRC" -B "$WORK/luzer" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_LUA_INCLUDE_DIR="$LUA_DIR" \
    -DCMAKE_LUA_LIBRARIES="$LUA_DIR/liblua.a" \
    -DENABLE_TESTING=OFF
env -u SANITIZER_FLAGS CFLAGS="$DEBUG_FLAGS $SANITIZER_FLAGS" CXXFLAGS="$DEBUG_FLAGS $SANITIZER_FLAGS" cmake --build "$WORK/luzer" --parallel "$MAYHEM_JOBS"

# -- 3) Assemble the runtime layout under $OUT (mirrors luzer's installed tree) -----
mkdir -p "$OUT/lua_modules/lib/lua/5.1" "$OUT/lua_modules/share/lua/5.1/luzer"
cp "$WORK/luzer/luzer/luzer_impl.so"          "$OUT/lua_modules/lib/lua/5.1/luzer_impl.so"
cp "$WORK/luzer/luzer/libcustom_mutator.so"   "$OUT/lua_modules/lib/lua/5.1/"
cp "$WORK/luzer/luzer/libfuzzer_with_asan.so" "$OUT/lua_modules/lib/lua/5.1/"
cp "$SRC/luzer/init.lua"                      "$OUT/lua_modules/share/lua/5.1/luzer/init.lua"
cp "$LUA_DIR/lua"                             "$OUT/lua"
cp "$SRC/mayhem/harnesses/fuzz_basic.lua"     "$OUT/fuzz_basic.lua"

# -- 4) Build the ELF launcher (the Mayhem cmd) -------------------------------------
#    Compiled WITH $SANITIZER_FLAGS to match the preloaded runtime's ABI.
$CC $DEBUG_FLAGS $SANITIZER_FLAGS -DLUA_EXAMPLE_BASE='"'"$OUT"'"' \
  "$SRC/mayhem/harnesses/launcher.c" -o "$OUT/fuzz_basic"

echo "build.sh complete:"
ls -la "$OUT/fuzz_basic" "$OUT/lua" \
       "$OUT/lua_modules/lib/lua/5.1/luzer_impl.so" \
       "$OUT/lua_modules/lib/lua/5.1/libfuzzer_with_asan.so" 2>&1 || true
