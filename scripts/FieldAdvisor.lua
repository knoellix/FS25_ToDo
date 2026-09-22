--[[
    FieldAdvisor.lua
    Human-readable field condition labels and next-step suggestions (respects career rules).

    Pipeline (one decision per concern — see docs/FIELD_PHASE.md, AUDIT_INVENTORY.md):
      classifyProbe / aggregateFieldProbes  -> field kind + dominant situation
      buildFieldPhaseFacts -> FieldPhase.deriveFieldPhase -> getCropPhase (legacy string)
      buildFieldContext     -> probes, weed, grass/straw windrow liters, bales (no phase decision)
      resolveActionCandidates -> phase reconciliation once, then PHASE_ACTION_BUILDERS dispatch
      FieldTaskCompletion   -> per-action completion from context (no phase re-derivation)
]]

FieldAdvisor = {}

FieldAdvisor.WEED_LABELS = {
    [0] = "none",
    [1] = "light",
    [2] = "medium",
    [3] = "heavy",
    [4] = "heavy",
    [5] = "heavy",
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
-- Density map often reports these indices for every meadow crop (lucerne/alfalfa included).
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
-- Overview/completion probe grid only (residue cross-bars use full measured extent).
FieldAdvisor.PROBE_SAMPLE_MAX_HALF_EXTENT = 96
-- Keep probe samples this far inside the engine field edge (per axis).
FieldAdvisor.PROBE_EDGE_INSET = 5
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
FieldAdvisor.WEED_SPRAY_PRESSURE_THRESHOLD = 0.10
FieldAdvisor.WEED_LIVE_RATIO_DONE_THRESHOLD = 0.05
FieldAdvisor.WEED_COVERAGE_CACHE_TTL_MS = 2000
FieldAdvisor.BALE_CACHE_TTL_ACTIVE_MS = 700
FieldAdvisor.BALE_CACHE_TTL_IDLE_MS = 5000
FieldAdvisor._baleOwnerFieldCache = nil
FieldAdvisor.COVERAGE_MAX_SAMPLE_POINTS = 31
-- Half-size of the windrow fill-level probe square used for grass fruit identification.
FieldAdvisor.GRASS_RESIDUE_SAMPLE_HALF_SIZE = 0.45
-- FS25 weed foliage: states 0–5 alive/sprayed-visible, 6+ dead (see data/foliage/weed/weed.xml).
FieldAdvisor.WEED_STATE_DEAD_MIN = 6
-- Grass residue states. deriveGrassResidueSummary: liters + line layout (loose mat vs rowed swaths).
FieldAdvisor.GRASS_RESIDUE_NONE = "none"
FieldAdvisor.GRASS_RESIDUE_LOOSE = "loose"
FieldAdvisor.GRASS_RESIDUE_SWATH = "swath"
FieldAdvisor.GRASS_RESIDUE_BALED = "baled"
-- Straw windrows: single runtime source = STRAW liters via DensityMapHeightUtil (see deriveStrawResidueSummary).
FieldAdvisor.STRAW_RESIDUE_CACHE_TTL_MS = 2000
FieldAdvisor.GRASS_RESIDUE_CACHE_TTL_MS = 2000
FieldAdvisor._coverageCache = {}
FieldAdvisor._strawFillTypeIndex = nil

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
            local map = {}
            local okEnum = pcall(function()
                for name, enumValue in pairs(FieldGroundType) do
                    if type(name) == "string" and type(enumValue) == "number" then
                        map[enumValue] = name
                    elseif type(name) == "string" and type(enumValue) == "string"
                        and FieldGroundType.getValueByType ~= nil then
                        local ok, resolvedValue = pcall(
                            FieldGroundType.getValueByType,
                            FieldGroundType,
                            enumValue
                        )
                        if ok and type(resolvedValue) == "number" then
                            map[resolvedValue] = name
                        end
                    end
                end
            end)
            -- Always assign (even empty) so we never rebuild forever on throw.
            FieldAdvisor.groundTypeNameByValue = map
            if not okEnum and FieldToDoLog ~= nil then
                FieldToDoLog.warning("FieldAdvisor: FieldGroundType enum cache failed")
            end
        end

        local resolvedName = FieldAdvisor.groundTypeNameByValue[value]
        if resolvedName ~= nil then
            return resolvedName
        end
    end

    return ""
end

FieldAdvisor._getGroundTypeNameDepth = 0
FieldAdvisor._getGroundTypeNameReentered = false

---@param fieldState table|nil
---@return string
function FieldAdvisor.getGroundTypeName(fieldState)
    if fieldState == nil then
        return ""
    end

    if FieldAdvisor._getGroundTypeNameDepth > 0 then
        FieldAdvisor._getGroundTypeNameReentered = true
        return ""
    end

    FieldAdvisor._getGroundTypeNameDepth = FieldAdvisor._getGroundTypeNameDepth + 1
    local raw = nil
    local okRead, errRead = pcall(function()
        raw = fieldState.groundType
        if raw == nil and type(fieldState.getGroundType) == "function" then
            local ok, groundType = pcall(fieldState.getGroundType, fieldState)
            if ok then
                raw = groundType
            end
        end
    end)
    FieldAdvisor._getGroundTypeNameDepth = FieldAdvisor._getGroundTypeNameDepth - 1

    if not okRead or FieldAdvisor._getGroundTypeNameReentered then
        FieldAdvisor._getGroundTypeNameReentered = false
        return ""
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

--- Post-mow meadow signal: cut ground, stubble, getIsCut, or growth above max harvest (Geistal map alfalfa/clover).
---@param fieldState table|nil
---@param field table|nil
---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isGrassPostMowState(fieldState, field, fruitTypeIndex)
    if fieldState == nil then
        return false
    end

    -- Freshly cut ground is unambiguous regardless of any regrowth.
    if FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(fieldState)) then
        return true
    end

    fruitTypeIndex = fruitTypeIndex
        or FieldAdvisor.resolveFruitTypeIndex(fieldState, field)

    local growthState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if growthState <= 0 then
        growthState = FieldAdvisor.getLastGrowthState(fieldState)
    end

    local growth = nil
    if fruitTypeIndex ~= nil and FieldAdvisor.isGrassCrop(fruitTypeIndex) and growthState > 0 then
        growth = FieldAdvisor.evaluateFruitGrowth(fruitTypeIndex, growthState)
        -- Regrown to mowable height: a standing, harvestable stand is NOT post-mow,
        -- even if stubble shred from the previous cut still lingers (e.g. clover/alfalfa).
        if not growth.isCut and (growth.isHarvestReady or growth.isHarvestable) then
            -- Density often reports ALFALFA/CLOVER on cut meadows where grass growth is
            -- outside that crop's harvest window. Inside the specific crop's window, trust
            -- standing harvestReady (e.g. Luzerne growth=5) — do not treat GRASS isCut at
            -- the same growth number as post-mow.
            local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
            local minHarvest = tonumber(fruitDesc ~= nil and fruitDesc.minHarvestingGrowthState) or 0
            local maxHarvest = tonumber(fruitDesc ~= nil and fruitDesc.maxHarvestingGrowthState) or 0
            local inSpecificHarvestWindow = maxHarvest > 0
                and growthState >= minHarvest
                and growthState <= maxHarvest
            if inSpecificHarvestWindow then
                return false
            end

            local genericIndex = FieldAdvisor.getDefaultGrassFruitTypeIndex()
            if genericIndex ~= nil and genericIndex ~= fruitTypeIndex then
                local genericGrowth = FieldAdvisor.evaluateFruitGrowth(genericIndex, growthState)
                if genericGrowth.isCut then
                    return true
                end
                if not genericGrowth.isCut
                    and (genericGrowth.isHarvestReady or genericGrowth.isHarvestable) then
                    return false
                end
            else
                return false
            end
        end
    end

    -- Lingering stubble shred indicates a recent mow (only when not regrown to mowable).
    if FieldAdvisor.getStateNumber(fieldState, "stubbleShredLevel") > 0 then
        return true
    end

    if fruitTypeIndex == nil or not FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        return false
    end
    if growthState <= 0 then
        return false
    end

    if growth == nil then
        growth = FieldAdvisor.evaluateFruitGrowth(fruitTypeIndex, growthState)
    end
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

    -- Prefer true meadow generics (never first arbitrary isGrassCrop like ALFALFA).
    local genericOrder = { "GRASS", "MEADOW", "FIELDGRASS", "PASTURE" }
    for _, name in ipairs(genericOrder) do
        local fruitTypeIndex = FieldAdvisor.getFruitTypeIndexByName(name)
        if fruitTypeIndex ~= nil and fruitTypeIndex > 0 then
            FieldAdvisor._defaultGrassFruitTypeIndex = fruitTypeIndex
            return FieldAdvisor._defaultGrassFruitTypeIndex
        end
    end

    local firstAnyGrass = nil
    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypes ~= nil then
        local ok, fruitTypes = pcall(g_fruitTypeManager.getFruitTypes, g_fruitTypeManager)
        if ok and fruitTypes ~= nil then
            for _, fruitDesc in ipairs(fruitTypes) do
                if fruitDesc ~= nil and fruitDesc.index ~= nil and fruitDesc.index > 0 then
                    if FieldAdvisor.isGrassCrop(fruitDesc.index) then
                        if FieldAdvisor.isGenericGrassFruitIndex(fruitDesc.index) then
                            FieldAdvisor._defaultGrassFruitTypeIndex = fruitDesc.index
                            return FieldAdvisor._defaultGrassFruitTypeIndex
                        end
                        if firstAnyGrass == nil then
                            firstAnyGrass = fruitDesc.index
                        end
                    end
                end
            end
        end
    end

    FieldAdvisor._defaultGrassFruitTypeIndex = firstAnyGrass
    return FieldAdvisor._defaultGrassFruitTypeIndex
end

--- Clear cached default grass index (tests / fruit-manager reload).
function FieldAdvisor.invalidateDefaultGrassFruitTypeIndex()
    FieldAdvisor._defaultGrassFruitTypeResolved = false
    FieldAdvisor._defaultGrassFruitTypeIndex = nil
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

        if (fieldState.isGrass == true or fieldState.isGrassCrop == true or fieldState.isGrassland == true)
            and FieldAdvisor.isGrassCrop(fruitIdx) then
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

    -- Edge/headland probes often classify unknown; center crop read must not lose (Field 2 maize).
    if dominantSituation == FieldAdvisor.PROBE_SITUATION.UNKNOWN
        and centerSituation ~= FieldAdvisor.PROBE_SITUATION.UNKNOWN
        and centerSituation ~= FieldAdvisor.PROBE_SITUATION.BARE_SOIL
        and (counts[centerSituation] or 0) >= 1 then
        dominantSituation = centerSituation
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
            if FieldAdvisor.isSamplePositionOnField(field, point.x, point.z) then
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
                -- Equal votes: prefer generic GRASS over ALFALFA/CLOVER (avoids Luzerne label).
                local curGeneric = FieldAdvisor.isGenericGrassFruitIndex(dominantGrassFruit)
                local newGeneric = FieldAdvisor.isGenericGrassFruitIndex(fruitIndex)
                beats = newGeneric and not curGeneric
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
    -- and not min-growth edge strips (growth 0 / missing fruit → localized "Growing").
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

-- Field-kind gate (C): is this field grass for *sampling/tracking* purposes (bales, weed skip)?
-- Richer than the phase gate isGrassPhaseContext: also weighs center situation, harvest-state
-- probe and resolved grass fruit. isArableFieldContext is its complement.
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

--- Sampling gate: arable weed probes only (grass/meadow misreads engine weed as 100%).
---@param aggregation table|nil
---@param fieldState table|nil
---@param field table|nil
---@param worldX number|nil
---@param worldZ number|nil
---@return boolean
function FieldAdvisor.isArableWeedSamplingContext(aggregation, fieldState, field, worldX, worldZ)
    if aggregation ~= nil and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS then
        return false
    end

    if FieldAdvisor.isGrassCropFieldContext(aggregation, fieldState, field, worldX, worldZ) then
        return false
    end

    return true
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

--- Grass *phase* gate: treat the field as grass for phase/label/action decisions when the
--- resolved probe is grass OR the probe aggregation is grass-dominant. This is the one place
--- that test lives now (was inlined in getCropPhase / getExpectedHarvestLabel / resolveActionCandidates).
--- Distinct from isGrassCropFieldContext, which additionally weighs center situation + grass fruit
--- and serves as the bale/weed sampling field-kind gate — not the phase gate.
---@param harvestState table|nil
---@param field table|nil
---@param aggregation table|nil
---@return boolean
function FieldAdvisor.isGrassPhaseContext(harvestState, field, aggregation)
    if FieldAdvisor.isGrassFieldState(harvestState, field) then
        return true
    end

    return aggregation ~= nil and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS
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

    if FieldAdvisor.isBareSoilProbe(fieldState, nil)
        or FieldAdvisor.isWorkedBareGround(fieldState) then
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

    -- One ordered source chain (no enrich-mutating last resort): aggregation → probe fruit →
    -- state-name grass → field-level grass probe. refineGrassFruitTypeIndex only narrows.
    local fruitTypeIndex = aggregation ~= nil and aggregation.dominantGrassFruit or nil

    if fruitTypeIndex == nil then
        fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, field)
    end
    if fruitTypeIndex == nil then
        fruitTypeIndex = FieldAdvisor.inferGrassFruitTypeIndexFromState(fieldState)
    end
    if fruitTypeIndex == nil then
        fruitTypeIndex = FieldAdvisor.inferGrassFruitTypeIndexFromField(field)
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

