--[[
    FieldDebugDump.lua
    Debug dump helpers for ftdlDump / ftdlFruits / ftdlAll (F9 dialog or dev console).
]]

FieldDebugDump = {}
FieldDebugDump.lastDumpedFieldId = nil

---@param value any
---@return string
local function stringify(value)
    if value == nil then
        return "nil"
    end
    return tostring(value)
end

---@param fruitTypeIndex any
---@return string
local function fruitLabel(fruitTypeIndex)
    local idx = tonumber(fruitTypeIndex)
    if idx == nil or idx <= 0 then
        return stringify(fruitTypeIndex)
    end
    local name = FieldAdvisor ~= nil and FieldAdvisor.getFruitTypeName(idx) or nil
    local generic = FieldAdvisor ~= nil and FieldAdvisor.isGenericGrassFruitIndex(idx) or false
    local grass = FieldAdvisor ~= nil and FieldAdvisor.isGrassCrop(idx) or false
    return string.format("%d(%s, grass=%s, generic=%s)", idx, stringify(name), stringify(grass), stringify(generic))
end

---@param line string
local function out(line)
    if FieldToDoLog ~= nil then
        FieldToDoLog.info("DUMP %s", line)
    end
end

---@param idx any
---@return string
local function fillTypeName(idx)
    idx = tonumber(idx)
    if idx == nil or idx <= 0 then
        return stringify(idx)
    end
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local ok, ft = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, idx)
        if ok and ft ~= nil and ft.name ~= nil then
            return string.format("%d(%s)", idx, tostring(ft.name))
        end
    end
    return tostring(idx)
end

--- Density-map availability probe at the field center. Grass residue (loose/swath) detection
--- was removed because the engine fill APIs are absent in this runtime (see docs/DECISIONS.md);
--- this only reports whether the windrow fill-level API is callable, for diagnosis.
local function dumpResidueRawScan(field, fieldState, worldX, worldZ, aggregation)
    if FieldAdvisor == nil or field == nil or worldX == nil or worldZ == nil then
        return
    end

    local heightUtil = FieldAdvisor.resolveDensityMapHeightUtil ~= nil
        and FieldAdvisor.resolveDensityMapHeightUtil() or nil
    local windrowFillIndex = nil
    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getWindrowFillTypeIndexByFruitTypeIndex ~= nil then
        local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
        if grassFruit ~= nil then
            local ok, idx = pcall(
                g_fruitTypeManager.getWindrowFillTypeIndexByFruitTypeIndex, g_fruitTypeManager, grassFruit
            )
            windrowFillIndex = ok and idx or nil
        end
    end

    out(string.format("residueRaw: heightUtil=%s getHeight=%s getType=%s windrowFill=%s",
        stringify(heightUtil ~= nil),
        stringify(getDensityHeightAtWorldPos ~= nil),
        stringify(getDensityTypeIndexAtWorldPos ~= nil),
        fillTypeName(windrowFillIndex)))
end

---@param fieldId number|nil
---@return table|nil, number|nil, number|nil
local function findEngineField(fieldId)
    if g_fieldManager == nil then
        return nil
    end
    local fields = g_fieldManager.fields
    if fields == nil and g_fieldManager.getFields ~= nil then
        fields = g_fieldManager:getFields()
    end
    if fields == nil then
        return nil
    end
    for _, field in pairs(fields) do
        local id = field.getId ~= nil and field:getId() or nil
        if id == fieldId then
            local x, z = FieldAdvisor.getFieldCenterWorldPosition(field)
            return field, x, z
        end
    end
    return nil
end

---@param worldX number
---@param worldZ number
local function dumpDensityMapFruit(worldX, worldZ)
    if rawget(_G, "FSDensityMapUtil") == nil then
        out("FSDensityMapUtil: GLOBAL MISSING")
        return
    end
    if FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        out("FSDensityMapUtil.getFruitTypeIndexAtWorldPos: METHOD MISSING")
        return
    end
    local ok, idx = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, worldX, worldZ)
    out(string.format("FSDensityMapUtil.getFruitTypeIndexAtWorldPos(%.1f,%.1f): ok=%s -> %s", worldX, worldZ, stringify(ok), fruitLabel(ok and idx or nil)))
