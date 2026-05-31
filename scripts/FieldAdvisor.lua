--[[
    FieldAdvisor.lua
    Human-readable field condition labels and next-step suggestions (respects career rules).
]]

FieldAdvisor = {}

FieldAdvisor.WEED_LABELS = {
    [0] = "kein",
    [1] = "leicht",
    [2] = "mittel",
    [3] = "stark",
    [4] = "stark",
    [5] = "stark",
}

-- Internal fruit names that behave like grass (no plowing, usually no mineral fertilizing).
FieldAdvisor.GRASS_FRUIT_NAMES = {
    GRASS = true,
    MEADOW = true,
    PASTURE = true,
    GREENRYE = true,
    FIELDGRASS = true,
    ALFALFA = true,
    CLOVER = true,
    LUCERNE = true,
    MEDICK = true,
}
-- Density map often reports these indices for every meadow crop (Luzerne/Alfalfa included).
FieldAdvisor.GENERIC_GRASS_FRUIT_NAMES = {
    GRASS = true,
    MEADOW = true,
    FIELDGRASS = true,
    PASTURE = true,
}
FieldAdvisor._defaultGrassFruitTypeIndex = nil
FieldAdvisor._defaultGrassFruitTypeResolved = false
FieldAdvisor._grassFruitTypeIndices = nil
FieldAdvisor._fruitTypeIndexByNameCache = {}
FieldAdvisor.OVERVIEW_SAMPLE_GRID_STEPS = 3
FieldAdvisor.PROBE_AGGREGATION_CACHE_TTL_MS = 3000
FieldAdvisor.PROBE_EARLY_EXIT_MIN_SAMPLES = 5
FieldAdvisor._grassFruitNameList = nil

FieldAdvisor.JOB_COMPLETION_THRESHOLD = FieldTaskCompletion ~= nil
    and FieldTaskCompletion.COMPLETION_THRESHOLD
    or 0.98
FieldAdvisor.JOB_SAMPLE_GRID_STEPS = FieldTaskCompletion ~= nil
    and FieldTaskCompletion.SAMPLE_GRID_STEPS
    or 5
FieldAdvisor.WEED_FACTOR_COMBAT_THRESHOLD = 0.05
FieldAdvisor.WEED_FACTOR_COMPLETE_THRESHOLD = 0.02
FieldAdvisor.WEED_FACTOR_TREATED_THRESHOLD = 0.15
FieldAdvisor.WEED_STATE_TREATED_MAX = 3
-- After herbicide, density map can still report high weedFactor with weedState 4–6 (brown residue).
FieldAdvisor.WEED_STATE_SPRAYED_LIVE_MAX = 2
FieldAdvisor.WEED_LIVE_RATIO_DONE_THRESHOLD = 0.05
FieldAdvisor.WEED_COVERAGE_CACHE_TTL_MS = 2000
FieldAdvisor.GRASS_RESIDUE_CACHE_TTL_ACTIVE_MS = 1500
FieldAdvisor.GRASS_RESIDUE_CACHE_TTL_IDLE_MS = 5000
FieldAdvisor.BALE_CACHE_TTL_ACTIVE_MS = 700
FieldAdvisor.BALE_CACHE_TTL_IDLE_MS = 5000
FieldAdvisor.COVERAGE_MAX_SAMPLE_POINTS = 31
FieldAdvisor.GRASS_RESIDUE_MAX_SAMPLE_POINTS = 85
FieldAdvisor.GRASS_RESIDUE_IDLE_SAMPLE_POINTS = 33
FieldAdvisor.GRASS_RESIDUE_SAMPLE_HALF_SIZE = 0.45
FieldAdvisor.GRASS_RESIDUE_CROSS_STEPS = 20
FieldAdvisor.GRASS_RESIDUE_IDLE_CROSS_STEPS = 10
FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN = 0.008
FieldAdvisor.GRASS_SWATH_OCCUPANCY_MAX = 0.30
FieldAdvisor.GRASS_SWATH_OCCUPANCY_HARD_MAX = 0.15
FieldAdvisor.GRASS_SWATH_DENSITY_MULTIPLIER = 3.5
-- Edge piles / unreachable remnants: not swath lines (Schwaden = Linien, not Haufen).
FieldAdvisor.GRASS_WINDROW_PILE_RATIO_MAX = 0.05
FieldAdvisor.GRASS_WINDROW_LINE_MIN_SWATH_HITS = 2
FieldAdvisor.GRASS_WINDROW_CROSS_LINE_MIN_TRANSITIONS = 2
-- Engine-height fallback without fill levels: post-collect stubble reads higher than lying swath material.
FieldAdvisor.GRASS_WINDROW_POST_COLLECT_MATERIAL_MIN = 120
-- Cut stubble at field center is near zero; real lying swaths read much higher at center.
FieldAdvisor.GRASS_WINDROW_CENTER_MATERIAL_MIN = 1.0
-- After wagon collect: ignore unreachable border windrows (road / foreign land strips).
FieldAdvisor.GRASS_COLLECT_REMNANT_RATIO_MAX = 0.15
FieldAdvisor.GRASS_COLLECT_BASELINE_RATIO_MAX = 0.18
FieldAdvisor.GRASS_COLLECT_BASELINE_DROP_MIN = 0.70
-- FS25 weed foliage: states 0–5 alive/sprayed-visible, 6+ dead (see data/foliage/weed/weed.xml).
FieldAdvisor.WEED_STATE_DEAD_MIN = 6
FieldAdvisor.GRASS_RESIDUE_NONE = "none"
FieldAdvisor.GRASS_RESIDUE_LOOSE = "loose"
FieldAdvisor.GRASS_RESIDUE_SWATH = "swath"
FieldAdvisor.GRASS_RESIDUE_BALED = "baled"
FieldAdvisor._coverageCache = {}

FieldAdvisor.SOIL_WORK_GROUND_TYPES = {
    "CULTIVATED",
    "SEEDBED",
    "PLOWED",
    "SOWN",
    "PLANTED",
    "RIDGE_SOWN",
}
FieldAdvisor.NON_GRASS_GROUND_TYPES = {
    "CULTIVATED",
    "SEEDBED",
    "PLOWED",
    "STUBBLE",
    "HARVEST_READY",
    "DIRECT_SOWN",
    "ROLLER_LINES",
    "SOWN",
    "PLANTED",
    "RIDGE_SOWN",
}

---@param fieldState table|nil
---@param field table|nil
---@return boolean
function FieldAdvisor.isNonGrassSoilState(fieldState, field)
    local situation = FieldAdvisor.classifyProbe(fieldState, field)
    return situation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL
        or situation == FieldAdvisor.PROBE_SITUATION.ARABLE
end

---@param fieldState table|nil
---@param field table|nil
---@return boolean
function FieldAdvisor.isBareSoilProbe(fieldState, field)
    return FieldAdvisor.classifyProbe(fieldState, field) == FieldAdvisor.PROBE_SITUATION.BARE_SOIL
end

--- Worked soil with no standing crop — ground-based, no classifyProbe (avoids stale-grass loop).
---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isWorkedBareGround(fieldState)
    if fieldState == nil then
        return false
    end

    local growth = FieldAdvisor.getGrowthState(fieldState)
    if growth > 0 then
        return false
    end

    local ground = FieldAdvisor.getGroundTypeName(fieldState)
    if FieldAdvisor.groundTypeIsOneOf(ground, FieldAdvisor.NON_GRASS_GROUND_TYPES) then
        return true
    end

    return FieldAdvisor.getStateNumber(fieldState, "plowLevel") > 0
end

---@param fieldState table|nil
function FieldAdvisor.clearStaleGrassMetadata(fieldState)
    if fieldState == nil then
        return
    end

    local grassNameFields = {
        "fruitTypeName",
        "fruitType",
        "plannedFruit",
        "currentFruitType",
        "fruit",
    }

    for _, key in ipairs(grassNameFields) do
        local rawName = fieldState[key]
        if rawName ~= nil and rawName ~= ""
            and FieldAdvisor.GRASS_FRUIT_NAMES[string.upper(tostring(rawName))] == true then
            fieldState[key] = nil
        end
    end

    local fruitTypeIndex = FieldAdvisor.getFruitTypeIndex(fieldState)
    if fruitTypeIndex ~= nil and FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        fieldState.fruitTypeIndex = FruitType ~= nil and FruitType.UNKNOWN or 0
        fieldState.currentFruitTypeIndex = nil
    end

    if FieldAdvisor.isGrassGroundType(FieldAdvisor.getGroundTypeName(fieldState)) then
        fieldState.groundType = nil
    end

    fieldState.isGrass = false
    fieldState.isGrassCrop = false
    fieldState.isGrassland = false
end

---@param value any
---@return number
function FieldAdvisor.toNumber(value)
    local numberValue = tonumber(value)
    if numberValue == nil then
        return 0
    end

    return numberValue
end

---@param field table
---@return table|nil
function FieldAdvisor.getFieldState(field)
    if field == nil then
        return nil
    end

    if field.fieldState ~= nil then
        return field.fieldState
    end

    if field.getFieldState ~= nil then
        local success, fieldState = pcall(field.getFieldState, field)
        if success and type(fieldState) == "table" then
            return fieldState
        end
    end

    return nil
end

---@param worldX number|nil
---@param worldZ number|nil
---@return table|nil
function FieldAdvisor.getLiveFieldState(worldX, worldZ)
    if worldX == nil or worldZ == nil or FieldState == nil or FieldState.new == nil then
        return nil
    end

    local ok, liveState = pcall(FieldState.new)
    if not ok or liveState == nil or liveState.update == nil then
        return nil
    end

    local updated, _ = pcall(liveState.update, liveState, worldX, worldZ)
    if not updated then
        return nil
    end

    return liveState
end

---@param fieldState table|nil
---@param key string
---@return number
function FieldAdvisor.getStateNumber(fieldState, key)
    if fieldState == nil or fieldState[key] == nil then
        return 0
    end

    return FieldAdvisor.toNumber(fieldState[key])
end

---@param fieldState table|nil
---@param key string
---@return boolean
function FieldAdvisor.getStateBool(fieldState, key)
    if fieldState == nil or fieldState[key] == nil then
        return false
    end

    return fieldState[key] == true
end

FieldAdvisor.groundTypeNameByValue = nil

---@param raw any
---@return string
function FieldAdvisor.resolveGroundTypeName(raw)
    if raw == nil then
        return ""
    end

    if type(raw) == "string" then
        local name = string.upper(raw)
        if name ~= "" and not string.match(name, "^%d+$") then
            return name
        end
    end

    local value = tonumber(raw)
    if value == nil then
        return ""
    end

    if value == 0 then
        return "NONE"
    end

    if FieldGroundType ~= nil then
        if FieldAdvisor.groundTypeNameByValue == nil then
            FieldAdvisor.groundTypeNameByValue = {}

            for name, enumValue in pairs(FieldGroundType) do
                if type(name) == "string" and type(enumValue) == "number" then
                    FieldAdvisor.groundTypeNameByValue[enumValue] = name
                elseif type(enumValue) == "string" and FieldGroundType.getValueByType ~= nil then
                    local ok, resolvedValue = pcall(FieldGroundType.getValueByType, FieldGroundType, enumValue)
                    if ok and resolvedValue ~= nil then
                        FieldAdvisor.groundTypeNameByValue[resolvedValue] = enumValue
                    end
                end
            end
        end

        local resolvedName = FieldAdvisor.groundTypeNameByValue[value]
        if resolvedName ~= nil then
            return resolvedName
        end
    end

    return ""
end

---@param fieldState table|nil
---@return string
function FieldAdvisor.getGroundTypeName(fieldState)
    if fieldState == nil then
        return ""
    end

    local raw = fieldState.groundType
    if raw == nil and type(fieldState.getGroundType) == "function" then
        local ok, groundType = pcall(fieldState.getGroundType, fieldState)
        if ok then
            raw = groundType
        end
    end

    return FieldAdvisor.resolveGroundTypeName(raw)
end

---@param groundType string
---@param candidates string[]
---@return boolean
function FieldAdvisor.groundTypeIsOneOf(groundType, candidates)
    for _, candidate in ipairs(candidates) do
        if groundType == candidate then
            return true
        end
    end

    return false
end

---@param fruitName string|nil
---@return number|nil
function FieldAdvisor.normalizeFruitName(fruitName)
    if string.isNilOrWhitespace(fruitName) then
        return nil
    end

    local normalized = string.upper(tostring(fruitName))
    normalized = string.gsub(normalized, "^%s+", "")
    normalized = string.gsub(normalized, "%s+$", "")
    normalized = string.gsub(normalized, "[^A-Z0-9_]", "_")
    normalized = string.gsub(normalized, "_+", "_")

    if normalized == "" then
        return nil
    end

    return normalized
end

---@return string[]
function FieldAdvisor.getGrassFruitNameList()
    if FieldAdvisor._grassFruitNameList == nil then
        local names = {}
        for grassName, _ in pairs(FieldAdvisor.GRASS_FRUIT_NAMES) do
            names[#names + 1] = grassName
        end
        table.sort(names, function(a, b)
            return #a > #b
        end)
        FieldAdvisor._grassFruitNameList = names
    end

    return FieldAdvisor._grassFruitNameList
end

---@param normalized string|nil
---@return string|nil
function FieldAdvisor.matchGrassFruitName(normalized)
    if normalized == nil or normalized == "" then
        return nil
    end

    if FieldAdvisor.GRASS_FRUIT_NAMES[normalized] == true then
        return normalized
    end

    for _, grassName in ipairs(FieldAdvisor.getGrassFruitNameList()) do
        if string.find(normalized, grassName, 1, true) ~= nil then
            return grassName
        end
    end

    return nil
end

---@param fieldState table|nil
---@return string|nil
function FieldAdvisor.buildFieldCompletionFingerprint(fieldState)
    if fieldState == nil then
        return nil
    end

    return table.concat({
        tostring(FieldAdvisor.getFruitTypeIndex(fieldState)),
        tostring(FieldAdvisor.getEffectiveGrowthState(fieldState)),
        tostring(FieldAdvisor.getGroundTypeName(fieldState)),
        tostring(FieldAdvisor.getStateNumber(fieldState, "weedState")),
        tostring(FieldAdvisor.getWeedFactor(fieldState)),
        tostring(FieldAdvisor.getStateNumber(fieldState, "plowLevel")),
        tostring(FieldAdvisor.getStateNumber(fieldState, "limeLevel")),
        tostring(FieldAdvisor.getStateNumber(fieldState, "rollerLevel")),
        tostring(FieldAdvisor.getStateNumber(fieldState, "stubbleShredLevel")),
        tostring(FieldAdvisor.getStateNumber(fieldState, "stoneLevel")),
        FieldAdvisor.getStateBool(fieldState, "needsPlowing") and "1" or "0",
        FieldAdvisor.getStateBool(fieldState, "needsRolling") and "1" or "0",
        FieldAdvisor.getStateBool(fieldState, "needsLime") and "1" or "0",
    }, ":")
end

---@param fruitName string|nil
---@return number|nil
function FieldAdvisor.getFruitTypeIndexByName(fruitName)
    if string.isNilOrWhitespace(fruitName) or g_fruitTypeManager == nil then
        return nil
    end

    local normalizedLookup = FieldAdvisor.normalizeFruitName(fruitName)
    if normalizedLookup ~= nil then
        local cached = FieldAdvisor._fruitTypeIndexByNameCache[normalizedLookup]
        if cached ~= nil then
            if cached > 0 then
                return cached
            end
            return nil
        end
    end

    local candidates = { tostring(fruitName) }
    local upperName = string.upper(tostring(fruitName))
    local lowerName = string.lower(tostring(fruitName))
    local normalizedName = FieldAdvisor.normalizeFruitName(fruitName)
    if upperName ~= candidates[1] then
        candidates[#candidates + 1] = upperName
    end
    if lowerName ~= candidates[1] and lowerName ~= upperName then
        candidates[#candidates + 1] = lowerName
    end
    if normalizedName ~= nil and normalizedName ~= candidates[1] and normalizedName ~= upperName then
        candidates[#candidates + 1] = normalizedName
    end

    local function rememberFruitIndex(nameKey, fruitTypeIndex)
        if nameKey ~= nil and nameKey ~= "" then
            FieldAdvisor._fruitTypeIndexByNameCache[nameKey] = fruitTypeIndex ~= nil and fruitTypeIndex > 0
                and fruitTypeIndex
                or 0
        end
    end

    if g_fruitTypeManager.getFruitTypeIndexByName ~= nil then
        for _, candidate in ipairs(candidates) do
            local ok, fruitTypeIndex = pcall(g_fruitTypeManager.getFruitTypeIndexByName, g_fruitTypeManager, candidate)
            if ok and fruitTypeIndex ~= nil and fruitTypeIndex > 0 then
                rememberFruitIndex(normalizedLookup, fruitTypeIndex)
                rememberFruitIndex(FieldAdvisor.normalizeFruitName(candidate), fruitTypeIndex)
                return fruitTypeIndex
            end
        end
    end

    if g_fruitTypeManager.getFruitTypes ~= nil then
        local ok, fruitTypes = pcall(g_fruitTypeManager.getFruitTypes, g_fruitTypeManager)
        if ok and fruitTypes ~= nil then
            for _, fruitDesc in ipairs(fruitTypes) do
                if fruitDesc ~= nil and fruitDesc.index ~= nil and fruitDesc.index > 0 then
                    local descName = fruitDesc.name
                    local descNormalized = FieldAdvisor.normalizeFruitName(descName)
                    for _, candidate in ipairs(candidates) do
                        local candidateNormalized = FieldAdvisor.normalizeFruitName(candidate)
                        if descName == candidate
                            or (descNormalized ~= nil and descNormalized == candidateNormalized)
                            or (descNormalized ~= nil and candidateNormalized ~= nil
                                and string.find(descNormalized, candidateNormalized, 1, true) ~= nil) then
                            rememberFruitIndex(normalizedLookup, fruitDesc.index)
                            rememberFruitIndex(descNormalized, fruitDesc.index)
                            rememberFruitIndex(candidateNormalized, fruitDesc.index)
                            return fruitDesc.index
                        end
                    end
                end
            end
        end
    end

    rememberFruitIndex(normalizedLookup, nil)
    return nil
end

---@param groundType string|nil
---@return boolean
function FieldAdvisor.isGrassGroundType(groundType)
    if groundType == nil or groundType == "" then
        return false
    end

    if groundType == "GRASS" or groundType == "MEADOW" then
        return true
    end

    return string.find(groundType, "GRASS", 1, true) ~= nil
end

---@param groundType string|nil
---@return boolean
function FieldAdvisor.isGrassCutGroundType(groundType)
    if groundType == nil or groundType == "" then
        return false
    end

    groundType = string.upper(tostring(groundType))
    if groundType == "GRASS_CUT" then
        return true
    end

    return string.find(groundType, "_CUT", 1, true) ~= nil
        or string.find(groundType, "CUT", 1, true) ~= nil
end

--- Post-mow meadow signal: cut ground, stubble, getIsCut, or growth above max harvest (Geistal alfalfa/clover).
---@param fieldState table|nil
---@param field table|nil
---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isGrassPostMowState(fieldState, field, fruitTypeIndex)
    if fieldState == nil then
        return false
    end

    if FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(fieldState)) then
        return true
    end

    if FieldAdvisor.getStateNumber(fieldState, "stubbleShredLevel") > 0 then
        return true
    end

    fruitTypeIndex = fruitTypeIndex
        or FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
    if fruitTypeIndex == nil or not FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        return false
    end

    local growthState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if growthState <= 0 then
        growthState = FieldAdvisor.getLastGrowthState(fieldState)
    end
    if growthState <= 0 then
        return false
    end

    local growth = FieldAdvisor.evaluateFruitGrowth(fruitTypeIndex, growthState)
    if growth.isCut then
        return true
    end

    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    local maxHarvest = tonumber(fruitDesc ~= nil and fruitDesc.maxHarvestingGrowthState) or 0
    if maxHarvest > 0 and growthState > maxHarvest then
        return true
    end

    return false
end

---@return number|nil
function FieldAdvisor.getDefaultGrassFruitTypeIndex()
    if FieldAdvisor._defaultGrassFruitTypeResolved then
        return FieldAdvisor._defaultGrassFruitTypeIndex
    end

    FieldAdvisor._defaultGrassFruitTypeResolved = true
    FieldAdvisor._defaultGrassFruitTypeIndex = nil

    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypes ~= nil then
        local ok, fruitTypes = pcall(g_fruitTypeManager.getFruitTypes, g_fruitTypeManager)
        if ok and fruitTypes ~= nil then
            for _, fruitDesc in ipairs(fruitTypes) do
                if fruitDesc ~= nil and fruitDesc.index ~= nil and fruitDesc.index > 0 then
                    if FieldAdvisor.isGrassCrop(fruitDesc.index) then
                        FieldAdvisor._defaultGrassFruitTypeIndex = fruitDesc.index
                        return FieldAdvisor._defaultGrassFruitTypeIndex
                    end
                end
            end
        end
    end

    local candidates = {
        "GRASS",
        "MEADOW",
        "FIELDGRASS",
        "ALFALFA",
        "CLOVER",
        "LUCERNE",
        "MEDICK",
    }

    for _, name in ipairs(candidates) do
        local fruitTypeIndex = FieldAdvisor.getFruitTypeIndexByName(name)
        if fruitTypeIndex ~= nil then
            FieldAdvisor._defaultGrassFruitTypeIndex = fruitTypeIndex
            break
        end
    end

    return FieldAdvisor._defaultGrassFruitTypeIndex
end

---@param field table|nil
---@param fieldState table|nil
function FieldAdvisor.enrichFieldStateFromField(field, fieldState)
    if field == nil or fieldState == nil then
        return
    end

    local function assignFruitIndex(value)
        local fruitTypeIndex = tonumber(value)
        if fruitTypeIndex == nil or fruitTypeIndex <= 0 then
            return
        end

        local current = fieldState.fruitTypeIndex
        local unknownIndex = FruitType ~= nil and FruitType.UNKNOWN or 0
        if current ~= nil and current > 0 and current ~= unknownIndex then
            if not FieldAdvisor.isGenericGrassFruitIndex(current)
                or FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
                return
            end
        end

        fieldState.fruitTypeIndex = fruitTypeIndex
    end

    assignFruitIndex(field.fruitTypeIndex)
    assignFruitIndex(field.currentFruitTypeIndex)
    assignFruitIndex(field.plannedFruitTypeIndex)

    local fieldProbes = {
        "getFruitTypeIndex",
        "getCurrentFruitTypeIndex",
        "getFruitType",
    }

    for _, probe in ipairs(fieldProbes) do
        if field[probe] ~= nil then
            local ok, value = pcall(field[probe], field)
            if ok and type(value) == "number" then
                assignFruitIndex(value)
            end
        end
    end

    local function assignFruitName(value)
        if value == nil or value == "" then
            return
        end

        local normalized = FieldAdvisor.normalizeFruitName(value)
        local currentNorm = fieldState.fruitTypeName ~= nil
            and FieldAdvisor.normalizeFruitName(fieldState.fruitTypeName) or nil
        local isSpecificGrass = normalized ~= nil and FieldAdvisor.GRASS_FRUIT_NAMES[normalized] == true
            and not FieldAdvisor.isGenericGrassFruitIndex(FieldAdvisor.getFruitTypeIndexByName(normalized))
        local currentIsGeneric = currentNorm == "GRASS" or currentNorm == "MEADOW"
            or currentNorm == "FIELDGRASS" or currentNorm == "PASTURE"

        if isSpecificGrass and (fieldState.fruitTypeName == nil or fieldState.fruitTypeName == "" or currentIsGeneric) then
            fieldState.fruitTypeName = tostring(value)
            return
        end

        if fieldState.fruitTypeName == nil or fieldState.fruitTypeName == "" then
            fieldState.fruitTypeName = tostring(value)
        end
    end

    local nameFields = {
        "fruitTypeName",
        "currentFruitTypeName",
        "cropTypeName",
        "currentCropTypeName",
        "fruitType",
        "plannedFruit",
    }

    for _, key in ipairs(nameFields) do
        assignFruitName(field[key])
    end

    for _, probe in ipairs({ "getFruitTypeName", "getCurrentFruitTypeName" }) do
        if field[probe] ~= nil then
            local ok, value = pcall(field[probe], field)
            if ok then
                assignFruitName(value)
            end
        end
    end

    local fieldGrassHint = FieldAdvisor.inferGrassFruitTypeIndexFromField(field)
    if fieldGrassHint ~= nil and not FieldAdvisor.isGenericGrassFruitIndex(fieldGrassHint)
        and not FieldAdvisor.isWorkedBareGround(fieldState) then
        local currentIndex = tonumber(fieldState.fruitTypeIndex)
        if currentIndex == nil or currentIndex <= 0
            or FieldAdvisor.isGenericGrassFruitIndex(currentIndex)
            or currentIndex == (FruitType ~= nil and FruitType.UNKNOWN or 0) then
            fieldState.fruitTypeIndex = fieldGrassHint
        end
    end

    -- Do not copy field.groundType here: live FieldState:update() is authoritative.
end

--- Probe layers: arable crop | grass meadow | bare worked soil | unknown
FieldAdvisor.PROBE_SITUATION = {
    ARABLE = "arable",
    GRASS = "grass",
    BARE_SOIL = "bare_soil",
    UNKNOWN = "unknown",
}

-- FS25 FieldGroundType (common): NONE, GRASS, MEADOW, PLOWED, CULTIVATED, SEEDBED,
-- SOWN, PLANTED, RIDGE_SOWN, ROLLER_LINES, STUBBLE, HARVEST_READY, DIRECT_SOWN, …
-- FruitTypeDesc growth (vanilla + mods): getIsCut, getIsGrowing, getIsHarvestable,
-- getIsHarvestReady, getIsWithered, min/maxHarvestingGrowthState (GDN FS25).

---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isUnknownFruitIndex(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 then
        return true
    end

    return FruitType ~= nil and fruitTypeIndex == FruitType.UNKNOWN
end

--- Classify one density-map probe (single FieldState sample).
---@param fieldState table|nil
---@param field table|nil
---@return string situation
---@return number|nil fruitHint
function FieldAdvisor.classifyProbe(fieldState, field)
    if fieldState == nil then
        return FieldAdvisor.PROBE_SITUATION.UNKNOWN, nil
    end

    local ground = FieldAdvisor.getGroundTypeName(fieldState)
    local fruitIdx = FieldAdvisor.getFruitTypeIndex(fieldState)
    local growth = FieldAdvisor.getGrowthState(fieldState)
    local unknownFruit = FieldAdvisor.isUnknownFruitIndex(fruitIdx)
    local bareGround = FieldAdvisor.groundTypeIsOneOf(ground, FieldAdvisor.NON_GRASS_GROUND_TYPES)
    local sownGround = FieldAdvisor.groundTypeIsOneOf(ground, {
        "SOWN", "PLANTED", "RIDGE_SOWN", "ROLLER_LINES",
    })

    -- Layer 1 — arable crop (clear non-grass fruit)
    if not unknownFruit and not FieldAdvisor.isGrassCrop(fruitIdx) then
        return FieldAdvisor.PROBE_SITUATION.ARABLE, fruitIdx
    end

    if sownGround and growth > 0 and (unknownFruit or not FieldAdvisor.isGrassCrop(fruitIdx)) then
        return FieldAdvisor.PROBE_SITUATION.ARABLE, unknownFruit and nil or fruitIdx
    end

    -- Bare worked soil before grass growth heuristics (stale lastGrowth must not win on PLOWED).
    if bareGround and growth <= 0 then
        return FieldAdvisor.PROBE_SITUATION.BARE_SOIL, nil
    end

    if FieldAdvisor.getStateNumber(fieldState, "plowLevel") > 0
        and growth <= 0
        and (unknownFruit or FieldAdvisor.isGrassCrop(fruitIdx))
        and not sownGround then
        return FieldAdvisor.PROBE_SITUATION.BARE_SOIL, nil
    end

    -- Grass/meadow fruit with a foliage growth phase (incl. cut after mowing) stays grass.
    if not unknownFruit and FieldAdvisor.isGrassCrop(fruitIdx) and not bareGround then
        local effectiveGrowth = FieldAdvisor.getEffectiveGrowthState(fieldState)
        local grassGrowth = FieldAdvisor.evaluateFruitGrowth(fruitIdx, effectiveGrowth)
        if grassGrowth.isCut or grassGrowth.isHarvestable or grassGrowth.isHarvestReady
            or grassGrowth.isGrowing or effectiveGrowth > 0 then
            return FieldAdvisor.PROBE_SITUATION.GRASS, fruitIdx
        end
    end

    -- Layer 3 — grass / meadow (alfalfa, grass, clover …)
    if not unknownFruit and FieldAdvisor.isGrassCrop(fruitIdx) and not bareGround then
        return FieldAdvisor.PROBE_SITUATION.GRASS, fruitIdx
    end

    if growth > 0 and not unknownFruit and FieldAdvisor.isGrassCrop(fruitIdx) and not bareGround then
        return FieldAdvisor.PROBE_SITUATION.GRASS, fruitIdx
    end

    if not bareGround then
        if FieldAdvisor.isGrassGroundType(ground) then
            return FieldAdvisor.PROBE_SITUATION.GRASS, FieldAdvisor.inferGrassFruitTypeIndexFromState(fieldState)
        end

        if fieldState.isGrass == true or fieldState.isGrassCrop == true or fieldState.isGrassland == true then
            return FieldAdvisor.PROBE_SITUATION.GRASS, FieldAdvisor.inferGrassFruitTypeIndexFromState(fieldState)
        end
    end

    if bareGround then
        return FieldAdvisor.PROBE_SITUATION.BARE_SOIL, nil
    end

    return FieldAdvisor.PROBE_SITUATION.UNKNOWN, nil
end

--- Majority situation from probe vote counts; center probe breaks ties (matches aggregateFieldProbes).
---@param counts table
---@param centerSituation string
---@return string
function FieldAdvisor.resolveDominantSituationFromCounts(counts, centerSituation)
    local dominantSituation = FieldAdvisor.PROBE_SITUATION.UNKNOWN
    local maxCount = 0
    for _, situation in ipairs({
        FieldAdvisor.PROBE_SITUATION.ARABLE,
        FieldAdvisor.PROBE_SITUATION.BARE_SOIL,
        FieldAdvisor.PROBE_SITUATION.GRASS,
        FieldAdvisor.PROBE_SITUATION.UNKNOWN,
    }) do
        local count = counts[situation] or 0
        if count > maxCount then
            maxCount = count
            dominantSituation = situation
        end
    end

    if counts[centerSituation] ~= nil and counts[centerSituation] >= maxCount then
        dominantSituation = centerSituation
    end

    -- Lone plowed center on a grass/arable majority must not flip the whole field to bare.
    if centerSituation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL then
        local bareCount = counts[FieldAdvisor.PROBE_SITUATION.BARE_SOIL] or 0
        if bareCount >= maxCount then
            dominantSituation = FieldAdvisor.PROBE_SITUATION.BARE_SOIL
        end
    end

    return dominantSituation
end

--- Representative probe on cache refresh: center when it matches dominant, else keep grid sample.
---@param dominantSituation string
---@param centerSituation string
---@param centerState table|nil
---@param cachedRepresentative table|nil
---@return table|nil
function FieldAdvisor.resolveRepresentativeStateForAggregation(
    dominantSituation, centerSituation, centerState, cachedRepresentative
)
    if centerState == nil then
        return cachedRepresentative
    end

    if dominantSituation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL then
        return centerState
    end

    if dominantSituation == centerSituation then
        return centerState
    end

    return cachedRepresentative or centerState
end

--- Aggregate grid probes: majority situation + best representative FieldState.
---@param aggregation table|nil
---@param centerState table|nil
---@param field table|nil
---@return table|nil
function FieldAdvisor.refreshAggregationFromCenter(aggregation, centerState, field)
    if aggregation == nil then
        return nil
    end

    local counts = aggregation.counts or {}
    local centerSituation = FieldAdvisor.classifyProbe(centerState, field)
    local dominantSituation = FieldAdvisor.resolveDominantSituationFromCounts(counts, centerSituation)
    local representativeState = FieldAdvisor.resolveRepresentativeStateForAggregation(
        dominantSituation,
        centerSituation,
        centerState,
        aggregation.representativeState
    )

    local dominantArableFruit = aggregation.dominantArableFruit
    if centerSituation == FieldAdvisor.PROBE_SITUATION.ARABLE and centerState ~= nil then
        local centerFruit = FieldAdvisor.getFruitTypeIndex(centerState)
        if centerFruit ~= nil and centerFruit > 0
            and not FieldAdvisor.isUnknownFruitIndex(centerFruit)
            and not FieldAdvisor.isGrassCrop(centerFruit) then
            dominantArableFruit = centerFruit
        end
    elseif centerSituation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL
        or centerSituation == FieldAdvisor.PROBE_SITUATION.GRASS
        or not FieldAdvisor.hasActiveCrop(centerState) then
        dominantArableFruit = nil
    end

    local dominantGrassFruit = aggregation.dominantGrassFruit
    if centerSituation == FieldAdvisor.PROBE_SITUATION.GRASS and centerState ~= nil then
        local centerFruit = FieldAdvisor.getFruitTypeIndex(centerState)
        if centerFruit ~= nil and centerFruit > 0 and not FieldAdvisor.isUnknownFruitIndex(centerFruit) then
            if FieldAdvisor.isGenericGrassFruitIndex(centerFruit) and field ~= nil then
                local wx, wz = FieldAdvisor.getFieldCenterWorldPosition(field)
                local refined = FieldAdvisor.refineGrassFruitTypeIndex(
                    centerState, field, centerFruit, wx, wz
                )
                if refined ~= nil and refined > 0 then
                    centerFruit = refined
                end
            end
            dominantGrassFruit = centerFruit
        end
    elseif dominantSituation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL then
        dominantGrassFruit = nil
    end

    return {
        dominantSituation = dominantSituation,
        representativeState = representativeState,
        harvestState = centerState,
        centerState = centerState,
        dominantGrassFruit = dominantGrassFruit,
        dominantArableFruit = dominantArableFruit,
        centerSituation = centerSituation,
        counts = counts,
        maxStubbleShredLevel = math.max(
            aggregation.maxStubbleShredLevel or 0,
            FieldAdvisor.getStateNumber(centerState, "stubbleShredLevel")
        ),
    }
end

---@param field table
---@param fieldId number|nil
---@param centerState table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param gridSteps number|nil
---@return table aggregation
function FieldAdvisor.aggregateFieldProbes(field, fieldId, centerState, worldX, worldZ, gridSteps)
    local steps = math.max(1, tonumber(gridSteps) or FieldAdvisor.JOB_SAMPLE_GRID_STEPS)

    if fieldId ~= nil then
        local cacheKind = string.format("aggregation:%d", steps)
        local cached = FieldAdvisor.getCoverageCache(
            fieldId,
            cacheKind,
            FieldAdvisor.PROBE_AGGREGATION_CACHE_TTL_MS
        )
        if cached ~= nil then
            local liveCenterSituation = FieldAdvisor.classifyProbe(centerState, field)
            if cached.centerSituation == liveCenterSituation then
                return FieldAdvisor.refreshAggregationFromCenter(cached, centerState, field)
            end
        end
    end

    local counts = {
        [FieldAdvisor.PROBE_SITUATION.ARABLE] = 0,
        [FieldAdvisor.PROBE_SITUATION.GRASS] = 0,
        [FieldAdvisor.PROBE_SITUATION.BARE_SOIL] = 0,
        [FieldAdvisor.PROBE_SITUATION.UNKNOWN] = 0,
    }
    local grassFruitVotes = {}
    local arableFruitVotes = {}

    local bestArableState = nil
    local bestArableGrowth = -1
    local bestGrassState = nil
    local bestGrassGrowth = -1
    local bestBareState = nil
    local centerSituation = FieldAdvisor.PROBE_SITUATION.UNKNOWN
    local fieldGrassHint = FieldAdvisor.inferGrassFruitTypeIndexFromField(field)
    local maxStubbleShredLevel = FieldAdvisor.getStateNumber(centerState, "stubbleShredLevel")

    if worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end

    local function considerProbe(state, isCenter, probeX, probeZ)
        if state == nil then
            return
        end

        local situation, fruitHint = FieldAdvisor.classifyProbe(state, field)
        counts[situation] = (counts[situation] or 0) + 1
        maxStubbleShredLevel = math.max(maxStubbleShredLevel, FieldAdvisor.getStateNumber(state, "stubbleShredLevel"))

        if isCenter then
            centerSituation = situation
        end

        local growth = FieldAdvisor.getEffectiveGrowthState(state)

        if situation == FieldAdvisor.PROBE_SITUATION.ARABLE then
            if fruitHint ~= nil and not FieldAdvisor.isGrassCrop(fruitHint) then
                arableFruitVotes[fruitHint] = (arableFruitVotes[fruitHint] or 0) + 1
            end
            if growth >= bestArableGrowth then
                bestArableGrowth = growth
                bestArableState = state
            end
        elseif situation == FieldAdvisor.PROBE_SITUATION.GRASS then
            local grassFruit = fruitHint or FieldAdvisor.inferGrassFruitTypeIndexFromState(state) or fieldGrassHint
            grassFruit = FieldAdvisor.refineGrassFruitTypeIndex(state, field, grassFruit, probeX, probeZ)
            if grassFruit ~= nil then
                grassFruitVotes[grassFruit] = (grassFruitVotes[grassFruit] or 0) + 1
            end
            if growth >= bestGrassGrowth then
                bestGrassGrowth = growth
                bestGrassState = state
            end
        elseif situation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL then
            if isCenter or bestBareState == nil then
                bestBareState = state
            end
        end
    end

    considerProbe(centerState, true, worldX, worldZ)

    local function getProbeTotal()
        local total = 0
        for _, count in pairs(counts) do
            total = total + count
        end
        return total
    end

    local function shouldStopProbeSampling()
        local total = getProbeTotal()
        if total < FieldAdvisor.PROBE_EARLY_EXIT_MIN_SAMPLES then
            return false
        end

        if centerSituation == FieldAdvisor.PROBE_SITUATION.UNKNOWN then
            return false
        end

        -- Require edge probes before skipping the rest (misclassified center must not truncate the grid).
        if total - 1 < 2 then
            return false
        end

        return counts[centerSituation] == total
    end

    if field ~= nil and worldX ~= nil and worldZ ~= nil then
        local points = {}
        if FieldTaskCompletion ~= nil and FieldTaskCompletion.collectSamplePoints ~= nil then
            points = FieldTaskCompletion.collectSamplePoints(field, worldX, worldZ, steps)
        end

        for _, point in ipairs(points) do
            if FieldAdvisor.isPositionInsideFieldOrUnknown(field, point.x, point.z) then
                local isCenter = point.x == worldX and point.z == worldZ
                if not isCenter then
                    local sampleState = FieldAdvisor.getEnrichedFieldState(field, fieldId, point.x, point.z)
                    considerProbe(sampleState, false, point.x, point.z)
                    if shouldStopProbeSampling() then
                        break
                    end
                end
            end
        end
    end

    local dominantSituation = FieldAdvisor.resolveDominantSituationFromCounts(counts, centerSituation)

    local dominantGrassFruit = nil
    local dominantGrassVotes = 0
    if centerSituation == FieldAdvisor.PROBE_SITUATION.GRASS and centerState ~= nil then
        local centerFruit = FieldAdvisor.getFruitTypeIndex(centerState)
        if centerFruit ~= nil and centerFruit > 0 and not FieldAdvisor.isUnknownFruitIndex(centerFruit) then
            if FieldAdvisor.isGenericGrassFruitIndex(centerFruit) then
                local refined = FieldAdvisor.refineGrassFruitTypeIndex(
                    centerState, field, centerFruit, worldX, worldZ
                )
                if refined ~= nil and refined > 0 then
                    centerFruit = refined
                end
            end
            dominantGrassFruit = centerFruit
            dominantGrassVotes = grassFruitVotes[centerFruit] or 1
        end
    end
    if dominantGrassFruit == nil then
        for fruitIndex, voteCount in pairs(grassFruitVotes) do
            local beats = voteCount > dominantGrassVotes
            if voteCount == dominantGrassVotes and dominantGrassFruit ~= nil then
                local curGeneric = FieldAdvisor.isGenericGrassFruitIndex(dominantGrassFruit)
                local newGeneric = FieldAdvisor.isGenericGrassFruitIndex(fruitIndex)
                beats = not newGeneric and curGeneric
            end
            if beats then
                dominantGrassVotes = voteCount
                dominantGrassFruit = fruitIndex
            end
        end
    end

    local dominantArableFruit = nil
    local dominantArableVotes = 0
    if centerSituation == FieldAdvisor.PROBE_SITUATION.ARABLE and centerState ~= nil then
        local centerFruit = FieldAdvisor.getFruitTypeIndex(centerState)
        if centerFruit ~= nil and centerFruit > 0
            and not FieldAdvisor.isUnknownFruitIndex(centerFruit)
            and not FieldAdvisor.isGrassCrop(centerFruit) then
            dominantArableFruit = centerFruit
            dominantArableVotes = arableFruitVotes[centerFruit] or 1
        end
    end
    if dominantArableFruit == nil
        and (dominantSituation == FieldAdvisor.PROBE_SITUATION.ARABLE
            or centerSituation == FieldAdvisor.PROBE_SITUATION.ARABLE) then
        for fruitIndex, voteCount in pairs(arableFruitVotes) do
            if voteCount > dominantArableVotes then
                dominantArableVotes = voteCount
                dominantArableFruit = fruitIndex
            end
        end
    end

    local representativeState = centerState
    if dominantSituation == FieldAdvisor.PROBE_SITUATION.ARABLE and bestArableState ~= nil then
        representativeState = bestArableState
    elseif dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS and bestGrassState ~= nil then
        representativeState = bestGrassState
    elseif dominantSituation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL then
        representativeState = bestBareState or centerState
    end

    -- Harvest month uses the field center probe — not max-growth edges (Jul silage)
    -- and not min-growth edge strips (growth 0 / missing fruit → "Wächst").
    local harvestState = centerState

    local aggregation = {
        dominantSituation = dominantSituation,
        representativeState = representativeState,
        harvestState = harvestState,
        centerState = centerState,
        dominantGrassFruit = dominantGrassFruit,
        dominantArableFruit = dominantArableFruit,
        centerSituation = centerSituation,
        counts = counts,
        maxStubbleShredLevel = maxStubbleShredLevel,
    }

    if fieldId ~= nil then
        FieldAdvisor.setCoverageCache(fieldId, string.format("aggregation:%d", steps), aggregation)
    end

    return aggregation
end

---@param fieldState table|nil
---@param aggregation table|nil
---@return table|nil
function FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)
    if aggregation ~= nil and aggregation.harvestState ~= nil then
        return aggregation.harvestState
    end

    return fieldState
end

---@param aggregation table|nil
---@param fieldState table|nil
---@param field table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return boolean
function FieldAdvisor.isGrassCropFieldContext(aggregation, fieldState, field, worldX, worldZ)
    if aggregation ~= nil then
        if aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS then
            return true
        end
        if aggregation.centerSituation == FieldAdvisor.PROBE_SITUATION.GRASS then
            return true
        end
    end

    if FieldAdvisor.isGrassFieldState(fieldState, field) then
        return true
    end

    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)
    if FieldAdvisor.isGrassFieldState(harvestState, field) then
        return true
    end

    local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(harvestState, field, aggregation, worldX, worldZ)
    return grassFruit ~= nil and FieldAdvisor.isGrassCrop(grassFruit)
end

---@param aggregation table|nil
---@param fieldState table|nil
---@param field table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return boolean
function FieldAdvisor.isArableFieldContext(aggregation, fieldState, field, worldX, worldZ)
    if FieldAdvisor.isGrassCropFieldContext(aggregation, fieldState, field, worldX, worldZ) then
        return false
    end

    if aggregation ~= nil then
        if aggregation.centerSituation == FieldAdvisor.PROBE_SITUATION.ARABLE then
            return true
        end
        if aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.ARABLE then
            return true
        end
    end

    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)
    return FieldAdvisor.classifyProbe(harvestState, field) == FieldAdvisor.PROBE_SITUATION.ARABLE
end

---@param field table|nil
---@param aggregation table|nil
---@param fieldState table|nil
---@return number|nil
function FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, fieldState)
    if aggregation ~= nil and aggregation.centerSituation == FieldAdvisor.PROBE_SITUATION.ARABLE then
        local harvestState = aggregation.harvestState or fieldState
        local centerFruit = FieldAdvisor.resolveFruitTypeIndex(harvestState, field)
        if centerFruit ~= nil and centerFruit > 0 and not FieldAdvisor.isUnknownFruitIndex(centerFruit) then
            return centerFruit
        end
    end

    if aggregation ~= nil and aggregation.dominantArableFruit ~= nil then
        local useEdgeFruit = aggregation.centerSituation == FieldAdvisor.PROBE_SITUATION.ARABLE
            or aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.ARABLE
        if useEdgeFruit then
            return aggregation.dominantArableFruit
        end
    end

    return FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
