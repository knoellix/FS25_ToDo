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

---@param line string
local function scanOut(line)
    if FieldToDoLog ~= nil then
        FieldToDoLog.info("STRAW_SCAN %s", line)
    end
end

---@param ok boolean
---@param err any
---@return string
local function formatPcallError(ok, err)
    if ok then
        return "ok"
    end
    return stringify(err)
end

---@return number|nil
local function resolveFillTypeStraw()
    if FillType ~= nil and FillType.STRAW ~= nil then
        local idx = tonumber(FillType.STRAW)
        if idx ~= nil and idx > 0 then
            return idx
        end
    end
    if FieldAdvisor ~= nil and FieldAdvisor.resolveStrawFillTypeIndex ~= nil then
        return FieldAdvisor.resolveStrawFillTypeIndex()
    end
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeIndexByName ~= nil then
        local ok, idx = pcall(g_fillTypeManager.getFillTypeIndexByName, g_fillTypeManager, "STRAW")
        idx = ok and tonumber(idx) or nil
        if idx ~= nil and idx > 0 then
            return idx
        end
    end
    return nil
end

---@return number|nil
local function resolveStrawTextureIndex(fillIndex)
    if fillIndex == nil or g_fillTypeManager == nil then
        return nil
    end
    if g_fillTypeManager.getTextureArrayIndexByFillTypeIndex ~= nil then
        local ok, idx = pcall(
            g_fillTypeManager.getTextureArrayIndexByFillTypeIndex, g_fillTypeManager, fillIndex
        )
        idx = ok and tonumber(idx) or nil
        if idx ~= nil and idx > 0 then
            return idx
        end
    end
    if g_fillTypeManager.getFillTypeByIndex ~= nil then
        local ok, ft = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, fillIndex)
        if ok and ft ~= nil then
            return tonumber(ft.textureArrayIndex)
        end
    end
    return nil
end

