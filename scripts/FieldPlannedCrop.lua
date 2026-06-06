--[[
    FieldPlannedCrop.lua
    Per-field planned sow crop (manual, persisted per savegame until changed).
]]

FieldPlannedCrop = {}

--- Sentinel: Grundstück/Hof — kein Schwergewichts-Scan (Halle, Tierhaltung, Hoffläche).
FieldPlannedCrop.FARMYARD_VALUE = -1

--- fieldId (number) -> fruitTypeIndex (number) or FARMYARD_VALUE
FieldPlannedCrop.byFieldId = {}

---@param fieldId number|nil
---@return number|nil raw stored value (-1 farmyard, >0 fruit)
function FieldPlannedCrop.getRaw(fieldId)
    fieldId = tonumber(fieldId)
    if fieldId == nil then
        return nil
    end

    local index = FieldPlannedCrop.byFieldId[fieldId]
    index = tonumber(index)
    if index == nil then
        return nil
    end

    return index
end

---@param fieldId number|nil
---@return number|nil planned sow fruit index only (>0)
function FieldPlannedCrop.get(fieldId)
    local index = FieldPlannedCrop.getRaw(fieldId)
    if index == nil or index <= 0 then
        return nil
    end

    return index
end

---@param fieldId number|nil
---@return boolean
function FieldPlannedCrop.isFarmyard(fieldId)
    return FieldPlannedCrop.getRaw(fieldId) == FieldPlannedCrop.FARMYARD_VALUE
end

---@param fieldId number|nil
---@return string
function FieldPlannedCrop.getDisplayLabel(fieldId)
    if FieldPlannedCrop.isFarmyard(fieldId) then
        return FieldToDoL10n.getText("ftdl_planned_crop_farmyard", "Hof")
    end

    local index = FieldPlannedCrop.get(fieldId)
    if index == nil or FieldAdvisor == nil then
        return "-"
    end

    local label = FieldAdvisor.getLocalizedFruitTitle(index)
    if label == nil or label == "" then
        return "-"
    end

    return label
end

---@param fieldId number|nil
---@param fieldName string|nil
---@param posX number|nil
---@param posZ number|nil
---@param areaHa number|nil
---@return table
function FieldPlannedCrop.buildFarmyardFieldRecord(fieldId, fieldName, posX, posZ, areaHa)
    return {
        id = fieldId,
        name = fieldName,
        worldX = posX,
        worldZ = posZ,
        areaHa = areaHa or 0,
        fruit = "-",
        plannedSow = FieldPlannedCrop.getDisplayLabel(fieldId),
        growthState = "-",
        expectedHarvest = "-",
        weed = "-",
        stones = "-",
        lime = "-",
        roller = "-",
        ph = "-",
        nitrogen = "-",
        moisture = "-",
        stress = "-",
        suggestion = FieldToDoL10n.getText("ftdl_farmyard_suggestion", "Hof"),
        suggestionDetails = {},
        actionType = "none",
        autoComplete = false,
        isFarmyard = true,
        showPrecisionFarming = false,
        showCropStress = false,
    }
end

---@param fieldId number|nil
---@param fruitTypeIndex number|nil nil clears; FARMYARD_VALUE = Hof; >0 = planned fruit
function FieldPlannedCrop.set(fieldId, fruitTypeIndex)
    fieldId = tonumber(fieldId)
    if fieldId == nil then
        return
    end

    if fruitTypeIndex == nil then
        FieldPlannedCrop.byFieldId[fieldId] = nil
        return
    end

    fruitTypeIndex = tonumber(fruitTypeIndex)
    if fruitTypeIndex == FieldPlannedCrop.FARMYARD_VALUE then
        FieldPlannedCrop.byFieldId[fieldId] = FieldPlannedCrop.FARMYARD_VALUE
        return
    end

    if fruitTypeIndex <= 0 then
        FieldPlannedCrop.byFieldId[fieldId] = nil
        return
    end

    FieldPlannedCrop.byFieldId[fieldId] = fruitTypeIndex