--- Harvest/regrowth label for mown grass (lucerne/clover): next harvest window or "Regrowth", never "Growing".
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
            none = { "ftdl_val_none", "kein" },
            light = { "ftdl_weed_light", "leicht" },
            medium = { "ftdl_weed_medium", "mittel" },
            heavy = { "ftdl_weed_heavy", "stark" },
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

    if weedState <= 0 then
        return true
    end

    if FieldAdvisor.hasWeedFactorReading(fieldState) then
        local weedFactor = FieldAdvisor.getWeedFactor(fieldState)
        if weedFactor <= FieldAdvisor.WEED_FACTOR_COMPLETE_THRESHOLD then
            return true
        end

        -- Regrowth after sleep: live density beats stale herbicide on foliage stages 1–5.
        if weedFactor > FieldAdvisor.WEED_FACTOR_TREATED_THRESHOLD then
            return false
        end

        -- Early sprayed weeds (states 1–2) with low factor + herbicide residue.
        if FieldAdvisor.hasHerbicideResidue(fieldState)
            and weedFactor <= FieldAdvisor.WEED_FACTOR_TREATED_THRESHOLD
            and weedState <= FieldAdvisor.WEED_STATE_SPRAYED_LIVE_MAX then
            return true
        end

        -- Mid/late stages with herbicide but no live regrowth factor.
        if FieldAdvisor.hasHerbicideResidue(fieldState)
            and weedState > FieldAdvisor.WEED_STATE_SPRAYED_LIVE_MAX then
            return true
        end

        return false
    end

    -- No weedFactor: dying foliage only — not stale spray on stage 3 regrowth.
    if weedState >= 4
        and weedState < FieldAdvisor.WEED_STATE_DEAD_MIN then
        return true
    end

    if FieldAdvisor.hasHerbicideResidue(fieldState)
        and weedState >= 4 then
        return true
    end

    return false
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

    if weedState <= 0 then
        return true
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
---@param aggregation table|nil when dominant grass, probes on grass tiles are skipped
---@return table summary
function FieldAdvisor.sampleWeedCoverage(field, fieldId, worldX, worldZ, aggregation)
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

    local skipGrassProbes = aggregation ~= nil
        and aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.GRASS

    for _, point in ipairs(points) do
        if FieldAdvisor.isSamplePositionOnField(field, point.x, point.z) then
            local sampleState = FieldAdvisor.getEnrichedFieldState(field, fieldId, point.x, point.z)
            if skipGrassProbes
                and FieldAdvisor.classifyProbe(sampleState, field) == FieldAdvisor.PROBE_SITUATION.GRASS then
                -- skip — grass/meadow tiles are not arable weed targets
            else
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

---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isWeedProbeWorkDone(fieldState)
    if fieldState == nil then
        return true
    end

    return not FieldAdvisor.isWeedProbeLive(fieldState)
end

---@param weedSummary table|nil
---@return boolean
function FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary)
    if weedSummary == nil then
        return false
    end

    local total = weedSummary.total or 0
    local live = weedSummary.live or 0
    local dead = weedSummary.dead or 0
    if total <= 0 then
        return false
    end

    local classified = weedSummary.classified
    if classified == nil then
        classified = live + dead
    end

    -- Mechanical work: every sampled probe must be weed-free (no live probes left).
    if live <= 0 then
        return true
    end

    if classified <= 0 then
        return false
    end

    -- Spray residue: nearly all probes dead, at most one misread live probe.
    if dead > 0
        and live <= 1
        and (weedSummary.deadRatio or 0) >= (1 - FieldAdvisor.WEED_LIVE_RATIO_DONE_THRESHOLD) then
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

--- Engine field at world position: field object first, then numeric id, then farmland.
--- Third return is the source label for dumps (no silent chain): getFieldAtWorldPosition |
--- getFieldAtPosition | getFieldIdAtWorldPosition | getFieldIDAtWorldPosition | farmland | none.
---@param x number|nil
---@param z number|nil
---@return number|nil fieldId
---@return table|nil engineField
---@return string source
function FieldAdvisor.resolveEngineFieldAtWorldPosition(x, z)
    if x == nil or z == nil then
        return nil, nil, "none"
    end

    if g_fieldManager ~= nil then
        local fieldMethods = { "getFieldAtWorldPosition", "getFieldAtPosition" }
        for _, methodName in ipairs(fieldMethods) do
            local fn = g_fieldManager[methodName]
            if type(fn) == "function" then
                local ok, engineField = pcall(fn, g_fieldManager, x, z)
                if ok and engineField ~= nil and engineField.getId ~= nil then
                    local okId, fieldId = pcall(engineField.getId, engineField)
                    fieldId = tonumber(fieldId)
                    if okId and fieldId ~= nil and fieldId > 0 then
                        return fieldId, engineField, methodName
                    end
                end
            end
        end

        local idMethods = { "getFieldIdAtWorldPosition", "getFieldIDAtWorldPosition" }
        for _, methodName in ipairs(idMethods) do
            local fn = g_fieldManager[methodName]
            if type(fn) == "function" then
                local ok, fieldId = pcall(fn, g_fieldManager, x, z)
                fieldId = tonumber(fieldId)
                if ok and fieldId ~= nil and fieldId > 0 then
                    return fieldId, FieldAdvisor.getEngineFieldById(fieldId), methodName
                end
            end
        end
    end

    local farmlandFieldId = FieldAdvisor.resolveFarmlandFieldIdAtWorldPosition(x, z)
    if farmlandFieldId ~= nil then
        return farmlandFieldId, FieldAdvisor.getEngineFieldById(farmlandFieldId), "farmland"
    end

    return nil, nil, "none"
end

---@param x number|nil
---@param z number|nil
---@return number|nil
---@return string source
function FieldAdvisor.resolveEngineFieldIdAtWorldPosition(x, z)
    local fieldId, _, source = FieldAdvisor.resolveEngineFieldAtWorldPosition(x, z)
    return fieldId, source or "none"
end

--- Farmland without predefined field id -> pseudo field id (engine parcel data).
---@param x number|nil
---@param z number|nil
---@return number|nil
function FieldAdvisor.resolveFarmlandFieldIdAtWorldPosition(x, z)
    if g_farmlandManager == nil or x == nil or z == nil then
        return nil
    end

    local farmland = nil
    if g_farmlandManager.getFarmlandAtWorldPosition ~= nil then
        local ok, result = pcall(g_farmlandManager.getFarmlandAtWorldPosition, g_farmlandManager, x, z)
        if ok then
            farmland = result
        end
    end

    if farmland == nil and g_farmlandManager.getFarmlandIdAtWorldPosition ~= nil then
        local ok, farmlandId = pcall(g_farmlandManager.getFarmlandIdAtWorldPosition, g_farmlandManager, x, z)
        farmlandId = tonumber(farmlandId)
        if ok and farmlandId ~= nil and farmlandId > 0 and g_farmlandManager.getFarmlandById ~= nil then
            local okFarmland, result = pcall(g_farmlandManager.getFarmlandById, g_farmlandManager, farmlandId)
            if okFarmland then
                farmland = result
            end
        end
    end

    if farmland == nil then
        return nil
    end

    if farmland.field ~= nil and farmland.field.getId ~= nil then
        local okId, fieldId = pcall(farmland.field.getId, farmland.field)
        fieldId = tonumber(fieldId)
        if okId and fieldId ~= nil and fieldId > 0 then
            return fieldId
        end
    end

    if farmland.id ~= nil and FieldScanner ~= nil and FieldScanner.FARMLAND_PSEUDO_ID_OFFSET ~= nil then
        return FieldScanner.FARMLAND_PSEUDO_ID_OFFSET + tonumber(farmland.id)
    end

    return nil
end

---@param fieldId number|nil
---@return table|nil
function FieldAdvisor.getEngineFieldById(fieldId)
    fieldId = tonumber(fieldId)
    if fieldId == nil or fieldId <= 0 then
        return nil
    end

    if FieldScanner ~= nil
        and FieldScanner.isFarmlandPseudoId ~= nil
        and FieldScanner.isFarmlandPseudoId(fieldId)
        and g_farmlandManager ~= nil
        and g_farmlandManager.getFarmlandById ~= nil then
        local farmlandId = fieldId - FieldScanner.FARMLAND_PSEUDO_ID_OFFSET
        local ok, farmland = pcall(g_farmlandManager.getFarmlandById, g_farmlandManager, farmlandId)
        if ok and farmland ~= nil then
            local scanner = g_currentMission ~= nil
                and g_currentMission.fieldToDoList ~= nil
                and g_currentMission.fieldToDoList.fieldScanner
            if scanner ~= nil and scanner.buildFarmlandPseudoField ~= nil then
                return scanner:buildFarmlandPseudoField(farmland)
            end
        end
    end

    if g_fieldManager == nil then
        return nil
    end

    local allFields = g_fieldManager.fields
    if allFields == nil and g_fieldManager.getFields ~= nil then
        local ok, fields = pcall(g_fieldManager.getFields, g_fieldManager)
        if ok then
            allFields = fields
        end
    end

    if allFields == nil then
        return nil
    end

    for _, field in pairs(allFields) do
        local currentId = field.getId ~= nil and tonumber(field:getId()) or nil
        if currentId == fieldId then
            return field
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
        if FieldAdvisor.isSamplePositionOnField(field, centerX + dirX * dist, centerZ + dirZ * dist) then
            maxDist = dist
        else
            break
        end
    end

    for dist = step, 320, step do
        if FieldAdvisor.isSamplePositionOnField(field, centerX - dirX * dist, centerZ - dirZ * dist) then
            maxDist = math.max(maxDist, dist)
        else
            break
        end
    end

    return maxDist
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

function FieldAdvisor.invalidateDensityMapHeightUtil()
    FieldAdvisor._densityMapHeightUtil = nil
    FieldAdvisor._densityMapHeightFillMethod = nil
    FieldAdvisor._densityMapHeightNeedsSelf = false
end

FieldAdvisor._sprayLevelMax = nil
FieldAdvisor._sprayLevelMaxResolved = false

function FieldAdvisor.invalidateSprayLevelMax()
    FieldAdvisor._sprayLevelMax = nil
    FieldAdvisor._sprayLevelMaxResolved = false
end

--- Game density-map max for fertilizer spray stages (1× mods lower this).
---@return number
function FieldAdvisor.resolveSprayLevelMax()
    if FieldAdvisor._sprayLevelMaxResolved then
        return FieldAdvisor._sprayLevelMax
            or (FertilizerAdvice ~= nil and FertilizerAdvice.SPRAY_LEVEL_MAX_FALLBACK)
            or 2
    end

    FieldAdvisor._sprayLevelMaxResolved = true
    FieldAdvisor._sprayLevelMax = nil

    local groundSystem = nil
    if g_currentMission ~= nil then
        groundSystem = g_currentMission.fieldGroundSystem or g_currentMission.groundSystem
    end
    if groundSystem == nil and g_fieldManager ~= nil then
        groundSystem = g_fieldManager.fieldGroundSystem or g_fieldManager.groundSystem
    end

    local sprayKey = nil
    if FieldDensityMap ~= nil then
        sprayKey = FieldDensityMap.SPRAY_LEVEL
    end

    if groundSystem ~= nil and sprayKey ~= nil and groundSystem.getMaxValue ~= nil then
        local ok, value = pcall(groundSystem.getMaxValue, groundSystem, sprayKey)
        local maxValue = ok and tonumber(value) or nil
        if maxValue ~= nil and maxValue >= 1 then
            FieldAdvisor._sprayLevelMax = math.floor(maxValue)
            return FieldAdvisor._sprayLevelMax
        end
    end

    local fallback = FertilizerAdvice ~= nil and FertilizerAdvice.SPRAY_LEVEL_MAX_FALLBACK or 2
    FieldAdvisor._sprayLevelMax = fallback
    return fallback
end

--- Facts for FertilizerAdvice.deriveFertilizerAdvice (PF nitrogen or vanilla sprayLevel).
---@param fieldState table|nil
---@param pfSample table|nil
---@param isGrass boolean|nil
---@return table
function FieldAdvisor.buildFertilizerAdviceFacts(fieldState, pfSample, isGrass)
    local pfReady = PrecisionFarmingReader ~= nil
        and PrecisionFarmingReader.isRuntimeReady ~= nil
        and PrecisionFarmingReader.isRuntimeReady()
    local nitrogenValue = pfSample ~= nil and tonumber(pfSample.nitrogenValue) or nil
    local sprayLevel = nil
    if fieldState ~= nil then
        sprayLevel = FieldAdvisor.getStateNumber(fieldState, "sprayLevel")
    end

    return {
        isGrass = isGrass == true,
        pfReady = pfReady == true,
        nitrogenValue = nitrogenValue,
        sprayLevel = sprayLevel,
        sprayLevelMax = FieldAdvisor.resolveSprayLevelMax(),
    }
end

---@param fieldState table|nil
---@param pfSample table|nil
---@param isGrass boolean|nil
---@return table
function FieldAdvisor.deriveFieldFertilizerAdvice(fieldState, pfSample, isGrass)
    if FertilizerAdvice == nil or FertilizerAdvice.deriveFertilizerAdvice == nil then
        return {
            needsFertilizer = false,
            done = false,
            source = "none",
            level = nil,
            max = nil,
        }
    end

    return FertilizerAdvice.deriveFertilizerAdvice(
        FieldAdvisor.buildFertilizerAdviceFacts(fieldState, pfSample, isGrass)
    )
end

---@param context table|nil
---@return table
function FieldAdvisor.getFertilizerAdviceFromContext(context)
    if context == nil then
        return FieldAdvisor.deriveFieldFertilizerAdvice(nil, nil, false)
    end

    local isGrass = context.isGrass == true
    if not isGrass and context.field ~= nil and context.fieldState ~= nil then
        isGrass = FieldAdvisor.classifyProbe(context.fieldState, context.field)
            == FieldAdvisor.PROBE_SITUATION.GRASS
    end

    return FieldAdvisor.deriveFieldFertilizerAdvice(context.fieldState, context.pfSample, isGrass)
end

--- FS25 exposes DensityMapHeightUtil as a script global, not always via rawget(_G, …).
---@return table|nil
function FieldAdvisor.resolveDensityMapHeightUtil()
    if FieldAdvisor._densityMapHeightUtil ~= nil then
        return FieldAdvisor._densityMapHeightUtil
    end

    FieldAdvisor._densityMapHeightFillMethod = nil
    FieldAdvisor._densityMapHeightNeedsSelf = false

    local util = nil
    if type(DensityMapHeightUtil) == "table" and DensityMapHeightUtil.getFillLevelAtArea ~= nil then
        util = DensityMapHeightUtil
    end

    if util == nil then
        util = rawget(_G, "DensityMapHeightUtil")
        if type(util) ~= "table" or util.getFillLevelAtArea == nil then
            util = nil
        end
    end

    if util == nil and g_densityMapHeightManager ~= nil then
        for _, methodName in ipairs({ "getFillLevelAtArea", "getFillLevelInArea" }) do
            if g_densityMapHeightManager[methodName] ~= nil then
                util = g_densityMapHeightManager
                FieldAdvisor._densityMapHeightFillMethod = methodName
                FieldAdvisor._densityMapHeightNeedsSelf = true
                break
            end
        end
    end

    if util ~= nil then
        if FieldAdvisor._densityMapHeightFillMethod == nil then
            FieldAdvisor._densityMapHeightFillMethod = "getFillLevelAtArea"
        end
        FieldAdvisor._densityMapHeightUtil = util
    end

    return util