end

---@param fieldState table|nil
---@param field table|nil
---@return boolean
function FieldAdvisor.isGrassFieldState(fieldState, field)
    return FieldAdvisor.classifyProbe(fieldState, field) == FieldAdvisor.PROBE_SITUATION.GRASS
end

---@param fieldState table|nil
---@return number
function FieldAdvisor.getEffectiveGrowthState(fieldState)
    local growthState = FieldAdvisor.getGrowthState(fieldState)
    if growthState > 0 then
        return growthState
    end

    return FieldAdvisor.getLastGrowthState(fieldState)
end

---@param fieldState table|nil
---@param field table|nil
---@return number|nil
function FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
    local fruitTypeIndex = FieldAdvisor.getFruitTypeIndex(fieldState)
    if fruitTypeIndex ~= nil and fruitTypeIndex > 0 then
        if FruitType == nil or fruitTypeIndex ~= FruitType.UNKNOWN then
            if FieldAdvisor.isGrassCrop(fruitTypeIndex) then
                if FieldAdvisor.isBareSoilProbe(fieldState, field) then
                    return nil
                end
                if FieldAdvisor.isGrassFieldState(fieldState, field) then
                    return fruitTypeIndex
                end
                return nil
            end
            return fruitTypeIndex
        end
    end

    return nil
end

---@param fieldState table|nil
---@return number|nil
function FieldAdvisor.inferGrassFruitTypeIndexFromState(fieldState)
    if fieldState == nil then
        return nil
    end

    local nameFields = {
        "fruitTypeName",
        "fruitType",
        "plannedFruit",
        "currentFruitType",
        "fruit",
    }

    for _, key in ipairs(nameFields) do
        local rawName = fieldState[key]
        if rawName ~= nil and rawName ~= "" then
            local normalized = FieldAdvisor.normalizeFruitName(rawName)
            if normalized ~= nil then
                local grassMatch = FieldAdvisor.matchGrassFruitName(normalized)
                if grassMatch ~= nil then
                    local fruitTypeIndex = FieldAdvisor.getFruitTypeIndexByName(normalized)
                    if fruitTypeIndex ~= nil then
                        return fruitTypeIndex
                    end
                    fruitTypeIndex = FieldAdvisor.getFruitTypeIndexByName(grassMatch)
                    if fruitTypeIndex ~= nil then
                        return fruitTypeIndex
                    end
                end
            end
        end
    end

    local fruitTypeIndex = FieldAdvisor.getFruitTypeIndex(fieldState)
    if fruitTypeIndex ~= nil and fruitTypeIndex > 0 and FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        return fruitTypeIndex
    end

    return nil
end

---@param rawName any
---@return number|nil
function FieldAdvisor.inferGrassFruitTypeIndexFromName(rawName)
    if rawName == nil or rawName == "" then
        return nil
    end

    local normalized = FieldAdvisor.normalizeFruitName(rawName)
    if normalized == nil then
        return nil
    end

    local grassMatch = FieldAdvisor.matchGrassFruitName(normalized)
    if grassMatch == nil then
        return nil
    end

    local fruitTypeIndex = FieldAdvisor.getFruitTypeIndexByName(normalized)
    if fruitTypeIndex ~= nil then
        return fruitTypeIndex
    end

    return FieldAdvisor.getFruitTypeIndexByName(grassMatch)
end

---@param source table|nil
---@return number|nil
function FieldAdvisor.inferGrassFruitTypeIndexFromNames(source)
    if source == nil then
        return nil
    end

    local nameFields = {
        "currentFruitTypeName",
        "fruitTypeName",
        "currentCropTypeName",
        "cropTypeName",
        "fruitType",
        "plannedFruit",
    }

    for _, key in ipairs(nameFields) do
        local fruitTypeIndex = FieldAdvisor.inferGrassFruitTypeIndexFromName(source[key])
        if fruitTypeIndex ~= nil then
            return fruitTypeIndex
        end
    end

    return nil
end

---@param field table|nil
---@return number|nil
function FieldAdvisor.inferGrassFruitTypeIndexFromField(field)
    if field == nil then
        return nil
    end

    local nameHint = FieldAdvisor.inferGrassFruitTypeIndexFromNames(field)
    if nameHint ~= nil and not FieldAdvisor.isGenericGrassFruitIndex(nameHint) then
        return nameHint
    end

    local fieldState = FieldAdvisor.getFieldState(field)
    local stateNameHint = FieldAdvisor.inferGrassFruitTypeIndexFromNames(fieldState)
    if stateNameHint ~= nil and not FieldAdvisor.isGenericGrassFruitIndex(stateNameHint) then
        return stateNameHint
    end

    local candidates = {
        field.fruitTypeIndex,
        field.currentFruitTypeIndex,
        field.plannedFruitTypeIndex,
        field.plannedFruitIndex,
    }

    for _, rawIndex in ipairs(candidates) do
        local fruitTypeIndex = tonumber(rawIndex)
        if fruitTypeIndex ~= nil and fruitTypeIndex > 0 and FieldAdvisor.isGrassCrop(fruitTypeIndex) then
            if nameHint == nil or not FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
                return fruitTypeIndex
            end
        end
    end

    local probes = {
        "getFruitTypeIndex",
        "getCurrentFruitTypeIndex",
        "getPlannedFruitTypeIndex",
        "getFruitType",
    }
    for _, probe in ipairs(probes) do
        if field[probe] ~= nil then
            local ok, value = pcall(field[probe], field)
            local fruitTypeIndex = ok and tonumber(value) or nil
            if fruitTypeIndex ~= nil and fruitTypeIndex > 0 and FieldAdvisor.isGrassCrop(fruitTypeIndex) then
                if nameHint == nil or not FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
                    return fruitTypeIndex
                end
            end
            if ok and type(value) == "string" then
                local fromName = FieldAdvisor.inferGrassFruitTypeIndexFromName(value)
                if fromName ~= nil and not FieldAdvisor.isGenericGrassFruitIndex(fromName) then
                    return fromName
                end
            end
        end
    end

    for _, probe in ipairs({ "getPlannedFruit", "getFruitTypeName", "getCurrentFruitTypeName" }) do
        if field[probe] ~= nil then
            local ok, value = pcall(field[probe], field)
            if ok then
                local fromName = FieldAdvisor.inferGrassFruitTypeIndexFromName(value)
                if fromName ~= nil and not FieldAdvisor.isGenericGrassFruitIndex(fromName) then
                    return fromName
                end
            end
        end
    end

    return nameHint or stateNameHint
end

---@param fieldState table|nil
---@param field table|nil
---@param aggregation table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return number|nil
function FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
    if fieldState == nil
        or FieldAdvisor.classifyProbe(fieldState, field) ~= FieldAdvisor.PROBE_SITUATION.GRASS then
        return nil
    end

    local fruitTypeIndex = nil
    if aggregation ~= nil and aggregation.dominantGrassFruit ~= nil then
        fruitTypeIndex = aggregation.dominantGrassFruit
    end

    if fruitTypeIndex == nil then
        fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
    end
    if fruitTypeIndex == nil then
        fruitTypeIndex = FieldAdvisor.inferGrassFruitTypeIndexFromState(fieldState)
    end
    if fruitTypeIndex == nil then
        fruitTypeIndex = FieldAdvisor.inferGrassFruitTypeIndexFromField(field)
    end
    if fruitTypeIndex == nil and field ~= nil then
        FieldAdvisor.enrichFieldStateFromField(field, fieldState)
        fruitTypeIndex = FieldAdvisor.getFruitTypeIndex(fieldState)
        if fruitTypeIndex ~= nil and fruitTypeIndex > 0 and not FieldAdvisor.isGrassCrop(fruitTypeIndex) then
            fruitTypeIndex = nil
        end
    end

    return FieldAdvisor.refineGrassFruitTypeIndex(fieldState, field, fruitTypeIndex, worldX, worldZ)
end

---@param fieldState table|nil
---@param field table|nil
---@return string
function FieldAdvisor.getGrassHarvestWindowLabel(fieldState, field, aggregation, grassResidueSummary)
    local postMowLabel = FieldAdvisor.getGrassPostMowDisplayLabel(field, fieldState, aggregation, grassResidueSummary)
    if postMowLabel ~= nil then
        return postMowLabel
    end

    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)
    local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(harvestState, field, aggregation)
        or (aggregation ~= nil and aggregation.dominantGrassFruit)
    local harvestWindow = FieldAdvisor.getHarvestWindowHint(grassFruit, harvestState)
    return FieldAdvisor.formatHarvestWindowLabel(harvestWindow)
end

--- Synthetic field state for next harvest month after mowing (stubble growth > maxHarvest breaks projection).
---@param fieldState table|nil
---@param fruitTypeIndex number|nil
---@return table
function FieldAdvisor.buildGrassRegrowthProjectionState(fieldState, fruitTypeIndex)
    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    local target = nil

    if fruitDesc ~= nil then
        if FieldAdvisor.fruitDescHasHarvestReadyApi(fruitTypeIndex) then
            for candidate = 1, 12 do
                if FieldAdvisor.isGrowthStateHarvestReadyByApi(fruitTypeIndex, candidate) then
                    target = candidate
                    break
                end
            end
        end
        if target == nil then
            local minHarvest = tonumber(fruitDesc.minHarvestingGrowthState) or 0
            if minHarvest > 0 then
                target = minHarvest
            end
        end
    end

    if target == nil or target <= 0 then
        target = 1
    end

    local projected = {
        growthState = target,
        lastGrowthState = 0,
        fruitTypeIndex = fruitTypeIndex,
    }

    if fieldState ~= nil then
        if fieldState.fruitTypeIndex ~= nil and fieldState.fruitTypeIndex > 0 then
            projected.fruitTypeIndex = fieldState.fruitTypeIndex
        elseif fieldState.currentFruitTypeIndex ~= nil and fieldState.currentFruitTypeIndex > 0 then
            projected.fruitTypeIndex = fieldState.currentFruitTypeIndex
        end
    end

    return projected
end

--- Harvest/regrowth label for mown grass (Luzerne/Klee): next window or „Nachwuchs“, never „Wächst“.
---@param field table|nil
---@param fieldState table|nil
---@param aggregation table|nil
---@param grassResidueSummary table|nil
---@return string|nil nil when field is not post-mow
function FieldAdvisor.getGrassPostMowDisplayLabel(field, fieldState, aggregation, grassResidueSummary)
    local probeState = aggregation ~= nil and aggregation.centerState or fieldState
    if not FieldAdvisor.isGrassPostMowState(probeState, field, nil) then
        return nil
    end

    local residueState = grassResidueSummary ~= nil and grassResidueSummary.residueState
        or FieldAdvisor.GRASS_RESIDUE_NONE
    if residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE then
        return FieldAdvisor.text("ftdl_action_regrowth", "Nachwuchs")
    end

    local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(probeState, field, aggregation)
        or (aggregation ~= nil and aggregation.dominantGrassFruit)
    if grassFruit == nil then
        return FieldAdvisor.text("ftdl_action_regrowth", "Nachwuchs")
    end

    local regrowthState = FieldAdvisor.buildGrassRegrowthProjectionState(probeState, grassFruit)
    local harvestWindow = FieldAdvisor.getHarvestWindowHint(grassFruit, regrowthState)
    if harvestWindow ~= "-" then
        return FieldAdvisor.formatHarvestWindowLabel(harvestWindow)
    end

    return FieldAdvisor.text("ftdl_action_regrowth", "Nachwuchs")
end

---@param field table|nil
---@param fieldId number|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return table|nil
function FieldAdvisor.getEnrichedFieldState(field, fieldId, worldX, worldZ)
    -- Live density-map sample only. No savegame fields.xml overlay.
    local fieldState = FieldAdvisor.getLiveFieldState(worldX, worldZ)
    if fieldState == nil then
        fieldState = FieldAdvisor.getFieldState(field)
        if fieldState ~= nil and fieldState.update ~= nil and worldX ~= nil and worldZ ~= nil then
            local ok = pcall(fieldState.update, fieldState, worldX, worldZ)
            if not ok then
                fieldState = nil
            end
        end
    end

    if fieldState == nil then
        return {
            fruitTypeIndex = FruitType ~= nil and FruitType.UNKNOWN or 0,
            growthState = 0,
            groundType = FieldGroundType ~= nil and FieldGroundType.NONE or 0,
        }
    end

    FieldAdvisor.enrichFieldStateFromField(field, fieldState)

    if FieldAdvisor.isWorkedBareGround(fieldState) then
        FieldAdvisor.clearStaleGrassMetadata(fieldState)
    end

    return fieldState
end

---@param actions table[]|nil
---@return table action
function FieldAdvisor.selectPrimaryAction(actions)
    if actions == nil or #actions == 0 then
        return {
            actionType = "none",
            label = FieldAdvisor.text("ftdl_action_all_ok", "Alles ok"),
            autoComplete = false,
        }
    end

    for _, action in ipairs(actions) do
        if action.autoComplete == true then
            return action
        end
    end

    for _, action in ipairs(actions) do
        if action.actionType ~= "harvest_info" and action.actionType ~= "growing" and action.actionType ~= "none" then
            return action
        end
    end

    return actions[1]
end

---@param level number
---@param rules table
---@return string
function FieldAdvisor.formatStoneLabel(level, rules)
    local label = level <= 0
        and FieldAdvisor.text("ftdl_val_none", "kein")
        or FieldAdvisor.text("ftdl_val_growth_stage", "St.%d", level)
    if not rules.stonesEnabled then
        return string.format("%s %s", label, FieldAdvisor.text("ftdl_val_disabled", "(aus)"))
    end

    return label
end

---@param level number
---@param rules table
---@param needsLime boolean|nil when false, field is limed (ignore stale limeLevel)
---@return string
function FieldAdvisor.formatLimeLabel(level, rules, needsLime)
    if not rules.limeRequired then
        local base = level <= 0
            and FieldAdvisor.text("ftdl_val_ok", "ok")
            or FieldAdvisor.text("ftdl_val_lime_level", "K%d", level)
        return string.format("%s %s", base, FieldAdvisor.text("ftdl_val_disabled", "(aus)"))
    end

    if needsLime == false or level <= 0 then
        return FieldAdvisor.text("ftdl_val_ok", "ok")
    end

    return FieldAdvisor.text("ftdl_val_lime_level", "K%d", level)
end

---@param weedState number
---@param rules table
---@return string
function FieldAdvisor.formatWeedLabel(weedState, rules)
    local label = FieldAdvisor.WEED_LABELS[weedState]
    if label == nil then
        label = weedState <= 0
            and FieldAdvisor.text("ftdl_val_none", "kein")
            or string.format("%d", weedState)
    else
        local weedKeys = {
            kein = { "ftdl_val_none", "kein" },
            leicht = { "ftdl_weed_light", "leicht" },
            mittel = { "ftdl_weed_medium", "mittel" },
            stark = { "ftdl_weed_heavy", "stark" },
        }
        local weedEntry = weedKeys[label]
        if weedEntry ~= nil then
            label = FieldAdvisor.text(weedEntry[1], weedEntry[2])
        end
    end

    if not rules.weedsEnabled then
        return string.format("%s %s", label, FieldAdvisor.text("ftdl_val_disabled", "(aus)"))
    end

    return label
end

---@param fieldState table|nil
---@return number
function FieldAdvisor.getWeedFactor(fieldState)
    return FieldAdvisor.getStateNumber(fieldState, "weedFactor")
end

---@param fieldState table|nil
---@return number
function FieldAdvisor.getWeedStateLevel(fieldState)
    return FieldAdvisor.getStateNumber(fieldState, "weedState")
end

---@param fieldState table|nil
---@return boolean
function FieldAdvisor.hasWeedFactorReading(fieldState)
    return fieldState ~= nil and fieldState.weedFactor ~= nil
end

---@param fieldState table|nil
---@return boolean
function FieldAdvisor.hasHerbicideResidue(fieldState)
    if fieldState == nil then
        return false
    end

    local sprayLevel = FieldAdvisor.getStateNumber(fieldState, "sprayLevel")
    local sprayType = FieldAdvisor.getStateNumber(fieldState, "sprayType")
    return sprayLevel > 0 or sprayType > 0
end