---@return table[]
local function collectHeightPlaneIds()
    local planes = {}
    local seen = {}

    local function addPlane(label, planeId)
        planeId = tonumber(planeId)
        if planeId == nil or planeId <= 0 or seen[planeId] then
            return
        end
        seen[planeId] = true
        planes[#planes + 1] = { label = label, id = planeId }
    end

    if g_currentMission ~= nil and g_currentMission.terrainDetailHeightId ~= nil then
        addPlane("mission.terrainDetailHeightId", g_currentMission.terrainDetailHeightId)
    end
    if getTerrainDataPlaneByName ~= nil then
        local ok, planeId = pcall(getTerrainDataPlaneByName, "height")
        if ok then
            addPlane("getTerrainDataPlaneByName(height)", planeId)
        end
    end
    return planes
end

---@param worldX number
---@param worldZ number
---@return number
local function sampleTerrainY(worldX, worldZ)
    if FieldVisit ~= nil and FieldVisit.sampleTerrainHeight ~= nil then
        local y = FieldVisit.sampleTerrainHeight(worldX, worldZ)
        if y ~= nil then
            return y
        end
    end
    if g_currentMission ~= nil and g_currentMission.getTerrainHeightAtWorldPos ~= nil then
        local ok, missionY = pcall(g_currentMission.getTerrainHeightAtWorldPos, g_currentMission, worldX, worldZ)
        if ok and missionY ~= nil and missionY > -1000 and missionY < 10000 then
            return missionY
        end
    end
    return 0
end

---@param label string
---@param fn function
---@param ... any
---@return table
local function callFillProbe(label, fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    return {
        label = label,
        ok = ok,
        liters = ok and tonumber(a) or nil,
        area = ok and tonumber(b) or nil,
        total = ok and tonumber(c) or nil,
        err = ok and nil or a,
    }
end

---@param fillIndex number
---@param worldX number
---@param worldZ number
---@param halfSize number
---@return table[]
local function probeFillMethods(fillIndex, worldX, worldZ, halfSize)
    local x0, z0 = worldX - halfSize, worldZ - halfSize
    local x1, z1 = worldX + halfSize, worldZ - halfSize
    local x2, z2 = worldX - halfSize, worldZ + halfSize
    local probes = {}

    if type(DensityMapHeightUtil) == "table" and DensityMapHeightUtil.getFillLevelAtArea ~= nil then
        probes[#probes + 1] = callFillProbe(
            "DensityMapHeightUtil.getFillLevelAtArea",
            DensityMapHeightUtil.getFillLevelAtArea,
            fillIndex, x0, z0, x1, z1, x2, z2
        )
    end

    local rawUtil = rawget(_G, "DensityMapHeightUtil")
    if type(rawUtil) == "table" and rawUtil.getFillLevelAtArea ~= nil
            and rawUtil ~= DensityMapHeightUtil then
        probes[#probes + 1] = callFillProbe(
            "rawget(_G).getFillLevelAtArea",
            rawUtil.getFillLevelAtArea,
            fillIndex, x0, z0, x1, z1, x2, z2
        )
    end

    if FieldAdvisor ~= nil and FieldAdvisor.callFillLevelAtArea ~= nil then
        local liters = FieldAdvisor.callFillLevelAtArea(fillIndex, x0, z0, x1, z1, x2, z2)
        probes[#probes + 1] = {
            label = "FieldAdvisor.callFillLevelAtArea",
            ok = true,
            liters = tonumber(liters),
            area = nil,
            total = nil,
            err = nil,
        }
    end

    if g_densityMapHeightManager ~= nil then
        for _, methodName in ipairs({
            "getFillLevelAtArea",
            "getFillLevelInArea",
            "getFillLevelAtWorldPos",
            "getFillLevelAtPosition",
        }) do
            local fn = g_densityMapHeightManager[methodName]
            if fn ~= nil then
                if methodName == "getFillLevelAtWorldPos" or methodName == "getFillLevelAtPosition" then
                    local y = sampleTerrainY(worldX, worldZ)
                    probes[#probes + 1] = callFillProbe(
                        "g_densityMapHeightManager:" .. methodName,
                        fn,
                        g_densityMapHeightManager, fillIndex, worldX, y, worldZ
                    )
                else
                    probes[#probes + 1] = callFillProbe(
                        "g_densityMapHeightManager:" .. methodName,
                        fn,
                        g_densityMapHeightManager, fillIndex, x0, z0, x1, z1, x2, z2
                    )
                end
            end
        end
    end

    if type(DensityMapHeightUtil) == "table" and DensityMapHeightUtil.getFillLevelAtWorldPos ~= nil then
        local y = sampleTerrainY(worldX, worldZ)
        probes[#probes + 1] = callFillProbe(
            "DensityMapHeightUtil.getFillLevelAtWorldPos",
            DensityMapHeightUtil.getFillLevelAtWorldPos,
            fillIndex, worldX, y, worldZ
        )
    end

    return probes
end

---@param planeId number
---@param worldX number
---@param worldZ number
---@param yBase number
---@return table[]
local function probeTypeAtPoint(planeId, worldX, worldZ, yBase)
    local hits = {}
    if getDensityTypeIndexAtWorldPos == nil then
        return hits
    end

    for _, offset in ipairs({ 0, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0 }) do
        local y = yBase + offset
        local ok, typeIdx = pcall(getDensityTypeIndexAtWorldPos, planeId, worldX, y, worldZ)
        typeIdx = ok and tonumber(typeIdx) or nil
        hits[#hits + 1] = { y = y, ok = ok, typeIdx = typeIdx, err = ok and nil or typeIdx }
    end

    return hits
end

---@param planeId number
---@param worldX number
---@param worldZ number
---@param yBase number
---@return table
local function probeHeightAtPoint(planeId, worldX, worldZ, yBase)
    if getDensityHeightAtWorldPos == nil then
        return { ok = false, height = nil, delta = nil, err = "getDensityHeightAtWorldPos missing" }
    end
    local ok, height, delta = pcall(getDensityHeightAtWorldPos, planeId, worldX, yBase, worldZ)
    return {
        ok = ok,
        height = ok and tonumber(height) or nil,
        delta = ok and tonumber(delta) or nil,
        err = ok and nil or height,
    }
end

---@param planeId number
---@param worldX number
---@param worldZ number
---@param yBase number
---@return table
local function probeDensityAtPoint(planeId, worldX, worldZ, yBase)
    if getDensityAtWorldPos == nil then
        return { ok = false, density = nil, err = "getDensityAtWorldPos missing" }
    end
    local ok, density = pcall(getDensityAtWorldPos, planeId, worldX, yBase, worldZ)
    return {
        ok = ok,
        density = ok and tonumber(density) or nil,
        err = ok and nil or density,
    }
end

---@param probe table
---@return boolean
local function fillProbePositive(probe)
    return probe.ok and probe.liters ~= nil and probe.liters > 0
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

---@param fieldId number
---@param worldX number|nil
---@param worldZ number|nil
---@return boolean
function FieldDebugDump.dumpStrawMaterialScan(fieldId, worldX, worldZ)
    fieldId = tonumber(fieldId)
    if fieldId == nil then
        scanOut("fieldId required")
        return false
    end

    local field, centerX, centerZ = findEngineField(fieldId)
    if field == nil then
        scanOut(string.format("field %d not found", fieldId))
        return false
    end

    if worldX == nil or worldZ == nil then
        worldX, worldZ = centerX, centerZ
    end
    if worldX == nil or worldZ == nil then
        scanOut(string.format("field %d: no world position", fieldId))
        return false
    end

    if FieldAdvisor ~= nil and FieldAdvisor.invalidateDensityMapHeightUtil ~= nil then
        FieldAdvisor.invalidateDensityMapHeightUtil()
    end

    scanOut(string.format("===== FIELD %d @ (%.2f, %.2f) =====", fieldId, worldX, worldZ))

    local fillIndex = resolveFillTypeStraw()
    local texIndex = resolveStrawTextureIndex(fillIndex)
    scanOut(string.format(
        "fillType: FillType.STRAW=%s nameLookup=%s textureArrayIndex=%s",
        stringify(FillType ~= nil and FillType.STRAW or nil),
        fillTypeName(fillIndex),
        stringify(texIndex)
    ))

    scanOut(string.format(
        "runtime: DensityMapHeightUtil=%s rawget=%s g_densityMapHeightManager=%s getType=%s getHeight=%s getDensity=%s",
        stringify(type(DensityMapHeightUtil) == "table"),
        stringify(rawget(_G, "DensityMapHeightUtil") ~= nil),
        stringify(g_densityMapHeightManager ~= nil),
        stringify(getDensityTypeIndexAtWorldPos ~= nil),
        stringify(getDensityHeightAtWorldPos ~= nil),
        stringify(getDensityAtWorldPos ~= nil)
    ))

    if FieldAdvisor ~= nil and FieldAdvisor.resolveDensityMapHeightUtil ~= nil then
        local util = FieldAdvisor.resolveDensityMapHeightUtil()
        scanOut(string.format(
            "resolveDensityMapHeightUtil -> %s method=%s needsSelf=%s",
            stringify(util ~= nil),
            stringify(FieldAdvisor._densityMapHeightFillMethod),
            stringify(FieldAdvisor._densityMapHeightNeedsSelf)
        ))
    end

    if g_densityMapHeightManager ~= nil then
        local mgrMethods = {}
        for key, value in pairs(g_densityMapHeightManager) do
            if type(key) == "string" and type(value) == "function"
                    and (string.find(key, "Fill", 1, true) ~= nil
                        or string.find(key, "Level", 1, true) ~= nil
                        or string.find(key, "Liter", 1, true) ~= nil) then
                mgrMethods[#mgrMethods + 1] = key
            end
        end
        table.sort(mgrMethods)
        scanOut(string.format("densityMapHeightManager methods: %s", table.concat(mgrMethods, ", ")))
    end

    local planes = collectHeightPlaneIds()
    if #planes == 0 then
        scanOut("height planes: none")
    else
        for _, plane in ipairs(planes) do
            scanOut(string.format("height plane: %s -> %s", plane.label, stringify(plane.id)))
        end
    end

    if fillIndex == nil then
        scanOut("STRAW fill type index unavailable — fill probes skipped")
        return false
    end

    local halfSize = FieldAdvisor ~= nil and FieldAdvisor.GRASS_RESIDUE_SAMPLE_HALF_SIZE or 2
    local halfExtent = FieldAdvisor ~= nil and FieldAdvisor.getFieldSampleHalfExtent ~= nil
        and FieldAdvisor.getFieldSampleHalfExtent(field) or 12

    local samplePoints = {
        { tag = "center", x = worldX, z = worldZ },
        { tag = "west", x = worldX - halfExtent * 0.5, z = worldZ },
        { tag = "east", x = worldX + halfExtent * 0.5, z = worldZ },
        { tag = "north", x = worldX, z = worldZ - halfExtent * 0.5 },
        { tag = "south", x = worldX, z = worldZ + halfExtent * 0.5 },
    }

    local positives = {}

    for _, point in ipairs(samplePoints) do
        scanOut(string.format("--- point %s (%.2f, %.2f) ---", point.tag, point.x, point.z))

        local yBase = 0
        yBase = sampleTerrainY(point.x, point.z)
        scanOut(string.format("terrainY=%.3f sampleHalf=%.2f", yBase, halfSize))

        for _, probe in ipairs(probeFillMethods(fillIndex, point.x, point.z, halfSize)) do
            scanOut(string.format(
                "fill|%s|liters=%s area=%s total=%s|%s",
                probe.label,
                stringify(probe.liters),
                stringify(probe.area),
                stringify(probe.total),
                formatPcallError(probe.ok, probe.err)
            ))
            if fillProbePositive(probe) then
                positives[#positives + 1] = string.format(
                    "%s@%s=%.4f", probe.label, point.tag, probe.liters
                )
            end
        end

        for _, plane in ipairs(planes) do
            local typeHits = probeTypeAtPoint(plane.id, point.x, point.z, yBase)
            local anyType = false
            for _, hit in ipairs(typeHits) do
                if hit.typeIdx ~= nil and hit.typeIdx > 0 then
                    anyType = true
                    local isStraw = hit.typeIdx == fillIndex
                        or hit.typeIdx == texIndex
                        or (texIndex ~= nil and hit.typeIdx == texIndex - 1)
                    scanOut(string.format(
                        "type|%s|y=%.2f|idx=%s strawMatch=%s|%s",
                        plane.label,
                        hit.y,
                        fillTypeName(hit.typeIdx),
                        stringify(isStraw),
                        formatPcallError(hit.ok, hit.err)
                    ))
                    if isStraw then
                        positives[#positives + 1] = string.format(
                            "type|%s@%s y=%.2f idx=%d", plane.label, point.tag, hit.y, hit.typeIdx
                        )
                    end
                end
            end
            if not anyType then
                scanOut(string.format("type|%s|all_y_nil_or_zero", plane.label))
            end

            local heightProbe = probeHeightAtPoint(plane.id, point.x, point.z, yBase)
            scanOut(string.format(
                "height|%s|h=%s delta=%s|%s",
                plane.label,
                stringify(heightProbe.height),
                stringify(heightProbe.delta),
                formatPcallError(heightProbe.ok, heightProbe.err)
            ))
            if heightProbe.ok and heightProbe.delta ~= nil and heightProbe.delta > 0.05 then
                positives[#positives + 1] = string.format(
                    "height_delta|%s@%s=%.4f", plane.label, point.tag, heightProbe.delta
                )
            end

            local densityProbe = probeDensityAtPoint(plane.id, point.x, point.z, yBase)
            scanOut(string.format(
                "density|%s|value=%s|%s",
                plane.label,
                stringify(densityProbe.density),
                formatPcallError(densityProbe.ok, densityProbe.err)
            ))
            if densityProbe.ok and densityProbe.density ~= nil and densityProbe.density > 0 then
                positives[#positives + 1] = string.format(
                    "density|%s@%s=%.4f", plane.label, point.tag, densityProbe.density
                )
            end
        end
    end

    if #positives == 0 then
        scanOut("SUMMARY: no positive straw/material signal on any method")
    else
        scanOut("SUMMARY positives: " .. table.concat(positives, "; "))
    end

    scanOut(string.format("===== END FIELD %d =====", fieldId))
    if FieldToDoLog ~= nil then
        FieldToDoLog.info(
            "ftdlStrawScan: field %d done — search STRAW_SCAN in log.txt (%d positive signal(s))",
            fieldId,
            #positives
        )
    end
    return true
end

--- Straw windrow line in ftdlDump — same single source as the UI (STRAW liters only).
local function dumpResidueRawScan(field, fieldId, fieldState, worldX, worldZ, aggregation, baleSummary)
    if FieldAdvisor == nil or field == nil or worldX == nil or worldZ == nil then
        return
    end

    local strawFillIndex = FieldAdvisor.resolveStrawFillTypeIndex ~= nil
        and FieldAdvisor.resolveStrawFillTypeIndex() or nil
    out(string.format(
        "strawSource: fillApiReady=%s strawFill=%s (compare APIs: ftdlStrawScan %s)",
        stringify(FieldAdvisor.isStrawFillLevelApiReady ~= nil and FieldAdvisor.isStrawFillLevelApiReady()),
        fillTypeName(strawFillIndex),
        stringify(fieldId)
    ))

    if FieldAdvisor.deriveGrassResidueSummary ~= nil then
        if FieldAdvisor.clearCoverageCache ~= nil then
            FieldAdvisor.clearCoverageCache(fieldId, "grassResidue")
        end
        local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
        local grassSummary = FieldAdvisor.deriveGrassResidueSummary(
            field, fieldId, worldX, worldZ, baleSummary, grassFruit
        )
        local sampleHalf = FieldAdvisor.getFieldSampleHalfExtent ~= nil
            and FieldAdvisor.getFieldSampleHalfExtent(field) or 0
        out(string.format(
            "grassResidue: state=%s source=%s hasWindrow=%s fillApiReady=%s sampleHalf=%.1f centerFill=%.3f crossFillMax=%.3f fillMin=%.3f ewTrans=%s ewAbove=%.2f nsTrans=%s nsAbove=%.2f grassBales=%s",
            stringify(grassSummary.residueState),
            stringify(grassSummary.residueSource),
            stringify(grassSummary.hasWindrow),
            stringify(grassSummary.fillApiReady),
            sampleHalf,
            grassSummary.centerFillLiters or 0,
            grassSummary.crossFillMax or 0,
            grassSummary.fillMinLiters or 0,
            stringify(grassSummary.ewLineTransitions),
            grassSummary.ewAboveRatio or 0,
            stringify(grassSummary.nsLineTransitions),
            grassSummary.nsAboveRatio or 0,
            stringify(grassSummary.fieldBaleCount)
        ))
    end

    if FieldAdvisor.deriveStrawResidueSummary ~= nil then
        if FieldAdvisor.clearCoverageCache ~= nil then
            FieldAdvisor.clearCoverageCache(fieldId, "strawResidue")
        end
        local strawSummary = FieldAdvisor.deriveStrawResidueSummary(
            field, fieldId, worldX, worldZ, baleSummary, FieldAdvisor.OVERVIEW_SAMPLE_GRID_STEPS
        )
        out(string.format(
            "strawResidue: hasWindrow=%s fillApiReady=%s centerFill=%.3f crossFillMax=%.3f fillMin=%.3f strawBales=%s",
            stringify(strawSummary.hasWindrow),
            stringify(strawSummary.fillApiReady),
            strawSummary.centerFillLiters or 0,
            strawSummary.crossFillMax or 0,
            strawSummary.fillMinLiters or 0,
            stringify(strawSummary.strawBaleCount)
        ))
    end
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
    local directUtil = type(DensityMapHeightUtil) == "table"
    local rawUtil = rawget(_G, "DensityMapHeightUtil") ~= nil
    out(string.format(
        "heightReader: util=%s directUtil=%s rawUtil=%s engineHeight=%s",
        stringify(heightUtil ~= nil),
        stringify(directUtil),
        stringify(rawUtil),
        stringify(getDensityHeightAtWorldPos ~= nil)
    ))

    out(string.format(
        "field obj: fruitTypeIndex=%s currentFruitTypeIndex=%s plannedFruitTypeIndex=%s name=%s",
        stringify(field.fruitTypeIndex), stringify(field.currentFruitTypeIndex), stringify(field.plannedFruitTypeIndex), stringify(field.name)
    ))
    out(string.format("inferGrassFruitTypeIndexFromField -> %s", fruitLabel(FieldAdvisor.inferGrassFruitTypeIndexFromField(field))))

    dumpDensityMapFruit(worldX, worldZ)
    if FieldAdvisor.getProbeSampleHalfExtents ~= nil then
        local halfX, halfZ = FieldAdvisor.getProbeSampleHalfExtents(field, worldX, worldZ)
        out(string.format(
            "probeGrid: halfX=%.1f halfZ=%.1f inset=%.1f cap=%.1f overviewSteps=%d",
            halfX,
            halfZ,
            tonumber(FieldAdvisor.PROBE_EDGE_INSET) or 0,
            tonumber(FieldAdvisor.PROBE_SAMPLE_MAX_HALF_EXTENT) or 0,
            tonumber(FieldAdvisor.OVERVIEW_SAMPLE_GRID_STEPS) or 0
        ))
    end
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

    local context = FieldAdvisor.buildFieldContext(field, fieldState, worldX, worldZ, aggregation)
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
        -- Residue: windrow liters + field bales (deriveGrassResidueSummary); see docs/DECISIONS.md.
        out(string.format(
            "grassResidue: available=%s source=%s state=%s fieldBaleCount=%s",
            stringify(grassResidue.residueAvailable),
            stringify(grassResidue.residueSource),
            stringify(grassResidue.residueState),
            stringify(grassResidue.fieldBaleCount)
        ))
    end
    local baleSummary = context ~= nil and context.baleSummary or nil
    dumpResidueRawScan(field, fieldId, fieldState, worldX, worldZ, aggregation, baleSummary)
    if FieldAdvisor.sampleBaleCoverage ~= nil then
        local mapBales = FieldAdvisor.collectMapBaleObjects ~= nil and FieldAdvisor.collectMapBaleObjects() or {}
        baleSummary = FieldAdvisor.sampleBaleCoverage(field, 0)
        out(string.format(
            "baleCoverage: total=%s straw=%s grass=%s other=%s mapBales=%s",
            stringify(baleSummary.total), stringify(baleSummary.straw),
            stringify(baleSummary.grass), stringify(baleSummary.other),
            stringify(#mapBales)
        ))
        local logged = 0
        for _, bale in ipairs(mapBales) do
            local bx, bz = FieldAdvisor.getBaleWorldPosition(bale)
            local kind = FieldAdvisor.classifyBaleKind(bale)
            local onField = bx ~= nil
                and FieldAdvisor.isBalePositionInsideField(field, bx, bz, worldX, worldZ)
            local engineId = FieldAdvisor.resolveEngineFieldIdAtWorldPosition ~= nil
                and FieldAdvisor.resolveEngineFieldIdAtWorldPosition(bx, bz) or nil
            local ownerId = FieldAdvisor.resolveBaleOwnerFieldId ~= nil
                and FieldAdvisor.resolveBaleOwnerFieldId(bx, bz) or nil
            if onField then
                out(string.format(
                    "  fieldBale: fillType=%s kind=%s engineField=%s ownerField=%s pos=(%.1f,%.1f)",
                    fillTypeName(FieldAdvisor.getBaleFillTypeIndex(bale)),
                    stringify(kind), stringify(engineId), stringify(ownerId), bx, bz
                ))
            elseif logged < 6 and bx ~= nil then
                logged = logged + 1
                out(string.format(
                    "  mapBale(skip): fillType=%s kind=%s engineField=%s ownerField=%s pos=(%.1f,%.1f)",
                    fillTypeName(FieldAdvisor.getBaleFillTypeIndex(bale)),
                    stringify(kind), stringify(engineId), stringify(ownerId), bx, bz
                ))
            end
        end
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

    if FieldAdvisor.buildFieldLabels ~= nil then
        local labels = FieldAdvisor.buildFieldLabels(field, fieldState, worldX, worldZ)
        out(string.format("uiSuggestion: %s", stringify(labels.suggestion)))
        if labels.suggestionDetails ~= nil then
            local types = {}
            for _, action in ipairs(labels.suggestionDetails) do
                if action ~= nil and action.actionType ~= nil then
                    types[#types + 1] = action.actionType
                end
            end
            out(string.format("uiActions: %s", table.concat(types, ", ")))
        end
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
                stringify(desc.index), stringify(desc.name), stringify(desc.minHarvestingGrowthState), stringify(desc.maxHarvestingGrowthState),
                stringify(FieldAdvisor.isGrassCrop(desc.index)), stringify(FieldAdvisor.isGenericGrassFruitIndex(desc.index))))
        end
    end
    out("===== END FRUIT TYPES =====")
    return true
end

--- Lists owned farmlands and flags the ones eligible as pseudo-fields (no predefined field,
--- indicator position known, center reads as field ground). Diagnoses the opt-in custom-field path.
---@return boolean
function FieldDebugDump.dumpOwnedFarmlands()
    if g_farmlandManager == nil or g_farmlandManager.farmlands == nil then
        out("g_farmlandManager not ready.")
        return false
    end

    local farmId = g_currentMission ~= nil and g_currentMission.getFarmId ~= nil
        and g_currentMission:getFarmId() or nil

    out(string.format("===== OWNED FARMLANDS (farmId=%s) =====", stringify(farmId)))

    local scanner = g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil
        and g_currentMission.fieldToDoList.fieldScanner or nil

    local ownedIds = nil
    if farmId ~= nil and g_farmlandManager.getOwnedFarmlandIdsByFarmId ~= nil then
        local ok, ids = pcall(g_farmlandManager.getOwnedFarmlandIdsByFarmId, g_farmlandManager, farmId)
        if ok and type(ids) == "table" then
            ownedIds = ids
        end
    end
    if ownedIds == nil then
        ownedIds = {}
        for id in pairs(g_farmlandManager.farmlands) do
            ownedIds[#ownedIds + 1] = id
        end
    end

    for _, id in pairs(ownedIds) do
        local farmland = g_farmlandManager.farmlands[id]
        if farmland ~= nil then
            local hasField = farmland.field ~= nil
            local px, pz = farmland.xWorldPos, farmland.zWorldPos
            local eligible = "false"
            if not hasField and px ~= nil and scanner ~= nil and scanner.farmlandCenterIsFieldGround ~= nil then
                eligible = stringify(scanner:farmlandCenterIsFieldGround(px, pz))
            end
            out(string.format(
                "farmland id=%s name=%s areaHa=%s hasField=%s pos=(%s,%s) -> pseudoFieldEligible=%s",
                stringify(id), stringify(farmland.name), stringify(farmland.areaInHa),
                stringify(hasField), stringify(px), stringify(pz), eligible
            ))
        end
    end

    out("===== END OWNED FARMLANDS =====")
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

function FieldDebugDump:consoleFarmlands()
    if FieldDebugDump.dumpOwnedFarmlands() then
        return "Owned farmlands dumped to log.txt (search '[FS25_FieldToDoList] DUMP')."
    end
    return "Farmland dump failed — see log.txt."
end

---@param args string|nil
function FieldDebugDump:consoleStrawScan(args)
    if args == nil or args == "" then
        return "Usage: ftdlStrawScan <fieldId> [worldX worldZ]"
    end

    local tokens = {}
    for token in string.gmatch(args, "%S+") do
        tokens[#tokens + 1] = token
    end

    local fieldId = tonumber(tokens[1])
    if fieldId == nil then
        return "Usage: ftdlStrawScan <fieldId> [worldX worldZ]"
    end

    local wx = tonumber(tokens[2])
    local wz = tonumber(tokens[3])

    if FieldDebugDump.dumpStrawMaterialScan(fieldId, wx, wz) then
        return string.format(
            "Straw material scan for field %d written to log.txt (search 'STRAW_SCAN'). Stand on swaths or use coords.",
            fieldId
        )
    end
    return string.format("Straw scan failed for field %d — see log.txt.", fieldId)
end

function FieldDebugDump.register()
    if addConsoleCommand == nil then
        return
    end
    addConsoleCommand("ftdlDump", "Dump one field's runtime data: ftdlDump <fieldId>", "consoleDump", FieldDebugDump)
    addConsoleCommand("ftdlFruits", "List fruit types with harvest growth states", "consoleFruits", FieldDebugDump)
    addConsoleCommand("ftdlFarmlands", "List owned farmlands and pseudo-field eligibility", "consoleFarmlands", FieldDebugDump)
    addConsoleCommand(
        "ftdlStrawScan",
        "Probe all straw/windrow APIs: ftdlStrawScan <fieldId> [worldX worldZ]",
        "consoleStrawScan",
        FieldDebugDump
    )
end

function FieldDebugDump.unregister()
    if removeConsoleCommand == nil then
        return
    end
    removeConsoleCommand("ftdlDump")
    removeConsoleCommand("ftdlFruits")
    removeConsoleCommand("ftdlFarmlands")
    removeConsoleCommand("ftdlStrawScan")
    FieldDebugDump.lastDumpedFieldId = nil
end