end

---@return boolean
--- DensityMapHeightUtil.getFillLevelAtArea — shared by straw and grass windrow scans.
---@return boolean
function FieldAdvisor.isWindrowFillLevelApiReady()
    return FieldAdvisor.resolveDensityMapHeightUtil() ~= nil
end

---@return boolean
function FieldAdvisor.isStrawFillLevelApiReady()
    return FieldAdvisor.isWindrowFillLevelApiReady()
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

---@param grassFruit number|nil
---@return number|nil
function FieldAdvisor.resolveGrassWindrowFillIndex(grassFruit)
    if grassFruit ~= nil and grassFruit > 0 and g_fruitTypeManager ~= nil
            and g_fruitTypeManager.getWindrowFillTypeIndexByFruitTypeIndex ~= nil then
        local ok, idx = pcall(
            g_fruitTypeManager.getWindrowFillTypeIndexByFruitTypeIndex,
            g_fruitTypeManager,
            grassFruit
        )
        idx = ok and tonumber(idx) or nil
        if idx ~= nil and idx > 0 then
            return idx
        end
    end

    if FillType ~= nil and FillType.GRASS_WINDROW ~= nil then
        local idx = tonumber(FillType.GRASS_WINDROW)
        if idx ~= nil and idx > 0 then
            return idx
        end
    end

    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeIndexByName ~= nil then
        local ok, idx = pcall(g_fillTypeManager.getFillTypeIndexByName, g_fillTypeManager, "GRASS_WINDROW")
        idx = ok and tonumber(idx) or nil
        if idx ~= nil and idx > 0 then
            return idx
        end
    end

    return nil
end

--- Cross-axis stats for one windrow fill sample line (used only by classifyGrassMaterialLayout).
---@param samples number[]
---@param fillMin number
---@return table
function FieldAdvisor.summarizeWindrowAxisSamples(samples, fillMin)
    local stats = {
        total = 0,
        above = 0,
        transitions = 0,
        max = 0,
        mean = 0,
    }

    if samples == nil or #samples == 0 then
        return stats
    end

    stats.total = #samples
    local sum = 0
    local prevAbove = false
    for _, liters in ipairs(samples) do
        local value = math.max(0, tonumber(liters) or 0)
        sum = sum + value
        if value > stats.max then
            stats.max = value
        end
        local above = value >= fillMin
        if above then
            stats.above = stats.above + 1
        end
        if above and not prevAbove then
            stats.transitions = stats.transitions + 1
        end
        prevAbove = above
    end

    stats.mean = sum / stats.total
    return stats
end

--- Loose cut mat vs rowed swaths: same liter API, layout differs along E–W / N–S probes.
---@param ewSamples number[]
---@param nsSamples number[]
---@param fillMin number
---@return string "none"|"loose"|"swath"
function FieldAdvisor.classifyGrassMaterialLayout(ewSamples, nsSamples, fillMin)
    local ew = FieldAdvisor.summarizeWindrowAxisSamples(ewSamples, fillMin)
    local ns = FieldAdvisor.summarizeWindrowAxisSamples(nsSamples, fillMin)
    local crossMax = math.max(ew.max, ns.max, 0)

    if crossMax < fillMin then
        return FieldAdvisor.GRASS_RESIDUE_NONE
    end

    local function axisLooksLikeSwathLine(stats)
        if stats.max < fillMin or stats.total <= 0 then
            return false
        end

        local aboveRatio = stats.above / stats.total
        -- Uniform loose mat: most probes hot, no separate row peaks.
        if aboveRatio >= 0.55 and stats.transitions <= 2 then
            return false
        end
        -- Rowed swaths: multiple enter/leave transitions along the cross bar.
        if stats.transitions >= 2 then
            return true
        end
        -- Narrow swath band: sparse hits with one sharp peak.
        if stats.transitions >= 1
            and aboveRatio <= 0.45
            and stats.max >= math.max(fillMin * 2, stats.mean * 2.5) then
            return true
        end

        return false
    end

    if axisLooksLikeSwathLine(ew) or axisLooksLikeSwathLine(ns) then
        return FieldAdvisor.GRASS_RESIDUE_SWATH
    end

    return FieldAdvisor.GRASS_RESIDUE_LOOSE
end

--- Single decision for grass post-mow material: windrow liters + line layout, then bales.
---@param field table|nil
---@param fieldId number|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param baleSummary table|nil
---@param grassFruit number|nil
---@return table summary
function FieldAdvisor.deriveGrassResidueSummary(field, fieldId, worldX, worldZ, baleSummary, grassFruit)
    local fieldBaleCount = FieldAdvisor.getFieldBaleCountByKind(baleSummary, "grass")
    local summary = {
        residueState = FieldAdvisor.GRASS_RESIDUE_NONE,
        residueAvailable = false,
        residueSource = "none",
        fieldBaleCount = fieldBaleCount,
        hasWindrow = false,
        fillApiReady = FieldAdvisor.isWindrowFillLevelApiReady(),
        centerFillLiters = 0,
        crossFillMax = 0,
        fillMinLiters = 0,
        windrowFillIndex = nil,
        ewLineTransitions = 0,
        nsLineTransitions = 0,
        ewAboveRatio = 0,
        nsAboveRatio = 0,
        total = 0,
        occupied = 0,
        occupiedRatio = 0,
    }

    if fieldBaleCount > 0 then
        summary.residueState = FieldAdvisor.GRASS_RESIDUE_BALED
        summary.residueAvailable = true
        summary.residueSource = "bales"
        return summary
    end

    if field == nil or not summary.fillApiReady then
        return summary
    end

    if fieldId ~= nil then
        local cached = FieldAdvisor.getCoverageCache(fieldId, "grassResidue", FieldAdvisor.GRASS_RESIDUE_CACHE_TTL_MS)
        if cached ~= nil then
            cached.fieldBaleCount = fieldBaleCount
            cached.fillApiReady = FieldAdvisor.isWindrowFillLevelApiReady()
            return cached
        end
    end

    if worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end
    if worldX == nil or worldZ == nil then
        return summary
    end

    local windrowFillIndex = FieldAdvisor.resolveGrassWindrowFillIndex(grassFruit)
    summary.windrowFillIndex = windrowFillIndex
    if windrowFillIndex == nil or windrowFillIndex <= 0 then
        return summary
    end

    local halfSize = FieldAdvisor.GRASS_RESIDUE_SAMPLE_HALF_SIZE
    summary.centerFillLiters = FieldAdvisor.callFillLevelAtArea(
        windrowFillIndex,
        worldX - halfSize, worldZ - halfSize,
        worldX + halfSize, worldZ - halfSize,
        worldX - halfSize, worldZ + halfSize
    )

    local halfExtent = FieldAdvisor.getFieldSampleHalfExtent(field)
    local lineSteps = 7
    local ewSamples = {}
    local nsSamples = {}

    for step = -lineSteps, lineSteps do
        local t = step / lineSteps
        local xEw = worldX + t * halfExtent
        if FieldAdvisor.isSamplePositionOnField(field, xEw, worldZ) then
            ewSamples[#ewSamples + 1] = FieldAdvisor.callFillLevelAtArea(
                windrowFillIndex,
                xEw - halfSize, worldZ - halfSize,
                xEw + halfSize, worldZ - halfSize,
                xEw - halfSize, worldZ + halfSize
            )
        end

        local zNs = worldZ + t * halfExtent
        if FieldAdvisor.isSamplePositionOnField(field, worldX, zNs) then
            nsSamples[#nsSamples + 1] = FieldAdvisor.callFillLevelAtArea(
                windrowFillIndex,
                worldX - halfSize, zNs - halfSize,
                worldX + halfSize, zNs - halfSize,
                worldX - halfSize, zNs + halfSize
            )
        end
    end

    summary.fillMinLiters = math.max(0.001, FieldAdvisor.getMinValidHeightLiters(windrowFillIndex) * 0.25)
    local ewStats = FieldAdvisor.summarizeWindrowAxisSamples(ewSamples, summary.fillMinLiters)
    local nsStats = FieldAdvisor.summarizeWindrowAxisSamples(nsSamples, summary.fillMinLiters)
    summary.crossFillMax = math.max(ewStats.max, nsStats.max, summary.centerFillLiters)
    summary.ewLineTransitions = ewStats.transitions
    summary.nsLineTransitions = nsStats.transitions
    if ewStats.total > 0 then
        summary.ewAboveRatio = ewStats.above / ewStats.total
    end
    if nsStats.total > 0 then
        summary.nsAboveRatio = nsStats.above / nsStats.total
    end

    summary.residueState = FieldAdvisor.classifyGrassMaterialLayout(
        ewSamples,
        nsSamples,
        summary.fillMinLiters
    )
    summary.hasWindrow = summary.residueState == FieldAdvisor.GRASS_RESIDUE_SWATH
    if summary.residueState == FieldAdvisor.GRASS_RESIDUE_SWATH then
        summary.residueAvailable = true
        summary.residueSource = "windrow_lines"
    elseif summary.residueState == FieldAdvisor.GRASS_RESIDUE_LOOSE then
        summary.residueAvailable = true
        summary.residueSource = "loose_liters"
    end

    if fieldId ~= nil then
        FieldAdvisor.setCoverageCache(fieldId, "grassResidue", summary)
    end

    return summary
end

---@return number|nil
function FieldAdvisor.resolveStrawFillTypeIndex()
    if FieldAdvisor._strawFillTypeIndex ~= nil then
        return FieldAdvisor._strawFillTypeIndex
    end

    if FillType ~= nil and FillType.STRAW ~= nil then
        local fillConst = tonumber(FillType.STRAW)
        if fillConst ~= nil and fillConst > 0 then
            FieldAdvisor._strawFillTypeIndex = fillConst
            return fillConst
        end
    end

    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeIndexByName == nil then
        return nil
    end

    local ok, idx = pcall(g_fillTypeManager.getFillTypeIndexByName, g_fillTypeManager, "STRAW")
    idx = ok and tonumber(idx) or nil
    if idx ~= nil and idx > 0 then
        FieldAdvisor._strawFillTypeIndex = idx
        return idx
    end

    return nil
end

---@param field table|nil
---@return number
--- Per-axis half-extent for overview/completion probe grids (inset + cap; residue uses getFieldSampleHalfExtent).
---@param field table|nil
---@param centerX number|nil
---@param centerZ number|nil
---@return number halfX
---@return number halfZ
function FieldAdvisor.getProbeSampleHalfExtents(field, centerX, centerZ)
    if centerX == nil or centerZ == nil then
        centerX, centerZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end
    if centerX == nil or centerZ == nil then
        return 0, 0
    end

    local extentX = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 1, 0)
    local extentZ = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 0, 1)
    local inset = math.max(0, tonumber(FieldAdvisor.PROBE_EDGE_INSET) or 0)
    local cap = math.max(0, tonumber(FieldAdvisor.PROBE_SAMPLE_MAX_HALF_EXTENT) or 0)

    local halfX = math.max(0, extentX - inset)
    local halfZ = math.max(0, extentZ - inset)
    if cap > 0 then
        halfX = math.min(halfX, cap)
        halfZ = math.min(halfZ, cap)
    end

    return halfX, halfZ
end

--- Max axis half-extent (dump compat); prefer getProbeSampleHalfExtents for rectangular grids.
---@param field table|nil
---@param centerX number|nil
---@param centerZ number|nil
---@return number
function FieldAdvisor.getProbeSampleHalfExtent(field, centerX, centerZ)
    local halfX, halfZ = FieldAdvisor.getProbeSampleHalfExtents(field, centerX, centerZ)
    return math.max(halfX, halfZ)
end

--- Half-extent for grass/straw cross-bar liter samples (full measured field reach).
---@param field table|nil
---@return number
function FieldAdvisor.getFieldSampleHalfExtent(field)
    local centerX, centerZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    if centerX == nil or centerZ == nil then
        return 0
    end

    local extentX = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 1, 0)
    local extentZ = FieldAdvisor.measureFieldAxisHalfExtent(field, centerX, centerZ, 0, 1)
    return math.max(extentX, extentZ)
end

--- Single decision for straw windrows: STRAW liters from DensityMapHeightUtil.getFillLevelAtArea only.
--- Bales on the field are a separate state (counted via baleSummary, not inferred here).
---@param field table|nil
---@param fieldId number|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param baleSummary table|nil
---@param gridSteps number|nil unused — kept for call-site compatibility
---@return table summary
function FieldAdvisor.deriveStrawResidueSummary(field, fieldId, worldX, worldZ, baleSummary, gridSteps)
    local strawBaleCount = FieldAdvisor.getFieldBaleCountByKind(baleSummary, "straw")
    local summary = {
        hasWindrow = false,
        strawBaleCount = strawBaleCount,
        fillApiReady = FieldAdvisor.isStrawFillLevelApiReady(),
        centerFillLiters = 0,
        crossFillMax = 0,
        fillMinLiters = 0,
    }

    if field == nil then
        return summary
    end

    if fieldId ~= nil then
        local cached = FieldAdvisor.getCoverageCache(fieldId, "strawResidue", FieldAdvisor.STRAW_RESIDUE_CACHE_TTL_MS)
        if cached ~= nil then
            cached.strawBaleCount = strawBaleCount
            cached.fillApiReady = FieldAdvisor.isStrawFillLevelApiReady()
            return cached
        end
    end

    if not summary.fillApiReady then
        return summary
    end

    if worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end
    if worldX == nil or worldZ == nil then
        return summary
    end

    local strawFillIndex = FieldAdvisor.resolveStrawFillTypeIndex()
    if strawFillIndex == nil or strawFillIndex <= 0 then
        return summary
    end

    local halfSize = FieldAdvisor.GRASS_RESIDUE_SAMPLE_HALF_SIZE
    summary.centerFillLiters = FieldAdvisor.callFillLevelAtArea(
        strawFillIndex,
        worldX - halfSize, worldZ - halfSize,
        worldX + halfSize, worldZ - halfSize,
        worldX - halfSize, worldZ + halfSize
    )

    local halfExtent = FieldAdvisor.getFieldSampleHalfExtent(field)
    local lineSteps = 5
    local ewFillMax = 0
    local nsFillMax = 0

    for step = -lineSteps, lineSteps do
        local t = step / lineSteps
        local xEw = worldX + t * halfExtent
        if FieldAdvisor.isSamplePositionOnField(field, xEw, worldZ) then
            local liters = FieldAdvisor.callFillLevelAtArea(
                strawFillIndex,
                xEw - halfSize, worldZ - halfSize,
                xEw + halfSize, worldZ - halfSize,
                xEw - halfSize, worldZ + halfSize
            )
            if liters > ewFillMax then
                ewFillMax = liters
            end
        end

        local zNs = worldZ + t * halfExtent
        if FieldAdvisor.isSamplePositionOnField(field, worldX, zNs) then
            local liters = FieldAdvisor.callFillLevelAtArea(
                strawFillIndex,
                worldX - halfSize, zNs - halfSize,
                worldX + halfSize, zNs - halfSize,
                worldX - halfSize, zNs + halfSize
            )
            if liters > nsFillMax then
                nsFillMax = liters
            end
        end
    end

    summary.crossFillMax = math.max(ewFillMax, nsFillMax, summary.centerFillLiters)
    summary.fillMinLiters = math.max(0.001, FieldAdvisor.getMinValidHeightLiters(strawFillIndex) * 0.25)
    summary.hasWindrow = summary.crossFillMax >= summary.fillMinLiters

    if fieldId ~= nil then
        FieldAdvisor.setCoverageCache(fieldId, "strawResidue", summary)
    end

    return summary
