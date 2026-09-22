--[[
    FieldTaskCompletion.lua
    Modular auto-complete: vanilla-style field coverage (98%) vs point/grass/straw handlers.

    Point strategy (grass_mow, grass_bale*, straw_bale*): completion from FieldAdvisor context
    (field-local bales; grass_mow = ≥98% post-mow sample coverage). No phase re-derivation here.
]]

FieldTaskCompletion = {}

FieldTaskCompletion.COMPLETION_THRESHOLD = 0.98
FieldTaskCompletion.SAMPLE_GRID_STEPS = 5
FieldTaskCompletion.OVERVIEW_SAMPLE_GRID_STEPS = 3
FieldTaskCompletion.SAMPLE_EARLY_EXIT_MIN = 5

--- Registry entry:
---   strategy = "coverage" | "sample" | "grass" | "point" | "none"
---   densityTargets = string[]  (FieldGroundType names, vanilla contract density map)
---   grassStep = "mow" | "swath" | "collect"  (grass strategy only)
---   coverageOnly = true  -> task completes only when ratio >= threshold (no center shortcut)
FieldTaskCompletion.REGISTRY = {
    plow = {
        strategy = "coverage",
        densityTargets = { "PLOWED" },
        coverageOnly = true,
    },
    cultivate = {
        strategy = "coverage",
        densityTargets = { "CULTIVATED", "SEEDBED" },
        coverageOnly = true,
    },
    roller = {
        strategy = "coverage",
        densityTargets = { "ROLLER_LINES" },
        coverageOnly = true,
    },
    sow = {
        strategy = "coverage",
        densityTargets = { "SOWN", "PLANTED", "RIDGE_SOWN" },
        coverageOnly = true,
    },
    stones = {
        strategy = "sample",
        coverageOnly = true,
    },
    lime = {
        strategy = "sample",
        coverageOnly = true,
    },
    -- Grass logistics: suggestions read windrow liters (deriveGrassResidueSummary); auto-complete
    -- only tracks object signals (mow cut state, bales appear/vanish). Swath/collect have no
    -- completion baseline -> manual reminder (FieldWorkCatalog autoComplete=false).
    grass_mow = { strategy = "point" },
    -- Mulching has no readable field state in this runtime -> manual reminder, never auto-done.
    mulch = { strategy = "none" },
    grass_swath = { strategy = "none" },
    grass_collect = { strategy = "none" },
    harvest = { strategy = "point" },
    weed_hoe = { strategy = "sample", coverageOnly = true },
    weed_combat = { strategy = "sample", coverageOnly = true },
    weed_watch = { strategy = "point" },
    pf_ph = { strategy = "point" },
    pf_n = { strategy = "point" },
    scs_moisture = { strategy = "point" },
    scs_stress_high = { strategy = "point" },
    scs_stress_watch = { strategy = "point" },
    withered = { strategy = "point" },
    grass_bale = { strategy = "point" },
    grass_silage_bale = { strategy = "point" },
    grass_bale_collect = { strategy = "point" },
    -- Straw logistics (arable stubble): same field-local bale signal as grass, keyed on STRAW bales.
    straw_bale = { strategy = "point" },
    straw_bale_collect = { strategy = "point" },
}

--- Register or override a completion strategy (e.g. mod extensions, new fruit workflows).
---@param actionType string
---@param entry table
function FieldTaskCompletion.registerEntry(actionType, entry)
    if string.isNilOrWhitespace(actionType) or entry == nil then
        return
    end

    FieldTaskCompletion.REGISTRY[actionType] = entry
end

---@param actionType string|nil
---@return table|nil
function FieldTaskCompletion.getEntry(actionType)
    if actionType == nil then
        return nil
    end

    return FieldTaskCompletion.REGISTRY[actionType]
end

---@param actionType string|nil
---@return boolean
function FieldTaskCompletion.isAutoTrackable(actionType)
    local entry = FieldTaskCompletion.getEntry(actionType)
    return entry ~= nil and entry.strategy ~= "none"
end

---@param entry table|nil
---@return boolean
function FieldTaskCompletion.requiresCoverageOnly(entry)
    return entry ~= nil and entry.coverageOnly == true
