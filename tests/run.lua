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

-- Grass loose vs swath layout (classifyGrassMaterialLayout).
dofile(repoRoot .. "/scripts/FieldAdvisor.lua")
if type(FieldAdvisor) == "table" and type(FieldAdvisor.classifyGrassMaterialLayout) == "function" then
  io.write("\n")
  local grassCases = {
    {
      name = "grass_layout_uniform_loose",
      ew = { 40, 45, 50, 48, 42, 44, 46 },
      ns = { 38, 41, 43, 45, 40, 39, 42 },
      fillMin = 10,
      expected = "loose",
    },
    {
      name = "grass_layout_rowed_swath",
      ew = { 0, 0, 0, 120, 130, 0, 0, 0 },
      ns = { 2, 1, 0, 0, 0, 0, 1, 2 },
      fillMin = 10,
      expected = "swath",
    },
    {
      name = "grass_layout_no_material",
      ew = { 0, 0, 0, 0 },
      ns = { 0, 0, 0, 0 },
      fillMin = 10,
      expected = "none",
    },
  }
  for _, c in ipairs(grassCases) do
    local got = FieldAdvisor.classifyGrassMaterialLayout(c.ew, c.ns, c.fillMin)
    if got == c.expected then
      pass = pass + 1
      io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> %s\n", c.name, tostring(got)))
    else
      fail = fail + 1
      io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s expected %s got %s\n", c.name, c.expected, tostring(got)))
    end
  end
end

if type(FieldAdvisor) == "table" and type(FieldAdvisor.classifyBaleKind) == "function" then
  io.write("\n")
  local baleCases = {
    { name = "bale_kind_straw", fillName = "STRAW", expected = "straw" },
    { name = "bale_kind_alfalfa_windrow", fillName = "ALFALFA_WINDROW", expected = "grass" },
    { name = "bale_kind_grass_windrow", fillName = "GRASS_WINDROW", expected = "grass" },
  }
  for _, c in ipairs(baleCases) do
    FieldAdvisor._baleKindByIndex = {}
    local oldManager = g_fillTypeManager
    g_fillTypeManager = {
      getFillTypeByIndex = function(_, idx)
        return { name = c.fillName }
      end,
    }
    local got = FieldAdvisor.classifyBaleKind({ fillType = 191 })
    g_fillTypeManager = oldManager
    if got == c.expected then
      pass = pass + 1
      io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> %s\n", c.name, tostring(got)))
    else
      fail = fail + 1
      io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s expected %s got %s\n", c.name, c.expected, tostring(got)))
    end
  end
end

-- P4: harvest ETA uses FruitTypeDesc only (nil when neither API nor minHarvest).
if type(FieldAdvisor) == "table" and type(FieldAdvisor.estimateNonSeasonalPeriodsUntilHarvest) == "function" then
  io.write("\n")
  local oldHasApi = FieldAdvisor.fruitDescHasHarvestReadyApi
  local oldIsReady = FieldAdvisor.isGrowthStateHarvestReadyByApi
  local oldGetFruit = FieldAdvisor.getFruitTypeDesc
  local oldGrowth = FieldAdvisor.getEffectiveGrowthState
  local oldActive = FieldAdvisor.hasActiveCrop

  FieldAdvisor.getEffectiveGrowthState = function() return 2 end
  FieldAdvisor.hasActiveCrop = function() return true end
  FieldAdvisor.fruitDescHasHarvestReadyApi = function() return false end
  FieldAdvisor.isGrowthStateHarvestReadyByApi = function() return false end
  FieldAdvisor.getFruitTypeDesc = function() return {} end -- no minHarvest

  local gotNil = FieldAdvisor.estimateNonSeasonalPeriodsUntilHarvest(1, {}, {})
  if gotNil == nil then
    pass = pass + 1
    io.write(GREEN .. "PASS" .. RESET .. " estimate_harvest_nil_without_desc_api\n")
  else
    fail = fail + 1
    io.write(string.format(RED .. "FAIL" .. RESET .. " estimate_harvest_nil_without_desc_api got %s\n", tostring(gotNil)))
  end

  FieldAdvisor.getFruitTypeDesc = function() return { minHarvestingGrowthState = 5 } end
  local gotSteps = FieldAdvisor.estimateNonSeasonalPeriodsUntilHarvest(1, {}, { minHarvestingGrowthState = 5 })
  if gotSteps == 3 then
    pass = pass + 1
    io.write(GREEN .. "PASS" .. RESET .. " estimate_harvest_minHarvest_delta\n")
  else
    fail = fail + 1
    io.write(string.format(RED .. "FAIL" .. RESET .. " estimate_harvest_minHarvest_delta expected 3 got %s\n", tostring(gotSteps)))
  end

  FieldAdvisor.fruitDescHasHarvestReadyApi = oldHasApi
  FieldAdvisor.isGrowthStateHarvestReadyByApi = oldIsReady
  FieldAdvisor.getFruitTypeDesc = oldGetFruit
  FieldAdvisor.getEffectiveGrowthState = oldGrowth
  FieldAdvisor.hasActiveCrop = oldActive