---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isWeedDeadOrSprayed(fieldState)
    if fieldState == nil then
        return false
    end

    local weedState = FieldAdvisor.getWeedStateLevel(fieldState)
    if weedState >= FieldAdvisor.WEED_STATE_DEAD_MIN then
        return true
    end

    if FieldAdvisor.hasHerbicideResidue(fieldState)
        and weedState > FieldAdvisor.WEED_STATE_SPRAYED_LIVE_MAX then
        return true
    end

    if FieldAdvisor.hasWeedFactorReading(fieldState) then
        local weedFactor = FieldAdvisor.getWeedFactor(fieldState)
        if weedFactor <= FieldAdvisor.WEED_FACTOR_COMPLETE_THRESHOLD then
            return true
        end

        if FieldAdvisor.hasHerbicideResidue(fieldState)
            and weedFactor <= FieldAdvisor.WEED_FACTOR_TREATED_THRESHOLD
            and weedState <= FieldAdvisor.WEED_STATE_TREATED_MAX then
            return true
        end

        return false
    end

    return weedState <= 0
end

---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isWeedProbeLive(fieldState)
    if fieldState == nil then
        return false
    end

    local weedState = FieldAdvisor.getWeedStateLevel(fieldState)
    if weedState <= 0 or weedState >= FieldAdvisor.WEED_STATE_DEAD_MIN then
        return false
    end

    if FieldAdvisor.hasHerbicideResidue(fieldState) then
        if weedState > FieldAdvisor.WEED_STATE_SPRAYED_LIVE_MAX then
            return false
        end
    end

    if FieldAdvisor.isWeedDeadOrSprayed(fieldState) then
        return false
    end

    return FieldAdvisor.getEffectiveWeedPressure(fieldState) > FieldAdvisor.WEED_FACTOR_COMPLETE_THRESHOLD
end

---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isWeedProbeDead(fieldState)
    if fieldState == nil then
        return false
    end

    local weedState = FieldAdvisor.getWeedStateLevel(fieldState)
    if weedState >= FieldAdvisor.WEED_STATE_DEAD_MIN then
        return true
    end

    if FieldAdvisor.hasHerbicideResidue(fieldState) then
        if weedState > FieldAdvisor.WEED_STATE_SPRAYED_LIVE_MAX then
            return true
        end
    end

    if weedState <= 0 then
        return false
    end

    return FieldAdvisor.isWeedDeadOrSprayed(fieldState)
end

---@param fieldState table|nil
---@return number
function FieldAdvisor.getEffectiveWeedPressure(fieldState)
    if FieldAdvisor.isWeedDeadOrSprayed(fieldState) then
        return 0
    end

    if FieldAdvisor.hasWeedFactorReading(fieldState) then
        return FieldAdvisor.getWeedFactor(fieldState)
    end

    local weedState = FieldAdvisor.getWeedStateLevel(fieldState)
    if weedState <= 0 then
        return 0
    end

    return math.min(1, weedState / 9)
end

---@param field table|nil
---@param fieldId number|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return table summary
function FieldAdvisor.sampleWeedCoverage(field, fieldId, worldX, worldZ)
    local cached = FieldAdvisor.getCoverageCache(fieldId, "weed", FieldAdvisor.WEED_COVERAGE_CACHE_TTL_MS)
    if cached ~= nil then
        return cached
    end

    local summary = {
        total = 0,
        live = 0,
        dead = 0,
        liveRatio = 0,
        deadRatio = 0,
        hasDead = false,
    }

    if field == nil then
        return summary
    end

    if worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end

    if worldX == nil or worldZ == nil then
        return summary
    end

    local points = {}
    if FieldTaskCompletion ~= nil and FieldTaskCompletion.collectSamplePoints ~= nil then
        points = FieldTaskCompletion.collectSamplePoints(field, worldX, worldZ)
    else
        points = { { x = worldX, z = worldZ } }
    end
    points = FieldAdvisor.reduceSamplePoints(points, FieldAdvisor.COVERAGE_MAX_SAMPLE_POINTS)

    for _, point in ipairs(points) do
        if FieldAdvisor.isPositionInsideFieldOrUnknown(field, point.x, point.z) then
            local sampleState = FieldAdvisor.getEnrichedFieldState(field, fieldId, point.x, point.z)
            summary.total = summary.total + 1

            local dead = FieldAdvisor.isWeedProbeDead(sampleState)
            local live = not dead and FieldAdvisor.isWeedProbeLive(sampleState)

            if dead then
                summary.dead = summary.dead + 1
            elseif live then
                summary.live = summary.live + 1
            end
        end
    end

    if summary.total > 0 then
        local classified = summary.live + summary.dead
        summary.classified = classified
        if classified > 0 then
            summary.liveRatio = summary.live / classified
            summary.deadRatio = summary.dead / classified
        end
        summary.hasDead = summary.dead > 0
    end

    FieldAdvisor.setCoverageCache(fieldId, "weed", summary)
    return summary
end

---@param weedSummary table|nil
---@return boolean
function FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary)
    if weedSummary == nil then
        return false
    end

    local classified = weedSummary.classified
    if classified == nil then
        classified = (weedSummary.live or 0) + (weedSummary.dead or 0)
    end
    if classified <= 0 then
        return false
    end

    if weedSummary.liveRatio <= FieldAdvisor.WEED_LIVE_RATIO_DONE_THRESHOLD then
        return true
    end

    if weedSummary.deadRatio >= (1 - FieldAdvisor.WEED_LIVE_RATIO_DONE_THRESHOLD) then
        return true
    end

    -- Residual live probes on a nearly dead field (e.g. sprayed residue misread as live).
    if weedSummary.dead > 0
        and weedSummary.live <= 1
        and weedSummary.deadRatio >= 0.85 then
        return true
    end

    return false
end

---@return number
function FieldAdvisor.getRuntimeTimeMs()
    if g_time ~= nil then
        return tonumber(g_time) or 0
    end

    if g_currentMission ~= nil and g_currentMission.time ~= nil then
        return tonumber(g_currentMission.time) or 0
    end

    return 0
end

---@param fieldId number|nil
---@param kind string
---@param ttlMs number|nil
---@return table|nil
function FieldAdvisor.getCoverageCache(fieldId, kind, ttlMs)
    if fieldId == nil or kind == nil then
        return nil
    end

    local cacheKey = string.format("%s:%s", tostring(fieldId), tostring(kind))
    local entry = FieldAdvisor._coverageCache[cacheKey]
    if entry == nil then
        return nil
    end

    local ttl = math.max(0, tonumber(ttlMs) or FieldAdvisor.WEED_COVERAGE_CACHE_TTL_MS)
    if FieldAdvisor.getRuntimeTimeMs() - (entry.timestampMs or 0) > ttl then
        FieldAdvisor._coverageCache[cacheKey] = nil
        return nil
    end

    return entry.value
end

---@param fieldId number|nil
---@param kind string
---@param value table
function FieldAdvisor.setCoverageCache(fieldId, kind, value)
    if fieldId == nil or kind == nil or value == nil then
        return
    end

    local cacheKey = string.format("%s:%s", tostring(fieldId), tostring(kind))
    FieldAdvisor._coverageCache[cacheKey] = {
        timestampMs = FieldAdvisor.getRuntimeTimeMs(),
        value = value,
    }
end

---@param fieldId number|nil
---@param kind string|nil
function FieldAdvisor.clearCoverageCache(fieldId, kind)
    if fieldId == nil or kind == nil then
        return
    end

    local cacheKey = string.format("%s:%s", tostring(fieldId), tostring(kind))
    FieldAdvisor._coverageCache[cacheKey] = nil
end

---@param x number|nil
---@param z number|nil
---@return number|nil
function FieldAdvisor.resolveEngineFieldIdAtWorldPosition(x, z)
    if g_fieldManager == nil or x == nil or z == nil then
        return nil
    end

    local idMethods = { "getFieldIdAtWorldPosition", "getFieldIDAtWorldPosition" }
    for _, methodName in ipairs(idMethods) do
        local fn = g_fieldManager[methodName]
        if type(fn) == "function" then
            local ok, fieldId = pcall(fn, g_fieldManager, x, z)
            fieldId = tonumber(fieldId)
            if ok and fieldId ~= nil and fieldId > 0 then
                return fieldId
            end
        end
    end

    local fieldMethods = { "getFieldAtWorldPosition", "getFieldAtPosition" }
    for _, methodName in ipairs(fieldMethods) do
        local fn = g_fieldManager[methodName]
        if type(fn) == "function" then
            local ok, engineField = pcall(fn, g_fieldManager, x, z)
            if ok and engineField ~= nil and engineField.getId ~= nil then
                local okId, fieldId = pcall(engineField.getId, engineField)
                fieldId = tonumber(fieldId)
                if okId and fieldId ~= nil and fieldId > 0 then
                    return fieldId
                end
            end
        end
    end

    return nil
end