end

--- Any probe on the field grid shows harvested arable stubble (partial NPC harvest).
---@param field table|nil
---@param fieldId number|nil
---@param worldX number|nil
---@param worldZ number|nil
---@param arableFruit number|nil
---@param gridSteps number|nil
---@return boolean
function FieldAdvisor.fieldHasAnyStubbleProbe(field, fieldId, worldX, worldZ, arableFruit, gridSteps)
    if field == nil or arableFruit == nil or arableFruit <= 0 then
        return false
    end

    if worldX == nil or worldZ == nil then
        worldX, worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end
    if worldX == nil or worldZ == nil then
        return false
    end

    local points = {}
    if FieldTaskCompletion ~= nil and FieldTaskCompletion.collectSamplePoints ~= nil then
        points = FieldTaskCompletion.collectSamplePoints(field, worldX, worldZ, gridSteps or 2)
    else
        points = { { x = worldX, z = worldZ } }
    end

    for _, point in ipairs(points) do
        local sampleState = FieldAdvisor.getEnrichedFieldState(field, fieldId, point.x, point.z)
        if FieldAdvisor.isArableHarvestedStubble(field, sampleState, arableFruit) then
            return true
        end
    end

    return false
end

-- Forward declaration: addStrawLogisticsActions is defined above FieldAdvisor_addAction body.
local FieldAdvisor_addAction

--- Straw logistics only when straw is physically present (windrows or bales). Stubble alone or
--- a straw-capable crop is not enough — the combine straw spreader may be off (no swaths).
---@param ctx table
---@return boolean
function FieldAdvisor.fieldHasStrawLogisticsContext(ctx)
    if ctx == nil or ctx.isGrass then
        return false
    end

    local strawFruit = FieldAdvisor.resolveDisplayArableFruitIndex(ctx.field, ctx.aggregation, ctx.probeState)
    if not FieldAdvisor.isStrawProducingCrop(strawFruit) then
        return false
    end

    if FieldAdvisor.getFieldBaleCountByKind(ctx.baleSummary, "straw") > 0 then
        return true
    end

    local summary = ctx.strawResidueSummary
    return summary ~= nil and summary.hasWindrow == true
end

--- Press while straw windrows remain; collect only when swaths are gone but bales remain.
---@param actions table[]
---@param ctx table
function FieldAdvisor.addStrawLogisticsActions(actions, ctx)
    if not FieldAdvisor.fieldHasStrawLogisticsContext(ctx) then
        return
    end

    local summary = ctx.strawResidueSummary
    local hasWindrow = summary ~= nil and summary.hasWindrow == true
    local strawBales = FieldAdvisor.getFieldBaleCountByKind(ctx.baleSummary, "straw")

    if hasWindrow then
        FieldAdvisor_addAction(actions, {
            actionType = "straw_bale",
            label = FieldAdvisor.text("ftdl_action_straw_bale", "Stroh pressen/bergen"),
            autoComplete = true,
        })
    elseif strawBales > 0 then
        FieldAdvisor_addAction(actions, {
            actionType = "straw_bale_collect",
            label = FieldAdvisor.text("ftdl_action_straw_bale_collect", "Strohballen einsammeln"),
            autoComplete = true,
        })
    end
end

--- Baling/silage-baling complete once bales physically appear on the field.
---@param summary table|nil
---@param baleSummary table|nil
---@param baseline table|nil
---@return boolean
function FieldAdvisor.isGrassBalingWorkComplete(summary, baleSummary, baseline)
    local grassNow = FieldAdvisor.getFieldBaleCountByKind(baleSummary, "grass")
    local baselineGrass = baseline ~= nil and tonumber(baseline.baleGrassCount) or nil
    if baselineGrass == nil and baseline ~= nil then
        baselineGrass = tonumber(baseline.baleCount) or 0
    end
    baselineGrass = baselineGrass or 0

    if grassNow > baselineGrass then
        return true
    end

    return summary ~= nil and summary.residueState == FieldAdvisor.GRASS_RESIDUE_BALED
        and grassNow > 0
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

-- Bale fill-type -> logistics kind. STRAW = arable straw bales; grass-derived bales (hay/silage/
-- fresh grass) belong to grass logistics. Resolved from g_fillTypeManager and memoized by index.
FieldAdvisor.BALE_KIND_BY_FILLTYPE_NAME = {
    STRAW = "straw",
    DRYGRASS_WINDROW = "grass",
    SILAGE = "grass",
    GRASS_WINDROW = "grass",
}

---@param bale any
---@return number|nil
function FieldAdvisor.getBaleFillTypeIndex(bale)
    if bale == nil then
        return nil
    end

    local idx = tonumber(bale.fillType)
    if (idx == nil or idx <= 0) and bale.getFillType ~= nil then
        local ok, value = pcall(bale.getFillType, bale)
        if ok then
            idx = tonumber(value)
        end
    end

    return idx
end

--- Classify a field bale as "straw" | "grass" | "other" by its fill type (cached by index).
---@param bale any
---@return string
function FieldAdvisor.classifyBaleKind(bale)
    local idx = FieldAdvisor.getBaleFillTypeIndex(bale)
    if idx == nil or idx <= 0 then
        return "other"
    end

    if FieldAdvisor._baleKindByIndex ~= nil and FieldAdvisor._baleKindByIndex[idx] ~= nil then
        return FieldAdvisor._baleKindByIndex[idx]
    end

    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeByIndex == nil then
        return "other"
    end

    local ok, fillType = pcall(g_fillTypeManager.getFillTypeByIndex, g_fillTypeManager, idx)
    if not ok or fillType == nil or fillType.name == nil then
        return "other"
    end

    local name = string.upper(tostring(fillType.name))
    local kind = FieldAdvisor.BALE_KIND_BY_FILLTYPE_NAME[name]
    if kind == nil then
        -- Crop windrow bales (ALFALFA_WINDROW, LUCERNE_WINDROW, …) are grass logistics, not "other".
        if string.match(name, "_WINDROW$") then
            kind = "grass"
        else
            kind = "other"
        end
    end
    FieldAdvisor._baleKindByIndex = FieldAdvisor._baleKindByIndex or {}
    FieldAdvisor._baleKindByIndex[idx] = kind
    return kind
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
        bale.obstacleNodeId,
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

--- True when (x,z) lies on a user-marked Hof parcel (Planfrucht = Hof).
---@param x number|nil
---@param z number|nil
---@return boolean
function FieldAdvisor.isBalePositionOnFarmyardPlot(x, z)
    if FieldPlannedCrop == nil or x == nil or z == nil or g_fieldManager == nil then
        return false
    end

    local fields = g_fieldManager.fields
    if fields == nil and g_fieldManager.getFields ~= nil then
        fields = g_fieldManager:getFields()
    end
    if fields == nil then
        return false
    end

    for _, plot in pairs(fields) do
        local plotId = plot.getId ~= nil and tonumber(plot:getId()) or nil
        if plotId ~= nil and FieldPlannedCrop.isFarmyard(plotId) then
            if FieldAdvisor.testPositionInsideField(plot, x, z) == true then
                return true
            end
        end
    end

    return false
end

--- Single owner per bale: engine field at position + polygon on that field object (no bbox/heuristic).
---@param x number|nil
---@param z number|nil
---@return number|nil fieldId
function FieldAdvisor.resolveBaleOwnerFieldId(x, z)
    if x == nil or z == nil then
        return nil
    end

    local cacheKey = string.format("%.1f,%.1f", x, z)
    if FieldAdvisor._baleOwnerFieldCache ~= nil and FieldAdvisor._baleOwnerFieldCache[cacheKey] ~= nil then
        local cached = FieldAdvisor._baleOwnerFieldCache[cacheKey]
        if cached == false then
            return nil
        end
        return cached
    end

    FieldAdvisor._baleOwnerFieldCache = FieldAdvisor._baleOwnerFieldCache or {}

    if FieldAdvisor.isBalePositionOnFarmyardPlot(x, z) then
        FieldAdvisor._baleOwnerFieldCache[cacheKey] = false
        return nil
    end

    local fieldId, ownerField = FieldAdvisor.resolveEngineFieldAtWorldPosition(x, z)
    if fieldId == nil then
        FieldAdvisor._baleOwnerFieldCache[cacheKey] = false
        return nil
    end

    if FieldPlannedCrop ~= nil and FieldPlannedCrop.isFarmyard(fieldId) then
        FieldAdvisor._baleOwnerFieldCache[cacheKey] = false
        return nil
    end

    if ownerField ~= nil then
        local inside = FieldAdvisor.testPositionInsideField(ownerField, x, z)
        if inside == false then
            FieldAdvisor._baleOwnerFieldCache[cacheKey] = false
            return nil
        end
    end

    FieldAdvisor._baleOwnerFieldCache[cacheKey] = fieldId
    return fieldId
end

--- Field-local bale test: owner field id from engine must match this field (no fallback).
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
    if targetFieldId == nil then
        return false
    end

    local ownerFieldId = FieldAdvisor.resolveBaleOwnerFieldId(x, z)
    return ownerFieldId ~= nil and ownerFieldId == targetFieldId
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

--- Bale count that matters for one logistics action (grass vs. straw vs. total).
--- Single place for collect/press completion and grass cut-phase suggestions.
---@param baleSummary table|nil
---@param actionType string|nil
---@return number
function FieldAdvisor.getTrackedBaleCountForAction(baleSummary, actionType)
    if actionType == "straw_bale" or actionType == "straw_bale_collect" then
        return FieldAdvisor.getFieldBaleCountByKind(baleSummary, "straw")
    end
    if actionType == "grass_bale" or actionType == "grass_silage_bale" or actionType == "grass_bale_collect" then
        return FieldAdvisor.getFieldBaleCountByKind(baleSummary, "grass")
    end
    return FieldAdvisor.getFieldBaleCount(baleSummary)
end

--- Field-local bale count for one logistics kind ("straw" | "grass" | "other"); nil kind = total.
---@param baleSummary table|nil
---@param kind string|nil
---@return number
function FieldAdvisor.getFieldBaleCountByKind(baleSummary, kind)
    if baleSummary == nil then
        return 0
    end

    if kind == nil then
        return FieldAdvisor.getFieldBaleCount(baleSummary)
    end

    return tonumber(baleSummary[kind]) or 0
end

---@param field table|nil
---@param cacheTtlMs number|nil
---@return table summary
function FieldAdvisor.sampleBaleCoverage(field, cacheTtlMs)
    local fieldId = field ~= nil and field.getId ~= nil and field:getId() or nil

    local summary = {
        total = 0,
        straw = 0,
        grass = 0,
        other = 0,
    }

    if field == nil then
        return summary
    end

    FieldAdvisor._baleOwnerFieldCache = {}

    local centerX, centerZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    local bales = FieldAdvisor.collectMapBaleObjects()

    for _, bale in ipairs(bales) do
        local x, z = FieldAdvisor.getBaleWorldPosition(bale)
        if x ~= nil and z ~= nil
            and FieldAdvisor.isBalePositionInsideField(field, x, z, centerX, centerZ) then
            summary.total = summary.total + 1
            local kind = FieldAdvisor.classifyBaleKind(bale)
            summary[kind] = (summary[kind] or 0) + 1
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

        if (weedSummary.live or 0) >= 1 and weedSummary.liveRatio > 0.001 then
            return string.format("%d%%", math.floor(weedSummary.liveRatio * 100 + 0.5))
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

--- Build the normalized facts for the single weed decision (WeedAdvice.deriveWeedAdvice).
--- Engine access lives here; the decision itself is pure and headless-tested.
---@param fieldState table|nil
---@param rules table|nil
---@param weedSummary table|nil
---@return table facts
function FieldAdvisor.buildWeedAdviceFacts(fieldState, rules, weedSummary)
    local hasSummary = weedSummary ~= nil
    local hasCoverage = hasSummary and (weedSummary.total or 0) > 0
    local classified = nil
    if hasSummary then
        classified = weedSummary.classified or ((weedSummary.live or 0) + (weedSummary.dead or 0))
    end

    return {
        enabled = rules ~= nil and rules.weedsEnabled == true,
        hasSummary = hasSummary,
        hasCoverage = hasCoverage,
        live = hasSummary and (weedSummary.live or 0) or 0,
        classified = classified or 0,
        liveRatio = hasSummary and (weedSummary.liveRatio or 0) or 0,
        doneByCoverage = hasCoverage and FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary) or false,
        deadOrSprayed = FieldAdvisor.isWeedDeadOrSprayed(fieldState),
        pressure = FieldAdvisor.getEffectiveWeedPressure(fieldState),
        weedState = FieldAdvisor.getWeedStateLevel(fieldState),
    }
end

---@param fieldState table|nil
---@param rules table
---@param weedSummary table|nil
---@return boolean
function FieldAdvisor.fieldNeedsWeedCombat(fieldState, rules, weedSummary)
    return WeedAdvice.deriveWeedAdvice(
        FieldAdvisor.buildWeedAdviceFacts(fieldState, rules, weedSummary)
    ).needsCombat
