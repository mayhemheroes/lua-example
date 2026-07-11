/*
 * mayhem/harnesses/launcher.c -- ELF entry point for the lua-example fuzz target.
 *
 * Mayhem requires a target `cmd:` to be a real ELF, not a shell/script wrapper
 * (fuzz-smoke rejects non-ELF cmds). luzer, however, runs its libFuzzer driver
 * (LLVMFuzzerRunDriver, inside libfuzzer_with_asan.so) by LD_PRELOAD-ing that
 * DSO into the *Lua interpreter* ELF and running the fuzz target as a Lua
 * script. This launcher is that ELF: it bakes the LD_PRELOAD / LUA_PATH /
 * LUA_CPATH / ASAN_OPTIONS environment and execv()s
 *
 *     /mayhem/lua  /mayhem/fuzz_basic.lua  [args...]
 *
 * forwarding every argv it receives. libFuzzer flags (-runs=, -max_total_time=,
 * -max_len=, ...) and a positional corpus directory therefore pass straight
 * through to luzer's init.lua flag parser and on into the real libFuzzer loop.
 * After execv() the process image IS the Lua interpreter, so all libFuzzer
 * output, ASan reports and the exit code come from the genuine fuzzer process.
 *
 * Built by mayhem/build.sh with $SANITIZER_FLAGS so the launcher matches the
 * sanitizer ABI of the preloaded runtime; it does no input parsing itself.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#ifndef LUA_EXAMPLE_BASE
#define LUA_EXAMPLE_BASE "/mayhem"
#endif

#define LP    LUA_EXAMPLE_BASE "/lua_modules/lib/lua/5.1"
#define SP    LUA_EXAMPLE_BASE "/lua_modules/share/lua/5.1"
#define LUA   LUA_EXAMPLE_BASE "/lua"
#define TGT   LUA_EXAMPLE_BASE "/fuzz_basic.lua"

int main(int argc, char **argv)
{
    setenv("LD_PRELOAD", LP "/libfuzzer_with_asan.so", 1);
    setenv("LUA_PATH",   SP "/?/init.lua;" SP "/?.lua;;", 1);
    setenv("LUA_CPATH",  LP "/?.so;;", 1);
    /* Mayhem owns ASAN_OPTIONS at runtime; only set a default for standalone
     * use (fuzz-smoke / local repro). Do not clobber an inherited value. */
    if (!getenv("ASAN_OPTIONS"))
        setenv("ASAN_OPTIONS", "detect_leaks=0", 1);

    char **na = calloc((size_t)argc + 3, sizeof(*na));
    if (!na) { perror("calloc"); return 127; }
    int n = 0;
    na[n++] = (char *)LUA;
    na[n++] = (char *)TGT;
    for (int i = 1; i < argc; i++)
        na[n++] = argv[i];
    na[n] = NULL;

    execv(LUA, na);
    perror("execv " LUA);
    return 127;
}
