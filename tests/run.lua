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

-- FertilizerAdvice contract (PF nitrogen vs vanilla sprayLevel fallback).
local fertFixtures = dofile(here .. "/fertilizer_fixtures.lua")
local okFert, FertilizerAdvice = pcall(function() return dofile(repoRoot .. "/scripts/FertilizerAdvice.lua") end)

if not okFert or type(FertilizerAdvice) ~= "table" or type(FertilizerAdvice.deriveFertilizerAdvice) ~= "function" then
  io.write(RED .. "PENDING: scripts/FertilizerAdvice.lua not implemented yet.\n" .. RESET)
  fail = fail + #fertFixtures
else
  io.write("\n")
  for _, c in ipairs(fertFixtures) do
    if c.kind == "passCount" then
      local ok, got = pcall(FertilizerAdvice.getSprayPassCount, c.level, c.max)
      if ok and got == c.expectCount then
        pass = pass + 1
        io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> %s\n", c.name, tostring(got)))
      else
        fail = fail + 1
        io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s expected %s got %s\n",
          c.name, tostring(c.expectCount), ok and tostring(got) or ("error: " .. tostring(got))))
      end
    elseif c.kind == "passTarget" then
      local ok, got = pcall(FertilizerAdvice.getSprayPassTarget, c.pass, c.passTotal, c.max)
      if ok and got == c.expectTarget then
        pass = pass + 1
        io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> %s\n", c.name, tostring(got)))
      else
        fail = fail + 1
        io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s expected %s got %s\n",
          c.name, tostring(c.expectTarget), ok and tostring(got) or ("error: " .. tostring(got))))
      end
    else
      local ok, advice = pcall(FertilizerAdvice.deriveFertilizerAdvice, c.facts)
      local mismatch = nil
      if not ok then
        mismatch = "error: " .. tostring(advice)
      else
        for key, want in pairs(c.expect) do
          local got = advice[key]
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

-- isGrassPostMowState: alfalfa harvestReady on cut meadow must not block (use generic GRASS isCut).
if type(FieldAdvisor) == "table" and type(FieldAdvisor.isGrassPostMowState) == "function" then
  io.write("\n")
  local oldGround = FieldAdvisor.getGroundTypeName
  local oldResolve = FieldAdvisor.resolveFruitTypeIndex
  local oldIsGrass = FieldAdvisor.isGrassCrop
  local oldEff = FieldAdvisor.getEffectiveGrowthState
  local oldLast = FieldAdvisor.getLastGrowthState
  local oldNum = FieldAdvisor.getStateNumber
  local oldDefault = FieldAdvisor.getDefaultGrassFruitTypeIndex
  local oldEval = FieldAdvisor.evaluateFruitGrowth
  local oldDesc = FieldAdvisor.getFruitTypeDesc

  FieldAdvisor.getGroundTypeName = function() return "GRASS" end
  FieldAdvisor.resolveFruitTypeIndex = function() return 2 end
  FieldAdvisor.isGrassCrop = function() return true end
  FieldAdvisor.getEffectiveGrowthState = function() return 4 end
  FieldAdvisor.getLastGrowthState = function() return 0 end
  FieldAdvisor.getStateNumber = function() return 0 end
  FieldAdvisor.getDefaultGrassFruitTypeIndex = function() return 1 end
  FieldAdvisor.getFruitTypeDesc = function() return { maxHarvestingGrowthState = 5 } end
  FieldAdvisor.evaluateFruitGrowth = function(idx)
    if idx == 2 then
      return { isCut = false, isHarvestReady = true, isHarvestable = true, isGrowing = false, isWithered = false }
    end
    return { isCut = true, isHarvestReady = false, isHarvestable = false, isGrowing = false, isWithered = false }
  end

  local got = FieldAdvisor.isGrassPostMowState({}, {})
  if got == true then
    pass = pass + 1
    io.write(GREEN .. "PASS" .. RESET .. " post_mow_alfalfa_false_standing_uses_generic_cut\n")
  else
    fail = fail + 1
    io.write(RED .. "FAIL" .. RESET .. " post_mow_alfalfa_false_standing_uses_generic_cut got false\n")
  end

  FieldAdvisor.getGroundTypeName = oldGround
  FieldAdvisor.resolveFruitTypeIndex = oldResolve
  FieldAdvisor.isGrassCrop = oldIsGrass
  FieldAdvisor.getEffectiveGrowthState = oldEff
  FieldAdvisor.getLastGrowthState = oldLast
  FieldAdvisor.getStateNumber = oldNum
  FieldAdvisor.getDefaultGrassFruitTypeIndex = oldDefault
  FieldAdvisor.evaluateFruitGrowth = oldEval
  FieldAdvisor.getFruitTypeDesc = oldDesc