end

---@param fieldState table|nil
---@param rules table
---@param weedSummary table|nil
---@return boolean
function FieldAdvisor.fieldNeedsWeedWatch(fieldState, rules, weedSummary)
    return WeedAdvice.deriveWeedAdvice(
        FieldAdvisor.buildWeedAdviceFacts(fieldState, rules, weedSummary)
    ).watch
end

--- Mechanical weeding (hoe) for light or moderate live weed.
---@param fieldState table|nil
---@param rules table
---@param weedSummary table|nil
---@return boolean
function FieldAdvisor.fieldNeedsWeedHoe(fieldState, rules, weedSummary)
    return WeedAdvice.deriveWeedAdvice(
        FieldAdvisor.buildWeedAdviceFacts(fieldState, rules, weedSummary)
    ).hoe
end

--- Herbicide spray for stronger weed pressure or growth stage.
---@param fieldState table|nil
---@param rules table
---@param weedSummary table|nil
---@return boolean
function FieldAdvisor.fieldShouldSuggestWeedSpray(fieldState, rules, weedSummary)
    return WeedAdvice.deriveWeedAdvice(
        FieldAdvisor.buildWeedAdviceFacts(fieldState, rules, weedSummary)
    ).spray
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
--- FruitTypeDesc only: getIsHarvestReady API and/or minHarvestingGrowthState. No inventing.
---@param fruitTypeIndex number|nil
---@param fieldState table|nil
---@param fruitDesc table|nil
---@return number|nil steps until ripe (0 = ripe now); nil → UI shows "-"
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
    if fruitDesc == nil then
        return nil
    end

    local target = nil
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

    if target == nil then
        return nil
    end

    if state >= target then
        return 0
    end

    return target - state
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

-- Fruit-kind dispatcher façade (B): routes grass -> isGrassHarvestable (meadow canon) and
-- arable -> isCropHarvestReady (season canon). Has no ripeness rule of its own.
---@param field table
---@param fieldState table|nil
---@return boolean
function FieldAdvisor.isHarvestReady(field, fieldState)
    local fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, field)

    if fruitTypeIndex ~= nil and FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        return FieldAdvisor.isGrassHarvestable(fieldState, field, nil)
    end

    if fruitTypeIndex ~= nil and fruitTypeIndex > 0 then
        if FieldAdvisor.isArableHarvestedStubble(field, fieldState, fruitTypeIndex) then
            return false
        end
        return FieldAdvisor.isCropHarvestReady(field, fieldState, fruitTypeIndex)
    end

    if fieldState ~= nil then
        if fieldState.isHarvestReady == true then
            return true
        end
    end

    if field ~= nil and field.groundType == "HARVEST_READY" then
        return true
    end

    return false
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

-- Crops that leave choppable stubble/chaff and gain a mulching yield bonus after harvest
-- (FS25 manual: wheat, barley, oat, sorghum, sunflower, soybean, corn). Root/leaf crops
-- (potato, beet, grass, ...) are not mulched here.
FieldAdvisor.MULCHABLE_STUBBLE_FRUITS = {
    WHEAT = true,
    BARLEY = true,
    OAT = true,
    RYE = true,
    TRITICALE = true,
    SORGHUM = true,
    SUNFLOWER = true,
    SOYBEAN = true,
    MAIZE = true,
}

---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isMulchableStubbleCrop(fruitTypeIndex)
    local normalized = FieldAdvisor.normalizeFruitName(FieldAdvisor.getFruitTypeName(fruitTypeIndex))
    if normalized == nil then
        return false
    end

    return FieldAdvisor.MULCHABLE_STUBBLE_FRUITS[normalized] == true
end

-- Crops that leave loose straw after harvest (can be baled or picked up): cereals + canola + soy.
-- Maize/sunflower and root/leaf crops leave no strawable swath in FS25.
FieldAdvisor.STRAW_PRODUCING_FRUITS = {
    WHEAT = true,
    BARLEY = true,
    OAT = true,
    CANOLA = true,
    RYE = true,
    TRITICALE = true,
    SORGHUM = true,
    SOYBEAN = true,
}

---@param fruitDesc table|nil
---@param growthMode number|nil
---@param period number|nil
---@return boolean
function FieldAdvisor.isFruitPlantableInPeriod(fruitDesc, growthMode, period)
    if fruitDesc == nil or fruitDesc.getIsPlantableInPeriod == nil then
        return false
    end

    growthMode = growthMode or FieldAdvisor.getActiveGrowthMode()
    period = period or FieldAdvisor.getCurrentSeasonPeriod()
    local ok, plantable = pcall(fruitDesc.getIsPlantableInPeriod, fruitDesc, growthMode, period)
    return ok and plantable == true
end

--- Next season period when the fruit may be sown (current period if allowed now).
---@param fruitDesc table|nil
---@param growthMode number|nil
---@param fromPeriod number|nil
---@return number|nil
function FieldAdvisor.getNextPlantablePeriod(fruitDesc, growthMode, fromPeriod)
    if fruitDesc == nil then
        return nil
    end

    growthMode = growthMode or FieldAdvisor.getActiveGrowthMode()
    fromPeriod = fromPeriod or FieldAdvisor.getCurrentSeasonPeriod()

    for offset = 0, 11 do
        local period = FieldAdvisor.getSeasonPeriodForOffset(fromPeriod, offset)
        if FieldAdvisor.isFruitPlantableInPeriod(fruitDesc, growthMode, period) then
            return period
        end
    end

    return nil
end

--- Calendar month label for the next sow window of a planned fruit (e.g. "Mär").
---@param fruitTypeIndex number|nil
---@return string|nil
function FieldAdvisor.getSowWindowHint(fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 then
        return nil
    end

    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    if fruitDesc == nil then
        return nil
    end

    local period = FieldAdvisor.getNextPlantablePeriod(fruitDesc)
    if period == nil then
        return nil
    end

    local monthLabel = FieldAdvisor.getHarvestPeriodDisplayLabel(period)
    if monthLabel == nil or monthLabel == "" or monthLabel == "-" then
        return nil
    end

    return monthLabel
end

--- Planned sow label (fruit + optional next sow month from FruitTypeDesc).
---@param plannedIndex number|nil
---@param resow boolean|nil
---@param short boolean|nil
---@return string|nil
function FieldAdvisor.formatPlannedSowLabel(plannedIndex, resow, short)
    if plannedIndex == nil or plannedIndex <= 0 then
        return nil
    end

    local plannedTitle = FieldAdvisor.getLocalizedFruitTitle(plannedIndex)
    if plannedTitle == nil or plannedTitle == "-" then
        return nil
    end

    local sowMonth = FieldAdvisor.getSowWindowHint(plannedIndex)
    local hasMonth = sowMonth ~= nil and sowMonth ~= "-"

    if short == true then
        if hasMonth then
            return FieldAdvisor.text("ftdl_action_sow_planned_short_month", "%s säen %s", plannedTitle, sowMonth)
        end
        return FieldAdvisor.text("ftdl_action_sow_planned_short", "%s säen", plannedTitle)
    end

    if resow == true then
        if hasMonth then
            return FieldAdvisor.text("ftdl_action_sow_planned_resow_month", "%s neu säen %s", plannedTitle, sowMonth)
        end
        return FieldAdvisor.text("ftdl_action_sow_planned_resow", "%s neu säen", plannedTitle)
    end

    if hasMonth then
        return FieldAdvisor.text("ftdl_action_sow_planned_month", "%s säen %s", plannedTitle, sowMonth)
    end

    return FieldAdvisor.text("ftdl_action_sow_planned", "%s säen", plannedTitle)
end

--- Sow suggestion/task label with per-field planned crop when set (FieldPlannedCrop).
---@param fieldId number|nil
---@param resow boolean|nil true = post-harvest re-sow wording
---@return string label, number|nil plannedFruitTypeIndex
function FieldAdvisor.formatSowActionLabel(fieldId, resow)
    local plannedIndex = FieldPlannedCrop ~= nil and FieldPlannedCrop.get(fieldId) or nil
    local label = FieldAdvisor.formatPlannedSowLabel(plannedIndex, resow, false)
    if label ~= nil then
        return label, plannedIndex
    end

    if resow == true then
        return FieldAdvisor.text("ftdl_action_resow", "Neu ansäen"), nil
    end

    return FieldAdvisor.text("ftdl_action_sow_empty", "Ansäen"), nil
end

---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isStrawProducingCrop(fruitTypeIndex)
    local normalized = FieldAdvisor.normalizeFruitName(FieldAdvisor.getFruitTypeName(fruitTypeIndex))
    if normalized == nil then
        return false
    end

    return FieldAdvisor.STRAW_PRODUCING_FRUITS[normalized] == true
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

    -- Specific grass crops (lucerne/clover/…) often share a generic grass fill type whose
    -- title localizes to "Grass". Prefer the crop name over the generic grass label.
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

    -- No +bonus for ALFALFA/CLOVER/etc.: growth flags alone often match generic GRASS equally,
    -- and a tie-break bias turned every meadow into Luzerne. Specific crops win only via
    -- density/residue/field hints or a strictly higher growth score.
    return score
end

--- Density map often returns generic GRASS for alfalfa/lucerne; match growth flags per grass crop.
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
        if score > bestScore then
            bestScore = score
            bestIndex = fruitTypeIndex
        elseif score == bestScore and bestIndex ~= nil then
            -- On equal growth match, keep generic GRASS rather than inventing Luzerne/Klee.
            local curGeneric = FieldAdvisor.isGenericGrassFruitIndex(bestIndex)
            local newGeneric = FieldAdvisor.isGenericGrassFruitIndex(fruitTypeIndex)
            if newGeneric and not curGeneric then
                bestIndex = fruitTypeIndex
            end
        end
    end

    if bestIndex ~= nil and bestScore > 0 then
        if probeIndex == nil then
            return bestIndex
        end
        local probeScore = FieldAdvisor.scoreGrassFruitGrowthMatch(probeIndex, fieldState)
        -- Only replace a generic probe when the candidate scores strictly higher.
        if FieldAdvisor.isGenericGrassFruitIndex(probeIndex) and bestScore > probeScore then
            return bestIndex
        end
        if not FieldAdvisor.isGenericGrassFruitIndex(probeIndex) and bestScore >= probeScore then
            return bestIndex
        end
    end

    return probeIndex
end

--- Detect lucerne/clover/etc. from windrow/cut residue fill type (more reliable than generic GRASS index).
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
                -- Strict > only: equal harvestReady scores must not upgrade GRASS → Luzerne.
                if specificScore > 0 and specificScore > genericScore then
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

--- Arable field after combine: stubble/cut remain, not a standing harvestable crop.
---@param field table|nil
---@param fieldState table|nil
---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isArableHarvestedStubble(field, fieldState, fruitTypeIndex)
    if fieldState == nil or fruitTypeIndex == nil or fruitTypeIndex <= 0 then
        return false
    end

    if FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        return false
    end

    if FieldAdvisor.isWithered(fieldState) then
        return false
    end

    local growthState = FieldAdvisor.getEffectiveGrowthState(fieldState)
    if growthState <= 0 then
        return false
    end

    local growth = FieldAdvisor.evaluateFruitGrowth(fruitTypeIndex, growthState)
    if growth.isCut then
        return true
    end

    local fruitDesc = FieldAdvisor.getFruitTypeDesc(fruitTypeIndex)
    local maxHarvest = 0
    if fruitDesc ~= nil and fruitDesc.maxHarvestingGrowthState ~= nil then
        maxHarvest = tonumber(fruitDesc.maxHarvestingGrowthState) or 0
        if maxHarvest > 0 and growthState > maxHarvest then
            return true
        end
    end

    if growth.isGrowing and not growth.isHarvestable and not growth.isHarvestReady then
        if maxHarvest > 0 and growthState > maxHarvest then
            return true
        end
    end

    local ground = FieldAdvisor.getGroundTypeName(fieldState)
    if FieldAdvisor.groundTypeIsOneOf(ground, { "STUBBLE", "HARVEST_READY", "HARVEST_READY_OTHER" }) then
        if growth.isHarvestReady or growth.isHarvestable then
            return false
        end
        if maxHarvest > 0 and growthState > 0 and growthState <= maxHarvest then
            return false
        end
        return true
    end

    return false
end

-- Growth-only ripeness core (B): no season-window check. isCropHarvestReady wraps this and adds
-- the season window; getExpectedHarvestPeriod reuses this raw test for ETA. Kept separate on
-- purpose — folding it into isCropHarvestReady would break the season-independent ETA path.
---@param field table|nil
---@param fieldState table|nil
---@param fruitTypeIndex number|nil
---@return boolean
function FieldAdvisor.isCropHarvestReadyByGrowth(field, fieldState, fruitTypeIndex)
    if fruitTypeIndex == nil or FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        return false
    end

    if FieldAdvisor.isArableHarvestedStubble(field, fieldState, fruitTypeIndex) then
        return false
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

    if fieldState ~= nil then
        if FieldAdvisor.resolveGroundTypeName(fieldState.groundType) == "HARVEST_READY" then
            return true
        end

        if fieldState.isHarvestReady == true then
            return true
        end
    end

    if FieldAdvisor.fruitDescHasHarvestReadyApi(fruitTypeIndex) then
        return false
    end

    return growth.isHarvestable
end

-- Canon for "arable crop ready to harvest now" (B): growth core + active season window.
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

    -- Lingering stubble shred implies a recent mow, but defer to the single post-mow
    -- predicate so a stand that regrew to mowable height stays "harvestable".
    if aggregation ~= nil and (aggregation.maxStubbleShredLevel or 0) > 0
        and FieldAdvisor.isGrassPostMowState(probeState, field, fruitTypeIndex) then
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
                -- Specific forage (ALFALFA/CLOVER) can claim harvestReady on a cut growth;
                -- trust generic meadow cut before advertising „mähen“.
                local genericIdx = FieldAdvisor.getDefaultGrassFruitTypeIndex()
                if genericIdx ~= nil and genericIdx ~= fruitTypeIndex then
                    local genericGrowth = FieldAdvisor.evaluateFruitGrowth(genericIdx, growthState)
                    if genericGrowth.isCut then
                        return "cut"
                    end
                end
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
        -- phase=="harvestable" means the center already passed the post-mow predicate
        -- (not freshly cut). Only a genuinely cut representative probe overrides it.
        if phase == "harvestable" and aggregation ~= nil and aggregation.representativeState ~= nil then
            local repPhase = phaseForState(aggregation.representativeState)
            if repPhase == "cut" then
                return "cut"
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

-- Thin readouts of the getGrassMeadowPhase canon (D). They never decide a phase themselves;
-- keep them as one-liners so call sites read intent ("is this meadow cut/harvestable?").
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

--- Readout for labels/completion — not for phase (use FieldPhase.deriveFieldPhase).
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

    if FieldAdvisor.isArableHarvestedStubble(field, fieldState, fruitTypeIndex) then
        return false
    end

    if FieldAdvisor.groundTypeIsOneOf(groundType, { "STUBBLE", "HARVEST_READY", "HARVEST_READY_OTHER" }) then
        return false
    end

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

--- Readout for sow completion — not for phase (stubble excluded via isArableHarvestedStubble).
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

    if growthState > 0 then
        local fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, nil)
        if fruitTypeIndex ~= nil then
            if not FieldAdvisor.isGrassCrop(fruitTypeIndex)
                and FieldAdvisor.isArableHarvestedStubble(nil, fieldState, fruitTypeIndex) then
                return false
            end
            return true
        end
    end

    return false
