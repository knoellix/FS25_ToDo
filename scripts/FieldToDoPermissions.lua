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

function FieldToDoPermissions.canEditFarmTodos(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    if FieldToDoPermissions.isFarmManager(farmId, userId) then
        return true
    end
    local uniqueId = FieldToDoPermissions.resolveUniqueUserId(userId)
    if FieldAdvisorSettings == nil or FieldAdvisorSettings.getTodoEditAllowedForUniqueUser == nil then
        return true
    end
    return FieldAdvisorSettings.getTodoEditAllowedForUniqueUser(uniqueId)
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
