-- mayhem/harnesses/fuzz_basic.lua
--
-- The OSS-Fuzz `lua-example` fuzz target, vendored here so the mayhem build is
-- self-contained (the upstream OSS-Fuzz project keeps this file in the oss-fuzz
-- repo, not in luzer). It is byte-for-byte the OSS-Fuzz example_basic.lua /
-- luzer examples/example_basic.lua harness.
--
-- Parse surface: luzer.FuzzedDataProvider consumes the first 4 bytes of the
-- libFuzzer-mutated input as a string; the harness then drives a tiny Lua
-- predicate over those bytes. The fuzzed code is REAL Lua executing inside the
-- (luzer-instrumented) Lua interpreter -- string.gsub, an anonymous closure,
-- table.insert and per-byte comparisons -- so coverage feedback comes from the
-- Lua VM via luzer's debug-hook tracer. The harness contains a deliberate
-- planted bug: the 4-byte string "oops" makes count==4 and trips assert(nil).
-- (This is the canonical OSS-Fuzz lua-example demo target.)

local luzer = require("luzer")

local function TestOneInput(buf)
    local fdp = luzer.FuzzedDataProvider(buf)
    local str = fdp:consume_string(4)

    local b = {}
    str:gsub(".", function(c) table.insert(b, c) end)
    local count = 0
    if b[1] == "o" then count = count + 1 end
    if b[2] == "o" then count = count + 1 end
    if b[3] == "p" then count = count + 1 end
    if b[4] == "s" then count = count + 1 end

    if count == 4 then assert(nil) end
end

local args = {
    only_ascii = 1,
    print_pcs = 1,
}

luzer.Fuzz(TestOneInput, nil, args)