---@param points table|nil
---@param maxPoints number|nil
---@return table
function FieldAdvisor.reduceSamplePoints(points, maxPoints)
    if points == nil or #points == 0 then
        return {}
    end

    local limit = math.max(1, math.floor(tonumber(maxPoints) or FieldAdvisor.COVERAGE_MAX_SAMPLE_POINTS))
    if #points <= limit then
        return points
    end

    local reduced = {}
    reduced[#reduced + 1] = points[1]

    local step = math.max(1, math.floor(#points / limit))
    for index = 2, #points, step do
        reduced[#reduced + 1] = points[index]
        if #reduced >= limit then
            break
        end
    end

    return reduced
end

---@param field table|nil
---@param centerX number
---@param centerZ number
---@param dirX number
---@param dirZ number
---@return number
function FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, dirX, dirZ)
    if field == nil then
        return 0
    end

    local maxDist = 0
    local step = 3
    for dist = step, 320, step do
        if FieldAdvisor.isPositionInsideFieldOrUnknown(field, centerX + dirX * dist, centerZ + dirZ * dist) then
            maxDist = dist
        else
            break
        end
    end

    for dist = step, 320, step do
        if FieldAdvisor.isPositionInsideFieldOrUnknown(field, centerX - dirX * dist, centerZ - dirZ * dist) then
            maxDist = math.max(maxDist, dist)
        else
            break
        end
    end

    if maxDist <= 0 then
        local areaHa = tonumber(field.areaHa) or 0
        if areaHa > 0 then
            maxDist = math.max(8, math.sqrt(areaHa * 10000) * 0.48)
        end
    end

    return math.max(6, maxDist)
end

--- Cross + bar scan through field center to hit narrow swath lines.
---@param field table|nil
---@param centerX number
---@param centerZ number
---@param crossSteps number|nil
---@return table points
function FieldAdvisor.collectGrassResidueSamplePoints(field, centerX, centerZ, crossSteps)
    local points = {}
    if field == nil or centerX == nil or centerZ == nil then
        return points
    end

    crossSteps = math.max(4, math.floor(tonumber(crossSteps) or FieldAdvisor.GRASS_RESIDUE_CROSS_STEPS))
    local seen = {}

    local function addPoint(x, z, axis)
        local key = string.format("%.2f|%.2f", x, z)
        if seen[key] then
            return
        end
        if not FieldAdvisor.isPositionInsideFieldOrUnknown(field, x, z) then
            return
        end
        seen[key] = true
        points[#points + 1] = { x = x, z = z, axis = axis }
    end

    addPoint(centerX, centerZ, "center")

    local extentX = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 1, 0)
    local extentZ = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 0, 1)

    for i = -crossSteps, crossSteps do
        local t = i / crossSteps
        addPoint(centerX + t * extentX, centerZ, "ew")
    end

    for i = -crossSteps, crossSteps do
        if i ~= 0 then
            local t = i / crossSteps
            addPoint(centerX, centerZ + t * extentZ, "ns")
        end
    end

    local extentDiag = math.min(extentX, extentZ) * 0.92
    local diagScale = 0.70710678
    for i = -crossSteps, crossSteps do
        if i ~= 0 then
            local t = i / crossSteps
            addPoint(
                centerX + t * extentDiag * diagScale,
                centerZ + t * extentDiag * diagScale,
                "diag1"
            )
            addPoint(
                centerX + t * extentDiag * diagScale,
                centerZ - t * extentDiag * diagScale,
                "diag2"
            )
        end
    end

    return points
end

---@param points table|nil
---@param maxPoints number|nil
---@return table
function FieldAdvisor.reduceGrassResidueSamplePoints(points, maxPoints)
    if points == nil or #points == 0 then
        return {}
    end

    local limit = math.max(1, math.floor(tonumber(maxPoints) or FieldAdvisor.GRASS_RESIDUE_MAX_SAMPLE_POINTS))
    if #points <= limit then
        return points
    end

    local centerPoint = points[1]
    local ewPoints = {}
    local nsPoints = {}
    local diagPoints = {}
    for index = 2, #points do
        local point = points[index]
        if point.axis == "ns" then
            nsPoints[#nsPoints + 1] = point
        elseif point.axis == "ew" then
            ewPoints[#ewPoints + 1] = point
        else
            diagPoints[#diagPoints + 1] = point
        end
    end

    local reduced = { centerPoint }
    local remaining = limit - 1
    local axisBudget = math.max(1, math.floor(remaining / 3))
    local diagBudget = remaining - (axisBudget * 2)

    local function subsample(source, budget)
        if budget <= 0 or #source == 0 then
            return
        end
        if #source <= budget then
            for _, point in ipairs(source) do
                reduced[#reduced + 1] = point
            end
            return
        end

        local step = math.max(1, math.floor(#source / budget))
        for index = 1, #source, step do
            reduced[#reduced + 1] = source[index]
            if #reduced >= limit then
                break
            end
        end
    end

    subsample(ewPoints, axisBudget)
    if #reduced < limit then
        subsample(nsPoints, axisBudget)
    end
    if #reduced < limit then
        subsample(diagPoints, math.min(diagBudget, limit - #reduced))
    end

    return reduced
end

--- Count high/low bands along a cross axis (swath rows = multiple transitions; uniform stubble = flat).
---@param materials number[]
---@param threshold number
---@return number
function FieldAdvisor.countAxisMaterialTransitions(materials, threshold)
    if materials == nil or #materials < 2 then
        return 0
    end

    local transitions = 0
    for index = 2, #materials do
        local prevAbove = materials[index - 1] >= threshold
        local curAbove = materials[index] >= threshold
        if prevAbove ~= curAbove then
            transitions = transitions + 1
        end
    end

    return transitions
end

--- Full E-W / N-S cross (not reduced grid): detect parallel swath lines vs flat cut stubble.
---@param field table|nil
---@param centerX number|nil
---@param centerZ number|nil
---@param crossSteps number|nil
---@return number ewTransitions
---@return number nsTransitions
---@return number maxTransitions
function FieldAdvisor.measureGrassCrossAxisLineTransitions(field, centerX, centerZ, crossSteps)
    if field == nil or centerX == nil or centerZ == nil then
        return 0, 0, 0
    end

    crossSteps = math.max(4, math.floor(tonumber(crossSteps) or FieldAdvisor.GRASS_RESIDUE_CROSS_STEPS))
    local threshold = FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN
    local ewMaterials = {}
    local nsMaterials = {}

    local extentX = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 1, 0)
    local extentZ = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 0, 1)

    for i = -crossSteps, crossSteps do
        local t = i / crossSteps
        local x = centerX + t * extentX
        local z = centerZ
        if FieldAdvisor.isPositionInsideFieldOrUnknown(field, x, z) then
            ewMaterials[#ewMaterials + 1] = FieldAdvisor.measureHeightMaterialAtPoint(x, z)
        end
    end

    for i = -crossSteps, crossSteps do
        if i ~= 0 then
            local t = i / crossSteps
            local x = centerX
            local z = centerZ + t * extentZ
            if FieldAdvisor.isPositionInsideFieldOrUnknown(field, x, z) then
                nsMaterials[#nsMaterials + 1] = FieldAdvisor.measureHeightMaterialAtPoint(x, z)
            end
        end
    end

    local ewTransitions = FieldAdvisor.countAxisMaterialTransitions(ewMaterials, threshold)
    local nsTransitions = FieldAdvisor.countAxisMaterialTransitions(nsMaterials, threshold)
    return ewTransitions, nsTransitions, math.max(ewTransitions, nsTransitions)
end

---@param field table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param crossSteps number|nil
---@return number maxMaterial
---@return number maxLiters
---@return number pointCount
function FieldAdvisor.scanCrossForMaxGrassMaterial(field, worldX, worldZ, crossSteps, prioritizedFruitTypeIndex)
    if field == nil or worldX == nil or worldZ == nil then
        return 0, 0, 0
    end

    local points = FieldAdvisor.collectGrassResidueSamplePoints(field, worldX, worldZ, crossSteps)
    local maxMaterial = 0
    local maxLiters = 0
    local fillTypes = FieldAdvisor.collectWindrowFillTypeIndices(prioritizedFruitTypeIndex)

    for _, point in ipairs(points) do
        local material = FieldAdvisor.measureHeightMaterialAtPoint(point.x, point.z)
        maxMaterial = math.max(maxMaterial, material)

        local liters = FieldAdvisor.measureWindrowLitersAtPoint(
            point,
            fillTypes,
            FieldAdvisor.GRASS_RESIDUE_SAMPLE_HALF_SIZE
        )
        maxLiters = math.max(maxLiters, liters)
    end

    return maxMaterial, maxLiters, #points
end

--- Count cross-scan points with windrow material (swath lines intersecting the cross).
---@param field table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param crossSteps number|nil
---@param prioritizedFruitTypeIndex number|nil
---@return number hits
---@return number maxLiters
---@return number maxMaterial
function FieldAdvisor.countGrassWindrowMaterialHits(field, worldX, worldZ, crossSteps, prioritizedFruitTypeIndex)
    if field == nil or worldX == nil or worldZ == nil then
        return 0, 0, 0
    end

    local points = FieldAdvisor.collectGrassResidueSamplePoints(field, worldX, worldZ, crossSteps)
    local fillTypes = FieldAdvisor.collectWindrowFillTypeIndices(prioritizedFruitTypeIndex)
    local hits = 0
    local maxLiters = 0
    local maxMaterial = 0
    local literThreshold = 0.008
    local materialThreshold = FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN

    for _, point in ipairs(points) do
        if FieldAdvisor.isPositionInsideFieldOrUnknown(field, point.x, point.z) then
            local material = FieldAdvisor.measureHeightMaterialAtPoint(point.x, point.z)
            maxMaterial = math.max(maxMaterial, material)

            local liters = FieldAdvisor.measureWindrowLitersAtPoint(
                point,
                fillTypes,
                FieldAdvisor.GRASS_RESIDUE_SAMPLE_HALF_SIZE
            )
            maxLiters = math.max(maxLiters, liters)

            if liters >= literThreshold or material >= materialThreshold then
                hits = hits + 1
            end
        end
    end

    return hits, maxLiters, maxMaterial
end

--- Standing meadow/grass crop (not post-mow logistics).
---@param meadowPhase string|nil
---@param probeState table|nil
---@param field table|nil
---@param grassFruitHint number|nil
---@return boolean
function FieldAdvisor.isGrassStandingCropPhase(meadowPhase, probeState, field, grassFruitHint)
    if meadowPhase == "harvestable" then
        return true
    end

    if meadowPhase == "growing"
        and not FieldAdvisor.isGrassPostMowState(probeState, field, grassFruitHint)
        and not FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(probeState)) then
        return true
    end

    return false
end

--- Post-mow / residue signals anywhere on the field (not center-only).
---@param aggregation table|nil
---@param probeState table|nil
---@param field table|nil
---@param grassFruitHint number|nil
---@return boolean
function FieldAdvisor.fieldHasPostMowGrassSignal(aggregation, probeState, field, grassFruitHint)
    if probeState ~= nil then
        if FieldAdvisor.isGrassPostMowState(probeState, field, grassFruitHint) then
            return true
        end
        if FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(probeState)) then
            return true
        end
        if FieldAdvisor.getStateNumber(probeState, "stubbleShredLevel") > 0 then
            return true
        end
    end

    if aggregation == nil then
        return false
    end

    if (aggregation.maxStubbleShredLevel or 0) > 0 then
        return true
    end

    local representativeState = aggregation.representativeState
    if representativeState ~= nil and representativeState ~= probeState then
        if FieldAdvisor.isGrassPostMowState(representativeState, field, grassFruitHint) then
            return true
        end
        if FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(representativeState)) then
            return true
        end
    end

    return false
end

--- Standing generic grass from probe growth only (no getGrassMeadowPhase — avoids resolve/recurse loop).
---@param fieldState table|nil
---@param field table|nil
---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isGenericGrassStandingCrop(fieldState, field, fruitTypeIndex)
    if fieldState == nil then
        return false
    end
    if fruitTypeIndex ~= nil and not FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
        return false
    end
    if FieldAdvisor.classifyProbe(fieldState, field) ~= FieldAdvisor.PROBE_SITUATION.GRASS then
        return false
    end
    if FieldAdvisor.isGrassPostMowState(fieldState, field, fruitTypeIndex) then
        return false
    end
    if FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(fieldState)) then
        return false
    end

    local evalFruit = fruitTypeIndex
    if evalFruit == nil or evalFruit <= 0 or FieldAdvisor.isGenericGrassFruitIndex(evalFruit) then
        evalFruit = FieldAdvisor.getFruitTypeIndex(fieldState)
    end
    if evalFruit == nil or evalFruit <= 0 then
        return false
    end

    local growthState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if growthState > 0 then
        local growth = FieldAdvisor.evaluateFruitGrowth(evalFruit, growthState)
        if growth.isCut or growth.isWithered then
            return false
        end
        if growth.isHarvestReady or growth.isHarvestable or growth.isGrowing then
            return true
        end
    end

    local lastGrowth = FieldAdvisor.getLastGrowthState(fieldState)
    if lastGrowth > 0 then
        local lastFlags = FieldAdvisor.evaluateFruitGrowth(evalFruit, lastGrowth)
        if lastFlags.isCut or lastFlags.isWithered then
            return false
        end
        if lastFlags.isHarvestReady or lastFlags.isHarvestable or lastFlags.isGrowing then
            return true
        end
    end

    return false
end

---@param summary table|nil
---@param aggregation table|nil
---@param probeState table|nil
---@param field table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param grassFruitHint number|nil
---@param meadowPhase string|nil
---@return boolean
function FieldAdvisor.shouldTreatGrassResidueAsSwath(summary, aggregation, probeState, field, worldX, worldZ, grassFruitHint, meadowPhase)
    if summary == nil then
        return false
    end

    if FieldAdvisor.isGrassCollectEffectivelyDone(summary, nil) then
        return false
    end

    if FieldAdvisor.isGrassStandingCropPhase(meadowPhase, probeState, field, grassFruitHint) then
        return false
    end

    local state = summary.residueState
    if state == FieldAdvisor.GRASS_RESIDUE_SWATH or state == FieldAdvisor.GRASS_RESIDUE_BALED then
        return FieldAdvisor.hasGrassWindrowLineEvidence(summary)
    end

    if state ~= FieldAdvisor.GRASS_RESIDUE_LOOSE and state ~= FieldAdvisor.GRASS_RESIDUE_NONE then
        return false
    end

    if FieldAdvisor.hasGrassWindrowLineEvidence(summary) then
        return true
    end

    if field == nil or worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end
    if field ~= nil and worldX ~= nil and worldZ ~= nil then
        local hits, crossLiters, crossMaterial = FieldAdvisor.countGrassWindrowMaterialHits(
            field,
            worldX,
            worldZ,
            FieldAdvisor.GRASS_RESIDUE_CROSS_STEPS,
            grassFruitHint
        )
        local occupiedRatio = tonumber(summary.occupiedRatio) or 0
        -- Full-field cut grass (ratio ~1) is loose mow residue, not formed swath lines.
        if occupiedRatio >= 0.55 then
            return false
        end
        if hits >= 2 and crossLiters > 0.04
            and occupiedRatio <= FieldAdvisor.GRASS_SWATH_OCCUPANCY_MAX then
            return true
        end
    end

    return false
end

---@param prioritizedFruitTypeIndex number|nil
---@return table
function FieldAdvisor.collectWindrowFillTypeIndices(prioritizedFruitTypeIndex)
    local fillTypes = {}
    local seen = {}

    local function addFillTypeIndex(fillTypeIndex)
        fillTypeIndex = tonumber(fillTypeIndex)
        if fillTypeIndex ~= nil and fillTypeIndex > 0 and seen[fillTypeIndex] ~= true then
            seen[fillTypeIndex] = true
            fillTypes[#fillTypes + 1] = fillTypeIndex
        end
    end

    local function addWindrowForFruit(fruitTypeIndex)
        if fruitTypeIndex == nil or fruitTypeIndex <= 0 then
            return
        end

        local windrowIndex = FieldAdvisor.getWindrowFillTypeIndexForFruit(fruitTypeIndex)
        if windrowIndex ~= nil then
            addFillTypeIndex(windrowIndex)
        end
    end

    addWindrowForFruit(prioritizedFruitTypeIndex)

    for _, fruitTypeIndex in ipairs(FieldAdvisor.getGrassFruitTypeIndices()) do
        addWindrowForFruit(fruitTypeIndex)
    end

    if FillType ~= nil then
        addFillTypeIndex(FillType.GRASS_WINDROW)
        addFillTypeIndex(FillType.DRYGRASS_WINDROW)
    end

    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypes ~= nil then
        local ok, fillTypeList = pcall(function()
            return g_fillTypeManager:getFillTypes()
        end)
        if ok and fillTypeList ~= nil then
            for _, fillType in ipairs(fillTypeList) do
                local name = fillType ~= nil and fillType.name or nil
                if name ~= nil and string.find(string.upper(tostring(name)), "WINDROW", 1, true) ~= nil then
                    addFillTypeIndex(fillType.index or fillType.fillTypeIndex)
                end
            end
        end
    end

    return fillTypes
end

---@return table
function FieldAdvisor.getWindrowFillTypes()
    return FieldAdvisor.collectWindrowFillTypeIndices(nil)
end

---@param fruitTypeIndex number|nil
---@return number|nil
function FieldAdvisor.getWindrowFillTypeIndexForFruit(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 or g_fruitTypeManager == nil then
        return nil
    end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitDesc ~= nil then
        for _, key in ipairs({ "windrowFillTypeIndex", "windrowFillType", "grassWindrowFillType" }) do
            local index = tonumber(fruitDesc[key])
            if index ~= nil and index > 0 then
                return index
            end
        end
    end

    if g_fruitTypeManager.getWindrowFillTypeIndexByFruitTypeIndex ~= nil then
        local ok, index = pcall(function()
            return g_fruitTypeManager:getWindrowFillTypeIndexByFruitTypeIndex(fruitTypeIndex)
        end)
        if ok and index ~= nil and index > 0 then
            return tonumber(index)
        end

        ok, index = pcall(
            g_fruitTypeManager.getWindrowFillTypeIndexByFruitTypeIndex,
            g_fruitTypeManager,
            fruitTypeIndex
        )
        if ok and index ~= nil and index > 0 then
            return tonumber(index)
        end
    end

    if fruitDesc ~= nil and fruitDesc.name ~= nil and g_fillTypeManager ~= nil then
        local rawName = string.upper(tostring(fruitDesc.name))
        local candidates = {
            rawName .. "_WINDROW",
            rawName .. "_WINDERROW",
            "DRY" .. rawName .. "_WINDROW",
            "DRY_" .. rawName .. "_WINDROW",
        }
        if g_fillTypeManager.getFillTypeIndexByName ~= nil then
            for _, candidate in ipairs(candidates) do
                local ok, index = pcall(g_fillTypeManager.getFillTypeIndexByName, g_fillTypeManager, candidate)
                if ok and index ~= nil and index > 0 then
                    return index
                end
            end
        end
    end

    return nil
end

---@param fillTypeIndex number
---@return number
function FieldAdvisor.getMinValidHeightLiters(fillTypeIndex)
    if g_densityMapHeightManager ~= nil and g_densityMapHeightManager.getMinValidLiterValue ~= nil then
        local ok, value = pcall(g_densityMapHeightManager.getMinValidLiterValue, g_densityMapHeightManager, fillTypeIndex)
        if ok and value ~= nil then
            return math.max(0.001, tonumber(value) or 0.001)
        end
    end

    return 0.5
end

FieldAdvisor._densityMapHeightUtil = nil
FieldAdvisor._densityMapHeightFillMethod = nil
FieldAdvisor._densityMapHeightNeedsSelf = false
FieldAdvisor._densityMapHeightUtilResolved = false

function FieldAdvisor.invalidateDensityMapHeightUtil()
    FieldAdvisor._densityMapHeightUtil = nil
    FieldAdvisor._densityMapHeightFillMethod = nil
    FieldAdvisor._densityMapHeightNeedsSelf = false
    FieldAdvisor._densityMapHeightUtilResolved = false
end

---@return table|nil
function FieldAdvisor.resolveDensityMapHeightUtil()
    if FieldAdvisor._densityMapHeightUtilResolved then
        return FieldAdvisor._densityMapHeightUtil
    end

    FieldAdvisor._densityMapHeightUtilResolved = true
    FieldAdvisor._densityMapHeightFillMethod = nil
    FieldAdvisor._densityMapHeightNeedsSelf = false

    local util = rawget(_G, "DensityMapHeightUtil")
    if util ~= nil and util.getFillLevelAtArea ~= nil then
        FieldAdvisor._densityMapHeightUtil = util
        FieldAdvisor._densityMapHeightFillMethod = "getFillLevelAtArea"
        return util
    end

    if g_densityMapHeightManager ~= nil then
        for _, methodName in ipairs({ "getFillLevelAtArea", "getFillLevelInArea" }) do
            if g_densityMapHeightManager[methodName] ~= nil then
                FieldAdvisor._densityMapHeightUtil = g_densityMapHeightManager
                FieldAdvisor._densityMapHeightFillMethod = methodName
                FieldAdvisor._densityMapHeightNeedsSelf = true
                return g_densityMapHeightManager
            end
        end
    end

    return nil
end

---@param fillTypeIndex number|nil
---@param x0 number
---@param z0 number
---@param x1 number
---@param z1 number
---@param x2 number
---@param z2 number
---@return number
function FieldAdvisor.callFillLevelAtArea(fillTypeIndex, x0, z0, x1, z1, x2, z2)
    local fillIndex = tonumber(fillTypeIndex)
    if fillIndex == nil or fillIndex <= 0 then
        return 0
    end

    for attempt = 1, 2 do
        local heightUtil = FieldAdvisor.resolveDensityMapHeightUtil()
        local methodName = FieldAdvisor._densityMapHeightFillMethod or "getFillLevelAtArea"
        if heightUtil == nil or heightUtil[methodName] == nil then
            return 0
        end

        local fn = heightUtil[methodName]
        local ok, liters
        if FieldAdvisor._densityMapHeightNeedsSelf then
            ok, liters = pcall(fn, heightUtil, fillIndex, x0, z0, x1, z1, x2, z2)
        else
            ok, liters = pcall(fn, fillIndex, x0, z0, x1, z1, x2, z2)
        end

        if ok and liters ~= nil then
            return math.max(0, tonumber(liters) or 0)
        end

        if attempt == 1 then
            FieldAdvisor.invalidateDensityMapHeightUtil()
        end
    end

    return 0
end

---@param x number
---@param z number
---@return number
function FieldAdvisor.getTerrainSampleY(x, z)
    if g_currentMission == nil or getTerrainHeightAtWorldPos == nil then
        return 0
    end

    local terrainId = g_currentMission.terrainRootNodeId
    if terrainId == nil then
        return 0
    end

    local ok, y = pcall(getTerrainHeightAtWorldPos, terrainId, x, z)
    if ok and y ~= nil then
        return tonumber(y) or 0
    end

    return 0
end

---@return number|nil
function FieldAdvisor.getHeightDetailPlaneId()
    if g_currentMission == nil then
        return nil
    end

    return g_currentMission.terrainDetailHeightId
end

---@param x number
---@param z number
---@return number
function FieldAdvisor.measureHeightMaterialAtPoint(x, z)
    local planeId = FieldAdvisor.getHeightDetailPlaneId()
    if planeId == nil or getDensityHeightAtWorldPos == nil then
        return 0
    end

    local y = FieldAdvisor.getTerrainSampleY(x, z)
    local ok, height, delta = pcall(getDensityHeightAtWorldPos, planeId, x, y, z)
    if not ok then
        return 0
    end

    local material = tonumber(delta)
    if material == nil or material <= 0 then
        material = tonumber(height) or 0
    end

    return math.max(0, material)
end

---@param x number
---@param z number
---@return number|nil fillTypeIndex
---@return number material
function FieldAdvisor.measureHeightFillTypeAtPoint(x, z)
    local material = FieldAdvisor.measureHeightMaterialAtPoint(x, z)
    local planeId = FieldAdvisor.getHeightDetailPlaneId()
    if planeId == nil or getDensityTypeIndexAtWorldPos == nil then
        return nil, material
    end

    local y = FieldAdvisor.getTerrainSampleY(x, z)
    local ok, fillTypeIndex = pcall(getDensityTypeIndexAtWorldPos, planeId, x, y, z)
    local idx = ok and tonumber(fillTypeIndex) or nil
    if idx ~= nil and idx > 0 then
        return idx, material
    end

    return nil, material
end

---@param fillTypes table
---@return table
function FieldAdvisor.buildWindrowFillTypeSet(fillTypes)
    local set = {}
    for _, fillTypeIndex in ipairs(fillTypes) do
        fillTypeIndex = tonumber(fillTypeIndex)
        if fillTypeIndex ~= nil and fillTypeIndex > 0 then
            set[fillTypeIndex] = true
        end
    end
    return set
end

---@param fillTypeIndex number|nil
---@param windrowSet table
---@return boolean
function FieldAdvisor.isKnownWindrowFillType(fillTypeIndex, windrowSet)
    fillTypeIndex = tonumber(fillTypeIndex)
    if fillTypeIndex == nil or fillTypeIndex <= 0 or windrowSet == nil then
        return false
    end
    return windrowSet[fillTypeIndex] == true
end

--- Fuse cross-scan + map signals into loose / swath / baled / none.
--- Never default to loose without positive material evidence.
---@param scan table
---@param baleSummary table|nil
---@return table summary
function FieldAdvisor.fuseGrassResidueSignals(scan, baleSummary)
    local summary = {
        total = scan.total or 0,
        occupied = scan.occupied or 0,
        occupiedRatio = 0,
        totalLiters = scan.totalLiters or 0,
        avgOccupiedLiters = 0,
        maxSampleLiters = scan.maxSampleLiters or 0,
        maxSampleMaterial = scan.maxSampleMaterial or 0,
        swathHits = scan.swathHits or 0,
        windrowTypeHits = scan.windrowTypeHits or 0,
        crossScanPoints = scan.crossScanPoints or 0,
        fillTypeCount = scan.fillTypeCount or 0,
        signalShred = scan.signalShred or 0,
        crossLineTransitions = scan.crossLineTransitions or 0,
        crossLineTransitionsEw = scan.crossLineTransitionsEw or 0,
        crossLineTransitionsNs = scan.crossLineTransitionsNs or 0,
        centerMaterial = scan.centerMaterial or 0,
        residueState = FieldAdvisor.GRASS_RESIDUE_NONE,
        residueAvailable = scan.residueAvailable == true,
        residueSource = scan.residueSource or "none",
    }

    if not summary.residueAvailable or summary.total <= 0 then
        summary.fieldBaleCount = FieldAdvisor.getFieldBaleCount(baleSummary)
        return FieldAdvisor.applyFieldBaleResidueOverlay(summary, baleSummary)
    end

    summary.occupiedRatio = summary.occupied / summary.total
    if summary.occupied > 0 then
        summary.avgOccupiedLiters = summary.totalLiters / summary.occupied
    end

    local minValid = scan.minValid or 0.02
    local swathThreshold = scan.swathHitThreshold or math.max(0.001, minValid * 0.12)
    local materialMin = FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN
    local maxShred = summary.signalShred

    local hasMaterial = summary.maxSampleLiters >= swathThreshold
        or summary.maxSampleMaterial >= materialMin

    if FieldAdvisor.isGrassWindrowPileRemnant(summary) then
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
        summary.residueAvailable = false
        return FieldAdvisor.applyFieldBaleResidueOverlay(summary, baleSummary)
    end

    if FieldAdvisor.hasGrassWindrowLineEvidence(summary) then
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
        return FieldAdvisor.applyFieldBaleResidueOverlay(summary, baleSummary)
    end

    if maxShred > 0 and not hasMaterial then
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
        return FieldAdvisor.applyFieldBaleResidueOverlay(summary, baleSummary)
    end

    if not hasMaterial then
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
        return FieldAdvisor.applyFieldBaleResidueOverlay(summary, baleSummary)
    end

    local densePile = summary.occupiedRatio >= 0.28
        and summary.avgOccupiedLiters >= (minValid * FieldAdvisor.GRASS_SWATH_DENSITY_MULTIPLIER)

    if densePile or summary.occupiedRatio >= 0.55 then
        if FieldAdvisor.isUniformCutFieldIdleResidue(summary) then
            summary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
            summary.residueAvailable = false
        else
            summary.residueState = FieldAdvisor.GRASS_RESIDUE_LOOSE
        end
        return FieldAdvisor.applyFieldBaleResidueOverlay(summary, baleSummary)
    end

    if hasMaterial and summary.occupiedRatio <= FieldAdvisor.GRASS_SWATH_OCCUPANCY_MAX then
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_LOOSE
        return FieldAdvisor.applyFieldBaleResidueOverlay(summary, baleSummary)
    end

    summary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
    return FieldAdvisor.applyFieldBaleResidueOverlay(summary, baleSummary)
end

--- Uniform full-field engine-height read after cut/bale — stubble noise, not loose grass to swath.
--- Fresh mow keeps centerMaterial low; post-logistics idle reads high on every cross point.
---@param summary table|nil
---@return boolean
function FieldAdvisor.isUniformCutFieldIdleResidue(summary)
    if summary == nil or summary.residueAvailable ~= true then
        return false
    end

    if summary.residueSource == "height_util" then
        return false
    end

    local swathHits = tonumber(summary.swathHits) or 0
    local windrowHits = tonumber(summary.windrowTypeHits) or 0
    if swathHits > 0 or windrowHits > 0 then
        return false
    end

    if FieldAdvisor.hasGrassWindrowLineEvidence(summary) then
        return false
    end

    local occupiedRatio = tonumber(summary.occupiedRatio) or 0
    if occupiedRatio < 0.55 then
        return false
    end

    local centerMaterial = tonumber(summary.centerMaterial) or 0
    if centerMaterial < FieldAdvisor.GRASS_WINDROW_CENTER_MATERIAL_MIN then
        return false
    end

    return true
end

--- Still windrow material on field (partial baling: swaths + some bales).
---@param summary table|nil
---@return boolean
function FieldAdvisor.hasGrassSwathMaterialRemaining(summary)
    if summary == nil then
        return false
    end

    local swathHits = tonumber(summary.swathHits) or 0
    local windrowTypeHits = tonumber(summary.windrowTypeHits) or 0
    local occupiedRatio = tonumber(summary.occupiedRatio) or 0
    local fieldBaleCount = tonumber(summary.fieldBaleCount) or 0
    local state = summary.residueState or FieldAdvisor.GRASS_RESIDUE_NONE

    -- Uniform full-field height read after baling: no pressable swaths left.
    if swathHits == 0 and windrowTypeHits == 0 and occupiedRatio >= 0.55 then
        if fieldBaleCount > 0 or state == FieldAdvisor.GRASS_RESIDUE_BALED then
            return false
        end
        return state == FieldAdvisor.GRASS_RESIDUE_LOOSE
    end

    if FieldAdvisor.hasGrassWindrowLineEvidence(summary) then
        return true
    end

    if state == FieldAdvisor.GRASS_RESIDUE_LOOSE then
        return true
    end

    local maxMaterial = tonumber(summary.maxSampleMaterial) or 0
    local maxLiters = tonumber(summary.maxSampleLiters) or 0

    if state == FieldAdvisor.GRASS_RESIDUE_SWATH then
        if swathHits > 0 or windrowTypeHits > 0 then
            return maxMaterial >= FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN
                or maxLiters > 0.025
        end
        return occupiedRatio < 0.55
            and (maxMaterial >= FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN or maxLiters > 0.025)
    end

    return false
end

--- Ballen/Silageballen erledigt: Schwaden weg, nicht schon beim ersten Ballen.
---@param summary table|nil
---@param baleSummary table|nil
---@param baseline table|nil
---@return boolean
function FieldAdvisor.isGrassBalingWorkComplete(summary, baleSummary, baseline)
    if FieldAdvisor.hasGrassSwathMaterialRemaining(summary) then
        return false
    end

    local baleCount = FieldAdvisor.getFieldBaleCount(baleSummary)
    local baselineBales = baseline ~= nil and tonumber(baseline.baleCount) or 0

    if baleCount > baselineBales then
        return true
    end

    if summary ~= nil and summary.residueState == FieldAdvisor.GRASS_RESIDUE_BALED then
        return true
    end

    if baseline ~= nil and baseline.grassResidueState == FieldAdvisor.GRASS_RESIDUE_SWATH then
        return FieldAdvisor.isGrassCollectEffectivelyDone(summary, baseline)
    end

    return false
end

--- Merge field-local bale count into residue summary without skipping swath scan.
---@param summary table
---@param baleSummary table|nil
---@return table
function FieldAdvisor.applyFieldBaleResidueOverlay(summary, baleSummary)
    local fieldBaleCount = FieldAdvisor.getFieldBaleCount(baleSummary)
    summary.fieldBaleCount = fieldBaleCount

    if fieldBaleCount <= 0 then
        return summary
    end

    summary.residueAvailable = true
    if FieldAdvisor.hasGrassSwathMaterialRemaining(summary) then
        if summary.residueState == FieldAdvisor.GRASS_RESIDUE_NONE
            or summary.residueState == FieldAdvisor.GRASS_RESIDUE_BALED then
            summary.residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
        end
    else
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_BALED
        summary.residueSource = "bales"
    end

    return summary
end

--- Tiny heaps at field border (< few cross points): not collectable swath lines.
---@param summary table|nil
---@return boolean
function FieldAdvisor.isGrassWindrowPileRemnant(summary)
    if summary == nil or summary.residueAvailable ~= true then
        return false
    end

    local occupiedRatio = tonumber(summary.occupiedRatio) or 0
    local occupied = tonumber(summary.occupied) or 0
    local total = tonumber(summary.total) or 0
    local lineHits = (summary.swathHits or 0) + (summary.windrowTypeHits or 0)

    if occupiedRatio > 0 and occupiedRatio <= FieldAdvisor.GRASS_WINDROW_PILE_RATIO_MAX then
        return true
    end

    if total > 0 and occupied <= 2 and lineHits <= 2 then
        return true
    end

    if lineHits <= 1 and occupiedRatio <= 0.08 then
        return true
    end

    return false
end

--- Schwaden = windrow lines on the cross (multiple aligned hits), not isolated piles.
---@param summary table|nil
---@return boolean
function FieldAdvisor.hasGrassWindrowLineEvidence(summary)
    if summary == nil or summary.residueAvailable ~= true then
        return false
    end

    if FieldAdvisor.isGrassWindrowPileRemnant(summary) then
        return false
    end

    local occupiedRatio = tonumber(summary.occupiedRatio) or 0
    local swathHits = tonumber(summary.swathHits) or 0
    local windrowTypeHits = tonumber(summary.windrowTypeHits) or 0
    local maxMaterial = tonumber(summary.maxSampleMaterial) or 0

    if windrowTypeHits >= 2 then
        return true
    end

    if windrowTypeHits >= 1 and swathHits >= FieldAdvisor.GRASS_WINDROW_LINE_MIN_SWATH_HITS then
        return true
    end

    if swathHits >= FieldAdvisor.GRASS_WINDROW_LINE_MIN_SWATH_HITS
        and occupiedRatio > FieldAdvisor.GRASS_WINDROW_PILE_RATIO_MAX
        and occupiedRatio <= FieldAdvisor.GRASS_SWATH_OCCUPANCY_MAX then
        return true
    end

    if swathHits >= 3 and occupiedRatio <= 0.35 then
        return true
    end

    if (summary.crossLineTransitions or 0) >= FieldAdvisor.GRASS_WINDROW_CROSS_LINE_MIN_TRANSITIONS then
        return true
    end

    -- Engine-height fallback: narrow swath lines only — not uniform full-field cut grass (ratio ~1).
    if summary.residueSource ~= "height_util"
        and occupiedRatio >= 0.35
        and occupiedRatio <= FieldAdvisor.GRASS_SWATH_OCCUPANCY_MAX
        and maxMaterial >= FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN
        and maxMaterial < FieldAdvisor.GRASS_WINDROW_POST_COLLECT_MATERIAL_MIN
        and (summary.windrowTypeHits or 0) == 0
        and swathHits == 0 then
        local centerMaterial = tonumber(summary.centerMaterial) or 0
        if (summary.crossLineTransitions or 0) >= FieldAdvisor.GRASS_WINDROW_CROSS_LINE_MIN_TRANSITIONS
            or centerMaterial >= FieldAdvisor.GRASS_WINDROW_CENTER_MATERIAL_MIN then
            return true
        end
    end

    return false
end

--- Schwaden erledigt = echte Windrow-Linien (nicht nur state=swath / lose Mähgut-Fläche).
---@param summary table|nil
---@return boolean
function FieldAdvisor.isGrassSwathWorkComplete(summary)
    if summary == nil or summary.residueAvailable ~= true then
        return false
    end

    local state = summary.residueState or FieldAdvisor.GRASS_RESIDUE_NONE
    if state == FieldAdvisor.GRASS_RESIDUE_BALED
        and not FieldAdvisor.hasGrassSwathMaterialRemaining(summary) then
        return true
    end

    return FieldAdvisor.hasGrassWindrowLineEvidence(summary)
end

--- Heu/Ladewagen: main field collected; tiny edge windrows (road, foreign land) count as done.
---@param summary table|nil
---@param baseline table|nil task completionBaseline
---@return boolean
function FieldAdvisor.isGrassCollectEffectivelyDone(summary, baseline)
    if summary == nil then
        return true
    end

    if summary.residueAvailable ~= true then
        return true
    end

    local state = summary.residueState or FieldAdvisor.GRASS_RESIDUE_NONE
    if state == FieldAdvisor.GRASS_RESIDUE_NONE then
        return true
    end

    if state == FieldAdvisor.GRASS_RESIDUE_BALED then
        return FieldAdvisor.getFieldBaleCount(summary) <= 0
    end

    local maxMaterial = tonumber(summary.maxSampleMaterial) or 0
    local centerMaterial = tonumber(summary.centerMaterial) or 0

    if not FieldAdvisor.hasGrassWindrowLineEvidence(summary) then
        if FieldAdvisor.isUniformCutFieldIdleResidue(summary) then
            return true
        end

        -- Mähen → Schwaden legen: loose cut grass is not "collect done".
        if state == FieldAdvisor.GRASS_RESIDUE_LOOSE then
            if maxMaterial >= FieldAdvisor.GRASS_WINDROW_POST_COLLECT_MATERIAL_MIN then
                return true
            end
            return false
        end

        if maxMaterial >= FieldAdvisor.GRASS_WINDROW_POST_COLLECT_MATERIAL_MIN then
            return true
        end

        -- False SWATH from uniform stubble height: still need Schwaden legen.
        if state == FieldAdvisor.GRASS_RESIDUE_SWATH
            and centerMaterial < FieldAdvisor.GRASS_WINDROW_CENTER_MATERIAL_MIN then
            return false
        end

        return true
    end

    local windrowHits = (summary.swathHits or 0) + (summary.windrowTypeHits or 0)
    local maxLiters = tonumber(summary.maxSampleLiters) or 0
    if windrowHits == 0 and maxLiters <= 0.025
        and maxMaterial <= FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN * 2 then
        return true
    end

    local occupiedRatio = tonumber(summary.occupiedRatio) or 0
    if occupiedRatio <= FieldAdvisor.GRASS_COLLECT_REMNANT_RATIO_MAX then
        if state == FieldAdvisor.GRASS_RESIDUE_LOOSE then
            local maxLiters = tonumber(summary.maxSampleLiters) or 0
            return maxLiters <= 0.08
        end
        return true
    end

    if baseline ~= nil then
        local baselineState = baseline.grassResidueState
        local baselineRatio = tonumber(baseline.grassResidueOccupiedRatio) or 0
        if baselineState == FieldAdvisor.GRASS_RESIDUE_SWATH and baselineRatio >= 0.35 then
            if occupiedRatio <= FieldAdvisor.GRASS_COLLECT_BASELINE_RATIO_MAX then
                return true
            end
            if baselineRatio - occupiedRatio >= FieldAdvisor.GRASS_COLLECT_BASELINE_DROP_MIN then
                return true
            end
            if baselineRatio > 0.05 and occupiedRatio / baselineRatio <= 0.18 then
                return true
            end
        end
    end

    return false
end

--- Upgrade loose/none residue when cross-scan or shred signals indicate lying swaths.
---@param summary table|nil
---@param aggregation table|nil
---@param probeState table|nil
---@param field table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param grassFruitHint number|nil
---@return table
function FieldAdvisor.refineGrassResidueSummary(summary, aggregation, probeState, field, worldX, worldZ, grassFruitHint)
    if summary == nil then
        summary = {
            residueState = FieldAdvisor.GRASS_RESIDUE_NONE,
            residueAvailable = false,
        }
    end

    if summary.residueState == FieldAdvisor.GRASS_RESIDUE_BALED then
        return summary
    end

    local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)
    if FieldAdvisor.isGrassStandingCropPhase(meadowPhase, probeState, field, grassFruitHint)
        and not FieldAdvisor.fieldHasPostMowGrassSignal(aggregation, probeState, field, grassFruitHint) then
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
        summary.residueAvailable = false
        return summary
    end

    local shredLevel = FieldAdvisor.getStateNumber(probeState, "stubbleShredLevel")
    if aggregation ~= nil then
        shredLevel = math.max(shredLevel, tonumber(aggregation.maxStubbleShredLevel) or 0)
    end

    local occupiedRatio = tonumber(summary.occupiedRatio) or 0
    local maxLiters = tonumber(summary.maxSampleLiters) or 0
    local maxMaterial = tonumber(summary.maxSampleMaterial) or 0
    local swathHits = tonumber(summary.swathHits) or 0
    local windrowHits = tonumber(summary.windrowTypeHits) or 0

    local function looksLikeLyingSwath()
        if swathHits >= 1 or windrowHits >= 1 then
            return true
        end
        if maxLiters > 0.025 and occupiedRatio <= FieldAdvisor.GRASS_SWATH_OCCUPANCY_MAX then
            return true
        end
        if maxMaterial >= FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN
            and occupiedRatio <= FieldAdvisor.GRASS_SWATH_OCCUPANCY_HARD_MAX then
            return true
        end
        return false
    end

    if summary.residueState == FieldAdvisor.GRASS_RESIDUE_LOOSE then
        local postMow = FieldAdvisor.isGrassPostMowState(probeState, field, grassFruitHint)
            or shredLevel > 0
            or FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(probeState))
        if looksLikeLyingSwath() then
            summary.residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
            summary.residueAvailable = true
            return summary
        end
        if field == nil or worldX == nil or worldZ == nil then
            worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
        end
        if postMow and field ~= nil and worldX ~= nil and worldZ ~= nil then
            local hits, crossLiters, crossMaterial = FieldAdvisor.countGrassWindrowMaterialHits(
                field, worldX, worldZ, FieldAdvisor.GRASS_RESIDUE_CROSS_STEPS, grassFruitHint
            )
            summary.maxSampleLiters = math.max(maxLiters, crossLiters)
            summary.maxSampleMaterial = math.max(maxMaterial, crossMaterial)
            if FieldAdvisor.hasGrassWindrowLineEvidence(summary) then
                summary.residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
                summary.residueAvailable = true
                return summary
            end
        end
        return summary
    end

    if summary.residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE then
        return summary
    end

    if field == nil or worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end
    if field == nil or worldX == nil or worldZ == nil then
        return summary
    end

    local postMow = FieldAdvisor.isGrassPostMowState(probeState, field, grassFruitHint)
        or shredLevel > 0
        or FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(probeState))
    if not postMow and grassFruitHint ~= nil then
        local lastGrowth = FieldAdvisor.getLastGrowthState(probeState)
        if lastGrowth > 0 then
            local lastFlags = FieldAdvisor.evaluateFruitGrowth(grassFruitHint, lastGrowth)
            postMow = lastFlags.isCut == true
        end
    end
    if not postMow then
        return summary
    end

    local crossMaterial, crossLiters = FieldAdvisor.scanCrossForMaxGrassMaterial(
        field,
        worldX,
        worldZ,
        FieldAdvisor.GRASS_RESIDUE_CROSS_STEPS,
        grassFruitHint
    )
    if crossLiters <= 0.012 and crossMaterial < FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN then
        return summary
    end

    summary.residueAvailable = true
    summary.maxSampleLiters = math.max(maxLiters, crossLiters)
    summary.maxSampleMaterial = math.max(maxMaterial, crossMaterial)
    if summary.total == nil or summary.total <= 0 then
        summary.total = 1
    end
    summary.occupiedRatio = summary.occupiedRatio or 0

    if FieldAdvisor.hasGrassWindrowLineEvidence(summary) then
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
    elseif crossLiters > 0.04 and crossMaterial >= FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN then
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_LOOSE
    else
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
        summary.residueAvailable = false
    end

    return summary
end

--- Multi-signal grass residue detector (cross + diagonals, windrow liters, engine height/fill-type).
---@param field table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param maxPoints number|nil
---@param prioritizedFruitTypeIndex number|nil
---@param baleSummary table|nil
---@param aggregation table|nil
---@return table summary
function FieldAdvisor.detectGrassResidue(field, worldX, worldZ, maxPoints, prioritizedFruitTypeIndex, baleSummary, aggregation)
    local empty = {
        total = 0,
        occupied = 0,
        occupiedRatio = 0,
        totalLiters = 0,
        residueState = FieldAdvisor.GRASS_RESIDUE_NONE,
        residueAvailable = false,
    }

    if field == nil then
        return empty
    end

    if aggregation ~= nil and aggregation.centerState ~= nil then
        local centerState = aggregation.centerState
        local centerMeadowPhase = FieldAdvisor.getGrassMeadowPhase(centerState, field, aggregation)
        local centerGrassHint = FieldAdvisor.getFruitTypeIndex(centerState)
        if centerMeadowPhase == "harvestable"
            and FieldAdvisor.isGrassStandingCropPhase(
                centerMeadowPhase, centerState, field, centerGrassHint)
            and not FieldAdvisor.fieldHasPostMowGrassSignal(aggregation, centerState, field, centerGrassHint) then
            return empty
        end
    end

    if worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end
    if worldX == nil or worldZ == nil then
        return empty
    end

    local fillTypes = FieldAdvisor.collectWindrowFillTypeIndices(prioritizedFruitTypeIndex)
    if #fillTypes == 0 then
        return empty
    end

    local heightUtil = FieldAdvisor.resolveDensityMapHeightUtil()
    local engineHeightAvailable = FieldAdvisor.getHeightDetailPlaneId() ~= nil
        and getDensityHeightAtWorldPos ~= nil
    local engineFillTypeAvailable = engineHeightAvailable
        and getDensityTypeIndexAtWorldPos ~= nil
    if heightUtil == nil and not engineHeightAvailable then
        return empty
    end

    local crossSteps = FieldAdvisor.GRASS_RESIDUE_CROSS_STEPS
    if (tonumber(maxPoints) or FieldAdvisor.GRASS_RESIDUE_MAX_SAMPLE_POINTS)
        <= FieldAdvisor.GRASS_RESIDUE_IDLE_SAMPLE_POINTS then
        crossSteps = FieldAdvisor.GRASS_RESIDUE_IDLE_CROSS_STEPS
    end

    local points = FieldAdvisor.collectGrassResidueSamplePoints(field, worldX, worldZ, crossSteps)
    local crossEw, crossNs, crossMax = FieldAdvisor.measureGrassCrossAxisLineTransitions(
        field, worldX, worldZ, crossSteps
    )
    local centerMaterial = FieldAdvisor.measureHeightMaterialAtPoint(worldX, worldZ)
    points = FieldAdvisor.reduceGrassResidueSamplePoints(
        points,
        tonumber(maxPoints) or FieldAdvisor.GRASS_RESIDUE_MAX_SAMPLE_POINTS
    )

    local minValid = 0.5
    for _, fillTypeIndex in ipairs(fillTypes) do
        minValid = math.min(minValid, FieldAdvisor.getMinValidHeightLiters(fillTypeIndex))
    end

    local residueSource = "engine_height"
    if heightUtil ~= nil then
        residueSource = "height_util"
    elseif engineFillTypeAvailable then
        residueSource = "engine_filltype"
    end

    local swathHitThreshold = math.max(0.001, minValid * 0.12)
    local occupancyThreshold = math.max(0.001, minValid * 0.30)
    if residueSource ~= "height_util" then
        swathHitThreshold = math.max(FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN, 0.015)
        occupancyThreshold = 0.04
        minValid = 0.02
    end

    local windrowSet = FieldAdvisor.buildWindrowFillTypeSet(fillTypes)
    local halfSize = FieldAdvisor.GRASS_RESIDUE_SAMPLE_HALF_SIZE
    local centerHalfSize = halfSize * 1.5
    local probeState = aggregation ~= nil and aggregation.centerState or nil
    local signalShred = FieldAdvisor.getStateNumber(probeState, "stubbleShredLevel")
    if aggregation ~= nil and aggregation.maxStubbleShredLevel ~= nil then
        signalShred = math.max(signalShred, tonumber(aggregation.maxStubbleShredLevel) or 0)
    end

    local scan = {
        total = 0,
        occupied = 0,
        totalLiters = 0,
        maxSampleLiters = 0,
        maxSampleMaterial = 0,
        swathHits = 0,
        windrowTypeHits = 0,
        crossScanPoints = #points,
        fillTypeCount = #fillTypes,
        residueAvailable = true,
        residueSource = residueSource,
        minValid = minValid,
        swathHitThreshold = swathHitThreshold,
        occupancyThreshold = occupancyThreshold,
        signalShred = signalShred,
        crossLineTransitions = crossMax,
        crossLineTransitionsEw = crossEw,
        crossLineTransitionsNs = crossNs,
        centerMaterial = centerMaterial,
    }

    for index, point in ipairs(points) do
        if FieldAdvisor.isPositionInsideFieldOrUnknown(field, point.x, point.z) then
            scan.total = scan.total + 1
            local sampleHalfSize = (index == 1) and centerHalfSize or halfSize
            local sampleLiters = FieldAdvisor.measureWindrowLitersAtPoint(point, fillTypes, sampleHalfSize)
            local fillTypeAtPoint, material = FieldAdvisor.measureHeightFillTypeAtPoint(point.x, point.z)
            local actualLiters = 0
            for _, fillTypeIndex in ipairs(fillTypes) do
                actualLiters = math.max(
                    actualLiters,
                    FieldAdvisor.measureFillLevelAtArea(
                        fillTypeIndex,
                        point.x - sampleHalfSize,
                        point.z - sampleHalfSize,
                        point.x + sampleHalfSize,
                        point.z - sampleHalfSize,
                        point.x - sampleHalfSize,
                        point.z + sampleHalfSize
                    )
                )
            end

            scan.maxSampleLiters = math.max(scan.maxSampleLiters, sampleLiters)
            scan.maxSampleMaterial = math.max(scan.maxSampleMaterial, material)
            scan.totalLiters = scan.totalLiters + sampleLiters

            if FieldAdvisor.isKnownWindrowFillType(fillTypeAtPoint, windrowSet)
                and material >= FieldAdvisor.GRASS_RESIDUE_ENGINE_MATERIAL_MIN then
                scan.windrowTypeHits = scan.windrowTypeHits + 1
            end

            if sampleLiters >= occupancyThreshold then
                scan.occupied = scan.occupied + 1
            end

            -- Line hits: real windrow fill only (not cut-grass height material on every cross point).
            if actualLiters >= swathHitThreshold then
                scan.swathHits = scan.swathHits + 1
            elseif FieldAdvisor.isKnownWindrowFillType(fillTypeAtPoint, windrowSet)
                and actualLiters >= swathHitThreshold * 0.5 then
                scan.swathHits = scan.swathHits + 1
            end
        end
    end

    return FieldAdvisor.fuseGrassResidueSignals(scan, baleSummary)
end

---@param fillTypeIndex number
---@param x0 number
---@param z0 number
---@param x1 number
---@param z1 number
---@param x2 number
---@param z2 number
---@return number
function FieldAdvisor.measureFillLevelAtArea(fillTypeIndex, x0, z0, x1, z1, x2, z2)
    return FieldAdvisor.callFillLevelAtArea(fillTypeIndex, x0, z0, x1, z1, x2, z2)
end

---@param point table
---@param fillTypes table
---@param sampleHalfSize number
---@return number
function FieldAdvisor.measureWindrowLitersAtPoint(point, fillTypes, sampleHalfSize)
    local sampleLiters = 0
    local x0 = point.x - sampleHalfSize
    local z0 = point.z - sampleHalfSize
    local x1 = point.x + sampleHalfSize
    local z1 = point.z - sampleHalfSize
    local x2 = point.x - sampleHalfSize
    local z2 = point.z + sampleHalfSize

    for _, fillTypeIndex in ipairs(fillTypes) do
        sampleLiters = math.max(
            sampleLiters,
            FieldAdvisor.measureFillLevelAtArea(fillTypeIndex, x0, z0, x1, z1, x2, z2)
        )
    end

    if sampleLiters > 0.001 then
        return sampleLiters
    end

    local offsets = {
        { 0, 0 },
        { sampleHalfSize, 0 },
        { -sampleHalfSize, 0 },
        { 0, sampleHalfSize },
        { 0, -sampleHalfSize },
    }
    local maxMaterial = 0
    for _, offset in ipairs(offsets) do
        maxMaterial = math.max(
            maxMaterial,
            FieldAdvisor.measureHeightMaterialAtPoint(point.x + offset[1], point.z + offset[2])
        )
    end

    if maxMaterial <= 0.001 then
        return 0
    end

    local litersPerMeter = 2500
    if g_densityMapHeightManager ~= nil and g_densityMapHeightManager.getLitersFromHeight ~= nil then
        local ok, liters = pcall(g_densityMapHeightManager.getLitersFromHeight, g_densityMapHeightManager, maxMaterial)
        liters = ok and tonumber(liters) or nil
        if liters ~= nil and liters > 0 then
            return liters
        end
    end

    return maxMaterial * litersPerMeter
end

--- Cached wrapper around detectGrassResidue.
---@param field table|nil
---@param fieldId number|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param cacheTtlMs number|nil
---@param maxPoints number|nil
---@param prioritizedFruitTypeIndex number|nil
---@param baleSummary table|nil
---@param aggregation table|nil
---@return table summary
function FieldAdvisor.sampleGrassResidueCoverage(field, fieldId, worldX, worldZ, cacheTtlMs, maxPoints, prioritizedFruitTypeIndex, baleSummary, aggregation, allowNoneCache)
    local ttl = tonumber(cacheTtlMs) or FieldAdvisor.GRASS_RESIDUE_CACHE_TTL_ACTIVE_MS
    local cached = FieldAdvisor.getCoverageCache(fieldId, "grassResidue", ttl)
    if cached ~= nil then
        if cached.residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE or allowNoneCache == true then
            return cached
        end
    end

    local summary = FieldAdvisor.detectGrassResidue(
        field,
        worldX,
        worldZ,
        maxPoints,
        prioritizedFruitTypeIndex,
        baleSummary,
        aggregation
    )

    FieldAdvisor.setCoverageCache(fieldId, "grassResidue", summary)
    return summary
end

---@param node any
---@return number|nil, number|nil
function FieldAdvisor.getNodeWorldXZ(node)
    if node == nil or node == 0 or getWorldTranslation == nil then
        return nil, nil
    end

    local ok, x, _, z = pcall(getWorldTranslation, node)
    if ok and x ~= nil and z ~= nil then
        return x, z
    end

    return nil, nil
end

---@param bale any
---@return boolean
function FieldAdvisor.isSpawnedBaleObject(bale)
    if bale == nil then
        return false
    end

    local nodeId = tonumber(bale.nodeId)
    if nodeId ~= nil and nodeId ~= 0 then
        if entityExists ~= nil then
            local ok, exists = pcall(entityExists, nodeId)
            if ok and exists == true then
                return true
            end
        else
            return true
        end
    end

    if bale.isa ~= nil and Bale ~= nil then
        local ok, isBale = pcall(bale.isa, bale, Bale)
        if ok and isBale == true then
            return nodeId ~= nil and nodeId ~= 0
        end
    end

    return false
end

--- World bales from slot system (g_baleManager.bales is only the type catalog).
---@return table[]
function FieldAdvisor.collectMapBaleObjects()
    local result = {}
    local seen = {}

    local function addBale(bale)
        if not FieldAdvisor.isSpawnedBaleObject(bale) then
            return
        end

        local key = tonumber(bale.id) or tonumber(bale.nodeId) or bale
        if seen[key] == true then
            return
        end
        seen[key] = true
        result[#result + 1] = bale
    end

    if g_currentMission == nil or g_currentMission.slotSystem == nil then
        return result
    end

    local limits = g_currentMission.slotSystem.objectLimits
    if limits == nil then
        return result
    end

    local baleLimit = SlotSystem ~= nil and SlotSystem.LIMITED_OBJECT_BALE or nil
    if baleLimit == nil then
        return result
    end

    local slot = limits[baleLimit]
    local objects = slot ~= nil and slot.objects or nil
    if objects ~= nil then
        for _, bale in pairs(objects) do
            addBale(bale)
        end
    end

    return result
end

---@param bale any
---@return number|nil, number|nil
function FieldAdvisor.getBaleWorldPosition(bale)
    if bale == nil then
        return nil, nil
    end

    local nodeId = tonumber(bale.nodeId)
    if nodeId ~= nil and nodeId ~= 0 and getWorldTranslation ~= nil then
        local ok, x, _, z = pcall(getWorldTranslation, nodeId)
        if ok and x ~= nil and z ~= nil then
            return x, z
        end
    end

    if nodeId ~= nil and nodeId ~= 0 then
        local x, z = FieldAdvisor.getNodeWorldXZ(nodeId)
        if x ~= nil then
            return x, z
        end
    end

    if bale.getInteractionPosition ~= nil then
        local ok, x, _, z = pcall(bale.getInteractionPosition, bale)
        if ok and x ~= nil and z ~= nil then
            return x, z
        end
    end

    local nodeCandidates = {
        bale.node,
        bale.rootNode,
        bale.nodeObject,
        bale.meshNode,
        bale.baleNode,
    }

    if bale.getNodeId ~= nil then
        local ok, node = pcall(bale.getNodeId, bale)
        if ok then
            nodeCandidates[#nodeCandidates + 1] = node
        end
    end

    for _, node in ipairs(nodeCandidates) do
        local x, z = FieldAdvisor.getNodeWorldXZ(node)
        if x ~= nil then
            return x, z
        end
    end

    if bale.getPosition ~= nil then
        local ok, x, _, z = pcall(bale.getPosition, bale)
        if ok and x ~= nil and z ~= nil then
            return x, z
        end
    end

    if bale.getWorldPosition ~= nil then
        local ok, x, _, z = pcall(bale.getWorldPosition, bale)
        if ok and x ~= nil and z ~= nil then
            return x, z
        end
    end

    return nil, nil
end

--- Tight field bounds for bale assignment (never uses unknown=inside extent walks).
---@param field table|nil
---@param centerX number|nil
---@param centerZ number|nil
---@return number halfX, number halfZ
function FieldAdvisor.getFieldBaleAssignmentHalfExtents(field, centerX, centerZ)
    if field == nil or centerX == nil or centerZ == nil then
        return 0, 0
    end

    local extentX = 0
    local extentZ = 0
    local step = 3
    for dist = step, 160, step do
        if FieldAdvisor.isPositionInsideField(field, centerX + dist, centerZ) then
            extentX = dist
        else
            break
        end
    end
    for dist = step, 160, step do
        if FieldAdvisor.isPositionInsideField(field, centerX - dist, centerZ) then
            extentX = math.max(extentX, dist)
        else
            break
        end
    end
    for dist = step, 160, step do
        if FieldAdvisor.isPositionInsideField(field, centerX, centerZ + dist) then
            extentZ = dist
        else
            break
        end
    end
    for dist = step, 160, step do
        if FieldAdvisor.isPositionInsideField(field, centerX, centerZ - dist) then
            extentZ = math.max(extentZ, dist)
        else
            break
        end
    end

    if extentX > 0 and extentZ > 0 then
        return extentX + 1, extentZ + 1
    end

    extentX = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 1, 0)
    extentZ = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 0, 1)
    if extentX > 0 and extentZ > 0 then
        return extentX + 2, extentZ + 2
    end

    local areaHa = tonumber(field.areaHa) or 0
    if areaHa <= 0 then
        return 0, 0
    end

    local sideM = math.sqrt(areaHa * 10000)
    local half = sideM * 0.48
    return half, half
end

--- Field-local bale test: engine field id, strict polygon, then tight area bounds only.
---@param field table|nil
---@param x number|nil
---@param z number|nil
---@param centerX number|nil
---@param centerZ number|nil
---@return boolean
function FieldAdvisor.isBalePositionInsideField(field, x, z, centerX, centerZ)
    if field == nil or x == nil or z == nil then
        return false
    end

    local targetFieldId = field.getId ~= nil and tonumber(field:getId()) or nil
    local baleFieldId = FieldAdvisor.resolveEngineFieldIdAtWorldPosition(x, z)
    if baleFieldId ~= nil and targetFieldId ~= nil then
        return baleFieldId == targetFieldId
    end

    local inside = FieldAdvisor.testPositionInsideField(field, x, z)
    if inside == true then
        return true
    end

    if centerX == nil or centerZ == nil then
        centerX, centerZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end
    if centerX == nil or centerZ == nil then
        return false
    end

    local halfX, halfZ = FieldAdvisor.getFieldBaleAssignmentHalfExtents(field, centerX, centerZ)
    if halfX <= 0 or halfZ <= 0 then
        return false
    end

    return math.abs(x - centerX) <= halfX
        and math.abs(z - centerZ) <= halfZ
end

---@param baleSummary table|nil
---@return number
function FieldAdvisor.getFieldBaleCount(baleSummary)
    if baleSummary == nil then
        return 0
    end

    if baleSummary.total ~= nil then
        return tonumber(baleSummary.total) or 0
    end

    return tonumber(baleSummary.fieldBaleCount) or 0
end

---@param field table|nil
---@param cacheTtlMs number|nil
---@return table summary
function FieldAdvisor.sampleBaleCoverage(field, cacheTtlMs)
    local fieldId = field ~= nil and field.getId ~= nil and field:getId() or nil

    local summary = {
        total = 0,
    }

    if field == nil then
        return summary
    end

    local centerX, centerZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    local bales = FieldAdvisor.collectMapBaleObjects()

    for _, bale in ipairs(bales) do
        local x, z = FieldAdvisor.getBaleWorldPosition(bale)
        if x ~= nil and z ~= nil
            and FieldAdvisor.isBalePositionInsideField(field, x, z, centerX, centerZ) then
            summary.total = summary.total + 1
        end
    end

    FieldAdvisor.setCoverageCache(fieldId, "bales", summary)
    return summary
end

---@param fieldState table|nil
---@param rules table
---@param weedSummary table|nil
---@return string
function FieldAdvisor.formatWeedDisplayLabel(fieldState, rules, weedSummary)
    if not rules.weedsEnabled then
        return FieldAdvisor.formatWeedLabel(FieldAdvisor.getWeedStateLevel(fieldState), rules)
    end

    if FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary) then
        return FieldAdvisor.text("ftdl_weed_dead", "tot")
    end

    if weedSummary ~= nil and (weedSummary.total or 0) > 0 then
        local classified = weedSummary.classified
            or ((weedSummary.live or 0) + (weedSummary.dead or 0))
        if classified <= 0 then
            local pressure = FieldAdvisor.getEffectiveWeedPressure(fieldState)
            if pressure > FieldAdvisor.WEED_LIVE_RATIO_DONE_THRESHOLD then
                return string.format("%d%%", math.floor(pressure * 100 + 0.5))
            end
            if FieldAdvisor.isWeedDeadOrSprayed(fieldState) then
                return FieldAdvisor.text("ftdl_weed_dead", "tot")
            end
            return FieldAdvisor.formatWeedLabel(FieldAdvisor.getWeedStateLevel(fieldState), rules)
        end

        if (weedSummary.live or 0) <= 0 and (weedSummary.dead or 0) > 0 then
            return FieldAdvisor.text("ftdl_weed_dead", "tot")
        end

        if weedSummary.liveRatio > 0.001 then
            local percent = math.floor(weedSummary.liveRatio * 100 + 0.5)
            local doneThreshold = math.floor(FieldAdvisor.WEED_LIVE_RATIO_DONE_THRESHOLD * 100 + 0.5)
            if percent <= doneThreshold then
                return FieldAdvisor.text("ftdl_val_none", "kein")
            end
            return string.format("%d%%", percent)
        end

        return FieldAdvisor.text("ftdl_val_none", "kein")
    end

    if FieldAdvisor.getWeedStateLevel(fieldState) >= FieldAdvisor.WEED_STATE_DEAD_MIN then
        return FieldAdvisor.text("ftdl_weed_dead", "tot")
    end

    if FieldAdvisor.isWeedDeadOrSprayed(fieldState) then
        return FieldAdvisor.text("ftdl_weed_dead", "tot")
    end

    local pressure = FieldAdvisor.getEffectiveWeedPressure(fieldState)
    if pressure > 0.001 then
        local percent = math.floor(pressure * 100 + 0.5)
        if percent <= 2 then
            return FieldAdvisor.text("ftdl_val_none", "kein")
        end

        return string.format("%d%%", percent)
    end

    return FieldAdvisor.formatWeedLabel(FieldAdvisor.getWeedStateLevel(fieldState), rules)
end

---@param fieldState table|nil
---@param rules table
---@param weedSummary table|nil
---@return boolean
function FieldAdvisor.fieldNeedsWeedCombat(fieldState, rules, weedSummary)
    if not rules.weedsEnabled then
        return false
    end

    if weedSummary ~= nil and (weedSummary.total or 0) > 0 then
        if FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary) then
            return false
        end
        if (weedSummary.classified or 0) <= 0 then
            return false
        end
        return weedSummary.liveRatio >= FieldAdvisor.WEED_FACTOR_COMBAT_THRESHOLD
    end

    if FieldAdvisor.isWeedDeadOrSprayed(fieldState) then
        return false
    end

    return FieldAdvisor.getEffectiveWeedPressure(fieldState) >= FieldAdvisor.WEED_FACTOR_COMBAT_THRESHOLD
end

---@param fieldState table|nil
---@param rules table
---@param weedSummary table|nil
---@return boolean
function FieldAdvisor.fieldNeedsWeedWatch(fieldState, rules, weedSummary)
    if not rules.weedsEnabled then
        return false
    end

    if weedSummary ~= nil and (weedSummary.total or 0) > 0 then
        if FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary) then
            return false
        end
        if (weedSummary.classified or 0) <= 0 then
            return false
        end
        if weedSummary.liveRatio >= FieldAdvisor.WEED_FACTOR_COMBAT_THRESHOLD then
            return false
        end
        return weedSummary.liveRatio > FieldAdvisor.WEED_FACTOR_COMPLETE_THRESHOLD
            and weedSummary.liveRatio < FieldAdvisor.WEED_FACTOR_COMBAT_THRESHOLD
    end

    if FieldAdvisor.isWeedDeadOrSprayed(fieldState) then
        return false
    end

    if FieldAdvisor.fieldNeedsWeedCombat(fieldState, rules, weedSummary) then
        return false
    end

    local pressure = FieldAdvisor.getEffectiveWeedPressure(fieldState)
    return pressure > FieldAdvisor.WEED_FACTOR_COMPLETE_THRESHOLD
        and pressure < FieldAdvisor.WEED_FACTOR_COMBAT_THRESHOLD
end

---@param period number
---@return string
function FieldAdvisor.getEnvironmentPeriodLabel(period)
    if g_currentMission ~= nil and g_currentMission.environment ~= nil then
        local environment = g_currentMission.environment

        if environment.getPeriodName ~= nil then
            local ok, periodName = pcall(environment.getPeriodName, environment, period)
            if ok and not string.isNilOrWhitespace(periodName) then
                return periodName
            end
        end

        if environment.periodNames ~= nil and environment.periodNames[period] ~= nil then
            return tostring(environment.periodNames[period])
        end
    end

    return PrecisionFarmingReader.getMonthName(FieldAdvisor.getCalendarMonthForSeasonPeriod(period))
end

--- FS25 season periods (EARLY_SPRING … LATE_WINTER) map to a representative calendar month.
---@param period number|nil
---@return number
function FieldAdvisor.getCalendarMonthForSeasonPeriod(period)
    period = math.max(1, math.min(12, math.floor(tonumber(period) or 1)))
    local mapping = {
        [1] = 3, [2] = 4, [3] = 5, [4] = 6, [5] = 7, [6] = 8,
        [7] = 9, [8] = 10, [9] = 11, [10] = 12, [11] = 1, [12] = 2,
    }
    return mapping[period] or math.max(1, math.min(12, period))
end

--- Safe field center lookup (engine API guarded).
---@param field table|nil
---@return number|nil
---@return number|nil
function FieldAdvisor.getFieldCenterWorldPosition(field)
    if field == nil or field.getCenterOfFieldWorldPosition == nil then
        return nil, nil
    end

    local ok, x, z = pcall(field.getCenterOfFieldWorldPosition, field)
    if ok and x ~= nil and z ~= nil then
        return x, z
    end

    return nil, nil
end

---@return number period 1..12
function FieldAdvisor.getCurrentSeasonPeriod()
    if g_currentMission == nil or g_currentMission.environment == nil then
        return 1
    end

    local environment = g_currentMission.environment
    if environment.currentPeriod ~= nil then
        local period = math.floor(tonumber(environment.currentPeriod) or 1)
        return math.max(1, math.min(12, period))
    end

    local currentDay = environment.currentDay or 1
    local daysPerPeriod = environment.daysPerPeriod or 1
    if daysPerPeriod <= 0 then
        daysPerPeriod = 1
    end

    return math.floor((currentDay - 1) / daysPerPeriod) % 12 + 1
end

---@return boolean
function FieldAdvisor.isSeasonalGrowthEnabled()
    if g_currentMission == nil then
        return true
    end

    local missionInfo = g_currentMission.missionInfo
    if missionInfo ~= nil then
        if missionInfo.seasonalGrowthEnabled ~= nil then
            return missionInfo.seasonalGrowthEnabled == true
        end
        if missionInfo.growthMode ~= nil and GrowthMode ~= nil then
            if GrowthMode.SEASONAL ~= nil then
                return missionInfo.growthMode == GrowthMode.SEASONAL
            end
            if GrowthMode.GROWTH_MODE_SEASONAL ~= nil then
                return missionInfo.growthMode == GrowthMode.GROWTH_MODE_SEASONAL
            end
        end
    end

    local growthSystem = g_currentMission.growthSystem
    if growthSystem ~= nil then
        if growthSystem.seasonalGrowthEnabled ~= nil then
            return growthSystem.seasonalGrowthEnabled == true
        end
        if growthSystem.getGrowthMode ~= nil then
            local ok, growthMode = pcall(growthSystem.getGrowthMode, growthSystem)
            if ok and growthMode ~= nil and GrowthMode ~= nil then
                if GrowthMode.SEASONAL ~= nil and growthMode == GrowthMode.SEASONAL then
                    return true
                end
                if GrowthMode.NON_SEASONAL ~= nil and growthMode == GrowthMode.NON_SEASONAL then
                    return false
                end
                if GrowthMode.GROWTH_MODE_SEASONAL ~= nil and growthMode == GrowthMode.GROWTH_MODE_SEASONAL then
                    return true
                end
                if GrowthMode.GROWTH_MODE_NON_SEASONAL ~= nil and growthMode == GrowthMode.GROWTH_MODE_NON_SEASONAL then
                    return false
                end
            end
        end
    end

    return true
end

---@return number growthMode for FruitTypeDesc period APIs
function FieldAdvisor.getActiveGrowthMode()
    if not FieldAdvisor.isSeasonalGrowthEnabled() then
        if GrowthMode ~= nil then
            return GrowthMode.NON_SEASONAL
                or GrowthMode.GROWTH_MODE_NON_SEASONAL
                or GrowthMode.NONSEASONAL
                or 2
        end
        return 2
    end

    if GrowthMode ~= nil then
        return GrowthMode.SEASONAL
            or GrowthMode.GROWTH_MODE_SEASONAL
            or 1
    end

    return 1
end

---@param period number|nil
---@return string
function FieldAdvisor.getHarvestPeriodDisplayLabel(period)
    if period == nil then
        return "-"
    end

    local monthIndex = FieldAdvisor.getCalendarMonthForSeasonPeriod(period)
    return PrecisionFarmingReader.getMonthName(monthIndex)
end

---@param fruitDesc table|nil
---@param growthMode number|nil
---@param period number|nil
---@return boolean
function FieldAdvisor.isFruitHarvestableInPeriod(fruitDesc, growthMode, period)
    if fruitDesc == nil or fruitDesc.getIsHarvestableInPeriod == nil then
        return true
    end

    growthMode = growthMode or FieldAdvisor.getActiveGrowthMode()
    period = period or FieldAdvisor.getCurrentSeasonPeriod()
    local ok, harvestable = pcall(fruitDesc.getIsHarvestableInPeriod, fruitDesc, growthMode, period)
    return ok and harvestable ~= nil and harvestable ~= false and tonumber(harvestable) ~= 0
end

--- Primary (grain/dry) harvest in a season period: harvestable in period AND projected
--- growth satisfies getIsHarvestReady (skips e.g. maize silage window in July).
---@param fruitDesc table|nil
---@param fruitTypeIndex number|nil
---@param growthMode number|nil
---@param period number|nil
---@param projectedGrowthState number|nil
---@return boolean
function FieldAdvisor.isFruitPrimaryHarvestInPeriod(fruitDesc, fruitTypeIndex, growthMode, period, projectedGrowthState)
    if not FieldAdvisor.isFruitHarvestableInPeriod(fruitDesc, growthMode, period) then
        return false
    end

    projectedGrowthState = math.floor(tonumber(projectedGrowthState) or 0)
    if projectedGrowthState <= 0 then
        return false
    end

    if FieldAdvisor.isGrowthStateHarvestReadyByApi(fruitTypeIndex, projectedGrowthState) then
        return true
    end

    if FieldAdvisor.fruitDescHasHarvestReadyApi(fruitTypeIndex) then
        return false
    end

    if fruitDesc == nil then
        return true
    end

    local minHarvest = tonumber(fruitDesc.minHarvestingGrowthState) or 0
    return minHarvest > 0 and projectedGrowthState >= minHarvest
end

---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.fruitDescHasHarvestReadyApi(fruitTypeIndex)
    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    return fruitDesc ~= nil and fruitDesc.getIsHarvestReady ~= nil
end

---@param fruitTypeIndex number|nil
---@param growthState number
---@return boolean
function FieldAdvisor.isGrowthStateHarvestReadyByApi(fruitTypeIndex, growthState)
    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    if fruitDesc == nil or fruitDesc.getIsHarvestReady == nil then
        return false
    end

    local ok, ready = pcall(fruitDesc.getIsHarvestReady, fruitDesc, growthState)
    return ok and ready == true
end

---@param fromPeriod number
---@param offset number
---@return number
function FieldAdvisor.getSeasonPeriodForOffset(fromPeriod, offset)
    fromPeriod = math.floor(tonumber(fromPeriod) or 1)
    offset = math.floor(tonumber(offset) or 0)
    return ((fromPeriod - 1 + offset) % 12) + 1
end

---@param fruitDesc table|nil
---@param fruitTypeIndex number|nil
---@param growthMode number|nil
---@param fromPeriod number|nil
---@param currentGrowthState number|nil
---@return number|nil
function FieldAdvisor.getNextPrimaryHarvestablePeriod(fruitDesc, fruitTypeIndex, growthMode, fromPeriod, currentGrowthState)
    if fruitDesc == nil then
        return nil
    end

    growthMode = growthMode or FieldAdvisor.getActiveGrowthMode()
    fromPeriod = fromPeriod or FieldAdvisor.getCurrentSeasonPeriod()
    currentGrowthState = math.max(1, math.floor(tonumber(currentGrowthState) or 1))

    for offset = 0, 11 do
        local period = FieldAdvisor.getSeasonPeriodForOffset(fromPeriod, offset)
        local projectedGrowth = currentGrowthState + offset
        if FieldAdvisor.isFruitPrimaryHarvestInPeriod(
            fruitDesc, fruitTypeIndex, growthMode, period, projectedGrowth) then
            return period
        end
    end

    return nil
end

--- Growth steps (≈ periods) until the crop is fully ripe for its primary harvest.
--- Targets first getIsHarvestReady growth state (grain), not the forage window.
---@param fruitTypeIndex number|nil
---@param fieldState table|nil
---@param fruitDesc table|nil
---@return number|nil steps until ripe (0 = ripe now)
function FieldAdvisor.estimateNonSeasonalPeriodsUntilHarvest(fruitTypeIndex, fieldState, fruitDesc)
    if fruitTypeIndex == nil or fieldState == nil then
        return nil
    end

    local state = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if state <= 0 then
        if FieldAdvisor.hasActiveCrop(fieldState) then
            state = 1
        else
            return nil
        end
    end

    fruitDesc = fruitDesc or FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)

    -- Preferred target: first growth state where getIsHarvestReady is true (grain).
    local target = nil
    if fruitDesc ~= nil then
        if FieldAdvisor.fruitDescHasHarvestReadyApi(fruitTypeIndex) then
            for candidate = state, state + 12 do
                if FieldAdvisor.isGrowthStateHarvestReadyByApi(fruitTypeIndex, candidate) then
                    target = candidate
                    break
                end
            end
        end
        if target == nil then
            local minHarvest = tonumber(fruitDesc.minHarvestingGrowthState) or 0
            if minHarvest > 0 then
                target = minHarvest
            end
        end
    end

    if target ~= nil then
        if state >= target then
            return 0
        end
        return target - state
    end

    -- Fallback: walk growth states until getIsHarvestReady reports ripe.
    if FieldAdvisor.isGrowthStateHarvestReadyByApi(fruitTypeIndex, state) then
        return 0
    end

    for candidate = state + 1, state + 12 do
        if FieldAdvisor.isGrowthStateHarvestReadyByApi(fruitTypeIndex, candidate) then
            return candidate - state
        end
    end

    return nil
end

---@param rollerLevel number
---@param needsRolling boolean
---@return string
function FieldAdvisor.formatRollerLabel(rollerLevel, needsRolling)
    if needsRolling or rollerLevel > 0 then
        return FieldAdvisor.text("ftdl_val_yes", "ja")
    end

    return FieldAdvisor.text("ftdl_val_no", "nein")
end

---@param fieldState table|nil
---@param rules table|nil
---@return boolean
function FieldAdvisor.fieldNeedsPlowingWork(fieldState, rules)
    rules = rules or FieldGameRules.get()
    if not rules.plowingRequiredEnabled or fieldState == nil then
        return false
    end

    -- Same contract as FieldTaskCompletion plow check: PLOWED + not needsPlowing = done.
    if FieldAdvisor.getGroundTypeName(fieldState) == "PLOWED"
        and not FieldAdvisor.getStateBool(fieldState, "needsPlowing") then
        return false
    end

    return FieldAdvisor.getStateBool(fieldState, "needsPlowing")
        or FieldAdvisor.getStateNumber(fieldState, "plowLevel") > 0
end

---@param fieldState table|nil
---@param rules table|nil
---@return boolean
function FieldAdvisor.fieldNeedsLimeWork(fieldState, rules)
    rules = rules or FieldGameRules.get()
    if not rules.limeRequired or fieldState == nil then
        return false
    end

    -- needsLime is authoritative once liming is done; limeLevel can stay stale (K1–K3 display).
    return FieldAdvisor.getStateBool(fieldState, "needsLime") == true
end

---@param fieldState table|nil
---@param rules table
---@return string
function FieldAdvisor.formatPlowLabel(fieldState, rules)
    if not rules.plowingRequiredEnabled then
        local needsPlowing = FieldAdvisor.getStateBool(fieldState, "needsPlowing")
        local value = needsPlowing
            and FieldAdvisor.text("ftdl_val_yes", "ja")
            or FieldAdvisor.text("ftdl_val_no", "nein")
        return string.format("%s %s", value, FieldAdvisor.text("ftdl_val_disabled", "(aus)"))
    end

    if FieldAdvisor.fieldNeedsPlowingWork(fieldState, rules) then
        return FieldAdvisor.text("ftdl_val_yes", "ja")
    end

    return FieldAdvisor.text("ftdl_val_no", "nein")
end

---@param fieldState table|nil
---@return string
function FieldAdvisor.summarizeFieldStateProbe(fieldState)
    if fieldState == nil then
        return "probe=nil"
    end

    local fruitTypeIndex = FieldAdvisor.getFruitTypeIndex(fieldState)
    local fruitName = fruitTypeIndex ~= nil and FieldAdvisor.getFruitTypeName(fruitTypeIndex) or "-"

    return string.format(
        "ground=%s fruit=%s(%s) growth=%d lastGrowth=%d needsPlow=%s plowLvl=%d needsLime=%s limeLvl=%d needsRoll=%s rollLvl=%d weed=%d stones=%d",
        FieldAdvisor.getGroundTypeName(fieldState),
        fruitName,
        tostring(fruitTypeIndex or "-"),
        FieldAdvisor.getGrowthState(fieldState),
        FieldAdvisor.getLastGrowthState(fieldState),
        tostring(FieldAdvisor.getStateBool(fieldState, "needsPlowing")),
        FieldAdvisor.getStateNumber(fieldState, "plowLevel"),
        tostring(FieldAdvisor.getStateBool(fieldState, "needsLime")),
        FieldAdvisor.getStateNumber(fieldState, "limeLevel"),
        tostring(FieldAdvisor.getStateBool(fieldState, "needsRolling")),
        FieldAdvisor.getStateNumber(fieldState, "rollerLevel"),
        FieldAdvisor.getStateNumber(fieldState, "weedState"),
        FieldAdvisor.getStateNumber(fieldState, "stoneLevel")
    )
end

---@param field table
---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isHarvestReady(field, fieldState)
    if fieldState ~= nil then
        if FieldAdvisor.resolveGroundTypeName(fieldState.groundType) == "HARVEST_READY" then
            return true
        end

        if fieldState.isHarvestReady == true then
            return true
        end
    end

    if field ~= nil and field.groundType == "HARVEST_READY" then
        return true
    end

    local fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
    if fruitTypeIndex ~= nil and FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        return false
    end

    return FieldAdvisor.isCropHarvestReady(field, fieldState, fruitTypeIndex)
end

---@param key string|nil
---@return string|nil
function FieldAdvisor.translateKey(key)
    if key == nil or key == "" or g_i18n == nil or g_i18n.hasText == nil then
        return nil
    end

    if g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end

    return nil
end

---@param key string|nil
---@param fallback string|nil
---@return string
function FieldAdvisor.text(key, fallback, ...)
    if FieldToDoL10n ~= nil then
        return FieldToDoL10n.getText(key, fallback, ...)
    end

    if select("#", ...) > 0 and fallback ~= nil then
        return string.format(fallback, ...)
    end

    return fallback or key or ""
end

---@param fillType table|nil
---@return string|nil
function FieldAdvisor.getLocalizedFillTypeTitle(fillType)
    if fillType == nil then
        return nil
    end

    if fillType.title ~= nil and fillType.title ~= "" then
        local title = tostring(fillType.title)
        local translated = FieldAdvisor.translateKey(title)
        if translated ~= nil then
            return translated
        end

        if not string.match(title, "^[A-Z0-9_]+$") then
            return title
        end
    end

    if fillType.name ~= nil then
        local translated = FieldAdvisor.translateKey("fillType_" .. fillType.name)
        if translated ~= nil then
            return translated
        end

        return fillType.name
    end

    return nil
end

---@param fruitTypeIndex number|nil
---@return string|nil
function FieldAdvisor.getFruitTypeName(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 or g_fruitTypeManager == nil then
        return nil
    end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitDesc == nil then
        return nil
    end

    return fruitDesc.name
end

---@param fruitTypeIndex number|nil
---@return string
function FieldAdvisor.getLocalizedFruitTitle(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 then
        return "-"
    end

    if FruitType ~= nil and fruitTypeIndex == FruitType.UNKNOWN then
        return "-"
    end

    if g_fruitTypeManager == nil or g_fruitTypeManager.getFruitTypeByIndex == nil then
        return "-"
    end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitDesc == nil then
        return "-"
    end

    -- Specific grass crops (Luzerne/Klee/…) often share a generic grass fill type whose
    -- title localizes to "Gras". Prefer the crop's own name so Luzerne is not shown as Gras.
    if fruitDesc.name ~= nil
        and FieldAdvisor.isGrassCrop(fruitTypeIndex)
        and not FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
        local rawName = tostring(fruitDesc.name)
        local lowerName = string.lower(rawName)
        local keys = {
            "fillType_" .. rawName,
            "fillType_" .. lowerName,
            "fruitType_" .. rawName,
            "fruitType_" .. lowerName,
        }
        for _, key in ipairs(keys) do
            local translated = FieldAdvisor.translateKey(key)
            if translated ~= nil and translated ~= "" then
                return translated
            end
        end
    end

    if fruitDesc.fillType ~= nil and g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByIndex ~= nil then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fruitDesc.fillType)
        local title = FieldAdvisor.getLocalizedFillTypeTitle(fillType)
        if title ~= nil and title ~= "" then
            return title
        end
    end

    if fruitDesc.name ~= nil and g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByName ~= nil then
        local fillType = g_fillTypeManager:getFillTypeByName(fruitDesc.name)
        local title = FieldAdvisor.getLocalizedFillTypeTitle(fillType)
        if title ~= nil and title ~= "" then
            return title
        end

        local translated = FieldAdvisor.translateKey("fillType_" .. fruitDesc.name)
        if translated ~= nil then
            return translated
        end

        translated = FieldAdvisor.translateKey("fruitType_" .. fruitDesc.name)
        if translated ~= nil then
            return translated
        end
    end

    return fruitDesc.name or "-"
end

---@param fruitTypeIndex number|nil
---@return table|nil
function FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 or g_fruitTypeManager == nil then
        return nil
    end

    return g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
end

---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isGrassCrop(fruitTypeIndex)
    local fruitName = FieldAdvisor.getFruitTypeName(fruitTypeIndex)
    if fruitName ~= nil and FieldAdvisor.GRASS_FRUIT_NAMES[string.upper(fruitName)] == true then
        return true
    end

    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    if fruitDesc == nil then
        return false
    end

    for _, flagName in ipairs({ "isGrassland", "isGrass", "isGrassCrop" }) do
        if fruitDesc[flagName] == true then
            return true
        end
    end

    if fruitDesc.getNeedsPlowing ~= nil then
        local ok, needsPlowing = pcall(fruitDesc.getNeedsPlowing, fruitDesc)
        if ok and needsPlowing == false and fruitDesc.minHarvestingGrowthState ~= nil then
            local minHarvest = tonumber(fruitDesc.minHarvestingGrowthState) or 0
            local maxHarvest = tonumber(fruitDesc.maxHarvestingGrowthState) or 0
            if maxHarvest > minHarvest and minHarvest >= 0 then
                return true
            end
        end
    end

    return false
end

---@return table
function FieldAdvisor.getGrassFruitTypeIndices()
    if FieldAdvisor._grassFruitTypeIndices ~= nil then
        return FieldAdvisor._grassFruitTypeIndices
    end

    local indices = {}
    local seen = {}
    for grassName, _ in pairs(FieldAdvisor.GRASS_FRUIT_NAMES) do
        local fruitTypeIndex = FieldAdvisor.getFruitTypeIndexByName(grassName)
        if fruitTypeIndex ~= nil and fruitTypeIndex > 0 and seen[fruitTypeIndex] ~= true then
            seen[fruitTypeIndex] = true
            indices[#indices + 1] = fruitTypeIndex
        end
    end

    FieldAdvisor._grassFruitTypeIndices = indices
    return indices
end

---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 then
        return false
    end

    local fruitName = FieldAdvisor.getFruitTypeName(fruitTypeIndex)
    if fruitName == nil then
        return false
    end

    return FieldAdvisor.GENERIC_GRASS_FRUIT_NAMES[string.upper(fruitName)] == true
end

---@param fruitTypeIndex number|nil
---@param fieldState table|nil
---@return number
function FieldAdvisor.scoreGrassFruitGrowthMatch(fruitTypeIndex, fieldState)
    if fruitTypeIndex == nil or fieldState == nil then
        return 0
    end

    local growthState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if growthState <= 0 then
        return 0
    end

    local growth = FieldAdvisor.evaluateFruitGrowth(fruitTypeIndex, growthState)
    local score = 0
    if growth.isCut then
        score = score + 40
    end
    if growth.isHarvestReady then
        score = score + 30
    end
    if growth.isHarvestable then
        score = score + 25
    end
    if growth.isGrowing then
        score = score + 15
    end
    if growth.isWithered then
        score = score + 10
    end

    local ground = FieldAdvisor.getGroundTypeName(fieldState)
    if growth.isCut and (ground == "GRASS_CUT" or string.find(ground, "CUT", 1, true) ~= nil) then
        score = score + 50
    end

    if not FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
        score = score + 20
    end

    return score
end

--- Density map often returns generic GRASS for Alfalfa/Luzerne; match growth flags per grass crop.
---@param fieldState table|nil
---@param field table|nil
---@param probeIndex number|nil
---@return number|nil
function FieldAdvisor.disambiguateGrassFruitTypeIndex(fieldState, field, probeIndex)
    if fieldState == nil then
        return probeIndex
    end

    local bestIndex = nil
    local bestScore = 0
    for _, fruitTypeIndex in ipairs(FieldAdvisor.getGrassFruitTypeIndices()) do
        local score = FieldAdvisor.scoreGrassFruitGrowthMatch(fruitTypeIndex, fieldState)
        if score > bestScore
            or (score == bestScore
                and bestIndex ~= nil
                and FieldAdvisor.isGenericGrassFruitIndex(bestIndex)
                and not FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex)) then
            bestScore = score
            bestIndex = fruitTypeIndex
        end
    end

    if bestIndex ~= nil and bestScore > 0 then
        if probeIndex == nil
            or FieldAdvisor.isGenericGrassFruitIndex(probeIndex)
            or bestScore >= FieldAdvisor.scoreGrassFruitGrowthMatch(probeIndex, fieldState) then
            return bestIndex
        end
    end

    return probeIndex
end

--- Detect Luzerne/Klee/etc. from windrow/cut residue fill type (more reliable than generic GRASS index).
---@param field table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return number|nil
function FieldAdvisor.inferGrassFruitTypeFromWindrowFill(field, worldX, worldZ)
    if field == nil or g_fruitTypeManager == nil then
        return nil
    end

    local heightUtil = FieldAdvisor.resolveDensityMapHeightUtil()
    if heightUtil == nil or FieldAdvisor._densityMapHeightFillMethod == nil then
        return nil
    end

    if worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end
    if worldX == nil or worldZ == nil then
        return nil
    end

    local bestFruit = nil
    local bestLiters = 0
    local bestFillTypeIndex = nil
    local halfSize = FieldAdvisor.GRASS_RESIDUE_SAMPLE_HALF_SIZE

    for _, fruitTypeIndex in ipairs(FieldAdvisor.getGrassFruitTypeIndices()) do
        if not FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex)
            and g_fruitTypeManager.getWindrowFillTypeIndexByFruitTypeIndex ~= nil then
            local ok, fillTypeIndex = pcall(
                g_fruitTypeManager.getWindrowFillTypeIndexByFruitTypeIndex,
                g_fruitTypeManager,
                fruitTypeIndex
            )
            if ok and fillTypeIndex ~= nil and tonumber(fillTypeIndex) ~= nil and tonumber(fillTypeIndex) > 0 then
                local liters = FieldAdvisor.callFillLevelAtArea(
                    fillTypeIndex,
                    worldX - halfSize, worldZ - halfSize,
                    worldX + halfSize, worldZ - halfSize,
                    worldX - halfSize, worldZ + halfSize
                )
                if liters > bestLiters then
                    bestLiters = liters
                    bestFruit = fruitTypeIndex
                    bestFillTypeIndex = fillTypeIndex
                end
            end
        end
    end

    if bestFruit == nil then
        return nil
    end

    local minValid = FieldAdvisor.getMinValidHeightLiters(bestFillTypeIndex)
    if bestLiters >= math.max(0.001, minValid * 0.25) then
        return bestFruit
    end

    return nil
end

---@param fieldState table|nil
---@param field table|nil
---@param fruitTypeIndex number|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return number|nil
function FieldAdvisor.refineGrassFruitTypeIndex(fieldState, field, fruitTypeIndex, worldX, worldZ)
    local fieldHint = FieldAdvisor.inferGrassFruitTypeIndexFromField(field)
    if fieldHint ~= nil and not FieldAdvisor.isGenericGrassFruitIndex(fieldHint) then
        if fruitTypeIndex == nil or FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
            fruitTypeIndex = fieldHint
        end
    end

    local skipDisambiguation = FieldAdvisor.isGenericGrassStandingCrop(fieldState, field, fruitTypeIndex)
    if skipDisambiguation then
        local genericFromState = FieldAdvisor.getFruitTypeIndex(fieldState)
        if genericFromState ~= nil and genericFromState > 0
            and FieldAdvisor.isGrassCrop(genericFromState) then
            return genericFromState
        end
        return fruitTypeIndex
    end

    if worldX ~= nil and worldZ ~= nil and rawget(_G, "FSDensityMapUtil") ~= nil then
        -- FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z) is a plain function (no self).
        if FSDensityMapUtil.getFruitTypeIndexAtWorldPos ~= nil then
            local ok, detectedIndex = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, worldX, worldZ)
            detectedIndex = ok and tonumber(detectedIndex) or nil
            if detectedIndex ~= nil
                and detectedIndex > 0
                and FieldAdvisor.isGrassCrop(detectedIndex)
                and not FieldAdvisor.isGenericGrassFruitIndex(detectedIndex) then
                fruitTypeIndex = detectedIndex
            end
        end
    end

    local residueHint = FieldAdvisor.inferGrassFruitTypeFromWindrowFill(field, worldX, worldZ)
    if residueHint ~= nil then
        if fruitTypeIndex == nil or FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
            fruitTypeIndex = residueHint
        end
    end

    if fruitTypeIndex == nil or FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
        for _, grassName in ipairs({ "ALFALFA", "LUCERNE", "CLOVER", "MEDICK", "GREENRYE" }) do
            local specificIndex = FieldAdvisor.getFruitTypeIndexByName(grassName)
            if specificIndex ~= nil and fieldState ~= nil then
                local specificScore = FieldAdvisor.scoreGrassFruitGrowthMatch(specificIndex, fieldState)
                local genericScore = fruitTypeIndex ~= nil
                    and FieldAdvisor.scoreGrassFruitGrowthMatch(fruitTypeIndex, fieldState) or 0
                if specificScore > 0 and specificScore >= genericScore then
                    fruitTypeIndex = specificIndex
                    break
                end
            end
        end
    end

    if fruitTypeIndex == nil or FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
        local refined = FieldAdvisor.disambiguateGrassFruitTypeIndex(fieldState, field, fruitTypeIndex)
        if refined ~= nil then
            fruitTypeIndex = refined
        end
    end

    if fieldHint ~= nil and not FieldAdvisor.isGenericGrassFruitIndex(fieldHint) then
        if fruitTypeIndex == nil or FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
            fruitTypeIndex = fieldHint
        end
    end

    return fruitTypeIndex