end

--- Readout for cultivate completion — not for phase (stubble returns false).
---@param fieldState table|nil
---@return boolean
function FieldAdvisor.hasActiveCrop(fieldState)
    if fieldState == nil then
        return false
    end

    local fruitTypeIndex = FieldAdvisor.resolveFruitTypeIndex(fieldState, nil)
    if fruitTypeIndex ~= nil and fruitTypeIndex > 0 and not FieldAdvisor.isGrassCrop(fruitTypeIndex) then
        if FieldAdvisor.isArableHarvestedStubble(nil, fieldState, fruitTypeIndex) then
            return false
        end
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
            if not FieldAdvisor.isGrassCrop(fruitTypeIndex)
                and FieldAdvisor.isArableHarvestedStubble(nil, fieldState, fruitTypeIndex) then
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
    local fruitTypeIndex = FieldAdvisor.getFruitTypeIndex(fieldState)
    if fruitTypeIndex ~= nil
        and FieldAdvisor.isArableHarvestedStubble(nil, fieldState, fruitTypeIndex) then
        return FieldAdvisor.text("ftdl_growth_stubble", "Stoppeln")
    end

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

--- True when a still-grass field has a meaningful mix of worked strips and standing/mown grass.
--- Single edge probes or mown-ground readings (CULTIVATED on cut grass) must not trigger this.
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

    if FieldAdvisor.classifyProbe(fieldState, field) ~= FieldAdvisor.PROBE_SITUATION.GRASS then
        return false
    end

    local points = {}
    if FieldTaskCompletion ~= nil and FieldTaskCompletion.collectSamplePoints ~= nil then
        points = FieldTaskCompletion.collectSamplePoints(field, worldX, worldZ)
    else
        points[#points + 1] = { x = worldX, z = worldZ }
    end

    local grassCount = 0
    local workedCount = 0

    for _, point in ipairs(points) do
        if FieldAdvisor.isSamplePositionOnField(field, point.x, point.z) then
            local sampleState = FieldAdvisor.getEnrichedFieldState(field, fieldId, point.x, point.z)
            local situation = FieldAdvisor.classifyProbe(sampleState, field)
            if situation == FieldAdvisor.PROBE_SITUATION.GRASS then
                grassCount = grassCount + 1
            elseif situation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL
                or situation == FieldAdvisor.PROBE_SITUATION.ARABLE then
                workedCount = workedCount + 1
            end
        end
    end

    local sampled = grassCount + workedCount
    if sampled <= 0 or workedCount <= 0 or grassCount <= 0 then
        return false
    end

    local workedRatio = workedCount / sampled
    return workedCount >= 2
        and grassCount >= 2
        and workedRatio >= 0.08
        and workedRatio <= 0.85
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
        -- Fully tilled soil with no active crop (PLOWED/CULTIVATED/SEEDBED, growth 0) has no
        -- standing crop, even if a stale fruit id lingers (e.g. just-plowed merged parcel) -> '-'.
        -- Stubble (growth > 0) and sown ground keep their crop name.
        local groundType = FieldAdvisor.getGroundTypeName(fieldState)
        local tilledNoCrop = FieldAdvisor.getGrowthState(fieldState) <= 0
            and FieldAdvisor.groundTypeIsOneOf(groundType, { "PLOWED", "CULTIVATED", "SEEDBED" })
        if label ~= "-" and not tilledNoCrop
            and not FieldAdvisor.fieldHasPartialSoilWork(field, fieldId, fieldState, worldX, worldZ) then
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
        -- Specific grass crops (lucerne/clover) must not collapse to generic "Grass (part. worked)"
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

--- Map a FieldPhase enum value to the legacy cropPhase string used by resolveActionCandidates.
---@param phase string FieldPhase.PHASE.*
---@param isGrass boolean
---@return string
function FieldAdvisor.mapFieldPhaseToCropPhase(phase, isGrass)
    if phase == FieldPhase.PHASE.HARVEST_READY or phase == FieldPhase.PHASE.GRASS_HARVESTABLE then
        return "harvest_ready"
    end
    if phase == FieldPhase.PHASE.WITHERED then
        return "withered"
    end
    if phase == FieldPhase.PHASE.POST_HARVEST then
        return "post_harvest"
    end
    if phase == FieldPhase.PHASE.EMPTY then
        return "empty"
    end
    if phase == FieldPhase.PHASE.STANDING
        or phase == FieldPhase.PHASE.GRASS_STANDING
        or phase == FieldPhase.PHASE.GRASS_CUT
        or phase == FieldPhase.PHASE.GRASS_RESIDUE then
        return "growing"
    end
    -- unknown
    return isGrass and "growing" or "empty"
end

--- Build the normalized facts table for FieldPhase.deriveFieldPhase from live engine helpers.
--- Engine access lives here; the decision itself stays pure in FieldPhase.
---@param field table
---@param harvestState table|nil
---@param aggregation table|nil
---@param isGrass boolean
---@param fieldId number|nil
---@return table facts
function FieldAdvisor.buildFieldPhaseFacts(field, harvestState, aggregation, isGrass, fieldId)
    local ground = FieldAdvisor.getGroundTypeName(harvestState)
    local growth = FieldAdvisor.getEffectiveGrowthState(harvestState)
    local shred = FieldAdvisor.getStateNumber(harvestState, "stubbleShredLevel")

    if isGrass then
        -- getGrassMeadowPhase is the single grass-phase decider (handles post-mow, regrowth,
        -- withered). Do not re-layer postMow/partial-soil-work on top — that re-creates the
        -- "harvestable stand wrongly flagged cut" bug (Field 76).
        local probeState = aggregation ~= nil and aggregation.centerState or harvestState
        local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)
        return {
            dominant = "grass",
            isGrassCrop = true,
            hasFruit = true,
            growth = growth,
            maxHarvest = 0,
            ground = ground,
            shred = shred,
            residue = "none",
            residueReliable = false,
            flags = {
                cut = meadowPhase == "cut",
                harvestable = meadowPhase == "harvestable",
                harvestReady = meadowPhase == "harvestable",
                withered = meadowPhase == "withered",
            },
        }
    end

    local dominant = "unknown"
    if aggregation ~= nil then
        if aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.ARABLE then
            dominant = "arable"
        elseif aggregation.dominantSituation == FieldAdvisor.PROBE_SITUATION.BARE_SOIL then
            dominant = "bare_soil"
        end
    end

    local arableFruit = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, harvestState)
    if arableFruit == nil then
        arableFruit = FieldAdvisor.resolveFruitTypeIndex(harvestState, field)
    end

    local maxHarvest = 0
    local growthFlags = FieldAdvisor.evaluateFruitGrowth(arableFruit, growth)
    if arableFruit ~= nil and arableFruit > 0 then
        local fruitDesc = FieldAdvisor.getFruitTypeDesc(arableFruit)
        if fruitDesc ~= nil and fruitDesc.maxHarvestingGrowthState ~= nil then
            maxHarvest = tonumber(fruitDesc.maxHarvestingGrowthState) or 0
        end
    end

    return {
        dominant = dominant,
        isGrassCrop = false,
        hasFruit = arableFruit ~= nil and arableFruit > 0,
        growth = growth,
        maxHarvest = maxHarvest,
        ground = ground,
        shred = shred,
        residue = "none",
        residueReliable = false,
        flags = {
            cut = growthFlags.isCut == true,
            harvestable = growthFlags.isHarvestable == true,
            harvestReady = FieldAdvisor.isCropHarvestReady(field, harvestState, arableFruit),
            withered = FieldAdvisor.isWithered(harvestState),
        },
    }
end

--- Legacy UI phase string (growing/harvest_ready/...). Decision: FieldPhase.deriveFieldPhase.
function FieldAdvisor.getCropPhase(field, fieldState, aggregation)
    local fieldId = field.getId ~= nil and field:getId() or nil
    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)

    local isGrass = FieldAdvisor.isGrassPhaseContext(harvestState, field, aggregation)

    local facts = FieldAdvisor.buildFieldPhaseFacts(field, harvestState, aggregation, isGrass, fieldId)
    local phase = FieldPhase.deriveFieldPhase(facts)
    return FieldAdvisor.mapFieldPhaseToCropPhase(phase, isGrass)
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

    if FieldAdvisor.isGrassPhaseContext(harvestState, field, aggregation) then
        local residueState = grassResidueSummary ~= nil and grassResidueSummary.residueState
            or FieldAdvisor.GRASS_RESIDUE_NONE
        if residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE then
            return FieldAdvisor.text("ftdl_action_regrowth", "Nachwuchs")
        end

        local probeState = aggregation ~= nil and aggregation.centerState or harvestState
        if FieldAdvisor.isGrassPostMowState(probeState, field, nil) then
            return FieldAdvisor.text("ftdl_action_regrowth", "Nachwuchs")
        end

        local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)

        if meadowPhase == "harvestable" then
            return FieldAdvisor.text("ftdl_action_grass_mow_short", "Mähen")
        end

        if meadowPhase == "withered" then
            return FieldAdvisor.text("ftdl_action_withered", "Verdorrt")
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
            FieldAdvisor.getHarvestPeriodDisplayLabel(FieldAdvisor.getCurrentSeasonPeriod())
        )
    end

    local displayArableFruit = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, harvestState)
    if FieldAdvisor.isArableHarvestedStubble(field, harvestState, displayArableFruit or arableFruit) then
        return FieldAdvisor.text("ftdl_growth_stubble", "Stoppeln")
    end

    if FieldAdvisor.hasActiveCrop(harvestState) then
        local displayFruit = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, harvestState)
        if displayFruit == nil or displayFruit <= 0 then
            displayFruit = arableFruit
        end
        local harvestWindow = FieldAdvisor.getHarvestWindowHint(displayFruit, harvestState)
        if harvestWindow ~= nil and harvestWindow ~= "" and harvestWindow ~= "-" then
            return harvestWindow
        end
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

    if FieldAdvisor.isArableHarvestedStubble(nil, fieldState, fruitTypeIndex) then
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

    local trackArableWeed = FieldAdvisor.isArableWeedSamplingContext(aggregation, probeState, field, worldX, worldZ)
    local weedSummary = rules.weedsEnabled and trackArableWeed
        and FieldAdvisor.sampleWeedCoverage(field, fieldId, worldX, worldZ, aggregation)
        or nil

    local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)
    local isCutGround = FieldAdvisor.isGrassPostMowState(probeState, field, nil)
    local cachedBales = FieldAdvisor.getCoverageCache(
        fieldId,
        "bales",
        FieldAdvisor.BALE_CACHE_TTL_IDLE_MS
    )
    local hasTrackedBales = cachedBales ~= nil and (cachedBales.total or 0) > 0

    local isGrassCropField = FieldAdvisor.isGrassCropFieldContext(aggregation, probeState, field, worldX, worldZ)
    local hasPostMowSignal = meadowPhase == "cut" or isCutGround
        or (aggregation ~= nil and (aggregation.maxStubbleShredLevel or 0) > 0)
        or FieldAdvisor.getStateNumber(probeState, "stubbleShredLevel") > 0
        or FieldAdvisor.fieldHasPostMowGrassSignal(aggregation, probeState, field, nil)
    local isActiveResiduePhase = hasPostMowSignal or hasTrackedBales
        or meadowPhase == "cut" or meadowPhase == "growing"

    local baleTtl = isActiveResiduePhase
        and FieldAdvisor.BALE_CACHE_TTL_ACTIVE_MS
        or FieldAdvisor.BALE_CACHE_TTL_IDLE_MS
    -- Straw bales sit on arable harvested stubble, not just grass fields, so sample bales there too.
    local arableStubbleFruit = (aggregation ~= nil and aggregation.dominantArableFruit)
        or FieldAdvisor.resolveFruitTypeIndex(probeState, field)
    local isArableStubble = not isGrassCropField
        and FieldAdvisor.isArableHarvestedStubble(field, probeState, arableStubbleFruit)
    local hasPartialStubble = not isGrassCropField
        and FieldAdvisor.isStrawProducingCrop(arableStubbleFruit)
        and FieldAdvisor.fieldHasAnyStubbleProbe(field, fieldId, worldX, worldZ, arableStubbleFruit)
    local shouldSampleBales = isGrassCropField or hasTrackedBales or isArableStubble or hasPartialStubble
    local baleSummary = shouldSampleBales
        and FieldAdvisor.sampleBaleCoverage(field, baleTtl)
        or nil

    -- Grass residue: windrow liters + field bales (deriveGrassResidueSummary). Straw bales sampled above separately.
    local grassResidueSummary = nil
    local grassFruitForResidue = FieldAdvisor.resolveGrassFruitTypeIndex(probeState, field, aggregation, worldX, worldZ)
        or (aggregation ~= nil and aggregation.dominantGrassFruit)
    if isGrassCropField or hasTrackedBales or hasPostMowSignal then
        if hasPostMowSignal and fieldId ~= nil and FieldAdvisor.clearCoverageCache ~= nil then
            FieldAdvisor.clearCoverageCache(fieldId, "grassResidue")
        end
        grassResidueSummary = FieldAdvisor.deriveGrassResidueSummary(
            field, fieldId, worldX, worldZ, baleSummary, grassFruitForResidue
        )
    end

    local strawResidueSummary = nil
    local strawBalesOnField = FieldAdvisor.getFieldBaleCountByKind(baleSummary, "straw")
    local onStrawGround = FieldAdvisor.groundTypeIsOneOf(
        FieldAdvisor.getGroundTypeName(probeState),
        { "STUBBLE", "HARVEST_READY", "HARVEST_READY_OTHER" }
    )
    local shouldScanStrawWindrows = not isGrassCropField
        and FieldAdvisor.isStrawProducingCrop(arableStubbleFruit)
        and (isArableStubble or hasPartialStubble or strawBalesOnField > 0 or onStrawGround)
    if shouldScanStrawWindrows then
        if fieldId ~= nil and FieldAdvisor.clearCoverageCache ~= nil then
            FieldAdvisor.clearCoverageCache(fieldId, "strawResidue")
        end
        strawResidueSummary = FieldAdvisor.deriveStrawResidueSummary(
            field, fieldId, worldX, worldZ, baleSummary, FieldAdvisor.OVERVIEW_SAMPLE_GRID_STEPS
        )
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
        strawResidueSummary = strawResidueSummary,
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
FieldAdvisor_addAction = function(actions, action)
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
---@param sprayLevel number|nil
---@return table[]
function FieldAdvisor.expandOrganicFertilizerPasses(actions, pfSample, sprayLevel)
    if actions == nil or not FieldAdvisorSettings.isOrganicMultiPassEnabled() then
        return actions
    end

    local nitrogen = pfSample ~= nil and tonumber(pfSample.nitrogenValue) or nil
    local passCount
    if nitrogen ~= nil then
        passCount = FieldAdvisor.getOrganicFertilizerPassCount(nitrogen)
    elseif FertilizerAdvice ~= nil and FertilizerAdvice.getSprayPassCount ~= nil then
        passCount = FertilizerAdvice.getSprayPassCount(sprayLevel, FieldAdvisor.resolveSprayLevelMax())
    else
        passCount = 1
    end
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

