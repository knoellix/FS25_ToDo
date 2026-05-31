--[[
    FieldScanner.lua
    Data acquisition layer: reads owned field fruit types, growth stages, and conditions.
]]

---@class FieldScanner
---@field mission table
---@field modDirectory string
FieldScanner = {}
local FieldScanner_mt = Class(FieldScanner)

---@param mission table
---@param modDirectory string
---@return FieldScanner
function FieldScanner.new(mission, modDirectory)
    local self = setmetatable({}, FieldScanner_mt)

    self.mission = mission
    self.modDirectory = modDirectory

    return self
end

function FieldScanner:delete()
    self.mission = nil
end

---@param field table
---@return string
function FieldScanner:getFruitName(field)
    local fieldState = FieldAdvisor.getFieldState(field)
    if fieldState == nil and field ~= nil then
        fieldState = field.fieldState
    end

    local fruitTypeIndex = FieldAdvisor.getFruitTypeIndex(fieldState)
    if fruitTypeIndex == nil or fruitTypeIndex <= 0 then
        return "-"
    end

    return FieldAdvisor.getLocalizedFruitTitle(fruitTypeIndex)
end

---@param field table
---@return string
function FieldScanner:getGrowthLabel(field)
    local posX, posZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    if posX == nil or posZ == nil then
        return "-"
    end

    local fieldId = field.getId ~= nil and field:getId() or 0
    local fieldState = FieldAdvisor.getEnrichedFieldState(field, fieldId, posX, posZ)
    if fieldState ~= nil then
        return FieldAdvisor.formatGrowthLabel(fieldState)
    end

    return "-"
end

---@param field table
---@return number|nil
function FieldScanner:getPlayerFarmId()
    if self.mission == nil or self.mission.getFarmId == nil then
        return nil
    end

    return self.mission:getFarmId()
end

---@param farmland table|number|nil
---@param farmId number|nil
---@return boolean
function FieldScanner:farmlandBelongsToFarm(farmland, farmId)
    if farmland == nil or farmId == nil then
        return false
    end

    local farmlandId = type(farmland) == "table" and farmland.id or farmland
    if farmlandId == nil then
        return false
    end

    if type(farmland) == "table" then
        if farmland.farmId == farmId or farmland.ownerFarmId == farmId then
            return true
        end
    end

    if g_farmlandManager ~= nil and g_farmlandManager.farmlands ~= nil then
        local entry = g_farmlandManager.farmlands[farmlandId]
        if entry ~= nil and (entry.farmId == farmId or entry.ownerFarmId == farmId) then
            return true
        end
    end

    return false
end

---@param field table
---@return boolean
function FieldScanner:isPlayerOwnedField(field)
    if field == nil then
        return false
    end

    local farmId = self:getPlayerFarmId()
    local posX, posZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    if posX == nil or posZ == nil then
        return false
    end

    if posX ~= nil and posZ ~= nil and field.fieldState ~= nil and field.fieldState.update ~= nil then
        pcall(field.fieldState.update, field.fieldState, posX, posZ)
    end

    if farmId ~= nil and field.fieldState ~= nil and field.fieldState.ownerFarmId == farmId then
        return true
    end

    if farmId ~= nil and field.farmland ~= nil and self:farmlandBelongsToFarm(field.farmland, farmId) then
        return true
    end

    if farmId ~= nil and posX ~= nil and posZ ~= nil and g_farmlandManager ~= nil then
        if g_farmlandManager.getFarmlandAtWorldPosition ~= nil then
            local ok, farmland = pcall(g_farmlandManager.getFarmlandAtWorldPosition, g_farmlandManager, posX, posZ)
            if ok and self:farmlandBelongsToFarm(farmland, farmId) then
                return true
            end
        end

        if g_farmlandManager.getFarmlandIdAtWorldPosition ~= nil then
            local ok, farmlandId = pcall(g_farmlandManager.getFarmlandIdAtWorldPosition, g_farmlandManager, posX, posZ)
            if ok and self:farmlandBelongsToFarm(farmlandId, farmId) then
                return true
            end
        end
    end

    return false
end

---@param field table
---@param forceInclude boolean|nil
---@return table|nil candidate
function FieldScanner:buildOwnedFieldCandidate(field, forceInclude)
    if field == nil then
        return nil
    end

    if forceInclude ~= true and not self:isPlayerOwnedField(field) then
        return nil
    end

    local fieldId = field.getId ~= nil and field:getId() or nil
    if fieldId == nil then
        return nil
    end

    return {
        field = field,
        forceInclude = forceInclude == true,
        id = fieldId,
    }
end

