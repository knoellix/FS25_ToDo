FieldToDoPermissions = {}
FieldToDoPermissions._testOverride = nil
--- Vanilla Hofverwaltung key used for farm To-Do edit (MP). Same string as MissionStartEvent.
FieldToDoPermissions.PERMISSION_KEY = "manageContracts"

--- Local player userId (one engine path).
---@param userId number|string|nil
---@return number|string|nil
local function resolveUserId(userId)
    if userId ~= nil then
        return userId
    end
    if FieldToDoPermissions._testOverride ~= nil then
        return FieldToDoPermissions._testOverride.userId
    end
    if g_currentMission ~= nil then
        return g_currentMission.playerUserId
    end
    return nil
end

--- Local peer farm id. One path: mission:getFarmId().
---@return number|nil
function FieldToDoPermissions.resolveLocalFarmId()
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.resolveFarmId ~= nil then
        return tonumber(override.resolveFarmId)
    end

    if g_currentMission == nil or g_currentMission.getFarmId == nil then
        return nil
    end

    local ok, farmId = pcall(g_currentMission.getFarmId, g_currentMission)
    if not ok then
        return nil
    end
    farmId = tonumber(farmId)
    if farmId == nil or farmId <= 0 then
        return nil
    end
    return farmId
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
    return info ~= nil and info.isMultiplayer == true
end

---@return string
function FieldToDoPermissions.getEditPermissionKey()
    return FieldToDoPermissions.PERMISSION_KEY
end

---@param userId number|string|nil
---@return table|nil
local function resolveUserConnection(userId)
    if userId == nil or g_currentMission == nil or g_currentMission.userManager == nil then
        return nil
    end
    local um = g_currentMission.userManager
    if um.getConnectionByUserId == nil then
        return nil
    end
    local ok, conn = pcall(um.getConnectionByUserId, um, userId)
    if ok then
        return conn
    end
    return nil
end

--- Log one manageContracts probe (search log.txt for "PERM manageContracts").
---@param fields table
---@param force boolean|nil
local function logManageContractsProbe(fields, force)
    if FieldToDoLog == nil then
        return
    end

    local reason = fields.reason or "-"
    local now = g_time or 0
    local signature = string.format(
        "%s|%s|%s|%s|%s",
        tostring(fields.farmId),
        tostring(fields.userId),
        tostring(fields.allowed),
        tostring(fields.raw),
        tostring(reason)
    )

    if force ~= true then
        if FieldToDoPermissions._lastPermLogSignature == signature
            and FieldToDoPermissions._lastPermLogAt ~= nil
            and now - FieldToDoPermissions._lastPermLogAt < 10000 then
            return
        end
    end

    FieldToDoPermissions._lastPermLogSignature = signature
    FieldToDoPermissions._lastPermLogAt = now

    FieldToDoLog.info(
        "PERM manageContracts reason=%s mp=%s key=%s farmId=%s userId=%s connection=%s api=%s pcallOk=%s raw=%s(%s) allowed=%s",
        tostring(reason),
        tostring(fields.mp),
        tostring(fields.key),
        tostring(fields.farmId),
        tostring(fields.userId),
        fields.connection == true and "yes" or "nil",
        fields.api == true and "yes" or "nil",
        tostring(fields.pcallOk),
        tostring(fields.raw),
        type(fields.raw),
        tostring(fields.allowed)
    )
end