end

---@param harvestWindow string|nil
---@return string
function FieldAdvisor.formatHarvestWindowLabel(harvestWindow)
    if harvestWindow == nil or harvestWindow == "" or harvestWindow == "-" then
        return "-"
    end

    return FieldAdvisor.text("ftdl_action_harvest_window", "Ernte %s", harvestWindow)
end

--- Fruit growth flags from FruitTypeDesc (vanilla + mod fruits).
---@param fruitTypeIndex number|nil
---@param growthState number
---@return table { isCut: boolean, isGrowing: boolean, isHarvestable: boolean, isWithered: boolean, isHarvestReady: boolean }
function FieldAdvisor.evaluateFruitGrowth(fruitTypeIndex, growthState)
    local result = {
        isCut = false,
        isGrowing = false,
        isHarvestable = false,
        isWithered = false,
        isHarvestReady = false,
    }

    growthState = FieldAdvisor.toNumber(growthState)
    if fruitTypeIndex == nil or growthState <= 0 then
        return result
    end

    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    if fruitDesc == nil then
        return result
    end

    local function callFlag(methodName)
        if fruitDesc[methodName] == nil then
            return nil
        end

        local ok, value = pcall(fruitDesc[methodName], fruitDesc, growthState)
        if ok then
            return value == true
        end

        return nil
    end

    result.isCut = callFlag("getIsCut") == true
    result.isWithered = callFlag("getIsWithered") == true
    result.isGrowing = callFlag("getIsGrowing") == true
    local apiHarvestable = callFlag("getIsHarvestable")
    result.isHarvestable = apiHarvestable == true
    local apiHarvestReady = callFlag("getIsHarvestReady")
    result.isHarvestReady = apiHarvestReady == true

    if apiHarvestable == nil and not result.isHarvestable
        and fruitDesc.minHarvestingGrowthState ~= nil and fruitDesc.maxHarvestingGrowthState ~= nil then
        local minHarvest = tonumber(fruitDesc.minHarvestingGrowthState) or 0
        local maxHarvest = tonumber(fruitDesc.maxHarvestingGrowthState) or 0
        if maxHarvest >= minHarvest and minHarvest > 0 and growthState >= minHarvest and growthState <= maxHarvest then
            result.isHarvestable = true
        end
    end

    return result