end

-- getDefaultGrassFruitTypeIndex must prefer GRASS over earlier ALFALFA in manager list.
if type(FieldAdvisor) == "table" and type(FieldAdvisor.getDefaultGrassFruitTypeIndex) == "function" then
  io.write("\n")
  local oldByName = FieldAdvisor.getFruitTypeIndexByName
  local oldIsGrass = FieldAdvisor.isGrassCrop
  local oldIsGeneric = FieldAdvisor.isGenericGrassFruitIndex
  local oldManager = rawget(_G, "g_fruitTypeManager")

  FieldAdvisor.invalidateDefaultGrassFruitTypeIndex()
  FieldAdvisor.getFruitTypeIndexByName = function(name)
    if name == "GRASS" then return 10 end
    if name == "ALFALFA" then return 2 end
    return nil
  end
  FieldAdvisor.isGrassCrop = function(idx) return idx == 2 or idx == 10 end
  FieldAdvisor.isGenericGrassFruitIndex = function(idx) return idx == 10 end
  rawset(_G, "g_fruitTypeManager", {
    getFruitTypes = function()
      return {
        { index = 2, name = "ALFALFA" },
        { index = 10, name = "GRASS" },
      }
    end,
  })

  local got = FieldAdvisor.getDefaultGrassFruitTypeIndex()
  if got == 10 then
    pass = pass + 1
    io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s\n", "default_grass_prefers_generic_GRASS"))
  else
    fail = fail + 1
    io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s expected 10 got %s\n",
      "default_grass_prefers_generic_GRASS", tostring(got)))
  end

  FieldAdvisor.invalidateDefaultGrassFruitTypeIndex()
  FieldAdvisor.getFruitTypeIndexByName = oldByName
  FieldAdvisor.isGrassCrop = oldIsGrass
  FieldAdvisor.isGenericGrassFruitIndex = oldIsGeneric
  rawset(_G, "g_fruitTypeManager", oldManager)
end

-- Grass crop scoring must not prefer ALFALFA over GRASS on equal growth flags.
if type(FieldAdvisor) == "table" and type(FieldAdvisor.scoreGrassFruitGrowthMatch) == "function" then
  io.write("\n")
  local oldGrowth = FieldAdvisor.getEffectiveGrowthState
  local oldEval = FieldAdvisor.evaluateFruitGrowth
  local oldGround = FieldAdvisor.getGroundTypeName
  local oldGeneric = FieldAdvisor.isGenericGrassFruitIndex

  FieldAdvisor.getEffectiveGrowthState = function() return 3 end
  FieldAdvisor.getGroundTypeName = function() return "GRASS" end
  FieldAdvisor.evaluateFruitGrowth = function()
    return {
      isCut = false,
      isHarvestReady = true,
      isHarvestable = true,
      isGrowing = false,
      isWithered = false,
    }
  end
  FieldAdvisor.isGenericGrassFruitIndex = function(idx) return idx == 1 end

  local grassScore = FieldAdvisor.scoreGrassFruitGrowthMatch(1, {})
  local alfalfaScore = FieldAdvisor.scoreGrassFruitGrowthMatch(2, {})
  if grassScore == alfalfaScore and grassScore > 0 then
    pass = pass + 1
    io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> score=%s\n",
      "grass_score_no_alfalfa_bias", tostring(grassScore)))
  else
    fail = fail + 1
    io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s grass=%s alfalfa=%s\n",
      "grass_score_no_alfalfa_bias", tostring(grassScore), tostring(alfalfaScore)))
  end

  FieldAdvisor.getEffectiveGrowthState = oldGrowth
  FieldAdvisor.evaluateFruitGrowth = oldEval
  FieldAdvisor.getGroundTypeName = oldGround
  FieldAdvisor.isGenericGrassFruitIndex = oldGeneric
end