end

---@param fieldId number
---@return boolean
function FieldDebugDump.dumpField(fieldId)
    fieldId = tonumber(fieldId)
    if fieldId == nil or FieldAdvisor == nil then
        return false
    end

    local field, worldX, worldZ = findEngineField(fieldId)
    if field == nil then
        out(string.format("Field %d not found in g_fieldManager.", fieldId))
        return false
    end
    if worldX == nil or worldZ == nil then
        out(string.format("Field %d: no center world position.", fieldId))
        return false
    end

    out(string.format("===== FIELD %d @ (%.1f, %.1f) =====", fieldId, worldX, worldZ))

    local fieldState = FieldAdvisor.getEnrichedFieldState(field, fieldId, worldX, worldZ)
    out(string.format(
        "FieldState: fruitTypeIndex=%s currentFruitTypeIndex=%s fruitTypeName=%s ground=%s growth=%s lastGrowth=%s weedState=%s weedFactor=%s sprayLevel=%s stubbleShred=%s",
        fruitLabel(fieldState ~= nil and fieldState.fruitTypeIndex or nil),
        fruitLabel(fieldState ~= nil and fieldState.currentFruitTypeIndex or nil),
        stringify(fieldState ~= nil and fieldState.fruitTypeName or nil),
        stringify(FieldAdvisor.getGroundTypeName(fieldState)),
        stringify(FieldAdvisor.getGrowthState(fieldState)),
        stringify(FieldAdvisor.getLastGrowthState(fieldState)),
        stringify(FieldAdvisor.getStateNumber(fieldState, "weedState")),
        stringify(FieldAdvisor.getWeedFactor(fieldState)),
        stringify(FieldAdvisor.getStateNumber(fieldState, "sprayLevel")),
        stringify(FieldAdvisor.getStateNumber(fieldState, "stubbleShredLevel"))
    ))

    local heightUtil = FieldAdvisor.resolveDensityMapHeightUtil ~= nil and FieldAdvisor.resolveDensityMapHeightUtil() or nil
    out(string.format(
        "heightReader: util=%s engineHeight=%s",
        stringify(heightUtil ~= nil),
        stringify(getDensityHeightAtWorldPos ~= nil)
    ))

    out(string.format(
        "field obj: fruitTypeIndex=%s currentFruitTypeIndex=%s plannedFruitTypeIndex=%s name=%s",
        stringify(field.fruitTypeIndex), stringify(field.currentFruitTypeIndex), stringify(field.plannedFruitTypeIndex), stringify(field.name)
    ))
    out(string.format("inferGrassFruitTypeIndexFromField -> %s", fruitLabel(FieldAdvisor.inferGrassFruitTypeIndexFromField(field))))

    dumpDensityMapFruit(worldX, worldZ)
    if FieldTaskCompletion ~= nil and FieldTaskCompletion.collectSamplePoints ~= nil then
        local points = FieldTaskCompletion.collectSamplePoints(field, worldX, worldZ)
        local shown = 0
        for _, p in ipairs(points) do
            if shown < 4 and not (p.x == worldX and p.z == worldZ) then
                shown = shown + 1
                dumpDensityMapFruit(p.x, p.z)
            end
        end
    end

    local situation = FieldAdvisor.classifyProbe(fieldState, field)
    out(string.format("classifyProbe -> %s", stringify(situation)))
    local aggregation = FieldAdvisor.aggregateFieldProbes(
        field, fieldId, fieldState, worldX, worldZ, FieldAdvisor.OVERVIEW_SAMPLE_GRID_STEPS
    )
    out(string.format("aggregate: dominant=%s dominantGrassFruit=%s dominantArableFruit=%s",
        stringify(aggregation.dominantSituation),
        fruitLabel(aggregation.dominantGrassFruit),
        fruitLabel(aggregation.dominantArableFruit)))
    out(string.format("resolveGrassFruitTypeIndex -> %s", fruitLabel(FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ))))
    local displayLabel = FieldAdvisor.getFieldFruitDisplayLabel(field, fieldId, fieldState, worldX, worldZ, aggregation)
    out(string.format("getFieldFruitDisplayLabel -> '%s'", stringify(displayLabel)))

    local context = FieldAdvisor.buildFieldContext(field, fieldState, worldX, worldZ)
    local weedSummary = context ~= nil and context.weedSummary or nil
    local probeState = aggregation.centerState or fieldState
    out(string.format(
        "meadowPhase: center=%s representative=%s ground=%s growthFlags(cut=%s harvestable=%s harvestReady=%s)",
        stringify(FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)),
        stringify(FieldAdvisor.getGrassMeadowPhase(aggregation.representativeState, field, aggregation)),
        stringify(FieldAdvisor.getGroundTypeName(fieldState)),
        stringify((function()
            local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
            local growth = FieldAdvisor.evaluateFruitGrowth(grassFruit, FieldAdvisor.getEffectiveGrowthState(fieldState))
            return growth.isCut
        end)()),
        stringify((function()
            local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
            local growth = FieldAdvisor.evaluateFruitGrowth(grassFruit, FieldAdvisor.getEffectiveGrowthState(fieldState))
            return growth.isHarvestable
        end)()),
        stringify((function()
            local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
            local growth = FieldAdvisor.evaluateFruitGrowth(grassFruit, FieldAdvisor.getEffectiveGrowthState(fieldState))
            return growth.isHarvestReady
        end)())
    ))
    local grassResidue = context ~= nil and context.grassResidueSummary or nil
    if grassResidue ~= nil then
        -- Residue is bale-only now (loose/swath not sensable; see docs/DECISIONS.md).
        out(string.format(
            "grassResidue: available=%s source=%s state=%s fieldBaleCount=%s",
            stringify(grassResidue.residueAvailable),
            stringify(grassResidue.residueSource),
            stringify(grassResidue.residueState),
            stringify(grassResidue.fieldBaleCount)
        ))
    end
    dumpResidueRawScan(field, fieldState, worldX, worldZ, aggregation)
    local baleSummary = context ~= nil and context.baleSummary or nil
    if baleSummary ~= nil then
        local mapBaleCount = nil
        if FieldAdvisor.collectMapBaleObjects ~= nil then
            mapBaleCount = #FieldAdvisor.collectMapBaleObjects()
        end
        out(string.format(
            "baleCoverage: total=%s mapBales=%s",
            stringify(baleSummary.total),
            stringify(mapBaleCount)
        ))
    end
    if weedSummary ~= nil then
        out(string.format(
            "weedCoverage: total=%s live=%s dead=%s liveRatio=%.3f deadRatio=%.3f doneByCoverage=%s",
            stringify(weedSummary.total), stringify(weedSummary.live), stringify(weedSummary.dead),
            weedSummary.liveRatio or 0, weedSummary.deadRatio or 0,
            stringify(FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary))
        ))
        out(string.format(
            "weedAdvisor: needsCombat=%s needsWatch=%s needsHoe=%s needsSpray=%s displayLabel='%s' centerDeadOrSprayed=%s",
            stringify(FieldAdvisor.fieldNeedsWeedCombat(fieldState, context.rules, weedSummary)),
            stringify(FieldAdvisor.fieldNeedsWeedWatch(fieldState, context.rules, weedSummary)),
            stringify(FieldAdvisor.fieldNeedsWeedHoe(fieldState, context.rules, weedSummary)),
            stringify(FieldAdvisor.fieldShouldSuggestWeedSpray(fieldState, context.rules, weedSummary)),
            stringify(FieldAdvisor.formatWeedDisplayLabel(fieldState, context.rules, weedSummary)),
            stringify(FieldAdvisor.isWeedDeadOrSprayed(fieldState))
        ))
    end

    out(string.format("season: period=%s calMonth=%s seasonalGrowth=%s growthMode=%s",
        stringify(FieldAdvisor.getCurrentSeasonPeriod()),
        stringify(FieldAdvisor.getCalendarMonthForSeasonPeriod(FieldAdvisor.getCurrentSeasonPeriod())),
        stringify(FieldAdvisor.isSeasonalGrowthEnabled()),
        stringify(FieldAdvisor.getActiveGrowthMode())))

    local arableFruit = FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
    local fruitForHarvest = arableFruit or aggregation.dominantArableFruit
    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)
    out(string.format("harvestState: growth=%s hint='%s' (representative growth=%s hint='%s')",
        stringify(FieldAdvisor.getEffectiveGrowthState(harvestState)),
        stringify(FieldAdvisor.getHarvestWindowHint(
            FieldAdvisor.resolveFruitTypeIndex(harvestState, field) or fruitForHarvest, harvestState)),
        stringify(FieldAdvisor.getEffectiveGrowthState(aggregation.representativeState)),
        stringify(FieldAdvisor.getHarvestWindowHint(fruitForHarvest, aggregation.representativeState))))
    out(string.format("resolveFruitTypeIndex (arable) -> %s", fruitLabel(fruitForHarvest)))
    if fruitForHarvest ~= nil then
        local desc = FieldAdvisor.getFruitTypeDesc(fruitForHarvest)
        if desc ~= nil then
            out(string.format("fruitDesc: minHarvest=%s maxHarvest=%s hasGetIsHarvestReady=%s hasGetIsHarvestableInPeriod=%s",
                stringify(desc.minHarvestingGrowthState), stringify(desc.maxHarvestingGrowthState),
                stringify(desc.getIsHarvestReady ~= nil), stringify(desc.getIsHarvestableInPeriod ~= nil)))
        end
        out(string.format("estimatePeriodsUntilHarvest -> %s", stringify(FieldAdvisor.estimateNonSeasonalPeriodsUntilHarvest(fruitForHarvest, harvestState, desc))))
        out(string.format("getExpectedHarvestPeriod -> %s (%s)",
            stringify(FieldAdvisor.getExpectedHarvestPeriod(fruitForHarvest, harvestState)),
            stringify(FieldAdvisor.getHarvestPeriodDisplayLabel(
                FieldAdvisor.getExpectedHarvestPeriod(fruitForHarvest, harvestState)))))
        out(string.format("getHarvestWindowHint -> '%s'", stringify(FieldAdvisor.getHarvestWindowHint(fruitForHarvest, harvestState))))
        local growthState = FieldAdvisor.getEffectiveGrowthState(harvestState)
        out(string.format("harvestProjection: growth=%s stepsUntilRipe=%s",
            stringify(growthState),
            stringify(FieldAdvisor.estimateNonSeasonalPeriodsUntilHarvest(fruitForHarvest, harvestState, desc))))
        out(string.format("isCropHarvestReady -> %s", stringify(FieldAdvisor.isCropHarvestReady(field, harvestState, fruitForHarvest))))
    end

    local phaseIsGrass = FieldAdvisor.isGrassFieldState(harvestState, field)
        or (aggregation ~= nil and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS)
    local phaseFacts = FieldAdvisor.buildFieldPhaseFacts(field, harvestState, aggregation, phaseIsGrass, fieldId)
    local phaseFlags = phaseFacts.flags or {}
    out(string.format(
        "phaseFacts: dominant=%s grass=%s hasFruit=%s growth=%s maxHarvest=%s ground=%s shred=%s residue=%s/%s flags(cut=%s harvestable=%s harvestReady=%s withered=%s)",
        stringify(phaseFacts.dominant), stringify(phaseFacts.isGrassCrop), stringify(phaseFacts.hasFruit),
        stringify(phaseFacts.growth), stringify(phaseFacts.maxHarvest), stringify(phaseFacts.ground),
        stringify(phaseFacts.shred), stringify(phaseFacts.residue), stringify(phaseFacts.residueReliable),
        stringify(phaseFlags.cut), stringify(phaseFlags.harvestable), stringify(phaseFlags.harvestReady),
        stringify(phaseFlags.withered)))
    out(string.format("deriveFieldPhase -> %s  | getCropPhase -> %s",
        stringify(FieldPhase.deriveFieldPhase(phaseFacts)),
        stringify(FieldAdvisor.getCropPhase(field, fieldState, aggregation))))

    out(string.format("===== END FIELD %d =====", fieldId))
    FieldDebugDump.lastDumpedFieldId = fieldId
    return true