end

---@param field table|nil
---@param fieldState table|nil
---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isCropHarvestReadyByGrowth(field, fieldState, fruitTypeIndex)
    if fruitTypeIndex == nil or FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        return false
    end

    if fieldState ~= nil then
        if FieldAdvisor.resolveGroundTypeName(fieldState.groundType) == "HARVEST_READY" then
            return true
        end

        if fieldState.isHarvestReady == true then
            return true
        end
    end

    local growthState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if growthState <= 0 then
        return false
    end

    local growth = FieldAdvisor.evaluateFruitGrowth(fruitTypeIndex, growthState)
    if growth.isWithered then
        return false
    end

    if growth.isHarvestReady then
        return true
    end

    if FieldAdvisor.fruitDescHasHarvestReadyApi(fruitTypeIndex) then
        return false
    end

    return growth.isHarvestable
end

---@param field table|nil
---@param fieldState table|nil
---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isCropHarvestReady(field, fieldState, fruitTypeIndex)
    if not FieldAdvisor.isCropHarvestReadyByGrowth(field, fieldState, fruitTypeIndex) then
        return false
    end

    if FieldAdvisor.isSeasonalGrowthEnabled() then
        local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
        local growthState = FieldAdvisor.getEffectiveGrowthState(fieldState)
        return FieldAdvisor.isFruitPrimaryHarvestInPeriod(
            fruitDesc,
            fruitTypeIndex,
            FieldAdvisor.getActiveGrowthMode(),
            FieldAdvisor.getCurrentSeasonPeriod(),
            growthState
        )
    end

    return true
end

---@param fruitTypeIndex number|nil
---@param fieldState table|nil
---@return number|nil
function FieldAdvisor.getExpectedHarvestPeriod(fruitTypeIndex, fieldState)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 then
        return nil
    end

    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    if fruitDesc == nil then
        return nil
    end

    local growthMode = FieldAdvisor.getActiveGrowthMode()
    local currentPeriod = FieldAdvisor.getCurrentSeasonPeriod()
    local currentState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if currentState <= 0 and FieldAdvisor.hasActiveCrop(fieldState) then
        currentState = 1
    end

    if FieldAdvisor.isCropHarvestReadyByGrowth(nil, fieldState, fruitTypeIndex)
        and FieldAdvisor.isFruitPrimaryHarvestInPeriod(
            fruitDesc, fruitTypeIndex, growthMode, currentPeriod, currentState) then
        return currentPeriod
    end

    local stepsUntilRipe = FieldAdvisor.estimateNonSeasonalPeriodsUntilHarvest(fruitTypeIndex, fieldState, fruitDesc)

    if not FieldAdvisor.isSeasonalGrowthEnabled() then
        if stepsUntilRipe == nil then
            return FieldAdvisor.getNextPrimaryHarvestablePeriod(
                fruitDesc, fruitTypeIndex, growthMode, currentPeriod, currentState)
        end
        if stepsUntilRipe <= 0 then
            return currentPeriod
        end
        return FieldAdvisor.getSeasonPeriodForOffset(currentPeriod, stepsUntilRipe)
    end

    -- Seasonal: first period where crop is harvestable AND projected growth is grain-ready
    -- (skips maize silage window in summer).
    local startOffset = 0
    if stepsUntilRipe ~= nil and stepsUntilRipe > 0 then
        startOffset = math.max(0, stepsUntilRipe - 1)
    end

    for offset = startOffset, 11 do
        local period = FieldAdvisor.getSeasonPeriodForOffset(currentPeriod, offset)
        local projectedGrowth = currentState + offset
        if FieldAdvisor.isFruitPrimaryHarvestInPeriod(
            fruitDesc, fruitTypeIndex, growthMode, period, projectedGrowth) then
            return period
        end
    end

    return FieldAdvisor.getNextPrimaryHarvestablePeriod(
        fruitDesc, fruitTypeIndex, growthMode, currentPeriod, currentState)
end

--- Grass meadow phase: cut | harvestable | growing | withered | dormant
---@param fieldState table|nil
---@param field table|nil
---@param aggregation table|nil
---@return string
function FieldAdvisor.getGrassMeadowPhase(fieldState, field, aggregation)
    local isGrassSituation = aggregation ~= nil
        and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS
    if not isGrassSituation and FieldAdvisor.classifyProbe(fieldState, field) ~= FieldAdvisor.PROBE_SITUATION.GRASS then
        return "dormant"
    end

    local probeState = fieldState
    if aggregation ~= nil and aggregation.centerState ~= nil then
        probeState = aggregation.centerState
    end

    local worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)

    local fruitTypeIndex = FieldAdvisor.resolveGrassFruitTypeIndex(probeState, field, aggregation, worldX, worldZ)
    if fruitTypeIndex == nil then
        fruitTypeIndex = FieldAdvisor.resolveGrassFruitTypeIndex(fieldState, field, aggregation, worldX, worldZ)
    end
    if fruitTypeIndex == nil then
        return "dormant"
    end

    if aggregation ~= nil and (aggregation.maxStubbleShredLevel or 0) > 0 then
        return "cut"
    end

    local function phaseForState(state)
        if state == nil then
            return nil
        end

        if FieldAdvisor.isGrassPostMowState(state, field, fruitTypeIndex) then
            return "cut"
        end

        local growthState = FieldAdvisor.getEffectiveGrowthState(state)
        if growthState > 0 then
            local growth = FieldAdvisor.evaluateFruitGrowth(fruitTypeIndex, growthState)
            if growth.isCut then
                return "cut"
            end
            if growth.isWithered then
                return "withered"
            end
            if growth.isHarvestReady or growth.isHarvestable then
                return "harvestable"
            end
            if growth.isGrowing then
                return "growing"
            end
            return "growing"
        end

        local lastGrowth = FieldAdvisor.getLastGrowthState(state)
        if lastGrowth > 0 then
            local lastGrowthFlags = FieldAdvisor.evaluateFruitGrowth(fruitTypeIndex, lastGrowth)
            if lastGrowthFlags.isCut then
                return "cut"
            end
            if lastGrowthFlags.isWithered then
                return "withered"
            end
            if lastGrowthFlags.isHarvestReady or lastGrowthFlags.isHarvestable then
                return "harvestable"
            end
            if lastGrowthFlags.isGrowing then
                return "growing"
            end
        end

        return nil
    end

    -- Center probe first: edge regrowth must not re-trigger mow on a freshly cut meadow.
    local phase = phaseForState(probeState)
    if phase == "cut" then
        return "cut"
    end

    if fieldState ~= probeState then
        local representativePhase = phaseForState(fieldState)
        if representativePhase == "cut" then
            return "cut"
        end
    end

    if phase ~= nil then
        if phase == "harvestable" and aggregation ~= nil then
            if (aggregation.maxStubbleShredLevel or 0) > 0 then
                return "cut"
            end
            if aggregation.representativeState ~= nil then
                local repPhase = phaseForState(aggregation.representativeState)
                if repPhase == "cut" then
                    return "cut"
                end
            end
        end
        return phase
    end

    phase = phaseForState(fieldState)
    if phase ~= nil then
        return phase
    end

    if FieldAdvisor.getStateNumber(probeState, "stubbleShredLevel") > 0 then
        return "cut"
    end

    return "dormant"
end

---@param fieldState table|nil
---@param field table|nil
---@return boolean
function FieldAdvisor.isGrassHarvestable(fieldState, field, aggregation)
    return FieldAdvisor.getGrassMeadowPhase(fieldState, field, aggregation) == "harvestable"
end

---@param fieldState table|nil
---@param field table|nil
---@param aggregation table|nil
---@return boolean
function FieldAdvisor.isGrassCut(fieldState, field, aggregation)
    return FieldAdvisor.getGrassMeadowPhase(fieldState, field, aggregation) == "cut"
end

---@param fieldState table|nil
---@return number
function FieldAdvisor.getLastGrowthState(fieldState)
    return FieldAdvisor.getStateNumber(fieldState, "lastGrowthState")
end

---@param fieldState table|nil
---@param baseline table|nil
---@param field table|nil
---@return boolean
function FieldAdvisor.isGrassPostCutCleared(fieldState, baseline, field)
    if fieldState == nil or baseline == nil then
        return false
    end

    if FieldAdvisor.isGrassCut(fieldState, field, nil) or FieldAdvisor.isGrassHarvestable(fieldState, field, nil) then
        return false
    end

    if baseline.wasGrassCut == true and FieldAdvisor.getGrowthState(fieldState) <= 0 then
        return true
    end

    local fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    if fruitDesc ~= nil and fruitDesc.getIsGrowing ~= nil then
        local ok, isGrowing = pcall(fruitDesc.getIsGrowing, fruitDesc, FieldAdvisor.getGrowthState(fieldState))
        if ok and isGrowing == true and baseline.wasGrassCut == true then
            return true
        end
    end

    if baseline.wasGrassCut == true
        and FieldAdvisor.getLastGrowthState(fieldState) ~= (baseline.lastGrowthState or -1) then
        return true
    end

    return false
end

---@param fieldState table|nil
---@return number|nil
function FieldAdvisor.getFruitTypeIndex(fieldState)
    if fieldState == nil then
        return nil
    end

    if fieldState.fruitTypeIndex ~= nil and fieldState.fruitTypeIndex > 0 then
        return fieldState.fruitTypeIndex
    end

    if fieldState.currentFruitTypeIndex ~= nil and fieldState.currentFruitTypeIndex > 0 then
        return fieldState.currentFruitTypeIndex
    end

    return nil
end

---@param fieldState table|nil
---@return number
function FieldAdvisor.getGrowthState(fieldState)
    return FieldAdvisor.getStateNumber(fieldState, "growthState")
end

---@param fieldState table|nil
---@param field table|nil
---@return boolean
function FieldAdvisor.isFieldUnsown(fieldState, field)
    if FieldAdvisor.isGrassFieldState(fieldState, field) then
        return false
    end

    if fieldState == nil then
        return true
    end

    local growthState = FieldAdvisor.getGrowthState(fieldState)
    local groundType = FieldAdvisor.getGroundTypeName(fieldState)
    local fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, field)

    if FieldAdvisor.groundTypeIsOneOf(groundType, { "SOWN", "PLANTED", "RIDGE_SOWN", "ROLLER_LINES" }) then
        return growthState <= 0
    end

    if fruitTypeIndex == nil then
        return growthState <= 0
    end

    if FruitType ~= nil and fruitTypeIndex == FruitType.UNKNOWN then
        return growthState <= 0
            and not FieldAdvisor.groundTypeIsOneOf(groundType, { "CULTIVATED", "PLOWED", "SEEDBED" })
    end

    return growthState <= 0
end

---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isFieldSown(fieldState)
    if fieldState == nil then
        return false
    end

    local growthState = FieldAdvisor.getGrowthState(fieldState)
    local groundType = FieldAdvisor.getGroundTypeName(fieldState)

    if FieldAdvisor.groundTypeIsOneOf(groundType, { "SOWN", "PLANTED", "RIDGE_SOWN" }) then
        return true
    end

    if growthState > 0 and FieldAdvisor.resolveFruitTypeIndex(fieldState, nil) ~= nil then
        return true
    end

    return false
end

---@param fieldState table|nil
---@return boolean
function FieldAdvisor.hasActiveCrop(fieldState)
    if fieldState == nil then
        return false
    end

    if FieldAdvisor.isFieldSown(fieldState) then
        return true
    end

    local growthState = FieldAdvisor.getGrowthState(fieldState)
    if growthState > 0 then
        local fruitTypeIndex = FieldAdvisor.getFruitTypeIndex(fieldState)
        if fruitTypeIndex ~= nil and fruitTypeIndex > 0 then
            if FieldAdvisor.isGrassCrop(fruitTypeIndex) and FieldAdvisor.isBareSoilProbe(fieldState, nil) then
                return false
            end
        end
        return true
    end

    local fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, nil)
    if fruitTypeIndex == nil then
        return false
    end

    if FruitType ~= nil and fruitTypeIndex == FruitType.UNKNOWN then
        return false
    end

    return growthState > 0
end

---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isWithered(fieldState)
    if fieldState == nil then
        return false
    end

    local growthState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if growthState <= 0 then
        return false
    end

    local fruitTypeIndex = FieldAdvisor.getFruitTypeIndex(fieldState)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 or g_fruitTypeManager == nil then
        return false
    end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitDesc == nil then
        return false
    end

    if fruitDesc.getIsWithered ~= nil then
        local success, isWithered = pcall(fruitDesc.getIsWithered, fruitDesc, growthState)
        if success and isWithered == true then
            return true
        end
    end

    if fruitDesc.witheredState ~= nil and growthState == fruitDesc.witheredState then
        return true
    end

    return false
end

---@param fieldState table|nil
---@return string
function FieldAdvisor.formatGrowthLabel(fieldState)
    local growthState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if growthState <= 0 then
        return "-"
    end

    if FieldAdvisor.isWithered(fieldState) then
        return string.format("V%d", growthState)
    end

    return tostring(growthState)
end

---@param field table
---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isPostHarvestSoilWorkPhase(field, fieldState)
    if FieldAdvisor.isWithered(fieldState) then
        return true
    end

    if FieldAdvisor.hasActiveCrop(fieldState) then
        return false
    end

    if FieldAdvisor.isHarvestReady(field, fieldState) then
        return false
    end

    return true
end

---@param field table|nil
---@param fieldId number|nil
---@param fieldState table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return boolean
function FieldAdvisor.fieldHasPartialSoilWork(field, fieldId, fieldState, worldX, worldZ)
    if field == nil or fieldState == nil then
        return false
    end

    if worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end

    if worldX == nil or worldZ == nil then
        return false
    end

    local centerIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
    local centerGrass = FieldAdvisor.isGrassFieldState(fieldState, field)

    if FieldAdvisor.classifyProbe(fieldState, field) ~= FieldAdvisor.PROBE_SITUATION.GRASS then
        return false
    end

    local points = {}
    if FieldTaskCompletion ~= nil and FieldTaskCompletion.collectSamplePoints ~= nil then
        points = FieldTaskCompletion.collectSamplePoints(field, worldX, worldZ)
    else
        points[#points + 1] = { x = worldX, z = worldZ }
    end

    for _, point in ipairs(points) do
        if FieldAdvisor.isPositionInsideFieldOrUnknown(field, point.x, point.z) then
            local sampleState = FieldAdvisor.getEnrichedFieldState(field, fieldId, point.x, point.z)
            local groundType = FieldAdvisor.getGroundTypeName(sampleState)
            if FieldAdvisor.groundTypeIsOneOf(groundType, FieldAdvisor.SOIL_WORK_GROUND_TYPES) then
                return true
            end
        end
    end

    return false
end

---@param field table|nil
---@param fieldId number|nil
---@param fieldState table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return string
function FieldAdvisor.getFieldFruitDisplayLabel(field, fieldId, fieldState, worldX, worldZ, aggregation)
    aggregation = aggregation
        or FieldAdvisor.aggregateFieldProbes(field, fieldId, fieldState, worldX, worldZ)

    if aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL then
        return "-"
    end

    if aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.ARABLE then
        local fruitTypeIndex = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, fieldState)
        local label = FieldAdvisor.getLocalizedFruitTitle(fruitTypeIndex)
        if label ~= "-" and not FieldAdvisor.fieldHasPartialSoilWork(field, fieldId, fieldState, worldX, worldZ) then
            return label
        end
    end

    if aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS then
        local centerState = aggregation.centerState or fieldState
        local centerFruit = FieldAdvisor.getFruitTypeIndex(centerState)

        if worldX ~= nil and worldZ ~= nil and rawget(_G, "FSDensityMapUtil") ~= nil then
            if FSDensityMapUtil.getFruitTypeIndexAtWorldPos ~= nil then
                local ok, detectedIndex = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, worldX, worldZ)
                detectedIndex = ok and tonumber(detectedIndex) or nil
                if detectedIndex ~= nil and detectedIndex > 0
                    and FieldAdvisor.isGrassCrop(detectedIndex)
                    and not FieldAdvisor.isGenericGrassFruitIndex(detectedIndex) then
                    centerFruit = detectedIndex
                end
            end
        end

        if FieldAdvisor.isGenericGrassFruitIndex(centerFruit)
            and aggregation.dominantGrassFruit ~= nil
            and not FieldAdvisor.isGenericGrassFruitIndex(aggregation.dominantGrassFruit) then
            centerFruit = aggregation.dominantGrassFruit
        end

        local fruitTypeIndex = centerFruit
        if FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) or fruitTypeIndex == nil then
            fruitTypeIndex = FieldAdvisor.resolveGrassFruitTypeIndex(
                centerState, field, aggregation, worldX, worldZ
            )
        else
            fruitTypeIndex = FieldAdvisor.refineGrassFruitTypeIndex(
                centerState, field, fruitTypeIndex, worldX, worldZ
            )
        end
        if FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex) then
            local nameHint = FieldAdvisor.inferGrassFruitTypeIndexFromField(field)
                or FieldAdvisor.inferGrassFruitTypeIndexFromState(centerState)
            if nameHint ~= nil and not FieldAdvisor.isGenericGrassFruitIndex(nameHint) then
                fruitTypeIndex = nameHint
            end
        end
        local label = FieldAdvisor.getLocalizedFruitTitle(fruitTypeIndex)
        local hasPartialWork = FieldAdvisor.fieldHasPartialSoilWork(field, fieldId, fieldState, worldX, worldZ)
        -- Specific grass crops (Luzerne/Klee) must not collapse to generic "Gras (teilw. bearb.)"
        -- when probes already resolved a non-generic index — e.g. mown alfalfa with worked strips.
        if label ~= "-"
            and (not hasPartialWork or not FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex)) then
            return label
        end
        if not hasPartialWork then
            return FieldAdvisor.text("ftdl_fruit_grass", "Gras")
        end
        return FieldAdvisor.text("ftdl_fruit_partial_grass", "Gras (teilw. bearb.)")
    end

    if FieldAdvisor.fieldHasPartialSoilWork(field, fieldId, fieldState, worldX, worldZ) then
        local planned = fieldState ~= nil and fieldState.plannedFruit or nil
        if planned == "FALLOW" then
            return FieldAdvisor.text("ftdl_fruit_partial_fallow", "Brache (teilw.)")
        end
        return FieldAdvisor.text("ftdl_fruit_partial_grass", "Gras (teilw. bearb.)")
    end

    return "-"