end

---@return table[] entries { fruitTypeIndex = number|nil, label = string }
---@return string[] optionTexts
function FieldPlannedCrop.buildPickerOptions()
    local entries = {
        { fruitTypeIndex = nil, label = FieldToDoL10n.getText("ftdl_planned_crop_none", "— keine —") },
        {
            fruitTypeIndex = FieldPlannedCrop.FARMYARD_VALUE,
            label = FieldToDoL10n.getText("ftdl_planned_crop_farmyard", "Hof"),
        },
    }

    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypes ~= nil then
        local ok, fruitTypes = pcall(g_fruitTypeManager.getFruitTypes, g_fruitTypeManager)
        if ok and fruitTypes ~= nil and FieldAdvisor ~= nil then
            for _, desc in pairs(fruitTypes) do
                if desc ~= nil and desc.index ~= nil then
                    local index = tonumber(desc.index)
                    if index ~= nil and index > 0
                        and (FruitType == nil or index ~= FruitType.UNKNOWN)
                        and not FieldAdvisor.isUnknownFruitIndex(index) then
                        local label = FieldAdvisor.getLocalizedFruitTitle(index)
                        if label ~= nil and label ~= "" and label ~= "-" then
                            entries[#entries + 1] = {
                                fruitTypeIndex = index,
                                label = label,
                            }
                        end
                    end
                end
            end
        end
    end

    if #entries > 2 then
        local fixedCount = 2
        local fruits = {}
        for index = fixedCount + 1, #entries do
            fruits[#fruits + 1] = entries[index]
        end
        table.sort(fruits, function(a, b)
            return (a.label or "") < (b.label or "")
        end)
        for index = 1, #fruits do
            entries[fixedCount + index] = fruits[index]
        end
    end

    local texts = {}
    for _, entry in ipairs(entries) do
        texts[#texts + 1] = entry.label
    end

    return entries, texts
end

---@param schema XMLSchema
---@param basePath string
function FieldPlannedCrop.registerXMLPaths(schema, basePath)
    schema:register(XMLValueType.INT, basePath .. ".plannedCrops.plannedCrop(?)#fieldId", "Field id")
    schema:register(XMLValueType.INT, basePath .. ".plannedCrops.plannedCrop(?)#fruitTypeIndex", "Planned sow fruit type index")
end

---@param xmlFile XMLFile|nil
---@param key string|nil
function FieldPlannedCrop.loadFromXMLFile(xmlFile, key)
    FieldPlannedCrop.byFieldId = {}
    if xmlFile == nil or key == nil then
        return
    end

    local index = 0
    while true do
        local entryKey = string.format("%s.plannedCrops.plannedCrop(%d)", key, index)
        local fieldId = xmlFile:getValue(entryKey .. "#fieldId")
        if fieldId == nil then
            break
        end

        local fruitTypeIndex = xmlFile:getValue(entryKey .. "#fruitTypeIndex")
        FieldPlannedCrop.set(fieldId, fruitTypeIndex)
        index = index + 1
    end
end

---@param xmlFile XMLFile|nil
---@param key string|nil
function FieldPlannedCrop.saveToXMLFile(xmlFile, key)
    if xmlFile == nil or key == nil then
        return
    end

    local sortedIds = {}
    for fieldId in pairs(FieldPlannedCrop.byFieldId) do
        sortedIds[#sortedIds + 1] = fieldId
    end
    table.sort(sortedIds)

    for index, fieldId in ipairs(sortedIds) do
        local entryKey = string.format("%s.plannedCrops.plannedCrop(%d)", key, index - 1)
        xmlFile:setValue(entryKey .. "#fieldId", fieldId)
        xmlFile:setValue(entryKey .. "#fruitTypeIndex", FieldPlannedCrop.byFieldId[fieldId])
    end
end