--- Vanilla manageContracts — same call as MissionStartEvent. nil = unavailable (fail-closed).
---@param farmId number|nil
---@param userId number|nil
---@param logReason string|nil if set, always log this probe (e.g. editAttempt, ftdlSync, serverDeny)
---@return boolean|nil
function FieldToDoPermissions.hasFarmTodoEditPermission(farmId, userId, logReason)
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.manageContracts ~= nil then
        return override.manageContracts == true
    end

    farmId = tonumber(farmId)
    userId = resolveUserId(userId)

    local key = FieldToDoPermissions.getEditPermissionKey()
    local mp = FieldToDoPermissions.isMultiplayerSession()
    local forceLog = logReason ~= nil and logReason ~= ""

    if farmId == nil or userId == nil then
        logManageContractsProbe({
            reason = logReason or "missingIds",
            mp = mp,
            key = key,
            farmId = farmId,
            userId = userId,
            connection = false,
            api = g_currentMission ~= nil and g_currentMission.getHasPlayerPermission ~= nil,
            pcallOk = false,
            raw = nil,
            allowed = nil,
        }, forceLog)
        return nil
    end

    if g_currentMission == nil or g_currentMission.getHasPlayerPermission == nil then
        logManageContractsProbe({
            reason = logReason or "noApi",
            mp = mp,
            key = key,
            farmId = farmId,
            userId = userId,
            connection = false,
            api = false,
            pcallOk = false,
            raw = nil,
            allowed = nil,
        }, forceLog)
        return nil
    end

    local connection = resolveUserConnection(userId)
    local ok, result = pcall(g_currentMission.getHasPlayerPermission, g_currentMission, key, connection, farmId)
    local allowed = nil
    if ok and result ~= nil then
        allowed = result == true
    end

    logManageContractsProbe({
        reason = logReason or "probe",
        mp = mp,
        key = key,
        farmId = farmId,
        userId = userId,
        connection = connection ~= nil,
        api = true,
        pcallOk = ok,
        raw = result,
        allowed = allowed,
    }, forceLog)

    return allowed
end

function FieldToDoPermissions.isFarmManager(farmId, userId)
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.isManager ~= nil then
        return override.isManager == true
    end
    farmId = tonumber(farmId)
    userId = resolveUserId(userId)
    if farmId == nil or userId == nil or g_farmManager == nil or g_farmManager.getFarmById == nil then
        return false
    end
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.isUserFarmManager == nil then
        return false
    end
    local ok, result = pcall(farm.isUserFarmManager, farm, userId)
    return ok and result == true
end

--- Membership via FarmManager:getFarmByUserId only. nil = unavailable.
---@param farmId number
---@param userId number
---@return boolean|nil
function FieldToDoPermissions.userBelongsToFarm(farmId, userId)
    farmId = tonumber(farmId)
    userId = tonumber(userId) or userId
    if farmId == nil or farmId <= 0 or userId == nil or g_farmManager == nil then
        return nil
    end

    if g_farmManager.getFarmByUserId == nil then
        return nil
    end

    local ok, farm = pcall(g_farmManager.getFarmByUserId, g_farmManager, userId)
    if not ok then
        return nil
    end
    return farm ~= nil and tonumber(farm.farmId) == farmId
end

--- Extract user id from farm user list entries (id number or User object — shape variance, not API cascade).
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
    if entry.userId ~= nil and type(entry.userId) ~= "table" then
        return entry.userId
    end
    return nil
end

--- Same-farm members may auto-complete. Unknown membership → deny (no fail-open).
---@param farmId number|nil
---@param userId number|nil
---@return boolean
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

    local resolved = resolveUserId(userId)
    if resolved == nil then
        return false
    end

    return FieldToDoPermissions.userBelongsToFarm(farmId, resolved) == true
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
    if um.getUniqueUserIdByUserId == nil then
        return nil
    end
    local ok, uid = pcall(um.getUniqueUserIdByUserId, um, userId)
    if ok and uid ~= nil and uid ~= "" then
        return tostring(uid)
    end
    return nil
end

--- Farm To-Do edit: SP always (same farm); MP only vanilla manageContracts.
---@param farmId number|nil
---@param userId number|nil
---@param logReason string|nil
---@return boolean
function FieldToDoPermissions.canEditFarmTodos(farmId, userId, logReason)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        if logReason ~= nil and FieldToDoLog ~= nil then
            FieldToDoLog.info(
                "PERM edit denied reason=%s cause=notSameFarmOrMembership farmId=%s userId=%s",
                tostring(logReason),
                tostring(farmId),
                tostring(userId)
            )
        end
        return false
    end
    if not FieldToDoPermissions.isMultiplayerSession() then
        return true
    end
    return FieldToDoPermissions.hasFarmTodoEditPermission(farmId, userId, logReason) == true
end

--- ESC grant UI retired — always false.
function FieldToDoPermissions.canManageTodoEditGrants(farmId, userId)
    return false
end

function FieldToDoPermissions.canChangeWorkersEditSetting(farmId, userId)
    return FieldToDoPermissions.canManageTodoEditGrants(farmId, userId)
end

---@param logReason string|nil
---@return boolean
function FieldToDoPermissions.canEditLocal(logReason)
    local farmId = FieldToDoPermissions.resolveLocalFarmId()
    return FieldToDoPermissions.canEditFarmTodos(farmId, nil, logReason)
end