end

---@param field table
---@param fieldState table|nil
---@param aggregation table|nil
---@return string
function FieldAdvisor.getCropPhase(field, fieldState, aggregation)
    local fieldId = field.getId ~= nil and field:getId() or nil
    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)

    if aggregation ~= nil and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL then
        local centerHasCrop = aggregation.centerSituation == FieldAdvisor.PROBE_SITUATION.ARABLE
            or FieldAdvisor.isFieldSown(harvestState)
            or FieldAdvisor.hasActiveCrop(harvestState)
        if not centerHasCrop then
            return "empty"
        end
    end

    if aggregation ~= nil and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.ARABLE then
        local arableFruit = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, harvestState)
        if FieldAdvisor.isCropHarvestReady(field, harvestState, arableFruit) then
            return "harvest_ready"
        end
        if FieldAdvisor.isWithered(harvestState) then
            return "withered"
        end
        return "growing"
    end

    if FieldAdvisor.isGrassFieldState(harvestState, field)
        or (aggregation ~= nil and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS) then
        if FieldAdvisor.fieldHasPartialSoilWork(field, fieldId, harvestState) then
            return "growing"
        end

        local probeState = aggregation ~= nil and aggregation.centerState or harvestState
        if FieldAdvisor.isGrassPostMowState(probeState, field, nil) then
            return "growing"
        end

        local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)
        if meadowPhase == "harvestable" then
            return "harvest_ready"
        end
        if meadowPhase == "cut" or meadowPhase == "growing" then
            return "growing"
        end
        if meadowPhase == "withered" then
            return "withered"
        end
        return "growing"
    end

    if FieldAdvisor.fieldHasPartialSoilWork(field, fieldId, harvestState) then
        return "empty"
    end

    local arableFruit = FieldAdvisor.resolveFruitTypeIndex(harvestState, field)
    if FieldAdvisor.isCropHarvestReady(field, harvestState, arableFruit) then
        return "harvest_ready"
    end

    if FieldAdvisor.isGrassHarvestable(harvestState, field, aggregation)
        and not FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(harvestState)) then
        return "harvest_ready"
    end

    if FieldAdvisor.isWithered(harvestState) then
        return "withered"
    end

    if FieldAdvisor.hasActiveCrop(harvestState) then
        return "growing"
    end

    if FieldAdvisor.getGrowthState(harvestState) > 0 and not FieldAdvisor.isWithered(harvestState) then
        if FieldAdvisor.groundTypeIsOneOf(FieldAdvisor.getGroundTypeName(harvestState), {
            "SOWN", "PLANTED", "RIDGE_SOWN", "ROLLER_LINES",
        }) then
            return "growing"
        end
    end

    if FieldAdvisor.isFieldUnsown(harvestState, field) then
        return "empty"
    end

    if FieldAdvisor.isFieldSown(harvestState) then
        return "growing"
    end

    return "post_harvest"
end

---@param field table
---@param fieldState table|nil
---@param aggregation table|nil
---@return string
function FieldAdvisor.getExpectedHarvestLabel(field, fieldState, aggregation, grassResidueSummary)
    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)

    if aggregation ~= nil and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL then
        return "-"
    end

    if FieldAdvisor.isGrassFieldState(harvestState, field)
        or (aggregation ~= nil and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS) then
        local residueState = grassResidueSummary ~= nil and grassResidueSummary.residueState
            or FieldAdvisor.GRASS_RESIDUE_NONE
        if residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE then
            return FieldAdvisor.text("ftdl_action_regrowth", "Nachwuchs")
        end

        local postMowLabel = FieldAdvisor.getGrassPostMowDisplayLabel(field, harvestState, aggregation, grassResidueSummary)
        if postMowLabel ~= nil then
            return postMowLabel
        end

        local probeState = aggregation ~= nil and aggregation.centerState or harvestState
        local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)

        if meadowPhase == "cut" then
            postMowLabel = FieldAdvisor.getGrassPostMowDisplayLabel(field, harvestState, aggregation, grassResidueSummary)
            if postMowLabel ~= nil then
                return postMowLabel
            end
        end

        if meadowPhase == "harvestable" then
            return FieldAdvisor.text("ftdl_action_grass_mow_short", "Mähen")
        end

        if meadowPhase == "withered" then
            return FieldAdvisor.text("ftdl_action_withered", "Verdorrt")
        end

        local grassFruit = FieldAdvisor.resolveGrassFruitTypeIndex(harvestState, field, aggregation)
            or (aggregation ~= nil and aggregation.dominantGrassFruit)
        local harvestWindow = FieldAdvisor.getHarvestWindowHint(grassFruit, harvestState)
        if harvestWindow ~= "-" then
            return FieldAdvisor.formatHarvestWindowLabel(harvestWindow)
        end

        if meadowPhase == "growing" or FieldAdvisor.getEffectiveGrowthState(harvestState) > 0 then
            return FieldAdvisor.text("ftdl_action_growing", "Wächst")
        end

        return FieldAdvisor.text("ftdl_fruit_grass", "Gras")
    end

    if FieldAdvisor.isFieldUnsown(harvestState, field) then
        return "-"
    end

    if FieldAdvisor.isWithered(harvestState) then
        return FieldAdvisor.text("ftdl_action_withered", "Verdorrt")
    end

    local arableFruit = FieldAdvisor.resolveFruitTypeIndex(harvestState, field)
    if FieldAdvisor.isCropHarvestReady(field, harvestState, arableFruit) then
        return FieldAdvisor.text(
            "ftdl_action_harvest_now_short",
            "Jetzt (%s)",
            PrecisionFarmingReader.getCurrentMonthLabel()
        )
    end

    local harvestFruit = arableFruit
    if harvestFruit == nil and aggregation ~= nil and aggregation.dominantArableFruit ~= nil then
        if aggregation.centerSituation == FieldAdvisor.PROBE_SITUATION.ARABLE
            or FieldAdvisor.hasActiveCrop(harvestState) then
            harvestFruit = aggregation.dominantArableFruit
        end
    end
    local harvestWindow = FieldAdvisor.getHarvestWindowHint(harvestFruit, harvestState)
    if harvestWindow ~= "-" then
        return FieldAdvisor.formatHarvestWindowLabel(harvestWindow)
    end

    if FieldAdvisor.hasActiveCrop(harvestState) then
        return FieldAdvisor.text("ftdl_action_growing", "Wächst")
    end

    return "-"
end

---@param fruitTypeIndex number|nil
---@param fieldState table|nil
---@return string
function FieldAdvisor.getHarvestWindowHint(fruitTypeIndex, fieldState)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 or g_fruitTypeManager == nil then
        return "-"
    end

    if g_fruitTypeManager.getFruitTypeByIndex == nil then
        return "-"
    end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitDesc == nil then
        return "-"
    end

    local period = FieldAdvisor.getExpectedHarvestPeriod(fruitTypeIndex, fieldState)
    if period ~= nil then
        return FieldAdvisor.getHarvestPeriodDisplayLabel(period)
    end

    local currentState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if currentState <= 0 and FieldAdvisor.hasActiveCrop(fieldState) then
        currentState = 1
    end
    period = FieldAdvisor.getNextPrimaryHarvestablePeriod(
        fruitDesc, fruitTypeIndex, FieldAdvisor.getActiveGrowthMode(),
        FieldAdvisor.getCurrentSeasonPeriod(), currentState)
    if period ~= nil then
        return FieldAdvisor.getHarvestPeriodDisplayLabel(period)
    end

    return "-"
end

---@param field table
---@param fieldState table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param aggregation table|nil
---@return table context
function FieldAdvisor.buildFieldContext(field, fieldState, worldX, worldZ, aggregation)
    local rules = FieldGameRules.get()
    local fieldId = field ~= nil and field.getId ~= nil and field:getId() or nil

    if aggregation == nil then
        aggregation = FieldAdvisor.aggregateFieldProbes(field, fieldId, fieldState, worldX, worldZ)
    end

    local probeState = aggregation.centerState or fieldState

    local pfSample = nil
    if PrecisionFarmingReader.isModLoaded() then
        pfSample = PrecisionFarmingReader.sampleField(worldX, worldZ, probeState, field)
    end

    local scsSample = nil
    if SeasonalCropStressReader.isRuntimeReady ~= nil and SeasonalCropStressReader.isRuntimeReady() then
        scsSample = SeasonalCropStressReader.sampleField(field)
    end

    local weedSummary = rules.weedsEnabled
        and FieldAdvisor.sampleWeedCoverage(field, fieldId, worldX, worldZ)
        or nil

    local probeSituation = FieldAdvisor.classifyProbe(probeState, field)
    local fieldGrassHint = FieldAdvisor.inferGrassFruitTypeIndexFromField(field)
    local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)
    local isCutGround = FieldAdvisor.isGrassPostMowState(probeState, field, nil)
    local cachedGrassResidue = FieldAdvisor.getCoverageCache(
        fieldId,
        "grassResidue",
        FieldAdvisor.GRASS_RESIDUE_CACHE_TTL_IDLE_MS
    )
    local cachedBales = FieldAdvisor.getCoverageCache(
        fieldId,
        "bales",
        FieldAdvisor.BALE_CACHE_TTL_IDLE_MS
    )
    local hasTrackedResidue = cachedGrassResidue ~= nil
        and cachedGrassResidue.residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE
    local hasTrackedBales = cachedBales ~= nil and (cachedBales.total or 0) > 0

    local isGrassCropField = FieldAdvisor.isGrassCropFieldContext(aggregation, probeState, field, worldX, worldZ)
    local isStandingGrassCrop = FieldAdvisor.isGrassStandingCropPhase(
        meadowPhase, probeState, field, FieldAdvisor.getFruitTypeIndex(probeState)
    )
    local hasPostMowSignal = meadowPhase == "cut" or isCutGround
        or FieldAdvisor.isGrassPostMowState(probeState, field, nil)
        or (aggregation ~= nil and (aggregation.maxStubbleShredLevel or 0) > 0)
        or FieldAdvisor.getStateNumber(probeState, "stubbleShredLevel") > 0
        or FieldAdvisor.fieldHasPostMowGrassSignal(aggregation, probeState, field, nil)
    local shouldTrackGrassResidue = isGrassCropField
        and not (isStandingGrassCrop and not FieldAdvisor.fieldHasPostMowGrassSignal(aggregation, probeState, field, nil))
    local isActiveResiduePhase = hasPostMowSignal or hasTrackedResidue or hasTrackedBales
        or meadowPhase == "cut" or meadowPhase == "growing"
    local residueTtl = isActiveResiduePhase
        and FieldAdvisor.GRASS_RESIDUE_CACHE_TTL_ACTIVE_MS
        or FieldAdvisor.GRASS_RESIDUE_CACHE_TTL_IDLE_MS
    local residueMaxPoints = isGrassCropField
        and FieldAdvisor.GRASS_RESIDUE_MAX_SAMPLE_POINTS
        or FieldAdvisor.GRASS_RESIDUE_IDLE_SAMPLE_POINTS

    local grassFruitHint = FieldAdvisor.resolveGrassFruitTypeIndex(probeState, field, aggregation, worldX, worldZ)
        or fieldGrassHint

    local baleTtl = isActiveResiduePhase
        and FieldAdvisor.BALE_CACHE_TTL_ACTIVE_MS
        or FieldAdvisor.BALE_CACHE_TTL_IDLE_MS
    local shouldSampleBales = isGrassCropField or shouldTrackGrassResidue or hasTrackedBales
    local baleSummary = shouldSampleBales
        and FieldAdvisor.sampleBaleCoverage(field, baleTtl)
        or nil

    local grassResidueSummary = nil
    if shouldTrackGrassResidue then
        local staleNoneCache = cachedGrassResidue ~= nil
            and cachedGrassResidue.residueState == FieldAdvisor.GRASS_RESIDUE_NONE
        grassResidueSummary = FieldAdvisor.sampleGrassResidueCoverage(
            field, fieldId, worldX, worldZ, residueTtl, residueMaxPoints, grassFruitHint, baleSummary, aggregation,
            not (hasPostMowSignal and staleNoneCache)
        )
        grassResidueSummary = FieldAdvisor.refineGrassResidueSummary(
            grassResidueSummary, aggregation, probeState, field, worldX, worldZ, grassFruitHint
        )
        if grassResidueSummary ~= nil then
            local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)
            if FieldAdvisor.isGrassCollectEffectivelyDone(grassResidueSummary, nil) then
                grassResidueSummary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
                grassResidueSummary.residueAvailable = false
            elseif FieldAdvisor.shouldTreatGrassResidueAsSwath(
                grassResidueSummary, aggregation, probeState, field, worldX, worldZ,
                grassFruitHint, meadowPhase) then
                grassResidueSummary.residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
                grassResidueSummary.residueAvailable = true
            end
        end
        if fieldId ~= nil then
            FieldAdvisor.setCoverageCache(fieldId, "grassResidue", grassResidueSummary)
        end
    elseif isGrassCropField then
        grassResidueSummary = cachedGrassResidue
    end

    if isGrassCropField and baleSummary ~= nil and FieldAdvisor.getFieldBaleCount(baleSummary) > 0 then
        if grassResidueSummary == nil then
            grassResidueSummary = {
                residueState = FieldAdvisor.GRASS_RESIDUE_NONE,
                residueAvailable = false,
                total = 0,
                occupied = 0,
                occupiedRatio = 0,
            }
        end
        grassResidueSummary = FieldAdvisor.applyFieldBaleResidueOverlay(grassResidueSummary, baleSummary)
        if fieldId ~= nil then
            FieldAdvisor.setCoverageCache(fieldId, "grassResidue", grassResidueSummary)
        end
    end

    if grassResidueSummary ~= nil and baleSummary ~= nil then
        grassResidueSummary.fieldBaleCount = FieldAdvisor.getFieldBaleCount(baleSummary)
        if grassResidueSummary.residueState == FieldAdvisor.GRASS_RESIDUE_BALED then
            if grassResidueSummary.fieldBaleCount <= 0 then
                grassResidueSummary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
                grassResidueSummary.residueAvailable = false
                grassResidueSummary.residueSource = "none"
            elseif FieldAdvisor.hasGrassSwathMaterialRemaining(grassResidueSummary) then
                grassResidueSummary.residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
                grassResidueSummary.residueAvailable = true
            end
        end
    end

    return {
        field = field,
        fieldId = fieldId,
        worldX = worldX,
        worldZ = worldZ,
        fieldState = probeState,
        rules = rules,
        pfSample = pfSample,
        scsSample = scsSample,
        weedSummary = weedSummary,
        grassResidueSummary = grassResidueSummary,
        baleSummary = baleSummary,
        needsPlowing = FieldAdvisor.getStateBool(probeState, "needsPlowing"),
        needsLime = FieldAdvisor.getStateBool(probeState, "needsLime"),
        needsRolling = FieldAdvisor.getStateBool(probeState, "needsRolling"),
        plowLevel = FieldAdvisor.getStateNumber(probeState, "plowLevel"),
        limeLevel = FieldAdvisor.getStateNumber(probeState, "limeLevel"),
        weedState = FieldAdvisor.getStateNumber(probeState, "weedState"),
        weedFactor = FieldAdvisor.getWeedFactor(probeState),
        stoneLevel = FieldAdvisor.getStateNumber(probeState, "stoneLevel"),
        rollerLevel = FieldAdvisor.getStateNumber(probeState, "rollerLevel"),
    }
end

