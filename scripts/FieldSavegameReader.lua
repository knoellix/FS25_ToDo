--[[
    FieldSavegameReader.lua
    Reads per-field attributes from savegame fields.xml (same data the game UI uses).
]]

FieldSavegameReader = {}

--- Disabled by default: io.open on savegame fields.xml can truncate the file while the game
--- still owns it. Use live FieldState only.
FieldSavegameReader.ENABLE_DISK_READ = false

FieldSavegameReader.cache = nil
FieldSavegameReader.cachePath = nil
FieldSavegameReader.cacheMtime = nil
--- While true, never open fields.xml (game may lock it during load/save).
FieldSavegameReader.deferDiskReads = false

---@return boolean
function FieldSavegameReader.isSaveInProgress()
    if g_currentMission ~= nil then
        if g_currentMission.isSaving == true or g_currentMission.isSavePending == true then
            return true
        end
    end

    if g_savegameController ~= nil then
        if g_savegameController.isSaving == true or g_savegameController.savePending == true then
            return true
        end
    end

    return false
end

---@return boolean
function FieldSavegameReader.mayReadFieldsFile()
    if FieldSavegameReader.deferDiskReads then
        return false
    end

    return not FieldSavegameReader.isSaveInProgress()
end

--- Call on mission start so we do not io.open fields.xml while the game still owns it.
function FieldSavegameReader.deferReadsUntilGameplay()
    FieldSavegameReader.deferDiskReads = true
end

---@return string|nil
function FieldSavegameReader.getSavegameDirectory()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return nil
    end

    return g_currentMission.missionInfo.savegameDirectory
end

function FieldSavegameReader.invalidate()
    FieldSavegameReader.cache = nil
    FieldSavegameReader.cachePath = nil
    FieldSavegameReader.cacheMtime = nil
end

---@param fieldBlock string
---@return table|nil
local function FieldSavegameReader_parseFieldBlock(fieldBlock)
    local fieldId = tonumber(fieldBlock:match('id="(%d+)"'))
    if fieldId == nil then
        return nil
    end

    local function readAttr(name)
        local value = fieldBlock:match(name .. '="([^"]*)"')
        if value == nil then
            return nil
        end
        return value
    end

    return {
        id = fieldId,
        plannedFruit = readAttr("plannedFruit"),
        fruitType = readAttr("fruitType"),
        growthState = tonumber(readAttr("growthState")) or 0,
        lastGrowthState = tonumber(readAttr("lastGrowthState")) or 0,
        weedState = tonumber(readAttr("weedState")) or 0,
        stoneLevel = tonumber(readAttr("stoneLevel")) or 0,
        groundType = readAttr("groundType"),
        sprayType = readAttr("sprayType"),
        sprayLevel = tonumber(readAttr("sprayLevel")) or 0,
        limeLevel = tonumber(readAttr("limeLevel")) or 0,
        rollerLevel = tonumber(readAttr("rollerLevel")) or 0,
        plowLevel = tonumber(readAttr("plowLevel")) or 0,
        stubbleShredLevel = tonumber(readAttr("stubbleShredLevel")) or 0,
        waterLevel = tonumber(readAttr("waterLevel")) or 0,
    }
end

---@param filePath string
---@return boolean
local function FieldSavegameReader_isReadableFieldsFile(filePath)
    if string.isNilOrWhitespace(filePath) or not fileExists(filePath) then
        return false
    end

    if getFileSize ~= nil then
        local size = getFileSize(filePath)
        if size == nil or size < 64 then
            return false
        end
    end

    return true
end

local function FieldSavegameReader_parseFile(filePath)
    if not FieldSavegameReader_isReadableFieldsFile(filePath) then
        return nil
    end

    local file = io.open(filePath, "r")
    if file == nil then
        return nil
    end

    local content = file:read("*a")
    file:close()

    if string.isNilOrWhitespace(content) or not string.find(content, "<field", 1, true) then
        return nil
    end

    local fields = {}
    for fieldBlock in content:gmatch("<field%s+[^>]*/>") do
        local record = FieldSavegameReader_parseFieldBlock(fieldBlock)
        if record ~= nil then
            fields[record.id] = record
        end
    end

    return fields
end

---@return table|nil fieldsById
function FieldSavegameReader.loadFields()
    if FieldSavegameReader.ENABLE_DISK_READ ~= true then
        return nil
    end

    local savegameDirectory = FieldSavegameReader.getSavegameDirectory()
    if string.isNilOrWhitespace(savegameDirectory) then
        return nil
    end

    local filePath = savegameDirectory .. "/fields.xml"
    if not FieldSavegameReader_isReadableFieldsFile(filePath) then
        return nil
    end

    local mtime = nil
    if getFileModificationTime ~= nil then
        mtime = getFileModificationTime(filePath)
    end

    if FieldSavegameReader.cache ~= nil
        and FieldSavegameReader.cachePath == filePath
        and (mtime == nil or FieldSavegameReader.cacheMtime == mtime) then
        return FieldSavegameReader.cache
    end

    if not FieldSavegameReader.mayReadFieldsFile() then
        return FieldSavegameReader.cache
    end

    local fields = FieldSavegameReader_parseFile(filePath)
    if fields == nil then
        return nil
    end

    FieldSavegameReader.cache = fields
    FieldSavegameReader.cachePath = filePath
    FieldSavegameReader.cacheMtime = mtime

    return fields
end

---@param fieldId number|nil
---@return table|nil
function FieldSavegameReader.getFieldAttributes(fieldId)
    if fieldId == nil then
        return nil
    end

    local fields = FieldSavegameReader.loadFields()
    if fields == nil then
        return nil
    end

    return fields[math.floor(tonumber(fieldId) or -1)]
end
