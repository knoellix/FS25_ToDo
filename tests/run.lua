#!/usr/bin/env lua
-- Headless test runner for the field-phase contract (no FS25 required).
-- Usage: lua tests/run.lua        (run from repo root)
-- Exit 0 = all green; 1 = failures or contract module missing (expected before Phase 2).

local here = arg[0]:match("^(.*)/[^/]+$") or "."
local repoRoot = here:match("^(.*)/tests$") or (here .. "/..")
package.path = table.concat({
  repoRoot .. "/scripts/?.lua",
  here .. "/?.lua",
  package.path,
}, ";")

local fixtures = dofile(here .. "/fixtures.lua")

-- Phase 2 deliverable: scripts/FieldPhase.lua returning a table with deriveFieldPhase(facts).
local okLoad, FieldPhase = pcall(function() return dofile(repoRoot .. "/scripts/FieldPhase.lua") end)

local GREEN, RED, DIM, RESET = "\27[32m", "\27[31m", "\27[2m", "\27[0m"
if os.getenv("NO_COLOR") then GREEN, RED, DIM, RESET = "", "", "", "" end

if not okLoad or type(FieldPhase) ~= "table" or type(FieldPhase.deriveFieldPhase) ~= "function" then
  io.write(RED .. "PENDING: scripts/FieldPhase.lua not implemented yet (Phase 2 target).\n" .. RESET)
  io.write(DIM .. "  " .. #fixtures .. " fixtures ready. Implement deriveFieldPhase(facts) per docs/FIELD_PHASE.md.\n" .. RESET)
  for _, c in ipairs(fixtures) do
    io.write(string.format(DIM .. "  - %-44s expect %s\n" .. RESET, c.name, c.expected))
  end
  os.exit(1)
end

local pass, fail = 0, 0
for _, c in ipairs(fixtures) do
  local ok, got = pcall(FieldPhase.deriveFieldPhase, c.facts)
  if ok and got == c.expected then
    pass = pass + 1
    io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> %s\n", c.name, tostring(got)))
  else
    fail = fail + 1
    local detail = ok and tostring(got) or ("error: " .. tostring(got))
    io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s expected %s got %s\n", c.name, c.expected, detail))
  end
end

-- WeedAdvice contract (single weed decision; locks W4/W5).
local weedFixtures = dofile(here .. "/weed_fixtures.lua")
local okWeed, WeedAdvice = pcall(function() return dofile(repoRoot .. "/scripts/WeedAdvice.lua") end)
local WEED_FIELDS = { "done", "hoe", "watch", "needsCombat", "spray" }

if not okWeed or type(WeedAdvice) ~= "table" or type(WeedAdvice.deriveWeedAdvice) ~= "function" then
  io.write(RED .. "PENDING: scripts/WeedAdvice.lua not implemented yet.\n" .. RESET)
  fail = fail + #weedFixtures
else
  io.write("\n")
  for _, c in ipairs(weedFixtures) do
    local ok, advice = pcall(WeedAdvice.deriveWeedAdvice, c.facts)
    local mismatch = nil
    if not ok then
      mismatch = "error: " .. tostring(advice)
    else
      for _, key in ipairs(WEED_FIELDS) do
        local want = c.expect[key] == true
        local got = advice[key] == true
        if want ~= got then
          mismatch = string.format("%s expected %s got %s", key, tostring(want), tostring(got))
          break
        end
      end
    end
    if mismatch == nil then
      pass = pass + 1
      io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> advice ok\n", c.name))
    else
      fail = fail + 1
      io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s %s\n", c.name, mismatch))
    end
  end
end

io.write(string.format("\n%d passed, %d failed, %d total\n", pass, fail, pass + fail))
os.exit(fail == 0 and 0 or 1)