--- Cheap ownership list for incremental overview scans.
---@return table[] candidates
function FieldScanner:collectOwnedFieldCandidates()
    local candidates = {}
    local seenIds = {}

    if g_fieldManager == nil then
        return candidates
    end

    local allFields = g_fieldManager.fields
    if allFields == nil and g_fieldManager.getFields ~= nil then
        local ok, value = pcall(g_fieldManager.getFields, g_fieldManager)
        if ok then
            allFields = value
        end
    end

    if allFields ~= nil then
        for _, field in pairs(allFields) do
            local candidate = self:buildOwnedFieldCandidate(field, false)
            if candidate ~= nil and not seenIds[candidate.id] then
                candidates[#candidates + 1] = candidate
                seenIds[candidate.id] = true
            end
        end
    end

    if g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil then
        local manager = g_currentMission.fieldToDoList
        if manager.manualTasks ~= nil and manager.fieldScanner == self then
            for _, task in pairs(manager.manualTasks) do
                local fieldId = tonumber(task.fieldId)
                if fieldId ~= nil and not seenIds[fieldId] and not task.completed then
                    local engineField = self:getEngineFieldById(fieldId)
                    local candidate = self:buildOwnedFieldCandidate(engineField, true)
                    if candidate ~= nil then
                        candidates[#candidates + 1] = candidate
                        seenIds[candidate.id] = true
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.id < b.id
    end)

    return candidates
end

---@param candidate table
---@return table|nil
function FieldScanner:buildPlaceholderFieldRecord(candidate)
    if candidate == nil or candidate.field == nil then
        return nil
    end

    local field = candidate.field
    local fieldId = candidate.id
    local posX, posZ = FieldAdvisor.getFieldCenterWorldPosition(field)

    local fieldName = field.name
    if string.isNilOrWhitespace(fieldName) then
        fieldName = string.format("Feld %d", fieldId)
    end

    return {
        id = fieldId,
        name = fieldName,
        worldX = posX,
        worldZ = posZ,
        fruit = "...",
        growthState = "...",
        expectedHarvest = "...",
        weed = "...",
        stones = "...",
        lime = "...",
        roller = "...",
        suggestion = "...",
        pendingScan = true,
        showPrecisionFarming = PrecisionFarmingReader ~= nil and PrecisionFarmingReader.isRuntimeReady(),
        showCropStress = SeasonalCropStressReader ~= nil and SeasonalCropStressReader.isRuntimeReady(),
    }
end

---@param records table[]
---@return table[]
function FieldScanner:sortFieldRecords(records)
    table.sort(records, function(a, b)
        if a.id == b.id then
            return (a.name or "") < (b.name or "")
        end
        return a.id < b.id
    end)

    return records
end

---@param field table
---@param forceInclude boolean|nil include even when ownership probe fails (open To-Do on this field)
---@return table|nil fieldRecord
function FieldScanner:normalizeField(field, forceInclude)
    if field == nil then
        return nil
    end

    if forceInclude ~= true and not self:isPlayerOwnedField(field) then
        return nil
    end

    local posX, posZ = FieldAdvisor.getFieldCenterWorldPosition(field)
    if posX == nil or posZ == nil then
        return nil
    end

    if field.fieldState ~= nil and field.fieldState.update ~= nil then
        pcall(field.fieldState.update, field.fieldState, posX, posZ)
    end

    local fieldId = field.getId ~= nil and field:getId() or 0
    local fieldState = FieldAdvisor.getEnrichedFieldState(field, fieldId, posX, posZ)
    local labels = FieldAdvisor.buildFieldLabels(field, fieldState, posX, posZ)

    local fieldName = field.name
    if string.isNilOrWhitespace(fieldName) then
        fieldName = string.format("Feld %d", fieldId)
    end

    local scsFieldId = nil
    if SeasonalCropStressReader ~= nil then
        scsFieldId = SeasonalCropStressReader.resolveScsFieldId(field, nil)
    end

    return {
        id = fieldId,
        farmlandId = scsFieldId,
        scsFieldId = scsFieldId,
        name = fieldName,
        worldX = posX,
        worldZ = posZ,
        fruit = labels.fruit or "-",
        growthState = labels.growthState or "-",
        expectedHarvest = labels.expectedHarvest or "-",
        cropPhase = labels.cropPhase,
        areaHa = field.areaHa or 0,
        weed = labels.weed,
        stones = labels.stones,
        lime = labels.lime,
        roller = labels.roller,
        ph = labels.ph,
        nitrogen = labels.nitrogen,
        moisture = labels.moisture,
        stress = labels.stress,
        suggestion = labels.suggestion,
        suggestionDetails = labels.suggestionDetails,
        actionType = labels.actionType,
        autoComplete = labels.autoComplete,
        isGrass = labels.isGrass == true,
        showPrecisionFarming = labels.showPrecisionFarming,
        showCropStress = labels.showCropStress,
    }
end

---@param fieldId number
---@return table|nil
function FieldScanner:getEngineFieldById(fieldId)
    if fieldId == nil or g_fieldManager == nil then
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
        local currentId = field.getId ~= nil and field:getId() or nil
        if currentId == fieldId then
            return field
        end
    end

    return nil
end

---Collects owned fields for the overview panel (sync; prefer incremental ToDoManager scan).
---@return table[] fields
function FieldScanner:scanOwnedFields()
    local fields = {}
    local candidates = self:collectOwnedFieldCandidates()

    for _, candidate in ipairs(candidates) do
        local ok, record = pcall(function()
            return self:normalizeField(candidate.field, candidate.forceInclude)
        end)
        if ok and record ~= nil then
            fields[#fields + 1] = record
        end
    end

    return self:sortFieldRecords(fields)
end

---@param fieldId number
---@return table|nil field
function FieldScanner:getFieldById(fieldId)
    if fieldId == nil then
        return nil
    end

    local engineField = self:getEngineFieldById(fieldId)
    if engineField == nil then
        return nil
    end

    local ok, record = pcall(function()
        return self:normalizeField(engineField)
    end)
    if ok then
        return record
    end

    return nil
end