end

---@return number
function FieldTaskCompletion.getThreshold()
    return FieldTaskCompletion.COMPLETION_THRESHOLD
end

---@return number
function FieldTaskCompletion.getSampleGridSteps()
    return FieldTaskCompletion.SAMPLE_GRID_STEPS
end

---@param field table
---@param groundTypeName string
---@return number|nil
function FieldTaskCompletion.getDensityMapGroundRatio(field, groundTypeName)
    if field == nil
        or string.isNilOrWhitespace(groundTypeName)
        or g_currentMission == nil
        or g_currentMission.fieldGroundSystem == nil
        or FieldGroundType == nil
        or FieldDensityMap == nil
        or DensityMapModifier == nil
        or DensityMapFilter == nil
        or DensityValueCompareType == nil
        or field.densityMapPolygon == nil then
        return nil
    end

    local targetValue = nil
    local enumValue = FieldGroundType[groundTypeName]
    if enumValue == nil and FieldGroundType.getByName ~= nil then
        local okName, named = pcall(FieldGroundType.getByName, FieldGroundType, groundTypeName)
        if okName then
            enumValue = named
        end
    end

    if enumValue ~= nil and FieldGroundType.getValueByType ~= nil then
        local ok, value = pcall(FieldGroundType.getValueByType, FieldGroundType, enumValue)
        if ok then
            targetValue = value
        end
    end

    if targetValue == nil then
        return nil
    end

    local ok, _sumPixels, completedArea, totalArea = pcall(function()
        local groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels =
            g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)

        local modifier = DensityMapModifier.new(
            groundTypeMapId,
            groundTypeFirstChannel,
            groundTypeNumChannels,
            g_terrainNode
        )
        local filter = DensityMapFilter.new(modifier)
        filter:setValueCompareParams(DensityValueCompareType.EQUAL, targetValue)

        field.densityMapPolygon:applyToModifier(modifier)
        return modifier:executeGet(filter)
    end)

    if not ok or totalArea == nil then
        return nil
    end

    local doneArea = tonumber(completedArea) or 0
    local areaTotal = tonumber(totalArea)
    if areaTotal == nil or areaTotal <= 0 then
        return nil
    end

    return math.min(1, doneArea / areaTotal)
end

---@param field table
---@param densityTargets string[]|nil
---@return number|nil
function FieldTaskCompletion.getDensityCoverageRatio(field, densityTargets)
    if densityTargets == nil or #densityTargets == 0 then
        return nil
    end

    local bestRatio = nil
    for _, groundTypeName in ipairs(densityTargets) do
        local ratio = FieldTaskCompletion.getDensityMapGroundRatio(field, groundTypeName)
        if ratio ~= nil and (bestRatio == nil or ratio > bestRatio) then
            bestRatio = ratio
        end
    end

    return bestRatio
end