end

-- FieldToDoPermissions contract (MP farm edit gates).
local permFixtures = dofile(here .. "/permissions_fixtures.lua")
dofile(repoRoot .. "/scripts/FieldAdvisorSettings.lua")
assert(type(FieldAdvisorSettings.isWorkersMayEditTodos) == "function")
assert(FieldAdvisorSettings.isWorkersMayEditTodos() == true)
FieldAdvisorSettings.setWorkersMayEditTodos(false)
assert(FieldAdvisorSettings.isWorkersMayEditTodos() == false)
FieldAdvisorSettings.setWorkersMayEditTodos(true)
dofile(repoRoot .. "/scripts/FieldToDoPermissions.lua")

if type(FieldToDoPermissions) ~= "table"
    or type(FieldToDoPermissions.canEditFarmTodos) ~= "function"
    or type(FieldToDoPermissions.canChangeWorkersEditSetting) ~= "function"
    or type(FieldToDoPermissions.canAutoCompleteFarmTodos) ~= "function" then
  io.write(RED .. "PENDING: scripts/FieldToDoPermissions.lua not implemented yet.\n" .. RESET)
  fail = fail + #permFixtures
else
  io.write("\n")
  for _, c in ipairs(permFixtures) do
    FieldAdvisorSettings.workersMayEditTodos = c.workersMayEdit
    FieldToDoPermissions._testOverride = {
      farmId = 1,
      userId = 1,
      isManager = c.isManager,
      resolveFarmId = c.sameFarm and 1 or 2,
    }
    local gotEdit = FieldToDoPermissions.canEditFarmTodos(1, 1)
    local gotSetting = FieldToDoPermissions.canChangeWorkersEditSetting(1, 1)
    local gotAuto = FieldToDoPermissions.canAutoCompleteFarmTodos(1, 1)
    local mismatch = nil
    if gotEdit ~= c.expect.edit then
      mismatch = string.format("edit expected %s got %s", tostring(c.expect.edit), tostring(gotEdit))
    elseif gotSetting ~= c.expect.changeSetting then
      mismatch = string.format("changeSetting expected %s got %s", tostring(c.expect.changeSetting), tostring(gotSetting))
    elseif gotAuto ~= c.expect.autoComplete then
      mismatch = string.format("autoComplete expected %s got %s", tostring(c.expect.autoComplete), tostring(gotAuto))
    end
    if mismatch == nil then
      pass = pass + 1
      io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> permissions ok\n", c.name))
    else
      fail = fail + 1
      io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s %s\n", c.name, mismatch))
    end
  end
  FieldToDoPermissions._testOverride = nil
end

io.write(string.format("\n%d passed, %d failed, %d total\n", pass, fail, pass + fail))
os.exit(fail == 0 and 0 or 1)
