FieldToDoPermissions = {}
FieldToDoPermissions._testOverride = nil

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

function FieldToDoPermissions.isFarmManager(farmId, userId)
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.isManager ~= nil then
        return override.isManager == true
    end
    farmId = tonumber(farmId)
    userId = resolveUserId(userId)
    if farmId == nil or userId == nil or g_farmManager == nil then
        -- SP / missing API: treat as manager so local play keeps working
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

    -- Fallback: farm user lists may contain ids or User objects (same as getActiveUsers).
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

    -- Keep whether the caller passed an explicit user (server request) before local resolve.
    local explicitUserId = userId ~= nil
    local resolved = resolveUserId(userId)

    if resolved ~= nil then
        local membership = FieldToDoPermissions.userBelongsToFarm(farmId, resolved)
        if membership ~= nil then
            return membership
        end
        -- Remote request with broken membership APIs: deny (do NOT use host getLocalFarmId).
        if explicitUserId then
            return false
        end
    elseif explicitUserId then
        return false
    end

    -- Local UI / SP fallback only (no explicit remote userId).
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

--- Farm-scoped grant lookup. Prefers ToDoManager.todoEditByFarmId (server authority).
---@param farmId number|nil
---@param uniqueUserId string|nil
---@param explicitUserId boolean|nil true when caller passed a remote userId (unused; kept for call sites)
---@return boolean
function FieldToDoPermissions.getTodoEditAllowed(farmId, uniqueUserId, explicitUserId)
    farmId = tonumber(farmId)

    -- Headless fixtures inject grants via FieldAdvisorSettings + _testOverride.
    if FieldToDoPermissions._testOverride ~= nil then
        if FieldAdvisorSettings ~= nil and FieldAdvisorSettings.getTodoEditAllowedForUniqueUser ~= nil then
            return FieldAdvisorSettings.getTodoEditAllowedForUniqueUser(uniqueUserId)
        end
        return true
    end

    local manager = nil
    if FieldToDoSync ~= nil and FieldToDoSync.getManager ~= nil then
        manager = FieldToDoSync.getManager()
    elseif g_currentMission ~= nil then
        manager = g_currentMission.fieldToDoList
    end

    if manager ~= nil and farmId ~= nil and manager.getTodoEditStateForFarm ~= nil then
        local state = manager:getTodoEditStateForFarm(farmId)
        if state ~= nil then
            -- Missing uniqueUserId: cannot apply per-user overrides → honor farm defaultAllow.
            -- (Do not fail-closed here; dedicated servers often lack uniqueUserId APIs.)
            if uniqueUserId == nil or uniqueUserId == "" then
                return state.defaultAllow ~= false
            end
            local mapped = state.byUniqueUserId[tostring(uniqueUserId)]
            if mapped == nil then
                return state.defaultAllow ~= false
            end
            return mapped == true
        end
    end

    -- UI / SP cache fallback when farm map not loaded yet.
    if FieldAdvisorSettings ~= nil and FieldAdvisorSettings.getTodoEditAllowedForUniqueUser ~= nil then
        return FieldAdvisorSettings.getTodoEditAllowedForUniqueUser(uniqueUserId)
    end

    -- No grant source at all: server fail-closed, client/SP allow.
    if g_server ~= nil then
        return false
    end
    return true
end

function FieldToDoPermissions.canEditFarmTodos(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    if FieldToDoPermissions.isFarmManager(farmId, userId) then
        return true
    end
    local explicitUserId = userId ~= nil
    local uniqueId = FieldToDoPermissions.resolveUniqueUserId(userId)
    return FieldToDoPermissions.getTodoEditAllowed(farmId, uniqueId, explicitUserId)
end

function FieldToDoPermissions.canManageTodoEditGrants(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    return FieldToDoPermissions.isFarmManager(farmId, userId)
end

function FieldToDoPermissions.canChangeWorkersEditSetting(farmId, userId)
    return FieldToDoPermissions.canManageTodoEditGrants(farmId, userId)
end

function FieldToDoPermissions.canEditLocal()
    local farmId = nil
    if g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil then
        farmId = g_currentMission.fieldToDoList:getLocalFarmId()
    end
    return FieldToDoPermissions.canEditFarmTodos(farmId, nil)
end