end

function FieldDebugDump.dumpFruitTypes()
    if g_fruitTypeManager == nil or g_fruitTypeManager.getFruitTypes == nil then
        out("g_fruitTypeManager not ready.")
        return false
    end
    local ok, fruitTypes = pcall(g_fruitTypeManager.getFruitTypes, g_fruitTypeManager)
    if not ok or fruitTypes == nil then
        out("getFruitTypes failed.")
        return false
    end
    out("===== FRUIT TYPES =====")
    for _, desc in pairs(fruitTypes) do
        if desc ~= nil and desc.index ~= nil then
            out(string.format("idx=%s name=%s min=%s max=%s grass=%s generic=%s",
                stringify(desc.index), stringify(desc.name), stringify(desc.minHarvestingGrowthState), stringify(desc.maxHarvestingGrowthState),
                stringify(FieldAdvisor.isGrassCrop(desc.index)), stringify(FieldAdvisor.isGenericGrassFruitIndex(desc.index))))
        end
    end
    out("===== END FRUIT TYPES =====")
    return true
end

---@param ownedFields table[]|nil
function FieldDebugDump.dumpAllOwnedFields(ownedFields)
    if ownedFields == nil or #ownedFields == 0 then
        return false
    end

    FieldDebugDump.dumpFruitTypes()
    out(string.format("===== OWNED FIELDS (%d) =====", #ownedFields))
    for _, record in ipairs(ownedFields) do
        if record ~= nil and record.id ~= nil then
            FieldDebugDump.dumpField(record.id)
        end
    end
    out("===== END OWNED FIELDS =====")
    return true
end

---@param fieldId string|number|nil
function FieldDebugDump:consoleDump(fieldId)
    fieldId = tonumber(fieldId)
    if fieldId == nil then
        return "Usage: ftdlDump <fieldId>  (e.g. ftdlDump 76)"
    end
    if FieldDebugDump.dumpField(fieldId) then
        return string.format("Field %d dumped to log.txt (search '[FS25_FieldToDoList] DUMP').", fieldId)
    end
    return string.format("Field %d dump failed — see log.txt.", fieldId)
end

function FieldDebugDump:consoleFruits()
    if FieldDebugDump.dumpFruitTypes() then
        return "Fruit types dumped to log.txt (search '[FS25_FieldToDoList] DUMP')."
    end
    return "Fruit type dump failed."
end

function FieldDebugDump.register()
    if addConsoleCommand == nil then
        return
    end
    addConsoleCommand("ftdlDump", "Dump one field's runtime data: ftdlDump <fieldId>", "consoleDump", FieldDebugDump)
    addConsoleCommand("ftdlFruits", "List fruit types with harvest growth states", "consoleFruits", FieldDebugDump)
end

function FieldDebugDump.unregister()
    if removeConsoleCommand == nil then
        return
    end
    removeConsoleCommand("ftdlDump")
    removeConsoleCommand("ftdlFruits")
    FieldDebugDump.lastDumpedFieldId = nil
end