--- Soil-work steps between manure/slurry passes (never two fertilizer passes back-to-back).
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
        or actionType == "weed_hoe"
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

    -- Manure/slurry passes between soil work (user picks manure or slurry each time).
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
        -- No plow/sow/lime/roller/cultivate on this field: at most one manure/slurry pass.
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
---@param sprayLevel number|nil
---@return table[]
function FieldAdvisor.finishActionCandidates(actions, pfSample, sprayLevel)
    actions = FieldAdvisor.expandOrganicFertilizerPasses(actions, pfSample, sprayLevel)

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
    local grassBaleCount = FieldAdvisor.getFieldBaleCountByKind(baleSummary, "grass")

    -- Standing grass ready to mow: suggest mow and stop (not post-mow logistics).
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

    -- Post-mow signals (cut ground, stubble shred, or bales on the field) => logistics phase.
    if FieldAdvisor.isGrassPostMowState(probeState, field, grassFruitHint)
        or grassBaleCount > 0
        or FieldAdvisor.getStateNumber(probeState, "stubbleShredLevel") > 0
        or (aggregation ~= nil and (aggregation.maxStubbleShredLevel or 0) > 0)
        or FieldAdvisor.isGrassCutGroundType(FieldAdvisor.getGroundTypeName(probeState)) then
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
        local residueState = grassResidueSummary ~= nil and grassResidueSummary.residueState
            or FieldAdvisor.GRASS_RESIDUE_NONE

        if grassBaleCount > 0 or residueState == FieldAdvisor.GRASS_RESIDUE_BALED then
            FieldAdvisor_addAction(actions, {
                actionType = "grass_bale_collect",
                label = FieldAdvisor.text("ftdl_action_grass_bale_collect", "Ballen einsammeln"),
                pickerLabel = FieldAdvisor.text("ftdl_action_grass_bale_collect", "Ballen einsammeln"),
                autoComplete = true,
            })
            return
        end

        local regrowthLabel = FieldAdvisor.getGrassPostMowDisplayLabel(field, fieldState, aggregation, grassResidueSummary)
            or FieldAdvisor.getGrassHarvestWindowLabel(fieldState, field, aggregation, grassResidueSummary)
        if regrowthLabel == "-" then
            regrowthLabel = FieldAdvisor.text("ftdl_action_regrowth", "Nachwuchs")
        end
        FieldAdvisor_addAction(actions, {
            actionType = "harvest_info",
            label = regrowthLabel,
            pickerLabel = regrowthLabel,
            autoComplete = false,
        })

        if residueState == FieldAdvisor.GRASS_RESIDUE_LOOSE
            or residueState == FieldAdvisor.GRASS_RESIDUE_NONE then
            FieldAdvisor_addAction(actions, {
                actionType = "grass_swath",
                label = FieldAdvisor.text("ftdl_action_grass_swath", "Schwaden"),
                pickerLabel = FieldAdvisor.text("ftdl_action_grass_swath", "Schwaden"),
                autoComplete = false,
            })
            FieldAdvisor_addAction(actions, {
                actionType = "grass_collect",
                label = FieldAdvisor.text("ftdl_action_grass_collect", "Heu sammeln (Ladewagen)"),
                pickerLabel = FieldAdvisor.text("ftdl_action_grass_collect", "Heu sammeln (Ladewagen)"),
                autoComplete = false,
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
            return
        end

        if residueState == FieldAdvisor.GRASS_RESIDUE_SWATH then
            FieldAdvisor_addAction(actions, {
                actionType = "grass_collect",
                label = FieldAdvisor.text("ftdl_action_grass_collect", "Heu sammeln (Ladewagen)"),
                pickerLabel = FieldAdvisor.text("ftdl_action_grass_collect", "Heu sammeln (Ladewagen)"),
                autoComplete = false,
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
            return
        end
    end
end

---@param field table
---@param fieldState table|nil
---@param pfSample table|nil
---@param scsSample table|nil
---@param rules table|nil
---@return table[] actions
---@param actions table[]
---@param ctx table
function FieldAdvisor.addHarvestReadyActions(actions, ctx)
    if ctx.isGrass then
        FieldAdvisor.addGrassWorkActions(actions, ctx.fieldState, ctx.field, ctx.aggregation, ctx.grassResidueSummary, ctx.baleSummary)
    else
        FieldAdvisor_addAction(actions, {
            actionType = "harvest",
            label = FieldAdvisor.text(
                "ftdl_action_harvest_now",
                "Jetzt ernten (%s)",
                FieldAdvisor.getHarvestPeriodDisplayLabel(FieldAdvisor.getCurrentSeasonPeriod())
            ),
            autoComplete = true,
        })
        -- Partial harvest: straw swaths or early baling while an NPC combine is still working.
        FieldAdvisor.addStrawLogisticsActions(actions, ctx)
    end
end

---@param actions table[]
---@param ctx table
function FieldAdvisor.addWitheredActions(actions, ctx)
    local rules = ctx.rules
    if rules.stonesEnabled and ctx.stoneLevel > 0 then
        FieldAdvisor_addAction(actions, {
            actionType = "stones",
            label = FieldAdvisor.text("ftdl_action_stones_pick", "Steine lesen"),
            autoComplete = true,
        })
    end

    if not ctx.isGrass then
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

    if FieldAdvisor.fieldNeedsLimeWork(ctx.soilState, rules) and not ctx.isGrass then
        FieldAdvisor_addAction(actions, {
            actionType = "lime",
            label = FieldAdvisor.text("ftdl_action_lime", "Kalken"),
            autoComplete = true,
        })
    end

    if not ctx.isGrass then
        FieldAdvisor_addAction(actions, {
            actionType = "sow",
            label = FieldAdvisor.text("ftdl_action_resow", "Neu ansäen"),
            autoComplete = true,
        })
    end
end

---@param actions table[]
---@param ctx table
function FieldAdvisor.addGrowingActions(actions, ctx)
    local rules = ctx.rules
    if ctx.isGrass then
        FieldAdvisor.addGrassWorkActions(actions, ctx.fieldState, ctx.field, ctx.aggregation, ctx.grassResidueSummary, ctx.baleSummary)
    end

    local trackArableWeed = FieldAdvisor.isArableWeedSamplingContext(ctx.aggregation, ctx.probeState, ctx.field, nil, nil)
    if trackArableWeed then
        if FieldAdvisor.fieldNeedsWeedHoe(ctx.fieldState, rules, ctx.weedSummary) then
            FieldAdvisor_addAction(actions, {
                actionType = "weed_hoe",
                label = FieldAdvisor.text("ftdl_action_weed_hoe_long", "Striegeln"),
                autoComplete = true,
            })
        end

        if FieldAdvisor.fieldShouldSuggestWeedSpray(ctx.fieldState, rules, ctx.weedSummary) then
            FieldAdvisor_addAction(actions, {
                actionType = "weed_combat",
                label = FieldAdvisor.text("ftdl_action_weed_combat_long", "Unkraut spritzen"),
                autoComplete = true,
            })
        end
    end

    if rules.stonesEnabled and ctx.stoneLevel > 0 then
        FieldAdvisor_addAction(actions, {
            actionType = "stones",
            label = FieldAdvisor.text("ftdl_action_stones_pick", "Steine lesen"),
            autoComplete = true,
        })
    end

    if not ctx.isGrass and (ctx.needsRolling or ctx.rollerLevel > 0) then
        FieldAdvisor_addAction(actions, {
            actionType = "roller",
            label = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
            pickerLabel = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
            autoComplete = true,
        })
    end

    if not ctx.isGrass and ctx.pfSample ~= nil and ctx.pfSample.pHValue ~= nil and ctx.pfSample.pHValue < 6.0 then
        FieldAdvisor_addAction(actions, {
            actionType = "pf_ph",
            label = FieldAdvisor.text("ftdl_action_raise_ph", "pH anheben (Kalk)"),
            autoComplete = true,
        })
    end

    local fertAdvice = FieldAdvisor.deriveFieldFertilizerAdvice(ctx.fieldState, ctx.pfSample, ctx.isGrass)
    if fertAdvice.needsFertilizer then
        FieldAdvisor_addAction(actions, {
            actionType = "pf_n",
            label = FieldAdvisor.text("ftdl_action_fert_n", "Düngen (N)"),
            autoComplete = true,
        })
    end

    if SeasonalCropStressReader.isRuntimeReady()
        and ctx.scsSample ~= nil
        and ctx.scsSample.moisture ~= nil
        and ctx.scsSample.moisture < 0.25 then
        FieldAdvisor_addAction(actions, {
            actionType = "scs_moisture",
            label = FieldAdvisor.text("ftdl_action_irrigate_dry", "Bewässern (trocken)"),
            autoComplete = true,
        })
    end

    if SeasonalCropStressReader.isRuntimeReady()
        and ctx.scsSample ~= nil
        and ctx.scsSample.stress ~= nil
        and ctx.scsSample.stress >= 0.6 then
        FieldAdvisor_addAction(actions, {
            actionType = "scs_stress_high",
            label = FieldAdvisor.text("ftdl_action_stress_high", "Pflanzenstress hoch"),
            autoComplete = true,
        })
    elseif SeasonalCropStressReader.isRuntimeReady()
        and ctx.scsSample ~= nil
        and ctx.scsSample.stress ~= nil
        and ctx.scsSample.stress >= 0.35 then
        FieldAdvisor_addAction(actions, {
            actionType = "scs_stress_watch",
            label = FieldAdvisor.text("ftdl_action_stress_watch", "Stress beobachten"),
            autoComplete = true,
        })
    end

    local hasGrassLogistics = false
    for _, action in ipairs(actions) do
        local actionType = action.actionType
        if actionType == "grass_mow"
            or actionType == "grass_swath"
            or actionType == "grass_collect"
            or actionType == "grass_bale"
            or actionType == "grass_silage_bale"
            or actionType == "grass_bale_collect" then
            hasGrassLogistics = true
            break
        end
    end

    if not hasGrassLogistics then
        local harvestState = FieldAdvisor.resolveHarvestFieldState(ctx.fieldState, ctx.aggregation)
        local harvestFruit = FieldAdvisor.resolveDisplayArableFruitIndex(ctx.field, ctx.aggregation, harvestState)
        local harvestWindow = FieldAdvisor.getHarvestWindowHint(harvestFruit, harvestState)
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
            label = FieldAdvisor.text("ftdl_action_growing", "Wächst"),
            pickerLabel = FieldAdvisor.text("ftdl_action_growing", "Wächst"),
            autoComplete = false,
        })
    end
end

---@param actions table[]
---@param ctx table
function FieldAdvisor.addEmptyOrPostHarvestActions(actions, ctx)
    local rules = ctx.rules
    local cropPhase = ctx.cropPhase

    if cropPhase == "post_harvest" and not ctx.isGrass then
        FieldAdvisor.addStrawLogisticsActions(actions, ctx)
    end

    -- Mulching is done on harvest stubble BEFORE any soil work, only for stubble-leaving crops
    -- and only if the player keeps it enabled. Straw press/collect is listed first when present.
    if cropPhase == "post_harvest" and not ctx.isGrass
            and FieldAdvisorSettings ~= nil and FieldAdvisorSettings.isMulchingEnabled() then
        local mulchFruit = FieldAdvisor.resolveDisplayArableFruitIndex(ctx.field, ctx.aggregation, ctx.probeState)
        if FieldAdvisor.isMulchableStubbleCrop(mulchFruit) then
            FieldAdvisor_addAction(actions, {
                actionType = "mulch",
                label = FieldAdvisor.text("ftdl_action_mulch_after_harvest", "Mulchen (vor Bodenarbeit)"),
                autoComplete = false,
            })
        end
    end

    if rules.stonesEnabled and ctx.stoneLevel > 0 then
        FieldAdvisor_addAction(actions, {
            actionType = "stones",
            label = FieldAdvisor.text("ftdl_action_stones_pick", "Steine lesen"),
            autoComplete = true,
        })
    end

    if ctx.postHarvestSoilWork and not ctx.isGrass then
        if FieldAdvisor.fieldNeedsPlowingWork(ctx.fieldState, rules) then
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

    if ctx.postHarvestSoilWork and FieldAdvisor.fieldNeedsLimeWork(ctx.soilState, rules) and not ctx.isGrass then
        FieldAdvisor_addAction(actions, {
            actionType = "lime",
            label = FieldAdvisor.text("ftdl_action_lime", "Kalken"),
            autoComplete = true,
        })
    end

    if cropPhase == "empty" and not ctx.isGrass and ctx.pfSample ~= nil and ctx.pfSample.pHValue ~= nil and ctx.pfSample.pHValue < 6.0 then
        FieldAdvisor_addAction(actions, {
            actionType = "pf_ph",
            label = FieldAdvisor.text("ftdl_action_raise_ph", "pH anheben (Kalk)"),
            autoComplete = true,
        })
    end

    local fieldId = ctx.field ~= nil and ctx.field.getId ~= nil and ctx.field:getId() or nil

    if cropPhase == "empty" then
        local sowLabel, plannedIndex = FieldAdvisor.formatSowActionLabel(fieldId, false)
        FieldAdvisor_addAction(actions, {
            actionType = "sow",
            label = sowLabel,
            autoComplete = false,
            plannedSowFruitIndex = plannedIndex,
        })
    elseif cropPhase == "post_harvest" and not ctx.isGrass then
        local sowLabel, plannedIndex = FieldAdvisor.formatSowActionLabel(fieldId, true)
        FieldAdvisor_addAction(actions, {
            actionType = "sow",
            label = sowLabel,
            autoComplete = true,
            plannedSowFruitIndex = plannedIndex,
        })
    end

    if ctx.postHarvestSoilWork and (ctx.needsRolling or ctx.rollerLevel > 0) then
        FieldAdvisor_addAction(actions, {
            actionType = "roller",
            label = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
            pickerLabel = FieldAdvisor.text("ftdl_action_roller", "Walzen"),
            autoComplete = true,
        })
    end

    local fertAdvice = FieldAdvisor.deriveFieldFertilizerAdvice(ctx.fieldState, ctx.pfSample, ctx.isGrass)
    if fertAdvice.needsFertilizer then
        FieldAdvisor_addAction(actions, {
            actionType = "pf_n",
            label = FieldAdvisor.text("ftdl_action_fert_n", "Düngen (N)"),
            autoComplete = true,
        })
    end
end

-- One builder per crop phase. resolveActionCandidates derives the final phase once, then
-- dispatches here; no second place decides what a phase needs.
FieldAdvisor.PHASE_ACTION_BUILDERS = {
    harvest_ready = FieldAdvisor.addHarvestReadyActions,
    withered = FieldAdvisor.addWitheredActions,
    growing = FieldAdvisor.addGrowingActions,
    empty = FieldAdvisor.addEmptyOrPostHarvestActions,
    post_harvest = FieldAdvisor.addEmptyOrPostHarvestActions,
}

---@return table[] actions
function FieldAdvisor.resolveActionCandidates(field, fieldState, pfSample, scsSample, rules, aggregation, weedSummary, grassResidueSummary, baleSummary, strawResidueSummary)
    rules = rules or FieldGameRules.get()
    local actions = {}

    local probeState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)
    local soilState = aggregation ~= nil and aggregation.representativeState or fieldState
    local isGrass = FieldAdvisor.isGrassPhaseContext(probeState, field, aggregation)

    local residueState = grassResidueSummary ~= nil and grassResidueSummary.residueState
        or FieldAdvisor.GRASS_RESIDUE_NONE
    local hasGrassResidue = residueState ~= FieldAdvisor.GRASS_RESIDUE_NONE
    if not isGrass and not FieldAdvisor.isArableFieldContext(aggregation, probeState, field) then
        if hasGrassResidue or FieldAdvisor.inferGrassFruitTypeIndexFromField(field) ~= nil then
            isGrass = true
        end
    end

    -- Final phase reconciliation (single place): bales on a grass field => post-mow logistics
    -- (growing); an arable field misread as growing but actually harvested stubble => post_harvest.
    local cropPhase = FieldAdvisor.getCropPhase(field, probeState, aggregation)
    local meadowPhase = FieldAdvisor.getGrassMeadowPhase(probeState, field, aggregation)
    local standingGrassCrop = FieldAdvisor.isGrassStandingCropPhase(
        meadowPhase, probeState, field, FieldAdvisor.getFruitTypeIndex(probeState)
    )
    if hasGrassResidue and isGrass and cropPhase ~= "harvest_ready" and not standingGrassCrop then
        cropPhase = "growing"
    end
    if not isGrass and cropPhase == "growing" then
        local displayArableFruit = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, probeState)
        if FieldAdvisor.isArableHarvestedStubble(field, probeState, displayArableFruit) then
            cropPhase = "post_harvest"
        end
    end
    if not isGrass and cropPhase == "empty" then
        local strawBales = FieldAdvisor.getFieldBaleCountByKind(baleSummary, "straw")
        local hasStrawWindrow = strawResidueSummary ~= nil and strawResidueSummary.hasWindrow == true
        local displayArableFruit = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, probeState)
        if strawBales > 0 or hasStrawWindrow
            or FieldAdvisor.isArableHarvestedStubble(field, probeState, displayArableFruit) then
            cropPhase = "post_harvest"
        end
    end

    local ctx = {
        field = field,
        fieldState = fieldState,
        aggregation = aggregation,
        rules = rules,
        probeState = probeState,
        soilState = soilState,
        isGrass = isGrass,
        cropPhase = cropPhase,
        postHarvestSoilWork = FieldAdvisor.isPostHarvestSoilWorkPhase(field, probeState),
        stoneLevel = FieldAdvisor.getStateNumber(fieldState, "stoneLevel"),
        needsRolling = FieldAdvisor.getStateBool(fieldState, "needsRolling"),
        rollerLevel = FieldAdvisor.getStateNumber(fieldState, "rollerLevel"),
        pfSample = pfSample,
        scsSample = scsSample,
        weedSummary = weedSummary,
        grassResidueSummary = grassResidueSummary,
        strawResidueSummary = strawResidueSummary,
        baleSummary = baleSummary,
        fieldId = field ~= nil and field.getId ~= nil and field:getId() or nil,
        worldX = nil,
        worldZ = nil,
    }
    if field ~= nil then
        ctx.worldX, ctx.worldZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    end

    local builder = FieldAdvisor.PHASE_ACTION_BUILDERS[cropPhase]
    if builder ~= nil then
        builder(actions, ctx)
    end

    if #actions == 0 then
        actions[1] = {
            actionType = "none",
            label = FieldAdvisor.text("ftdl_action_all_ok", "Alles ok"),
            autoComplete = false,
        }
    end

    return FieldAdvisor.finishActionCandidates(
        actions,
        pfSample,
        FieldAdvisor.getStateNumber(fieldState, "sprayLevel")
    )
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
        mulch = { "ftdl_action_mulch", "Mulchen" },
        weed_hoe = { "ftdl_action_weed_hoe", "Striegeln" },
        weed_combat = { "ftdl_action_weed_combat", "Spritzen" },
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
        straw_bale = { "ftdl_action_straw_bale", "Stroh pressen" },
        straw_bale_collect = { "ftdl_action_straw_bale_collect", "Stroh holen" },
        harvest_info = { "ftdl_action_harvest_info", "Ernte" },
        growing = { "ftdl_action_growing", "Wächst" },
        none = { "ftdl_action_none", "Ok" },
    }

    if action.actionType == "pf_n" and action.fertPass ~= nil and action.fertPassTotal ~= nil then
        return FieldAdvisor.getOrganicFertilizerPassLabel(action.fertPass, action.fertPassTotal)
    end

    if action.actionType == "sow" and action.plannedSowFruitIndex ~= nil then
        local shortLabel = FieldAdvisor.formatPlannedSowLabel(action.plannedSowFruitIndex, false, true)
        if shortLabel ~= nil then
            return shortLabel
        end
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
---@return string|nil
function FieldAdvisor.getHarvestInfoSuggestionLabel(actions)
    if actions == nil then
        return nil
    end

    for _, action in ipairs(actions) do
        if action.actionType == "harvest_info" then
            local label = action.label
            if label ~= nil and label ~= "" and label ~= "-" then
                return label
            end
        end
    end

    return nil