---@param field table
---@param centerX number
---@param centerZ number
---@param gridSteps number|nil
---@return table[]
function FieldTaskCompletion.collectSamplePoints(field, centerX, centerZ, gridSteps)
    local points = {}

    if field == nil or FieldAdvisor == nil then
        return points
    end

    if FieldAdvisor.isSamplePositionOnField(field, centerX, centerZ) then
        points[#points + 1] = { x = centerX, z = centerZ }
    end

    local halfExtentX = 0
    local halfExtentZ = 0
    if FieldAdvisor.getProbeSampleHalfExtents ~= nil then
        halfExtentX, halfExtentZ = FieldAdvisor.getProbeSampleHalfExtents(field, centerX, centerZ)
    elseif FieldAdvisor.getProbeSampleHalfExtent ~= nil then
        local halfExtent = FieldAdvisor.getProbeSampleHalfExtent(field, centerX, centerZ)
        halfExtentX = halfExtent
        halfExtentZ = halfExtent
    end
    if halfExtentX <= 0 and halfExtentZ <= 0 then
        return points
    end

    local steps = math.max(1, tonumber(gridSteps) or FieldTaskCompletion.getSampleGridSteps())

    for ix = -steps, steps do
        for iz = -steps, steps do
            if not (ix == 0 and iz == 0)
                and (ix == 0 or halfExtentX > 0)
                and (iz == 0 or halfExtentZ > 0) then
                local sampleX = centerX + (ix / steps) * halfExtentX
                local sampleZ = centerZ + (iz / steps) * halfExtentZ
                if FieldAdvisor.isSamplePositionOnField(field, sampleX, sampleZ) then
                    points[#points + 1] = { x = sampleX, z = sampleZ }
                end
            end
        end
    end

    return points
end

---@param field table
---@param sampleState table|nil
---@return table
function FieldTaskCompletion.buildLightSampleContext(field, sampleState)
    return {
        field = field,
        fieldState = sampleState,
        rules = FieldGameRules.get(),
        needsPlowing = FieldAdvisor.getStateBool(sampleState, "needsPlowing"),
        needsLime = FieldAdvisor.getStateBool(sampleState, "needsLime"),
        needsRolling = FieldAdvisor.getStateBool(sampleState, "needsRolling"),
        plowLevel = FieldAdvisor.getStateNumber(sampleState, "plowLevel"),
        limeLevel = FieldAdvisor.getStateNumber(sampleState, "limeLevel"),
        rollerLevel = FieldAdvisor.getStateNumber(sampleState, "rollerLevel"),
        stoneLevel = FieldAdvisor.getStateNumber(sampleState, "stoneLevel"),
        pfSample = nil,
        scsSample = nil,
        weedSummary = nil,
        grassResidueSummary = nil,
        baleSummary = nil,
    }
end

---@param field table
---@param task table
---@param centerX number
---@param centerZ number
---@return number|nil
function FieldTaskCompletion.getSampleGridRatio(field, task, centerX, centerZ)
    if field == nil or task == nil or FieldAdvisor == nil then
        return nil
    end

    local points = FieldTaskCompletion.collectSamplePoints(field, centerX, centerZ)
    if #points == 0 then
        return nil
    end

    local total = 0
    local completed = 0
    local threshold = FieldTaskCompletion.getThreshold()
    local pointCount = #points

    for pointIndex, point in ipairs(points) do
        local sampleState = FieldAdvisor.getEnrichedFieldState(field, task.fieldId, point.x, point.z)
        local sampleContext = FieldTaskCompletion.buildLightSampleContext(field, sampleState)

        total = total + 1
        if FieldTaskCompletion.isActionComplete(task.actionType, sampleContext, task) then
            completed = completed + 1
        end

        if total >= FieldTaskCompletion.SAMPLE_EARLY_EXIT_MIN then
            local remaining = pointCount - pointIndex
            if remaining > 0 and (completed + remaining) / (total + remaining) < threshold then
                break
            end
        end
    end

    if field.fieldState ~= nil and field.fieldState.update ~= nil then
        pcall(field.fieldState.update, field.fieldState, centerX, centerZ)
    end

    if total <= 0 then
        return nil
    end

    return completed / total
end

--- Standard field work (plow, sow, roller, …): density map like vanilla contracts, else 98% sample grid.
---@param field table
---@param task table
---@param centerX number
---@param centerZ number
---@param entry table
---@return number|nil
function FieldTaskCompletion.getCoverageStrategyRatio(field, task, centerX, centerZ, entry)
    local densityRatio = FieldTaskCompletion.getDensityCoverageRatio(field, entry.densityTargets)
    if densityRatio ~= nil then
        return densityRatio
    end

    return FieldTaskCompletion.getSampleGridRatio(field, task, centerX, centerZ)
end

--- Grass uses no reliable ground-type density target; 98% grid with grass-specific point checks only.
---@param field table
---@param task table
---@param centerX number
---@param centerZ number
---@param entry table
---@return number|nil
function FieldTaskCompletion.getGrassStrategyRatio(field, task, centerX, centerZ, entry)
    if entry.grassStep == nil then
        return nil
    end

    return FieldTaskCompletion.getSampleGridRatio(field, task, centerX, centerZ)
end

---@param field table
---@param task table
---@param centerX number
---@param centerZ number
---@return number|nil
function FieldTaskCompletion.getCompletionRatio(field, task, centerX, centerZ)
    if field == nil or task == nil then
        return nil
    end

    local entry = FieldTaskCompletion.getEntry(task.actionType)
    if entry == nil then
        return nil
    end

    if entry.strategy == "coverage" then
        return FieldTaskCompletion.getCoverageStrategyRatio(field, task, centerX, centerZ, entry)
    end

    if entry.strategy == "grass" then
        return FieldTaskCompletion.getGrassStrategyRatio(field, task, centerX, centerZ, entry)
    end

    if entry.strategy == "sample" then
        return FieldTaskCompletion.getSampleGridRatio(field, task, centerX, centerZ)
    end

    return nil
end

---@param actionType string|nil
---@return boolean
function FieldTaskCompletion.isGrassLogisticsAction(actionType)
    return actionType == "grass_mow"
        or actionType == "grass_swath"
        or actionType == "grass_collect"
        or actionType == "grass_bale"
        or actionType == "grass_silage_bale"
        or actionType == "grass_bale_collect"
        or actionType == "straw_bale"
        or actionType == "straw_bale_collect"
end

---@param actionType string|nil
---@return boolean
function FieldTaskCompletion.isBaleAction(actionType)
    return actionType == "grass_bale"
        or actionType == "grass_silage_bale"
        or actionType == "grass_bale_collect"
        or actionType == "straw_bale"
        or actionType == "straw_bale_collect"
end

---@param actionMeta table|nil
---@return number
function FieldTaskCompletion.getBaselineBaleCount(actionMeta)
    if actionMeta == nil or actionMeta.completionBaseline == nil then
        return 0
    end

    return tonumber(actionMeta.completionBaseline.baleCount) or 0
end

---@param context table|nil
---@return number
function FieldTaskCompletion.getContextBaleCount(context)
    if context == nil or context.baleSummary == nil then
        return 0
    end

    return tonumber(context.baleSummary.total) or 0
end

--- Fraction of grass-relevant sample probes that look post-mow (cut ground / cut growth / shred).
--- Standing harvestable/growing grass counts against completion so half-mowed fields stay open.
---@param field table|nil
---@param fieldId number|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param gridSteps number|nil
---@return number|nil
function FieldTaskCompletion.getGrassMowCutRatio(field, fieldId, worldX, worldZ, gridSteps)
    if field == nil or worldX == nil or worldZ == nil or FieldAdvisor == nil then
        return nil
    end

    local points = FieldTaskCompletion.collectSamplePoints(
        field,
        worldX,
        worldZ,
        gridSteps or FieldTaskCompletion.SAMPLE_GRID_STEPS
    )
    if #points == 0 then
        return nil
    end

    local relevant = 0
    local cut = 0
    local threshold = FieldTaskCompletion.getThreshold()
    local pointCount = #points

    for pointIndex, point in ipairs(points) do
        local sampleState = FieldAdvisor.getEnrichedFieldState(field, fieldId, point.x, point.z)
        local situation = FieldAdvisor.classifyProbe(sampleState, field)
        local ground = FieldAdvisor.getGroundTypeName(sampleState)
        local postMow = FieldAdvisor.isGrassPostMowState(sampleState, field, nil)
            or FieldAdvisor.isGrassCutGroundType(ground)
        -- Also accept generic-grass cut flags (meadow fruit index often wrong after mow).
        if not postMow and sampleState ~= nil then
            local grassIdx = FieldAdvisor.getDefaultGrassFruitTypeIndex()
            if grassIdx ~= nil then
                postMow = FieldAdvisor.isGrassPostMowState(sampleState, field, grassIdx)
            end
        end
        local standingGrass = situation == FieldAdvisor.PROBE_SITUATION.GRASS and not postMow

        if postMow or standingGrass then
            relevant = relevant + 1
            if postMow then
                cut = cut + 1
            end
        end

        if relevant >= FieldTaskCompletion.SAMPLE_EARLY_EXIT_MIN then
            local remaining = pointCount - pointIndex
            if remaining > 0 and (cut + remaining) / (relevant + remaining) < threshold then
                break
            end
        end
    end

    if field.fieldState ~= nil and field.fieldState.update ~= nil then
        pcall(field.fieldState.update, field.fieldState, worldX, worldZ)
    end

    if relevant <= 0 then
        return nil
    end

    return cut / relevant
end

---@param actionType string
---@param context table
---@param actionMeta table|nil
---@return boolean
function FieldTaskCompletion.isGrassLogisticsComplete(actionType, context, actionMeta)
    if context == nil or FieldAdvisor == nil then
        return false
    end

    local field = context.field
    local fieldState = context.fieldState
    local residueSummary = context.grassResidueSummary
    local baseline = actionMeta ~= nil and actionMeta.completionBaseline or nil
    local baselineBales = FieldTaskCompletion.getBaselineBaleCount(actionMeta)

    if FieldTaskCompletion.isBaleAction(actionType) and field ~= nil and FieldAdvisor.sampleBaleCoverage ~= nil then
        local currentBales = FieldTaskCompletion.getContextBaleCount(context)
        -- Re-sample for fresh counts when we don't yet see new bales, or for collect steps that
        -- must confirm bales are gone.
        if currentBales <= baselineBales
            or actionType == "grass_bale_collect" or actionType == "straw_bale_collect" then
            local fieldId = context.fieldId
            if fieldId == nil and field.getId ~= nil then
                fieldId = field:getId()
            end
            if fieldId ~= nil and FieldAdvisor.clearCoverageCache ~= nil then
                FieldAdvisor.clearCoverageCache(fieldId, "bales")
            end
            context.baleSummary = FieldAdvisor.sampleBaleCoverage(field, 0)
        end
    end

    if actionType == "straw_bale" then
        local strawNow = FieldAdvisor.getTrackedBaleCountForAction(context.baleSummary, actionType)
        local baselineStraw = baseline ~= nil and tonumber(baseline.baleStrawCount) or 0
        return strawNow > baselineStraw
    end

    if actionType == "straw_bale_collect" then
        return FieldAdvisor.getTrackedBaleCountForAction(context.baleSummary, actionType) <= 0
    end

    if actionType == "grass_mow" then
        -- Require nearly full-field post-mow coverage (≥98%). A single cut probe /
        -- meadowPhase=cut / fieldHasPostMowGrassSignal used to complete at ~50% mowed.
        local ratio = FieldTaskCompletion.getGrassMowCutRatio(
            field,
            context.fieldId,
            context.worldX,
            context.worldZ,
            FieldTaskCompletion.SAMPLE_GRID_STEPS
        )
        if ratio ~= nil then
            return ratio >= FieldTaskCompletion.getThreshold()
        end

        return FieldAdvisor.isGrassPostMowState(fieldState, field, nil)
            or FieldAdvisor.isGrassCut(fieldState, field, nil)
    end

    -- grass_swath / grass_collect: strategy "none" in REGISTRY — never routed here (manual only).

    if actionType == "grass_bale" or actionType == "grass_silage_bale" then
        return FieldAdvisor.isGrassBalingWorkComplete(
            residueSummary,
            context.baleSummary,
            baseline
        )
    end

    if actionType == "grass_bale_collect" then
        return FieldAdvisor.getTrackedBaleCountForAction(context.baleSummary, actionType) <= 0
    end

    return false
end

---@param actionType string
---@param context table
---@param actionMeta table|nil
---@return boolean
function FieldTaskCompletion.isActionComplete(actionType, context, actionMeta)
    if actionType == nil or actionType == "none" or context == nil then
        return false
    end

    local field = context.field
    local fieldState = context.fieldState
    local rules = context.rules or FieldGameRules.get()
    local pfSample = context.pfSample
    local scsSample = context.scsSample

    if FieldTaskCompletion.isGrassLogisticsAction(actionType) then
        return FieldTaskCompletion.isGrassLogisticsComplete(actionType, context, actionMeta)
    end

    if actionType == "harvest" then
        return not FieldAdvisor.isHarvestReady(field, fieldState)
    end

    if actionType == "plow" then
        if FieldAdvisor.isWithered(fieldState) then
            return false
        end

        if not rules.plowingRequiredEnabled then
            return true
        end

        if FieldAdvisor.getGroundTypeName(fieldState) == "PLOWED" and not context.needsPlowing then
            return true
        end

        return false
    end

    if actionType == "cultivate" then
        if FieldAdvisor.isWithered(fieldState) then
            return false
        end

        if FieldAdvisor.hasActiveCrop(fieldState) then
            return false
        end

        local groundType = FieldAdvisor.getGroundTypeName(fieldState)
        if FieldAdvisor.groundTypeIsOneOf(groundType, { "CULTIVATED", "SEEDBED" }) then
            return true
        end

        local isCultivated = FieldAdvisor.getStateBool(fieldState, "isCultivated")
            or FieldAdvisor.getStateBool(fieldState, "cultivated")
            or FieldAdvisor.getStateBool(fieldState, "seedbed")
            or FieldAdvisor.getStateBool(fieldState, "isSeedbed")

        if isCultivated then
            return true
        end

        return false
    end

    if actionType == "lime" then
        if not rules.limeRequired then
            return true
        end

        return not context.needsLime
    end

    if actionType == "weed_hoe" or actionType == "weed_combat" or actionType == "weed_watch" then
        if not rules.weedsEnabled then
            return true
        end

        return FieldAdvisor.isWeedProbeWorkDone(fieldState)
    end

    if actionType == "stones" then
        if not rules.stonesEnabled then
            return true
        end

        return context.stoneLevel <= 0
    end

    if actionType == "roller" then
        if FieldAdvisor.isWithered(fieldState) then
            return false
        end

        if FieldAdvisor.getGroundTypeName(fieldState) == "ROLLER_LINES" then
            return true
        end

        return not context.needsRolling and context.rollerLevel <= 0
    end

    if actionType == "pf_ph" then
        if not PrecisionFarmingReader.isRuntimeReady() then
            return true
        end

        if pfSample == nil or pfSample.pHValue == nil then
            return false
        end

        return tonumber(pfSample.pHValue) >= 6.0
    end

    if actionType == "pf_n" then
        local advice = FieldAdvisor.getFertilizerAdviceFromContext(context)
        if advice.source == "none" then
            return false
        end

        if actionMeta ~= nil and actionMeta.fertPass ~= nil then
            local passTotal = tonumber(actionMeta.fertPassTotal) or 1
            local level = tonumber(advice.level) or 0
            if advice.source == "spray" then
                local target = FertilizerAdvice ~= nil
                    and FertilizerAdvice.getSprayPassTarget(actionMeta.fertPass, passTotal, advice.max)
                    or FieldAdvisor.getOrganicFertilizerPassTarget(actionMeta.fertPass, passTotal, advice.max or 2)
                return level >= target
            end

            local target = FieldAdvisor.getOrganicFertilizerPassTarget(actionMeta.fertPass, passTotal, 80)
            return level >= target
        end

        return advice.done == true
    end

    if actionType == "scs_moisture" or actionType == "scs_stress_high" or actionType == "scs_stress_watch" then
        if SeasonalCropStressReader == nil
            or SeasonalCropStressReader.isRuntimeReady == nil
            or not SeasonalCropStressReader.isRuntimeReady() then
            return false
        end
    end

    if actionType == "scs_moisture" then
        if scsSample == nil or scsSample.moisture == nil then
            return false
        end

        return scsSample.moisture >= 0.25
    end

    if actionType == "scs_stress_high" then
        if scsSample == nil or scsSample.stress == nil then
            return false
        end

        return scsSample.stress < 0.6
    end

    if actionType == "scs_stress_watch" then
        if scsSample == nil or scsSample.stress == nil then
            return false
        end

        return scsSample.stress < 0.35
    end

    if actionType == "withered" then
        return not FieldAdvisor.isWithered(fieldState)
    end

    if actionType == "sow" then
        return FieldAdvisor.isFieldSown(fieldState) and not FieldAdvisor.isWithered(fieldState)
    end

    return false
end

---@param task table
---@param context table
---@return boolean
function FieldTaskCompletion.hasPointProgress(task, context)
    if FieldAdvisor == nil or FieldAdvisor.hasCompletionProgress == nil then
        return false
    end

    return FieldAdvisor.hasCompletionProgress(task, context)
end

---@param entry table|nil
---@param fieldCache table|nil
---@return boolean
function FieldTaskCompletion.shouldUseCachedRatio(entry, fieldCache)
    if fieldCache == nil or fieldCache.fingerprintMatch ~= true then
        return false
    end

    -- Point tasks must always re-evaluate; cached grid ratios (e.g. legacy grass_mow) block completion.
    if entry == nil or entry.strategy == "coverage" or entry.strategy == "point" then
        return false
    end

    return true
end

---@param field table
---@param posX number
---@param posZ number
---@return table
function FieldTaskCompletion.newFieldCompletionCache(field, posX, posZ)
    return {
        field = field,
        posX = posX,
        posZ = posZ,
        fieldState = nil,
        fingerprint = nil,
        fingerprintMatch = false,
        ratios = {},
        pointContext = nil,
    }
end

---@param task table
---@param scanner table
---@param fieldCache table|nil
---@return boolean
function FieldTaskCompletion.isTaskComplete(task, scanner, fieldCache)
    if task == nil or task.source ~= "field" or task.completed or task.autoComplete ~= true then
        return false
    end

    local entry = FieldTaskCompletion.getEntry(task.actionType)
    if entry == nil or entry.strategy == "none" then
        return false
    end

    if task.actionType == "harvest_info" or task.actionType == "growing" or task.actionType == "custom" then
        return false
    end

    local field = fieldCache ~= nil and fieldCache.field or nil
    local posX = fieldCache ~= nil and fieldCache.posX or nil
    local posZ = fieldCache ~= nil and fieldCache.posZ or nil

    if field == nil or posX == nil or posZ == nil then
        if scanner == nil or scanner.getEngineFieldById == nil then
            return false
        end

        field = scanner:getEngineFieldById(task.fieldId)
        if field == nil or field.getCenterOfFieldWorldPosition == nil then
            return false
        end

        local okPos, px, pz = pcall(field.getCenterOfFieldWorldPosition, field)
        if not okPos or px == nil or pz == nil then
            return false
        end
        posX, posZ = px, pz
    end

    local threshold = FieldTaskCompletion.getThreshold()
    local ratio = fieldCache ~= nil and fieldCache.ratios[task.actionType] or nil
    if ratio == nil or not FieldTaskCompletion.shouldUseCachedRatio(entry, fieldCache) then
        ratio = FieldTaskCompletion.getCompletionRatio(field, task, posX, posZ)
        if fieldCache ~= nil and fieldCache.ratios ~= nil then
            fieldCache.ratios[task.actionType] = ratio
        end
    end

    if FieldTaskCompletion.requiresCoverageOnly(entry) then
        return ratio ~= nil and ratio >= threshold
    end

    if ratio ~= nil and entry.strategy ~= "point" then
        return ratio >= threshold
    end

    if entry.strategy ~= "point" or FieldAdvisor == nil then
        return false
    end

    if FieldTaskCompletion.isGrassLogisticsAction(task.actionType) and task.fieldId ~= nil then
        FieldAdvisor.clearCoverageCache(task.fieldId, "bales")
        FieldAdvisor.clearCoverageCache(task.fieldId, "grassResidue")
        if fieldCache ~= nil then
            fieldCache.pointContext = nil
        end
    end

    if task.fieldId ~= nil
        and (task.actionType == "weed_hoe" or task.actionType == "weed_combat" or task.actionType == "weed_watch") then
        FieldAdvisor.clearCoverageCache(task.fieldId, "weed")
        if fieldCache ~= nil then
            fieldCache.pointContext = nil
        end
    end

    local context = fieldCache ~= nil and fieldCache.pointContext or nil
    if context == nil then
        local fieldState = fieldCache ~= nil and fieldCache.fieldState or nil
        if fieldState == nil then
            fieldState = FieldAdvisor.getEnrichedFieldState(field, task.fieldId, posX, posZ)
        end
        context = FieldAdvisor.buildFieldContext(field, fieldState, posX, posZ)
        if fieldCache ~= nil then
            fieldCache.pointContext = context
        end
    end

    if FieldTaskCompletion.isActionComplete(task.actionType, context, task) then
        return true
    end

    return FieldTaskCompletion.hasPointProgress(task, context)
end
