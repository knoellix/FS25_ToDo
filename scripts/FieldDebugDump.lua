--[[
    FieldDebugDump.lua
    Debug dump helpers for ftdlDump / ftdlFruits / ftdlAll (F9 dialog or dev console).
]]

FieldDebugDump = {}
FieldDebugDump.lastDumpedFieldId = nil

---@param value any
---@return string
local function s(value)
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
        return s(fruitTypeIndex)
    end
    local name = FieldAdvisor ~= nil and FieldAdvisor.getFruitTypeName(idx) or nil
    local generic = FieldAdvisor ~= nil and FieldAdvisor.isGenericGrassFruitIndex(idx) or false
    local grass = FieldAdvisor ~= nil and FieldAdvisor.isGrassCrop(idx) or false
    return string.format("%d(%s, grass=%s, generic=%s)", idx, s(name), s(grass), s(generic))
end

---@param line string
local function out(line)
    if FieldToDoLog ~= nil then
        FieldToDoLog.info("DUMP %s", line)
    end
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
    out(string.format("FSDensityMapUtil.getFruitTypeIndexAtWorldPos(%.1f,%.1f): ok=%s -> %s", worldX, worldZ, s(ok), fruitLabel(ok and idx or nil)))
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
        "FieldState: fruitTypeIndex=%s currentFruitTypeIndex=%s fruitTypeName=%s ground=%s growth=%s lastGrowth=%s weedState=%s sprayLevel=%s stubbleShred=%s",
        fruitLabel(fieldState ~= nil and fieldState.fruitTypeIndex or nil),
        fruitLabel(fieldState ~= nil and fieldState.currentFruitTypeIndex or nil),
        s(fieldState ~= nil and fieldState.fruitTypeName or nil),
        s(FieldAdvisor.getGroundTypeName(fieldState)),
        s(FieldAdvisor.getGrowthState(fieldState)),
        s(FieldAdvisor.getLastGrowthState(fieldState)),
        s(FieldAdvisor.getStateNumber(fieldState, "weedState")),
        s(FieldAdvisor.getStateNumber(fieldState, "sprayLevel")),
        s(FieldAdvisor.getStateNumber(fieldState, "stubbleShredLevel"))
    ))

    local heightUtil = FieldAdvisor.resolveDensityMapHeightUtil ~= nil and FieldAdvisor.resolveDensityMapHeightUtil() or nil
    out(string.format(
        "heightReader: util=%s engineHeight=%s planeId=%s centerMaterial=%.4f",
        s(heightUtil ~= nil),
        s(getDensityHeightAtWorldPos ~= nil),
        s(FieldAdvisor.getHeightDetailPlaneId ~= nil and FieldAdvisor.getHeightDetailPlaneId() or nil),
        FieldAdvisor.measureHeightMaterialAtPoint ~= nil and FieldAdvisor.measureHeightMaterialAtPoint(worldX, worldZ) or 0
    ))

    out(string.format(
        "field obj: fruitTypeIndex=%s currentFruitTypeIndex=%s plannedFruitTypeIndex=%s name=%s",
        s(field.fruitTypeIndex), s(field.currentFruitTypeIndex), s(field.plannedFruitTypeIndex), s(field.name)
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
    out(string.format("classifyProbe -> %s", s(situation)))
    local aggregation = FieldAdvisor.aggregateFieldProbes(field, fieldId, fieldState, worldX, worldZ)
    out(string.format("aggregate: dominant=%s dominantGrassFruit=%s dominantArableFruit=%s",
        s(aggregation.dominantSituation),
        fruitLabel(aggregation.dominantGrassFruit),
        fruitLabel(aggregation.dominantArableFruit)))
    out(string.format("resolveGrassFruitTypeIndex -> %s", fruitLabel(FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ))))
    local displayLabel = FieldAdvisor.getFieldFruitDisplayLabel(field, fieldId, fieldState, worldX, worldZ, aggregation)
    out(string.format("getFieldFruitDisplayLabel -> '%s'", s(displayLabel)))

    local context = FieldAdvisor.buildFieldContext(field, fieldState, worldX, worldZ)
    local weedSummary = context ~= nil and context.weedSummary or nil
    local probeState = aggregation.centerState or fieldState
    out(string.format(
        "meadowPhase: center=%s representative=%s ground=%s growthFlags(cut=%s harvestable=%s harvestReady=%s)",
        s(FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)),
        s(FieldAdvisor.getGrassMeadowPhase(aggregation.representativeState, field, aggregation)),
        s(FieldAdvisor.getGroundTypeName(fieldState)),
        s((function()
            local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
            local growth = FieldAdvisor.evaluateFruitGrowth(grassFruit, FieldAdvisor.getEffectiveGrowthState(fieldState))
            return growth.isCut
        end)()),
        s((function()
            local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
            local growth = FieldAdvisor.evaluateFruitGrowth(grassFruit, FieldAdvisor.getEffectiveGrowthState(fieldState))
            return growth.isHarvestable
        end)()),
        s((function()
            local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
            local growth = FieldAdvisor.evaluateFruitGrowth(grassFruit, FieldAdvisor.getEffectiveGrowthState(fieldState))
            return growth.isHarvestReady
        end)())
    ))
    local grassResidue = context ~= nil and context.grassResidueSummary or nil
    if grassResidue ~= nil then
        out(string.format(
            "grassResidue: available=%s source=%s state=%s total=%s occupied=%s ratio=%.3f liters=%.3f maxSample=%.3f maxMaterial=%.4f centerMat=%.4f swathHits=%s windrowHits=%s shred=%s crossLine=%s lineEv=%s crossPts=%s fillTypes=%d",
            s(grassResidue.residueAvailable),
            s(grassResidue.residueSource),
            s(grassResidue.residueState),
            s(grassResidue.total),
            s(grassResidue.occupied),
            grassResidue.occupiedRatio or 0,
            grassResidue.totalLiters or 0,
            grassResidue.maxSampleLiters or 0,
            grassResidue.maxSampleMaterial or 0,
            grassResidue.centerMaterial or 0,
            s(grassResidue.swathHits),
            s(grassResidue.windrowTypeHits),
            s(grassResidue.signalShred),
            s(grassResidue.crossLineTransitions),
            s(FieldAdvisor.hasGrassWindrowLineEvidence(grassResidue)),
            s(grassResidue.crossScanPoints),
            #(FieldAdvisor.collectWindrowFillTypeIndices(
                FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
            ))
        ))
    end
    local baleSummary = context ~= nil and context.baleSummary or nil
    if baleSummary ~= nil then
        local mapBaleCount = nil
        if FieldAdvisor.collectMapBaleObjects ~= nil then
            mapBaleCount = #FieldAdvisor.collectMapBaleObjects()
        end
        out(string.format(
            "baleCoverage: total=%s mapBales=%s",
            s(baleSummary.total),
            s(mapBaleCount)
        ))
    end
    if weedSummary ~= nil then
        out(string.format(
            "weedCoverage: total=%s live=%s dead=%s liveRatio=%.3f deadRatio=%.3f doneByCoverage=%s",
            s(weedSummary.total), s(weedSummary.live), s(weedSummary.dead),
            weedSummary.liveRatio or 0, weedSummary.deadRatio or 0,
            s(FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary))
        ))
        out(string.format(
            "weedAdvisor: needsCombat=%s needsWatch=%s displayLabel='%s' centerDeadOrSprayed=%s",
            s(FieldAdvisor.fieldNeedsWeedCombat(fieldState, context.rules, weedSummary)),
            s(FieldAdvisor.fieldNeedsWeedWatch(fieldState, context.rules, weedSummary)),
            s(FieldAdvisor.formatWeedDisplayLabel(fieldState, context.rules, weedSummary)),
            s(FieldAdvisor.isWeedDeadOrSprayed(fieldState))
        ))
    end

    out(string.format("season: period=%s calMonth=%s seasonalGrowth=%s growthMode=%s",
        s(FieldAdvisor.getCurrentSeasonPeriod()),
        s(FieldAdvisor.getCalendarMonthForSeasonPeriod(FieldAdvisor.getCurrentSeasonPeriod())),
        s(FieldAdvisor.isSeasonalGrowthEnabled()),
        s(FieldAdvisor.getActiveGrowthMode())))

    local arableFruit = FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
    local fruitForHarvest = arableFruit or aggregation.dominantArableFruit
    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)
    out(string.format("harvestState: growth=%s hint='%s' (representative growth=%s hint='%s')",
        s(FieldAdvisor.getEffectiveGrowthState(harvestState)),
        s(FieldAdvisor.getHarvestWindowHint(
            FieldAdvisor.resolveFruitTypeIndex(harvestState, field) or fruitForHarvest, harvestState)),
        s(FieldAdvisor.getEffectiveGrowthState(aggregation.representativeState)),
        s(FieldAdvisor.getHarvestWindowHint(fruitForHarvest, aggregation.representativeState))))
    out(string.format("resolveFruitTypeIndex (arable) -> %s", fruitLabel(fruitForHarvest)))
    if fruitForHarvest ~= nil then
        local desc = FieldAdvisor.getFruitTypeDesc(fruitForHarvest)
        if desc ~= nil then
            out(string.format("fruitDesc: minHarvest=%s maxHarvest=%s hasGetIsHarvestReady=%s hasGetIsHarvestableInPeriod=%s",
                s(desc.minHarvestingGrowthState), s(desc.maxHarvestingGrowthState),
                s(desc.getIsHarvestReady ~= nil), s(desc.getIsHarvestableInPeriod ~= nil)))
        end
        out(string.format("estimatePeriodsUntilHarvest -> %s", s(FieldAdvisor.estimateNonSeasonalPeriodsUntilHarvest(fruitForHarvest, harvestState, desc))))
        out(string.format("getExpectedHarvestPeriod -> %s (%s)",
            s(FieldAdvisor.getExpectedHarvestPeriod(fruitForHarvest, harvestState)),
            s(FieldAdvisor.getHarvestPeriodDisplayLabel(
                FieldAdvisor.getExpectedHarvestPeriod(fruitForHarvest, harvestState)))))
        out(string.format("getHarvestWindowHint -> '%s'", s(FieldAdvisor.getHarvestWindowHint(fruitForHarvest, harvestState))))
        local growthState = FieldAdvisor.getEffectiveGrowthState(harvestState)
        out(string.format("harvestProjection: growth=%s stepsUntilRipe=%s",
            s(growthState),
            s(FieldAdvisor.estimateNonSeasonalPeriodsUntilHarvest(fruitForHarvest, harvestState, desc))))
        out(string.format("isCropHarvestReady -> %s", s(FieldAdvisor.isCropHarvestReady(field, harvestState, fruitForHarvest))))
    end

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
                s(desc.index), s(desc.name), s(desc.minHarvestingGrowthState), s(desc.maxHarvestingGrowthState),
                s(FieldAdvisor.isGrassCrop(desc.index)), s(FieldAdvisor.isGenericGrassFruitIndex(desc.index))))
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