-- grass_mow cut ratio: half post-mow must stay below completion threshold.
dofile(repoRoot .. "/scripts/FieldTaskCompletion.lua")
if type(FieldTaskCompletion) == "table" and type(FieldTaskCompletion.getGrassMowCutRatio) == "function" then
  io.write("\n")
  local oldCollect = FieldTaskCompletion.collectSamplePoints
  local oldEnrich = FieldAdvisor.getEnrichedFieldState
  local oldClassify = FieldAdvisor.classifyProbe
  local oldPostMow = FieldAdvisor.isGrassPostMowState
  local oldCutGround = FieldAdvisor.isGrassCutGroundType
  local oldGround = FieldAdvisor.getGroundTypeName
  local oldDefaultGrass = FieldAdvisor.getDefaultGrassFruitTypeIndex

  FieldAdvisor.getDefaultGrassFruitTypeIndex = function() return nil end
  FieldTaskCompletion.collectSamplePoints = function()
    return {
      { x = 1, z = 1 }, { x = 2, z = 2 }, { x = 3, z = 3 }, { x = 4, z = 4 },
      { x = 5, z = 5 }, { x = 6, z = 6 }, { x = 7, z = 7 }, { x = 8, z = 8 },
      { x = 9, z = 9 }, { x = 10, z = 10 },
    }
  end
  FieldAdvisor.getEnrichedFieldState = function(_, _, x)
    return { x = x }
  end
  FieldAdvisor.classifyProbe = function()
    return FieldAdvisor.PROBE_SITUATION.GRASS
  end
  FieldAdvisor.getGroundTypeName = function() return "GRASS" end
  FieldAdvisor.isGrassCutGroundType = function() return false end
  -- First 5 cut, last 5 standing → ratio 0.5
  FieldAdvisor.isGrassPostMowState = function(state)
    return state.x <= 5
  end

  local halfRatio = FieldTaskCompletion.getGrassMowCutRatio({}, 17, 0, 0, 5)
  local threshold = FieldTaskCompletion.getThreshold()
  -- Early-exit may return >0.5 once standing probes make ≥98% unreachable; still must stay open.
  if halfRatio ~= nil and halfRatio < threshold then
    pass = pass + 1
    io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> ratio=%.2f\n",
      "grass_mow_half_field_not_complete", halfRatio))
  else
    fail = fail + 1
    io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s got %s (threshold %s)\n",
      "grass_mow_half_field_not_complete", tostring(halfRatio), tostring(threshold)))
  end

  FieldAdvisor.isGrassPostMowState = function() return true end
  local fullRatio = FieldTaskCompletion.getGrassMowCutRatio({}, 17, 0, 0, 5)
  if fullRatio ~= nil and fullRatio >= threshold then
    pass = pass + 1
    io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> ratio=%.2f\n",
      "grass_mow_full_field_complete", fullRatio))
  else
    fail = fail + 1
    io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s got %s\n",
      "grass_mow_full_field_complete", tostring(fullRatio)))
  end

  FieldTaskCompletion.collectSamplePoints = oldCollect
  FieldAdvisor.getEnrichedFieldState = oldEnrich
  FieldAdvisor.classifyProbe = oldClassify
  FieldAdvisor.isGrassPostMowState = oldPostMow
  FieldAdvisor.isGrassCutGroundType = oldCutGround
  FieldAdvisor.getGroundTypeName = oldGround
  FieldAdvisor.getDefaultGrassFruitTypeIndex = oldDefaultGrass
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

io.write("\n")
local groundFixtures = dofile(here .. "/ground_type_fixtures.lua")
for _, c in ipairs(groundFixtures.resolveCases) do
  local ok, got = pcall(FieldAdvisor.resolveGroundTypeName, c.raw)
  if ok and got == c.expected then
    pass = pass + 1
    io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> %s\n", c.name, tostring(got)))
  else
    fail = fail + 1
    local detail = ok and tostring(got) or ("error: " .. tostring(got))
    io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s expected %s got %s\n", c.name, c.expected, detail))
  end
end

do
    local state, calls = groundFixtures.makeReentrantFieldState()
    local ok, got = pcall(FieldAdvisor.getGroundTypeName, state)
    local passReentry = ok and got == "" and calls.n >= 1
    if passReentry then
        pass = pass + 1
        io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> reentrancy guarded\n", "getGroundTypeName_reentrant"))
    else
        fail = fail + 1
        io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s ok=%s got=%s calls=%s\n",
            "getGroundTypeName_reentrant", tostring(ok), tostring(got), tostring(calls and calls.n)))
    end
end

-- FieldToDoPermissions contract (MP farm edit = manageContracts; SP always).
local permFixtures = dofile(here .. "/permissions_fixtures.lua")
dofile(repoRoot .. "/scripts/FieldAdvisorSettings.lua")
dofile(repoRoot .. "/scripts/FieldToDoPermissions.lua")

