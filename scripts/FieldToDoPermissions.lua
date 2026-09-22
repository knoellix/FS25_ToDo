FieldToDoPermissions = {}
FieldToDoPermissions._testOverride = nil
--- Vanilla Hofverwaltung key used for farm To-Do edit (MP).
FieldToDoPermissions.PERMISSION_KEY = "manageContracts"

local function resolveUserId(userId)
    if userId ~= nil then
        return userId
    end
    if FieldToDoPermissions._testOverride ~= nil then
        return FieldToDoPermissions._testOverride.userId
    end
    if g_currentMission ~= nil and g_currentMission.playerUserId ~= nil then
        return g_currentMission.playerUserId
    end
    if g_localPlayer ~= nil and g_localPlayer.userId ~= nil then
        return g_localPlayer.userId
    end
    return nil
end

--- Local peer farm id (MP client / SP). Tries several engine sources.
---@return number|nil
function FieldToDoPermissions.resolveLocalFarmId()
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.resolveFarmId ~= nil then
        return tonumber(override.resolveFarmId)
    end

    local candidates = {}

    local mission = g_currentMission
    if mission ~= nil and mission.getFarmId ~= nil then
        local ok, farmId = pcall(mission.getFarmId, mission)
        if ok then
            candidates[#candidates + 1] = farmId
        end
    end

    if g_localPlayer ~= nil then
        candidates[#candidates + 1] = g_localPlayer.farmId
    end

    if mission ~= nil and mission.player ~= nil then
        candidates[#candidates + 1] = mission.player.farmId
    end

    local userId = resolveUserId(nil)
    if userId ~= nil and g_farmManager ~= nil and g_farmManager.getFarmByUserId ~= nil then
        local ok, farm = pcall(g_farmManager.getFarmByUserId, g_farmManager, userId)
        if ok and farm ~= nil then
            candidates[#candidates + 1] = farm.farmId
        end
    end

    for i = 1, #candidates do
        local farmId = tonumber(candidates[i])
        if farmId ~= nil and farmId > 0 then
            return farmId
        end
    end

    return nil
end

--- True when the current session is multiplayer (listen/dedicated). SP → false.
---@return boolean
function FieldToDoPermissions.isMultiplayerSession()
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.isMultiplayer ~= nil then
        return override.isMultiplayer == true
    end

    if g_currentMission == nil then
        return false
    end

    local info = g_currentMission.missionDynamicInfo
    if info ~= nil and info.isMultiplayer == true then
        return true
    end

    return false
end

--- Resolve manageContracts key (engine constant when available).
---@return string
function FieldToDoPermissions.getEditPermissionKey()
    if Farm ~= nil and type(Farm.PERMISSION) == "table" and Farm.PERMISSION.MANAGE_CONTRACTS ~= nil then
        return tostring(Farm.PERMISSION.MANAGE_CONTRACTS)
    end
    return FieldToDoPermissions.PERMISSION_KEY
end

--- Read vanilla manageContracts for To-Do edit. nil = API unavailable.
---@param farmId number|nil
---@param userId number|nil
---@return boolean|nil
function FieldToDoPermissions.hasFarmTodoEditPermission(farmId, userId)
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.manageContracts ~= nil then
        return override.manageContracts == true
    end

    farmId = tonumber(farmId)
    userId = resolveUserId(userId)
    if farmId == nil or userId == nil or g_farmManager == nil then
        return nil
    end

    local key = FieldToDoPermissions.getEditPermissionKey()
    local farm = g_farmManager.getFarmById ~= nil and g_farmManager:getFarmById(farmId) or nil
    if farm == nil then
        return nil
    end

    if farm.getUserPermission ~= nil then
        local ok, result = pcall(farm.getUserPermission, farm, userId, key)
        if ok and result ~= nil then
            return result == true
        end
    end

    if farm.hasUserPermission ~= nil then
        local ok, result = pcall(farm.hasUserPermission, farm, userId, key)
        if ok and result ~= nil then
            return result == true
        end
    end

    if farm.users ~= nil then
        local entry = farm.users[userId] or farm.users[tostring(userId)]
        if type(entry) == "table" and type(entry.permissions) == "table" then
            local mapped = entry.permissions[key]
            if mapped ~= nil then
                return mapped == true
            end
        end
    end

    return nil
end

function FieldToDoPermissions.isFarmManager(farmId, userId)
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.isManager ~= nil then
        return override.isManager == true
    end
    farmId = tonumber(farmId)
    userId = resolveUserId(userId)
    if farmId == nil or userId == nil or g_farmManager == nil then
        return true
    end
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.isUserFarmManager == nil then
        return true
    end
    local ok, result = pcall(farm.isUserFarmManager, farm, userId)
    return ok and result == true
end

--- Membership check. Returns true/false when known, nil when APIs unavailable.
---@param farmId number
---@param userId number
---@return boolean|nil
function FieldToDoPermissions.userBelongsToFarm(farmId, userId)
    farmId = tonumber(farmId)
    userId = tonumber(userId) or userId
    if farmId == nil or farmId <= 0 or userId == nil or g_farmManager == nil then
        return nil
    end

    if g_farmManager.getFarmByUserId ~= nil then
        local ok, farm = pcall(g_farmManager.getFarmByUserId, g_farmManager, userId)
        if ok then
            return farm ~= nil and tonumber(farm.farmId) == farmId
        end
    end

    local farm = g_farmManager.getFarmById ~= nil and g_farmManager:getFarmById(farmId) or nil
    if farm ~= nil and farm.isUserInFarm ~= nil then
        local ok, inFarm = pcall(farm.isUserInFarm, farm, userId)
        if ok then
            return inFarm == true
        end
    end

    if farm ~= nil then
        local list = nil
        if farm.getUsers ~= nil then
            local ok, users = pcall(farm.getUsers, farm)
            if ok then
                list = users
            end
        end
        if list == nil and farm.getActiveUsers ~= nil then
            local ok, users = pcall(farm.getActiveUsers, farm)
            if ok then
                list = users
            end
        end
        if type(list) == "table" then
            for _, entry in pairs(list) do
                local uid = FieldToDoPermissions.extractUserIdFromFarmUserEntry(entry)
                if uid ~= nil and (uid == userId or tonumber(uid) == tonumber(userId)) then
                    return true
                end
            end
            return false
        end
    end

    return nil
end

--- Extract numeric/string user id from farm user list entries (id or User object).
---@param entry any
---@return number|string|nil
function FieldToDoPermissions.extractUserIdFromFarmUserEntry(entry)
    if entry == nil then
        return nil
    end
    if type(entry) == "number" or type(entry) == "string" then
        return entry
    end
    if type(entry) ~= "table" then
        return nil
    end
    if entry.getUserId ~= nil then
        local ok, uid = pcall(entry.getUserId, entry)
        if ok and uid ~= nil then
            return uid
        end
    end
    if entry.getId ~= nil then
        local ok, uid = pcall(entry.getId, entry)
        if ok and uid ~= nil and type(uid) ~= "table" then
            return uid
        end
    end
    if entry.userId ~= nil and type(entry.userId) ~= "table" then
        return entry.userId
    end
    if entry.id ~= nil and type(entry.id) ~= "table" then
        return entry.id
    end
    return nil
end

function FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId)
    farmId = tonumber(farmId)
    if farmId == nil or farmId <= 0 then
        return false
    end

    local override = FieldToDoPermissions._testOverride
    if override ~= nil then
        if override.resolveFarmId ~= nil and override.resolveFarmId ~= farmId then
            return false
        end
        return true
    end

    local explicitUserId = userId ~= nil
    local resolved = resolveUserId(userId)

    if resolved ~= nil then
        local membership = FieldToDoPermissions.userBelongsToFarm(farmId, resolved)
        if membership ~= nil then
            return membership
        end
        if explicitUserId then
            return false
        end
    elseif explicitUserId then
        return false
    end

    local localFarm = nil
    if ToDoManager ~= nil and g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil then
        localFarm = g_currentMission.fieldToDoList:getLocalFarmId()
    end
    if localFarm ~= nil and localFarm ~= farmId then
        return false
    end

    return true
end

function FieldToDoPermissions.resolveUniqueUserId(userId)
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.uniqueUserId ~= nil then
        return tostring(override.uniqueUserId)
    end
    userId = resolveUserId(userId)
    if userId == nil or g_currentMission == nil or g_currentMission.userManager == nil then
        return nil
    end
    local um = g_currentMission.userManager
    if um.getUniqueUserIdByUserId ~= nil then
        local ok, uid = pcall(um.getUniqueUserIdByUserId, um, userId)
        if ok and uid ~= nil and uid ~= "" then
            return tostring(uid)
        end
    end
    if um.getUserByUserId ~= nil then
        local ok, user = pcall(um.getUserByUserId, um, userId)
        if ok and user ~= nil and user.getUniqueUserId ~= nil then
            local ok2, uid = pcall(user.getUniqueUserId, user)
            if ok2 and uid ~= nil then
                return tostring(uid)
            end
        end
    end
    return nil
end

--- Farm To-Do edit: SP always (same farm); MP only with vanilla manageContracts. No grant fallback.
---@param farmId number|nil
---@param userId number|nil
---@return boolean
function FieldToDoPermissions.canEditFarmTodos(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    if not FieldToDoPermissions.isMultiplayerSession() then
        return true
    end
    return FieldToDoPermissions.hasFarmTodoEditPermission(farmId, userId) == true
end

--- ESC grant UI retired — always false.
function FieldToDoPermissions.canManageTodoEditGrants(farmId, userId)
    return false
end

function FieldToDoPermissions.canChangeWorkersEditSetting(farmId, userId)
    return FieldToDoPermissions.canManageTodoEditGrants(farmId, userId)
end

function FieldToDoPermissions.canEditLocal()
    local farmId = FieldToDoPermissions.resolveLocalFarmId()
    if farmId == nil and g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil then
        farmId = g_currentMission.fieldToDoList:getLocalFarmId()
    end
    return FieldToDoPermissions.canEditFarmTodos(farmId, nil)
end
