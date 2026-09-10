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

function FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId)
    farmId = tonumber(farmId)
    if farmId == nil or farmId <= 0 then
        return false
    end
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.resolveFarmId ~= nil and override.resolveFarmId ~= farmId then
        return false
    end
    if override == nil then
        local localFarm = nil
        if ToDoManager ~= nil and g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil then
            localFarm = g_currentMission.fieldToDoList:getLocalFarmId()
        end
        if localFarm ~= nil and localFarm ~= farmId then
            return false
        end
    end
    return true
end

function FieldToDoPermissions.canEditFarmTodos(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    local workersOk = true
    if FieldAdvisorSettings ~= nil and FieldAdvisorSettings.isWorkersMayEditTodos ~= nil then
        workersOk = FieldAdvisorSettings.isWorkersMayEditTodos()
    elseif FieldAdvisorSettings ~= nil then
        workersOk = FieldAdvisorSettings.workersMayEditTodos ~= false
    end
    if workersOk then
        return true
    end
    return FieldToDoPermissions.isFarmManager(farmId, userId)
end

function FieldToDoPermissions.canChangeWorkersEditSetting(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    return FieldToDoPermissions.isFarmManager(farmId, userId)
end

function FieldToDoPermissions.canEditLocal()
    local farmId = nil
    if g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil then
        farmId = g_currentMission.fieldToDoList:getLocalFarmId()
    end
    return FieldToDoPermissions.canEditFarmTodos(farmId, nil)
end