if type(FieldToDoPermissions) ~= "table"
    or type(FieldToDoPermissions.canEditFarmTodos) ~= "function"
    or type(FieldToDoPermissions.canManageTodoEditGrants) ~= "function"
    or type(FieldToDoPermissions.canAutoCompleteFarmTodos) ~= "function" then
  io.write(RED .. "PENDING: scripts/FieldToDoPermissions.lua not implemented yet.\n" .. RESET)
  fail = fail + #permFixtures
else
  io.write("\n")
  for _, c in ipairs(permFixtures) do
    FieldToDoPermissions._testOverride = {
      farmId = 1,
      userId = 1,
      uniqueUserId = "u1",
      resolveFarmId = c.sameFarm and 1 or 2,
      isMultiplayer = c.isMultiplayer == true,
      manageContracts = c.manageContracts == true,
    }
    local gotEdit = FieldToDoPermissions.canEditFarmTodos(1, 1)
    local gotManage = FieldToDoPermissions.canManageTodoEditGrants(1, 1)
    local gotAuto = FieldToDoPermissions.canAutoCompleteFarmTodos(1, 1)
    local mismatch = nil
    if gotEdit ~= c.expect.edit then
      mismatch = string.format("edit expected %s got %s", tostring(c.expect.edit), tostring(gotEdit))
    elseif gotManage ~= c.expect.manageGrants then
      mismatch = string.format("manageGrants expected %s got %s", tostring(c.expect.manageGrants), tostring(gotManage))
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

local hudFixtures = dofile(here .. "/hud_layout_fixtures.lua")
dofile(repoRoot .. "/scripts/FieldToDoHudOverlay.lua")

io.write("\n")
for _, c in ipairs(hudFixtures) do
  local mismatch = nil
  if c.name == "clamp_keeps_panel_on_screen" then
    if type(FieldToDoHudOverlay.clampPanelPosition) ~= "function" then
      mismatch = "clampPanelPosition missing"
    else
      local x, y = FieldToDoHudOverlay.clampPanelPosition(c.panelX, c.panelY, c.panelW, c.panelH, c.margin)
      if x < c.expectXMin - 1e-6 or x > c.expectXMax + 1e-6 then
        mismatch = string.format("x=%s out of range", tostring(x))
      elseif y < c.expectYMin - 1e-6 or y > c.expectYMax + 1e-6 then
        mismatch = string.format("y=%s out of range", tostring(y))
      end
    end
  elseif c.name == "header_is_top_strip" then
    if type(FieldToDoHudOverlay.getHeaderRect) ~= "function" then
      mismatch = "getHeaderRect missing"
    else
      local _, hy = FieldToDoHudOverlay.getHeaderRect(c.panelX, c.panelY, c.panelW, c.panelH, c.headerH)
      if math.abs(hy - c.expectHeaderY) > 1e-6 then
        mismatch = string.format("headerY expected %s got %s", c.expectHeaderY, tostring(hy))
      end
    end
  elseif c.name == "row1_below_header" then
    if type(FieldToDoHudOverlay.getRowRect) ~= "function" then
      mismatch = "getRowRect missing"
    else
      local _, ry = FieldToDoHudOverlay.getRowRect(
        c.panelX, c.panelY, c.panelW, c.panelH, c.headerH, c.rowH, c.rowIndex
      )
      if math.abs(ry - c.expectRowY) > 1e-6 then
        mismatch = string.format("rowY expected %s got %s", c.expectRowY, tostring(ry))
      end
    end
  elseif c.name == "point_in_header" then
    if type(FieldToDoHudOverlay.pointInRect) ~= "function" then
      mismatch = "pointInRect missing"
    else
      local r = c.rect
      local inside = FieldToDoHudOverlay.pointInRect(c.px, c.py, r.x, r.y, r.w, r.h)
      if inside ~= c.expectInside then
        mismatch = string.format("inside expected %s got %s", tostring(c.expectInside), tostring(inside))
      end
    end
  elseif c.name == "drag_threshold_constant" then
    if FieldToDoHudOverlay.DRAG_MOVE_THRESHOLD ~= c.expectThreshold then
      mismatch = string.format(
        "threshold expected %s got %s",
        tostring(c.expectThreshold),
        tostring(FieldToDoHudOverlay.DRAG_MOVE_THRESHOLD)
      )
    end
  end

  if mismatch == nil then
    pass = pass + 1
    io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> hud layout ok\n", c.name))
  else
    fail = fail + 1
    io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s %s\n", c.name, mismatch))
  end
end

io.write(string.format("\n%d passed, %d failed, %d total\n", pass, fail, pass + fail))
os.exit(fail == 0 and 0 or 1)