---@param actions table[]
---@param action table
local function FieldAdvisor_addAction(actions, action)
    if action == nil then
        return
    end

    for _, existing in ipairs(actions) do
        if existing.actionType == action.actionType then
            return
        end
    end

    actions[#actions + 1] = action
end

---@param pass number
---@param passTotal number
---@return string
function FieldAdvisor.getOrganicFertilizerPassLabel(pass, passTotal)
    local safePass = math.max(1, math.floor(tonumber(pass) or 1))
    local safeTotal = math.max(safePass, math.floor(tonumber(passTotal) or safePass))

    return FieldAdvisor.text("ftdl_action_organic_pass", "Mist/Gülle %d/%d", safePass, safeTotal)
end

---@param actions table[]
---@param pfSample table|nil
---@return table[]
function FieldAdvisor.expandOrganicFertilizerPasses(actions, pfSample)
    if actions == nil or not FieldAdvisorSettings.isOrganicMultiPassEnabled() then
        return actions
    end

    local nitrogen = pfSample ~= nil and tonumber(pfSample.nitrogenValue) or nil
    local passCount = FieldAdvisor.getOrganicFertilizerPassCount(nitrogen)
    if passCount <= 1 then
        return actions
    end

    local expanded = {}
    for _, action in ipairs(actions) do
        if action.actionType == "pf_n" then
            for pass = 1, passCount do
                expanded[#expanded + 1] = {
                    actionType = "pf_n",
                    fertPass = pass,
                    fertPassTotal = passCount,
                    label = FieldAdvisor.getOrganicFertilizerPassLabel(pass, passCount),
                    autoComplete = true,
                }
            end
        else
            expanded[#expanded + 1] = action
        end
    end

    return expanded
end

---@param nitrogen number|nil
---@return number
function FieldAdvisor.getOrganicFertilizerPassCount(nitrogen)
    if nitrogen == nil or nitrogen >= 80 then
        return 1
    end

    if nitrogen < 45 then
        return 3
    end

    if nitrogen < 65 then
        return 2
    end

    return 2
end

---@param pass number
---@param passTotal number
---@param targetN number
---@return number
function FieldAdvisor.getOrganicFertilizerPassTarget(pass, passTotal, targetN)
    local safePass = math.max(1, math.floor(tonumber(pass) or 1))
    local safeTotal = math.max(safePass, math.floor(tonumber(passTotal) or safePass))
    local safeTarget = tonumber(targetN) or 80

    return math.floor(safeTarget * (safePass / safeTotal))
end

--- Boden-Schritte zwischen Mist/Gülle-Durchgängen (nie zwei Düngungen direkt hintereinander).
---@param soilActions table[]
---@return table[]
function FieldAdvisor.collectOrganicInterleaveSlots(soilActions)
    local slots = {}
    local slotOrder = { "plow", "cultivate", "lime", "sow", "roller" }

    for _, slotType in ipairs(slotOrder) do
        for _, action in ipairs(soilActions) do
            if action.actionType == slotType then
                slots[#slots + 1] = action
                break
            end
        end
    end

    return slots
end

---@param action table|nil
---@return boolean
function FieldAdvisor.isOrganicInterleavePrefixSoil(action)
    if action == nil then
        return false
    end

    local actionType = action.actionType
    return actionType == "stones"
        or actionType == "weed_combat"
        or actionType == "weed_watch"
        or actionType == "pf_ph"
        or actionType == "harvest"
        or actionType == "harvest_info"
        or actionType == "growing"
        or actionType == "withered"
        or actionType == "grass_mow"
        or actionType == "grass_swath"
        or actionType == "grass_collect"
        or actionType == "grass_bale"
        or actionType == "grass_silage_bale"
        or actionType == "grass_bale_collect"
        or actionType == "scs_moisture"
        or actionType == "scs_stress_high"
        or actionType == "scs_stress_watch"
        or actionType == "none"
end

---@param actions table[]
---@return table[]
function FieldAdvisor.interleaveFertilizerPasses(actions)
    if actions == nil or #actions <= 1 or not FieldAdvisorSettings.isOrganicMultiPassEnabled() then
        return actions
    end

    local soilActions = {}
    local fertActions = {}

    for _, action in ipairs(actions) do
        if action.actionType == "pf_n" and action.fertPass ~= nil then
            fertActions[#fertActions + 1] = action
        else
            soilActions[#soilActions + 1] = action
        end
    end

    if #fertActions <= 1 then
        return actions
    end

    table.sort(fertActions, function(a, b)
        return (tonumber(a.fertPass) or 0) < (tonumber(b.fertPass) or 0)
    end)

    local prefixSoil = {}
    local interleaveSlots = FieldAdvisor.collectOrganicInterleaveSlots(soilActions)
    local slotted = {}

    for _, action in ipairs(interleaveSlots) do
        slotted[action] = true
    end

    for _, action in ipairs(soilActions) do
        if FieldAdvisor.isOrganicInterleavePrefixSoil(action) then
            prefixSoil[#prefixSoil + 1] = action
        elseif not slotted[action] then
            prefixSoil[#prefixSoil + 1] = action
        end
    end

    -- Mist/Gülle passes between soil work (user picks manure or slurry each time).
    local maxPasses = #interleaveSlots + 1
    while #fertActions > maxPasses do
        table.remove(fertActions)
    end

    for index, action in ipairs(fertActions) do
        action.fertPass = index
        action.fertPassTotal = #fertActions
        action.label = FieldAdvisor.getOrganicFertilizerPassLabel(index, #fertActions)
    end

    if #fertActions == 0 then
        return actions
    end

    local interleaved = {}

    if #interleaveSlots == 0 then
        -- No plow/sow/lime/roller/cultivate on this field: at most one Mist/Gülle pass.
        fertActions[1].fertPass = 1
        fertActions[1].fertPassTotal = 1
        fertActions[1].label = FieldAdvisor.getOrganicFertilizerPassLabel(1, 1)
        interleaved[#interleaved + 1] = fertActions[1]
    else
        for fertIndex = 1, #fertActions do
            interleaved[#interleaved + 1] = fertActions[fertIndex]
            if fertIndex < #fertActions then
                local separator = interleaveSlots[fertIndex]
                if separator == nil then
                    break
                end
                interleaved[#interleaved + 1] = separator
            end
        end
    end

    local result = {}
    for _, action in ipairs(prefixSoil) do
        result[#result + 1] = action
    end
    for _, action in ipairs(interleaved) do
        result[#result + 1] = action
    end

    return result
end

---@param actions table[]
---@param pfSample table|nil
---@return table[]
function FieldAdvisor.finishActionCandidates(actions, pfSample)
    actions = FieldAdvisor.expandOrganicFertilizerPasses(actions, pfSample)

    if FieldAdvisorSettings.isOrganicMultiPassEnabled() then
        return FieldAdvisor.interleaveFertilizerPasses(actions)
    end

    return FieldAdvisorSettings.sortActions(actions)
end

---@param actions table[]
---@param fieldState table|nil
---@param field table
---@param aggregation table|nil
---@param grassResidueSummary table|nil
---@param baleSummary table|nil
function FieldAdvisor.addGrassWorkActions(actions, fieldState, field, aggregation, grassResidueSummary, baleSummary)
    local probeState = fieldState
    if aggregation ~= nil and aggregation.centerState ~= nil then
        probeState = aggregation.centerState
    end

    local worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    local grassFruitHint = FieldAdvisor.resolveGrassFruitTypeIndex(probeState, field, aggregation, worldX, worldZ)

    local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)
    local fieldBaleCountEarly = FieldAdvisor.getFieldBaleCount(baleSummary)
    if fieldBaleCountEarly > 0 and grassResidueSummary ~= nil
        and grassResidueSummary.residueState == FieldAdvisor.GRASS_RESIDUE_BALED
        and not FieldAdvisor.hasGrassSwathMaterialRemaining(grassResidueSummary) then
        meadowPhase = "cut"
    end

    if meadowPhase == "harvestable"
        and FieldAdvisor.isGrassStandingCropPhase(meadowPhase, probeState, field, grassFruitHint)
        and not FieldAdvisor.isGrassPostMowState(probeState, field, grassFruitHint)
        and not FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(probeState)) then
        FieldAdvisor_addAction(actions, {
            actionType = "grass_mow",
            label = FieldAdvisor.text("ftdl_action_grass_mow", "Mähen"),
            pickerLabel = FieldAdvisor.text("ftdl_action_grass_mow", "Mähen"),
            autoComplete = true,
        })
        return
    end

    grassResidueSummary = FieldAdvisor.refineGrassResidueSummary(
        grassResidueSummary, aggregation, probeState, field, worldX, worldZ, grassFruitHint
    )

    local residueState = grassResidueSummary ~= nil and grassResidueSummary.residueState
        or FieldAdvisor.GRASS_RESIDUE_NONE
    local fieldBaleCount = FieldAdvisor.getFieldBaleCount(baleSummary)

    if residueState == FieldAdvisor.GRASS_RESIDUE_BALED and fieldBaleCount <= 0 then
        residueState = FieldAdvisor.GRASS_RESIDUE_NONE
        if grassResidueSummary ~= nil then
            grassResidueSummary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
            grassResidueSummary.residueAvailable = false
            grassResidueSummary.residueSource = "none"
        end
    elseif residueState == FieldAdvisor.GRASS_RESIDUE_BALED
        and FieldAdvisor.hasGrassSwathMaterialRemaining(grassResidueSummary) then
        residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
        if grassResidueSummary ~= nil then
            grassResidueSummary.residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
            grassResidueSummary.residueAvailable = true
        end
    elseif FieldAdvisor.isUniformCutFieldIdleResidue(grassResidueSummary) then
        residueState = FieldAdvisor.GRASS_RESIDUE_NONE
        if grassResidueSummary ~= nil then
            grassResidueSummary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
            grassResidueSummary.residueAvailable = false
            grassResidueSummary.residueSource = "none"
        end
    end

    local shredLevel = FieldAdvisor.getStateNumber(probeState, "stubbleShredLevel")
    if aggregation ~= nil then
        shredLevel = math.max(shredLevel, tonumber(aggregation.maxStubbleShredLevel) or 0)
    end

    if FieldAdvisor.isGrassPostMowState(probeState, field, grassFruitHint) then
        meadowPhase = "cut"
    end

    if meadowPhase ~= "harvestable"
        and residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE then
        -- Fallback: if residue is physically present, we are in post-mow logistics.
        meadowPhase = "cut"
    end

    if meadowPhase == "harvestable"
        and FieldAdvisor.getStateNumber(probeState, "stubbleShredLevel") > 0 then
        meadowPhase = "cut"
    end

    if meadowPhase == "harvestable"
        and FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(probeState)) then
        meadowPhase = "cut"
    end

    if FieldAdvisor.shouldTreatGrassResidueAsSwath(
        grassResidueSummary, aggregation, probeState, field, worldX, worldZ, grassFruitHint, meadowPhase
    ) then
        residueState = FieldAdvisor.GRASS_RESIDUE_SWATH
        meadowPhase = "cut"
    elseif FieldAdvisor.isGrassCollectEffectivelyDone(grassResidueSummary, nil) then
        residueState = FieldAdvisor.GRASS_RESIDUE_NONE
        if grassResidueSummary ~= nil then
            grassResidueSummary.residueState = FieldAdvisor.GRASS_RESIDUE_NONE
            grassResidueSummary.residueAvailable = false
        end
    elseif meadowPhase ~= "harvestable" and residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE then
        meadowPhase = "cut"
    end

    if meadowPhase == "harvestable" then
        FieldAdvisor_addAction(actions, {
            actionType = "grass_mow",
            label = FieldAdvisor.text("ftdl_action_grass_mow", "Mähen"),
            pickerLabel = FieldAdvisor.text("ftdl_action_grass_mow", "Mähen"),
            autoComplete = true,
        })
        return
    end

    if meadowPhase == "cut" then
        if residueState == FieldAdvisor.GRASS_RESIDUE_NONE then
            local regrowthLabel = FieldAdvisor.getGrassPostMowDisplayLabel(field, fieldState, aggregation)
                or FieldAdvisor.getGrassHarvestWindowLabel(fieldState, field, aggregation)
            if regrowthLabel == "-" then
                regrowthLabel = FieldAdvisor.text("ftdl_action_regrowth", "Nachwuchs")
            end
            FieldAdvisor_addAction(actions, {
                actionType = "harvest_info",
                label = regrowthLabel,
                pickerLabel = regrowthLabel,
                autoComplete = false,
            })
        end

        if residueState == FieldAdvisor.GRASS_RESIDUE_LOOSE then
            FieldAdvisor_addAction(actions, {
                actionType = "grass_swath",
                label = FieldAdvisor.text("ftdl_action_grass_swath", "Schwaden"),
                pickerLabel = FieldAdvisor.text("ftdl_action_grass_swath", "Schwaden"),
                autoComplete = true,
            })
        elseif residueState == FieldAdvisor.GRASS_RESIDUE_SWATH then
            if FieldAdvisor.isGrassCollectEffectivelyDone(grassResidueSummary, nil) then
                local regrowthLabel = FieldAdvisor.getGrassPostMowDisplayLabel(field, fieldState, aggregation)
                    or FieldAdvisor.getGrassHarvestWindowLabel(fieldState, field, aggregation)
                if regrowthLabel == "-" then
                    regrowthLabel = FieldAdvisor.text("ftdl_action_regrowth", "Nachwuchs")
                end
                FieldAdvisor_addAction(actions, {
                    actionType = "harvest_info",
                    label = regrowthLabel,
                    pickerLabel = regrowthLabel,
                    autoComplete = false,
                })
            elseif not FieldAdvisor.hasGrassWindrowLineEvidence(grassResidueSummary)
                and not FieldAdvisor.hasGrassSwathMaterialRemaining(grassResidueSummary) then
                FieldAdvisor_addAction(actions, {
                    actionType = "grass_swath",
                    label = FieldAdvisor.text("ftdl_action_grass_swath", "Schwaden"),
                    pickerLabel = FieldAdvisor.text("ftdl_action_grass_swath", "Schwaden"),
                    autoComplete = true,
                })
            else
                FieldAdvisor_addAction(actions, {
                    actionType = "grass_collect",
                    label = FieldAdvisor.text("ftdl_action_grass_collect", "Heu sammeln (Ladewagen)"),
                    pickerLabel = FieldAdvisor.text("ftdl_action_grass_collect", "Heu sammeln (Ladewagen)"),
                    autoComplete = true,
                })
                FieldAdvisor_addAction(actions, {
                    actionType = "grass_bale",
                    label = FieldAdvisor.text("ftdl_action_grass_bale", "Ballen pressen"),
                    pickerLabel = FieldAdvisor.text("ftdl_action_grass_bale", "Ballen pressen"),
                    autoComplete = true,
                })
                FieldAdvisor_addAction(actions, {
                    actionType = "grass_silage_bale",
                    label = FieldAdvisor.text("ftdl_action_grass_silage_bale", "Silageballen pressen"),
                    pickerLabel = FieldAdvisor.text("ftdl_action_grass_silage_bale", "Silageballen pressen"),
                    autoComplete = true,
                })
            end
        elseif residueState == FieldAdvisor.GRASS_RESIDUE_BALED
            and fieldBaleCount > 0
            and not FieldAdvisor.hasGrassSwathMaterialRemaining(grassResidueSummary) then
            FieldAdvisor_addAction(actions, {
                actionType = "grass_bale_collect",
                label = FieldAdvisor.text("ftdl_action_grass_bale_collect", "Ballen einsammeln"),
                pickerLabel = FieldAdvisor.text("ftdl_action_grass_bale_collect", "Ballen einsammeln"),
                autoComplete = true,
            })
        end
    end
end

---@param field table
---@param fieldState table|nil
---@param pfSample table|nil
---@param scsSample table|nil
---@param rules table|nil
---@return table[] actions
function FieldAdvisor.resolveActionCandidates(field, fieldState, pfSample, scsSample, rules, aggregation, weedSummary, grassResidueSummary, baleSummary)
    rules = rules or FieldGameRules.get()
    local actions = {}

    local probeState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)
    local soilState = aggregation ~= nil and aggregation.representativeState or fieldState
    local isGrass = aggregation ~= nil
        and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS
    if not isGrass then
        isGrass = FieldAdvisor.isGrassFieldState(probeState, field)
    end
    local residueState = grassResidueSummary ~= nil and grassResidueSummary.residueState
        or FieldAdvisor.GRASS_RESIDUE_NONE
    local hasGrassResidue = residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE
    if not isGrass and not FieldAdvisor.isArableFieldContext(aggregation, probeState, field) then
        if hasGrassResidue or FieldAdvisor.inferGrassFruitTypeIndexFromField(field) ~= nil then
            isGrass = true
        end
    end
    local cropPhase = FieldAdvisor.getCropPhase(field, probeState, aggregation)
    local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)
    local standingGrassCrop = FieldAdvisor.isGrassStandingCropPhase(
        meadowPhase, probeState, field, FieldAdvisor.getFruitTypeIndex(probeState)
    )
    if hasGrassResidue and isGrass and cropPhase ~= "harvest_ready" and not standingGrassCrop then
        cropPhase = "growing"
    end
    local growthState = FieldAdvisor.getGrowthState(probeState)
    local postHarvestSoilWork = FieldAdvisor.isPostHarvestSoilWorkPhase(field, probeState)

    local needsPlowing = FieldAdvisor.getStateBool(fieldState, "needsPlowing")
    local needsRolling = FieldAdvisor.getStateBool(fieldState, "needsRolling")
    local plowLevel = FieldAdvisor.getStateNumber(fieldState, "plowLevel")
    local limeLevel = FieldAdvisor.getStateNumber(soilState, "limeLevel")
    local weedState = FieldAdvisor.getStateNumber(fieldState, "weedState")
    local stoneLevel = FieldAdvisor.getStateNumber(fieldState, "stoneLevel")
    local rollerLevel = FieldAdvisor.getStateNumber(fieldState, "rollerLevel")

    if cropPhase == "harvest_ready" then
        if isGrass then
            FieldAdvisor.addGrassWorkActions(actions, fieldState, field, aggregation, grassResidueSummary, baleSummary)
        else
            FieldAdvisor_addAction(actions, {
                actionType = "harvest",
                label = FieldAdvisor.text(
                    "ftdl_action_harvest_now",
                    "Jetzt ernten (%s)",
                    PrecisionFarmingReader.getCurrentMonthLabel()
                ),
                autoComplete = true,
            })
        end
    end

    if cropPhase == "withered" then
        if rules.stonesEnabled and stoneLevel > 0 then
            FieldAdvisor_addAction(actions, {
                actionType = "stones",
                label = FieldAdvisor.text("ftdl_action_stones_pick", "Steine lesen"),
                autoComplete = true,
            })
        end

        if not isGrass then
            FieldAdvisor_addAction(actions, {
                actionType = "cultivate",
                label = FieldAdvisor.text("ftdl_action_cultivate", "Grubbern"),
                pickerLabel = FieldAdvisor.text("ftdl_action_cultivate", "Grubbern"),
                autoComplete = true,
            })

            if rules.plowingRequiredEnabled then
                FieldAdvisor_addAction(actions, {
                    actionType = "plow",
                    label = FieldAdvisor.text("ftdl_action_plow", "Pflügen"),
                    pickerLabel = FieldAdvisor.text("ftdl_action_plow", "Pflügen"),
                    autoComplete = true,
                })
            end

            FieldAdvisor_addAction(actions, {
                actionType = "roller",
                label = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
                pickerLabel = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
                autoComplete = true,
            })
        end

        if FieldAdvisor.fieldNeedsLimeWork(soilState, rules) and not isGrass then
            FieldAdvisor_addAction(actions, {
                actionType = "lime",
                label = FieldAdvisor.text("ftdl_action_lime", "Kalken"),
                autoComplete = true,
            })
        end

        if not isGrass then
            FieldAdvisor_addAction(actions, {
                actionType = "sow",
                label = FieldAdvisor.text("ftdl_action_resow", "Neu ansäen"),
                autoComplete = true,
            })
        end

        return FieldAdvisor.finishActionCandidates(actions, pfSample)
    end

    if cropPhase == "growing" then
        if isGrass then
            FieldAdvisor.addGrassWorkActions(actions, fieldState, field, aggregation, grassResidueSummary, baleSummary)
        end

        if FieldAdvisor.fieldNeedsWeedCombat(fieldState, rules, weedSummary) then
            FieldAdvisor_addAction(actions, {
                actionType = "weed_combat",
                label = FieldAdvisor.text("ftdl_action_weed_combat_long", "Unkraut bekämpfen"),
                autoComplete = true,
            })
        elseif FieldAdvisor.fieldNeedsWeedWatch(fieldState, rules, weedSummary) then
            FieldAdvisor_addAction(actions, {
                actionType = "weed_watch",
                label = FieldAdvisor.text("ftdl_action_weed_watch_long", "Unkraut beobachten"),
                autoComplete = true,
            })
        end

        if rules.stonesEnabled and stoneLevel > 0 then
            FieldAdvisor_addAction(actions, {
                actionType = "stones",
                label = FieldAdvisor.text("ftdl_action_stones_pick", "Steine lesen"),
                autoComplete = true,
            })
        end

        if not isGrass and (needsRolling or rollerLevel > 0) then
            FieldAdvisor_addAction(actions, {
                actionType = "roller",
                label = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
                pickerLabel = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
                autoComplete = true,
            })
        end

        if not isGrass and pfSample ~= nil and pfSample.pHValue ~= nil and pfSample.pHValue < 6.0 then
            FieldAdvisor_addAction(actions, {
                actionType = "pf_ph",
                label = FieldAdvisor.text("ftdl_action_raise_ph", "pH anheben (Kalk)"),
                autoComplete = true,
            })
        end

        if not isGrass and pfSample ~= nil and pfSample.nitrogenValue ~= nil and pfSample.nitrogenValue < 80 then
            FieldAdvisor_addAction(actions, {
                actionType = "pf_n",
                label = FieldAdvisor.text("ftdl_action_fert_n", "Düngen (N)"),
                autoComplete = true,
            })
        end

        if SeasonalCropStressReader.isRuntimeReady()
            and scsSample ~= nil
            and scsSample.moisture ~= nil
            and scsSample.moisture < 0.25 then
            FieldAdvisor_addAction(actions, {
                actionType = "scs_moisture",
                label = FieldAdvisor.text("ftdl_action_irrigate_dry", "Bewässern (trocken)"),
                autoComplete = true,
            })
        end

        if SeasonalCropStressReader.isRuntimeReady()
            and scsSample ~= nil
            and scsSample.stress ~= nil
            and scsSample.stress >= 0.6 then
            FieldAdvisor_addAction(actions, {
                actionType = "scs_stress_high",
                label = FieldAdvisor.text("ftdl_action_stress_high", "Pflanzenstress hoch"),
                autoComplete = true,
            })
        elseif SeasonalCropStressReader.isRuntimeReady()
            and scsSample ~= nil
            and scsSample.stress ~= nil
            and scsSample.stress >= 0.35 then
            FieldAdvisor_addAction(actions, {
                actionType = "scs_stress_watch",
                label = FieldAdvisor.text("ftdl_action_stress_watch", "Stress beobachten"),
                autoComplete = true,
            })
        end

        local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)
        local harvestFruit = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, harvestState)
        local harvestWindow = FieldAdvisor.getHarvestWindowHint(harvestFruit, harvestState)
        local growingLabel = harvestWindow ~= "-"
            and harvestWindow
            or FieldAdvisor.text("ftdl_action_growing", "Wächst")
        if harvestWindow ~= "-" then
            FieldAdvisor_addAction(actions, {
                actionType = "harvest_info",
                label = FieldAdvisor.text("ftdl_action_harvest_window", "Ernte %s", harvestWindow),
                pickerLabel = FieldAdvisor.text("ftdl_action_harvest_window", "Ernte %s", harvestWindow),
                autoComplete = false,
            })
        end

        FieldAdvisor_addAction(actions, {
            actionType = "growing",
            label = growingLabel,
            pickerLabel = growingLabel,
            autoComplete = false,
        })

        return FieldAdvisor.finishActionCandidates(actions, pfSample)
    end

    if cropPhase == "empty" or cropPhase == "post_harvest" then
        if rules.stonesEnabled and stoneLevel > 0 then
            FieldAdvisor_addAction(actions, {
                actionType = "stones",
                label = FieldAdvisor.text("ftdl_action_stones_pick", "Steine lesen"),
                autoComplete = true,
            })
        end

        if postHarvestSoilWork and not isGrass then
            if FieldAdvisor.fieldNeedsPlowingWork(fieldState, rules) then
                FieldAdvisor_addAction(actions, {
                    actionType = "plow",
                    label = FieldAdvisor.text("ftdl_action_plow_after_harvest", "Pflügen (nach Ernte)"),
                    autoComplete = true,
                })
            else
                FieldAdvisor_addAction(actions, {
                    actionType = "cultivate",
                    label = FieldAdvisor.text("ftdl_action_cultivate_after_harvest", "Grubbern (nach Ernte)"),
                    autoComplete = true,
                })
            end
        end

        if postHarvestSoilWork and FieldAdvisor.fieldNeedsLimeWork(soilState, rules) and not isGrass then
            FieldAdvisor_addAction(actions, {
                actionType = "lime",
                label = FieldAdvisor.text("ftdl_action_lime", "Kalken"),
                autoComplete = true,
            })
        end

        if cropPhase == "empty" and not isGrass and pfSample ~= nil and pfSample.pHValue ~= nil and pfSample.pHValue < 6.0 then
            FieldAdvisor_addAction(actions, {
                actionType = "pf_ph",
                label = FieldAdvisor.text("ftdl_action_raise_ph", "pH anheben (Kalk)"),
                autoComplete = true,
            })
        end

        if cropPhase == "empty" then
            FieldAdvisor_addAction(actions, {
                actionType = "sow",
                label = FieldAdvisor.text("ftdl_action_sow_empty", "Ansäen"),
                autoComplete = false,
            })
        end

        if postHarvestSoilWork and (needsRolling or rollerLevel > 0) then
            FieldAdvisor_addAction(actions, {
                actionType = "roller",
                label = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
                pickerLabel = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
                autoComplete = true,
            })
        end
    end

    if #actions == 0 then
        actions[1] = {
            actionType = "none",
            label = FieldAdvisor.text("ftdl_action_all_ok", "Alles ok"),
            autoComplete = false,
        }
    end

    return FieldAdvisor.finishActionCandidates(actions, pfSample)
end

---@param field table
---@param fieldState table|nil
---@param pfSample table|nil
---@param scsSample table|nil
---@param rules table|nil
---@return table action { actionType: string, label: string, autoComplete: boolean }
function FieldAdvisor.resolvePrimaryAction(field, fieldState, pfSample, scsSample, rules)
    local actions = FieldAdvisor.resolveActionCandidates(field, fieldState, pfSample, scsSample, rules, nil, nil, nil)
    return FieldAdvisor.selectPrimaryAction(actions)
end

---@param action table|nil
---@return string
function FieldAdvisor.getShortActionLabel(action)
    if action == nil then
        return "-"
    end

    local shortLabels = {
        harvest = { "ftdl_action_harvest", "Ernten" },
        withered = { "ftdl_action_withered", "Verdorrt" },
        stones = { "ftdl_action_stones", "Steine" },
        cultivate = { "ftdl_action_cultivate", "Grubbern" },
        plow = { "ftdl_action_plow", "Pflügen" },
        lime = { "ftdl_action_lime", "Kalken" },
        sow = { "ftdl_action_sow", "Säen" },
        roller = { "ftdl_action_roller", "Walzen" },
        weed_combat = { "ftdl_action_weed_combat", "Unkraut" },
        weed_watch = { "ftdl_action_weed_watch", "Unkraut?" },
        pf_ph = { "ftdl_action_pf_ph", "Kalk/pH" },
        pf_n = { "ftdl_action_pf_n", "Düngen" },
        scs_moisture = { "ftdl_action_scs_moisture", "Bewässern" },
        scs_stress_high = { "ftdl_action_scs_stress_high", "Stress!" },
        scs_stress_watch = { "ftdl_action_scs_stress_watch", "Stress" },
        grass_swath = { "ftdl_action_grass_swath", "Schwaden" },
        grass_collect = { "ftdl_action_grass_collect", "Ladewagen" },
        grass_bale = { "ftdl_action_grass_bale", "Ballen" },
        grass_silage_bale = { "ftdl_action_grass_silage_bale", "Silageballen" },
        grass_bale_collect = { "ftdl_action_grass_bale_collect", "Ballen holen" },
        harvest_info = { "ftdl_action_harvest_info", "Ernte" },
        growing = { "ftdl_action_growing", "Wächst" },
        none = { "ftdl_action_none", "Ok" },
    }

    if action.actionType == "pf_n" and action.fertPass ~= nil and action.fertPassTotal ~= nil then
        return FieldAdvisor.getOrganicFertilizerPassLabel(action.fertPass, action.fertPassTotal)
    end

    local short = shortLabels[action.actionType]
    if short ~= nil then
        return FieldAdvisor.text(short[1], short[2])
    end

    local label = action.label or "-"
    label = string.gsub(label, " / gruppieren", "")
    label = string.gsub(label, "Wachsen lassen %(St%. %d+%)", FieldAdvisor.text("ftdl_action_growing", "Wächst"))
    return label
end

---@param actions table[]|nil
---@return table[]
function FieldAdvisor.getCycleableActions(actions)
    local cycleable = {}

    if actions == nil then
        return cycleable
    end

    for _, action in ipairs(actions) do
        if action.actionType ~= "none"
            and action.actionType ~= "growing"
            and action.actionType ~= "harvest_info"
            and action.actionType ~= "withered" then
            cycleable[#cycleable + 1] = action
        end
    end

    return cycleable
end

---@param action table|nil
---@param other table|nil
---@return boolean
function FieldAdvisor.isSameCycleableAction(action, other)
    if action == nil or other == nil then
        return false
    end

    if action.actionType ~= other.actionType then
        return false
    end

    if action.actionType == "pf_n" then
        return (tonumber(action.fertPass) or 1) == (tonumber(other.fertPass) or 1)
    end

    return true
end

---@param actions table[]|nil
---@param index number
---@return table|nil
function FieldAdvisor.getCycleableActionAt(actions, index)
    local cycleable = FieldAdvisor.getCycleableActions(actions)
    if #cycleable == 0 then
        return nil
    end

    local safeIndex = math.floor(tonumber(index) or 1)
    if safeIndex < 1 then
        safeIndex = 1
    end

    safeIndex = ((safeIndex - 1) % #cycleable) + 1
    return cycleable[safeIndex], safeIndex, #cycleable
end

---@param action table|nil
---@param index number
---@param total number
---@return string
function FieldAdvisor.formatCycledSuggestionLabel(action, index, total)
    if action == nil then
        return FieldAdvisor.text("ftdl_action_all_ok", "Alles ok")
    end

    local label = FieldAdvisor.getShortActionLabel(action)
    if action.fertPass ~= nil and action.fertPassTotal ~= nil then
        return label
    end

    if total <= 1 then
        return label
    end

    return string.format("%s  %d/%d", label, index, total)
end

---@param actions table[]|nil
---@param maxSteps number|nil
---@return string|nil
function FieldAdvisor.formatWorkOrderSuggestionPreview(actions, maxSteps)
    local cycleable = FieldAdvisor.getCycleableActions(actions)
    if #cycleable == 0 then
        return nil
    end

    local stepLimit = math.max(1, tonumber(maxSteps) or 4)
    if #cycleable == 1 then
        return FieldAdvisor.getShortActionLabel(cycleable[1])
    end

    local parts = {}
    for index = 1, math.min(#cycleable, stepLimit) do
        parts[#parts + 1] = FieldAdvisor.getShortActionLabel(cycleable[index])
    end

    local preview = table.concat(parts, " → ")
    if #cycleable > stepLimit then
        preview = FieldAdvisor.text("ftdl_action_preview_more", "%s (+%d)", preview, #cycleable - stepLimit)
    end

    return preview
end

---@param actions table[]|nil
---@param expectedHarvest string|nil
---@return string
function FieldAdvisor.formatSuggestionColumn(actions, expectedHarvest)
    if actions == nil or #actions == 0 then
        return FieldAdvisor.text("ftdl_action_all_ok", "Alles ok")
    end

    local logisticsActions = {}
    for _, action in ipairs(actions) do
        if action.actionType == "grass_swath"
            or action.actionType == "grass_collect"
            or action.actionType == "grass_bale"
            or action.actionType == "grass_silage_bale"
            or action.actionType == "grass_bale_collect" then
            logisticsActions[#logisticsActions + 1] = action
        end
    end

    local workOrderPreview = FieldAdvisor.formatWorkOrderSuggestionPreview(
        #logisticsActions > 0 and logisticsActions or actions,
        4
    )
    if workOrderPreview ~= nil and #logisticsActions > 0 then
        return workOrderPreview
    end

    workOrderPreview = FieldAdvisor.formatWorkOrderSuggestionPreview(actions, 4)
    if workOrderPreview ~= nil then
        return workOrderPreview
    end

    local displayLabels = {}
    for _, action in ipairs(actions) do
        if action.actionType ~= "none"
            and action.actionType ~= "growing"
            and action.actionType ~= "harvest_info" then
            displayLabels[#displayLabels + 1] = FieldAdvisor.getShortActionLabel(action)
        end
    end

    if #displayLabels == 0 then
        for _, action in ipairs(actions) do
            if action.actionType == "harvest_info" then
                local label = action.label or ""
                if label ~= "" then
                    local template = FieldAdvisor.text("ftdl_action_harvest_window", "Ernte %s", "___")
                    local prefix = string.gsub(template, "%%s", "")
                    if prefix ~= "" and string.sub(label, 1, #prefix) == prefix then
                        return string.sub(label, #prefix + 1)
                    end
                    return label
                end
            end
        end

        if expectedHarvest ~= nil and expectedHarvest ~= "" and expectedHarvest ~= "-" then
            return expectedHarvest
        end

        return FieldAdvisor.text("ftdl_action_growing", "Wächst")
    end

    local primary = displayLabels[1]
    if #displayLabels > 1 then
        return FieldAdvisor.text("ftdl_action_preview_more", "%s (+%d)", primary, #displayLabels - 1)
    end

    return primary
end

---@param field table|nil
---@param x number
---@param z number
---@return boolean|nil true inside, false outside, nil when engine exposes no inside test
function FieldAdvisor.testPositionInsideField(field, x, z)
    if field == nil or x == nil or z == nil then
        return nil
    end

    local probes = {
        "isWorldPositionInField",
        "isWorldPositionInsideField",
        "isWorldPositionInside",
        "containsWorldPosition",
    }

    for _, probe in ipairs(probes) do
        local fn = field[probe]
        if type(fn) == "function" then
            local ok, result = pcall(fn, field, x, z)
            if ok and type(result) == "boolean" then
                return result
            end

            ok, result = pcall(fn, x, z)
            if ok and type(result) == "boolean" then
                return result
            end
        end
    end

    return nil
end

--- Strict inside test for bales — unknown positions are treated as outside.
---@param field table|nil
---@param x number
---@param z number
---@return boolean
function FieldAdvisor.isPositionInsideField(field, x, z)
    return FieldAdvisor.testPositionInsideField(field, x, z) == true
end

--- Permissive inside test for field-local scans — unknown keeps legacy behaviour when polygon test is unavailable.
---@param field table|nil
---@param x number
---@param z number
---@return boolean
function FieldAdvisor.isPositionInsideFieldOrUnknown(field, x, z)
    local inside = FieldAdvisor.testPositionInsideField(field, x, z)
    if inside == nil then
        return true
    end
    return inside
end

---@param field table|nil
---@param fieldId number|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return table|nil
function FieldAdvisor.captureTaskBaseline(field, fieldId, worldX, worldZ)
    local fieldState = FieldAdvisor.getEnrichedFieldState(field, fieldId, worldX, worldZ)
    if fieldState == nil then
        return nil
    end

    local context = FieldAdvisor.buildFieldContext(field, fieldState, worldX, worldZ)

    return {
        growthState = FieldAdvisor.getGrowthState(fieldState),
        lastGrowthState = FieldAdvisor.getLastGrowthState(fieldState),
        groundType = FieldAdvisor.getGroundTypeName(fieldState),
        fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, field),
        weedState = context.weedState,
        weedFactor = context.weedFactor,
        needsPlowing = context.needsPlowing,
        needsLime = context.needsLime,
        needsRolling = context.needsRolling,
        plowLevel = context.plowLevel,
        limeLevel = context.limeLevel,
        rollerLevel = context.rollerLevel,
        stoneLevel = context.stoneLevel,
        stubbleShredLevel = FieldAdvisor.getStateNumber(fieldState, "stubbleShredLevel"),
        wasGrassCut = FieldAdvisor.isGrassCut(fieldState, field),
        wasGrassHarvestable = FieldAdvisor.isGrassHarvestable(fieldState, field),
        grassResidueState = context.grassResidueSummary ~= nil and context.grassResidueSummary.residueState or nil,
        grassResidueOccupiedRatio = context.grassResidueSummary ~= nil and context.grassResidueSummary.occupiedRatio or 0,
        baleCount = context.baleSummary ~= nil and context.baleSummary.total or 0,
        phValue = context.pfSample ~= nil and context.pfSample.pHValue or nil,
        nitrogenValue = context.pfSample ~= nil and context.pfSample.nitrogenValue or nil,
    }
end

---@param task table
---@param scanner FieldScanner
---@return boolean
function FieldAdvisor.isFieldTaskComplete(task, scanner, fieldCache)
    if FieldTaskCompletion == nil then
        return false
    end

    return FieldTaskCompletion.isTaskComplete(task, scanner, fieldCache)
end

---@param field table
---@param fieldId number|nil
---@param fieldState table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return table|nil
function FieldAdvisor.resolveRepresentativeFieldState(field, fieldId, fieldState, worldX, worldZ)
    if field == nil then
        return fieldState
    end

    local aggregation = FieldAdvisor.aggregateFieldProbes(field, fieldId, fieldState, worldX, worldZ)
    return aggregation.representativeState or fieldState
end

---@param task table
---@param context table
---@return boolean
function FieldAdvisor.hasCompletionProgress(task, context)
    local baseline = task ~= nil and task.completionBaseline or nil
    if baseline == nil or context == nil or context.fieldState == nil then
        return false
    end

    local fieldState = context.fieldState
    local actionType = task.actionType

    if FieldTaskCompletion ~= nil and FieldTaskCompletion.requiresCoverageOnly(FieldTaskCompletion.getEntry(actionType)) then
        return false
    end

    if actionType == "weed_combat" or actionType == "weed_watch" then
        if context.weedSummary ~= nil and (context.weedSummary.total or 0) > 0 then
            return FieldAdvisor.isWeedTaskDoneByCoverage(context.weedSummary)
        end

        if FieldAdvisor.isWeedDeadOrSprayed(fieldState) then
            return true
        end

        if FieldAdvisor.hasWeedFactorReading(fieldState) and baseline.weedFactor ~= nil then
            return FieldAdvisor.getWeedFactor(fieldState) < baseline.weedFactor - 0.01
        end

        return FieldAdvisor.getWeedStateLevel(fieldState) < (baseline.weedState or 0)
    end

    if FieldTaskCompletion ~= nil and FieldTaskCompletion.isGrassLogisticsAction(actionType) then
        return FieldTaskCompletion.isGrassLogisticsComplete(actionType, context, task)
    end

    if actionType == "pf_ph" and context.pfSample ~= nil and context.pfSample.pHValue ~= nil and baseline.phValue ~= nil then
        return tonumber(context.pfSample.pHValue) > tonumber(baseline.phValue)
    end

    if actionType == "pf_n" and context.pfSample ~= nil and context.pfSample.nitrogenValue ~= nil and baseline.nitrogenValue ~= nil then
        return tonumber(context.pfSample.nitrogenValue) > tonumber(baseline.nitrogenValue)
    end

    return false
end

---@param field table
---@param fieldState table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return table labels
function FieldAdvisor.buildFieldLabels(field, fieldState, worldX, worldZ)
    local rules = FieldGameRules.get()
    local fieldId = field.getId ~= nil and field:getId() or nil
    local aggregation = FieldAdvisor.aggregateFieldProbes(
        field,
        fieldId,
        fieldState,
        worldX,
        worldZ,
        FieldAdvisor.OVERVIEW_SAMPLE_GRID_STEPS
    )
    local effectiveFieldState = aggregation.representativeState or fieldState

    local weedState = FieldAdvisor.getStateNumber(effectiveFieldState, "weedState")
    local stoneLevel = FieldAdvisor.getStateNumber(effectiveFieldState, "stoneLevel")
    local limeLevel = FieldAdvisor.getStateNumber(effectiveFieldState, "limeLevel")
    local rollerLevel = FieldAdvisor.getStateNumber(effectiveFieldState, "rollerLevel")
    local plowLevel = FieldAdvisor.getStateNumber(effectiveFieldState, "plowLevel")

    local needsRolling = FieldAdvisor.getStateBool(effectiveFieldState, "needsRolling")
    local needsPlowing = FieldAdvisor.getStateBool(effectiveFieldState, "needsPlowing")
    local needsLime = FieldAdvisor.getStateBool(effectiveFieldState, "needsLime")

    local context = FieldAdvisor.buildFieldContext(field, fieldState, worldX, worldZ, aggregation)
    local weedSummary = context.weedSummary
    local grassResidueSummary = context.grassResidueSummary
    local actions = FieldAdvisor.resolveActionCandidates(
        field,
        fieldState,
        context.pfSample,
        context.scsSample,
        context.rules,
        aggregation,
        weedSummary,
        grassResidueSummary,
        context.baleSummary
    )
    local action = FieldAdvisor.selectPrimaryAction(actions)
    local fruitTypeIndex = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, fieldState)
    local partialSoilWork = FieldAdvisor.fieldHasPartialSoilWork(field, fieldId, fieldState, worldX, worldZ)
    local expectedHarvest = FieldAdvisor.getExpectedHarvestLabel(field, fieldState, aggregation, grassResidueSummary)
    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)

    return {
        weed = FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary)
            and FieldAdvisor.text("ftdl_weed_dead", "tot")
            or FieldAdvisor.formatWeedDisplayLabel(effectiveFieldState, rules, weedSummary),
        stones = FieldAdvisor.formatStoneLabel(stoneLevel, rules),
        lime = FieldAdvisor.formatLimeLabel(limeLevel, rules, needsLime),
        roller = FieldAdvisor.formatRollerLabel(rollerLevel, needsRolling),
        plow = FieldAdvisor.formatPlowLabel(effectiveFieldState, rules),
        ph = context.pfSample ~= nil and context.pfSample.phLabel or nil,
        nitrogen = context.pfSample ~= nil and context.pfSample.nitrogenLabel or nil,
        moisture = context.scsSample ~= nil and context.scsSample.moistureLabel or nil,
        stress = context.scsSample ~= nil and context.scsSample.stressLabel or nil,
        fruit = FieldAdvisor.getFieldFruitDisplayLabel(
            field, fieldId, fieldState, worldX, worldZ, aggregation
        ),
        growthState = FieldAdvisor.formatGrowthLabel(harvestState),
        cropPhase = FieldAdvisor.getCropPhase(field, fieldState, aggregation),
        expectedHarvest = expectedHarvest,
        suggestion = FieldAdvisor.formatSuggestionColumn(actions, expectedHarvest),
        suggestionDetails = actions,
        actionType = action.actionType,
        autoComplete = action.autoComplete,
        isGrass = aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS and not partialSoilWork,
        showPrecisionFarming = PrecisionFarmingReader.isRuntimeReady(),
        showCropStress = SeasonalCropStressReader.isRuntimeReady(),
    }
end