end

---@param baseLabel string|nil
---@param actions table[]|nil
---@param expectedHarvest string|nil month hint from getExpectedHarvestLabel when no harvest_info action
---@return string|nil
function FieldAdvisor.prefixHarvestInfoSuggestion(baseLabel, actions, expectedHarvest)
    local harvestInfo = FieldAdvisor.getHarvestInfoSuggestionLabel(actions)
    if harvestInfo == nil then
        local growingLabel = FieldAdvisor.text("ftdl_action_growing", "Wächst")
        if expectedHarvest ~= nil and expectedHarvest ~= "" and expectedHarvest ~= "-"
            and expectedHarvest ~= growingLabel then
            harvestInfo = FieldAdvisor.formatHarvestWindowLabel(expectedHarvest)
            if harvestInfo == "-" then
                harvestInfo = nil
            end
        end
    end
    if harvestInfo == nil then
        return baseLabel
    end

    if baseLabel == nil or baseLabel == "" then
        return harvestInfo
    end

    if baseLabel == harvestInfo or string.find(baseLabel, harvestInfo, 1, true) ~= nil then
        return baseLabel
    end

    return harvestInfo .. " → " .. baseLabel
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
            or action.actionType == "grass_bale_collect"
            or action.actionType == "straw_bale"
            or action.actionType == "straw_bale_collect" then
            logisticsActions[#logisticsActions + 1] = action
        end
    end

    local workOrderPreview = FieldAdvisor.formatWorkOrderSuggestionPreview(
        #logisticsActions > 0 and logisticsActions or actions,
        4
    )
    if workOrderPreview ~= nil and #logisticsActions > 0 then
        return FieldAdvisor.prefixHarvestInfoSuggestion(workOrderPreview, actions, expectedHarvest)
            or workOrderPreview
    end

    workOrderPreview = FieldAdvisor.formatWorkOrderSuggestionPreview(actions, 4)
    if workOrderPreview ~= nil then
        return FieldAdvisor.prefixHarvestInfoSuggestion(workOrderPreview, actions, expectedHarvest)
            or workOrderPreview
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
        local harvestInfo = FieldAdvisor.getHarvestInfoSuggestionLabel(actions)
        if harvestInfo ~= nil then
            return harvestInfo
        end

        local growingLabel = FieldAdvisor.text("ftdl_action_growing", "Wächst")
        if expectedHarvest ~= nil and expectedHarvest ~= "" and expectedHarvest ~= "-"
            and expectedHarvest ~= growingLabel then
            return FieldAdvisor.formatHarvestWindowLabel(expectedHarvest)
        end

        return growingLabel
    end

    local primary = displayLabels[1]
    if #displayLabels > 1 then
        return FieldAdvisor.prefixHarvestInfoSuggestion(
            FieldAdvisor.text("ftdl_action_preview_more", "%s (+%d)", primary, #displayLabels - 1),
            actions,
            expectedHarvest
        ) or FieldAdvisor.text("ftdl_action_preview_more", "%s (+%d)", primary, #displayLabels - 1)
    end

    return FieldAdvisor.prefixHarvestInfoSuggestion(primary, actions, expectedHarvest) or primary
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

--- Strict polygon only (false/nil => outside). Bale owner check uses this on the owner field object.
---@param field table|nil
---@param x number
---@param z number
---@return boolean
function FieldAdvisor.isPositionInsideField(field, x, z)
    return FieldAdvisor.testPositionInsideField(field, x, z) == true
end

--- Single gate for field-local probes/residue/completion samples (not bales).
--- Polygon true => inside; polygon false => outside; polygon nil => engine field id at (x,z) must match.
---@param field table|nil
---@param x number|nil
---@param z number|nil
---@return boolean
function FieldAdvisor.isSamplePositionOnField(field, x, z)
    if field == nil or x == nil or z == nil then
        return false
    end

    local targetFieldId = field.getId ~= nil and tonumber(field:getId()) or nil
    if targetFieldId == nil then
        return false
    end

    local inside = FieldAdvisor.testPositionInsideField(field, x, z)
    if inside == true then
        return true
    end
    if inside == false then
        return false
    end

    local sampleFieldId = FieldAdvisor.resolveEngineFieldIdAtWorldPosition(x, z)
    return sampleFieldId ~= nil and sampleFieldId == targetFieldId
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
        baleGrassCount = context.baleSummary ~= nil and (context.baleSummary.grass or 0) or 0,
        baleStrawCount = context.baleSummary ~= nil and (context.baleSummary.straw or 0) or 0,
        phValue = context.pfSample ~= nil and context.pfSample.pHValue or nil,
        nitrogenValue = context.pfSample ~= nil and context.pfSample.nitrogenValue or nil,
        sprayLevel = FieldAdvisor.getStateNumber(fieldState, "sprayLevel"),
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

    if actionType == "weed_hoe" or actionType == "weed_combat" or actionType == "weed_watch" then
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

    if actionType == "pf_n" then
        if context.pfSample ~= nil and context.pfSample.nitrogenValue ~= nil and baseline.nitrogenValue ~= nil then
            return tonumber(context.pfSample.nitrogenValue) > tonumber(baseline.nitrogenValue)
        end
        local sprayNow = FieldAdvisor.getStateNumber(context.fieldState, "sprayLevel")
        local sprayBase = baseline.sprayLevel
        if sprayBase ~= nil and sprayNow > tonumber(sprayBase) then
            return true
        end
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
        context.baleSummary,
        context.strawResidueSummary
    )
    local action = FieldAdvisor.selectPrimaryAction(actions)
    local fruitTypeIndex = FieldAdvisor.resolveDisplayArableFruitIndex(field, aggregation, fieldState)
    local partialSoilWork = FieldAdvisor.fieldHasPartialSoilWork(field, fieldId, fieldState, worldX, worldZ)
    local expectedHarvest = FieldAdvisor.getExpectedHarvestLabel(field, fieldState, aggregation, grassResidueSummary)
    local harvestState = FieldAdvisor.resolveHarvestFieldState(fieldState, aggregation)

    local trackArableWeed = FieldAdvisor.isArableWeedSamplingContext(aggregation, fieldState, field, worldX, worldZ)
    local weedLabel = FieldAdvisor.text("ftdl_val_none", "kein")
    if trackArableWeed then
        weedLabel = FieldAdvisor.isWeedTaskDoneByCoverage(weedSummary)
            and FieldAdvisor.text("ftdl_weed_dead", "tot")
            or FieldAdvisor.formatWeedDisplayLabel(effectiveFieldState, rules, weedSummary)
    end

    return {
        weed = weedLabel,
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
