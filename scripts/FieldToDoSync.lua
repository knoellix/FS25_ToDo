--[[
    FieldToDoSync.lua
    Multiplayer sync core: opcodes, stream (de)serialization, and request/notify/state
    dispatch for farm to-do tasks and shared settings.

    Flow:
      Client calls FieldToDoSync.request(op, payload) -> sends FieldToDoRequestEvent to the
      server (or applies locally when already the server/SP).
      Server (FieldToDoSync.handleRequest) applies the op via a ToDoManager "applyX" method
      (added in Task 4) and broadcasts a FieldToDoNotifyEvent to all clients (including the
      requester). Clients apply notify via FieldToDoSync.applyNotify using the same "applyX"
      methods; the host skips re-apply in FieldToDoNotifyEvent:run (already applied locally).
      On join / resync, the server sends a full FieldToDoStateEvent via sendStateToConnection.

    Server resolves farmId from userId, checks FieldToDoPermissions, applies via ToDoManager
    apply* methods, then broadcasts authoritative notify payloads to other clients.
]]

FieldToDoSync = {}
FieldToDoSync.SCHEMA_VERSION = 4
FieldToDoSync.lastRequest = nil
FieldToDoSync.lastDeny = nil
FieldToDoSync.lastNotify = nil

---@return number
local function syncNow()
    if g_time ~= nil then
        return g_time
    end
    if g_currentMission ~= nil and g_currentMission.time ~= nil then
        return g_currentMission.time
    end
    return 0
end

---@param bucketName string
---@param op number|nil
---@param reason string|nil
---@param farmId number|nil
local function recordSyncDebug(bucketName, op, reason, farmId)
    FieldToDoSync[bucketName] = {
        op = op,
        reason = reason,
        farmId = farmId,
        time = syncNow(),
    }
end

---@param version number|nil
---@return boolean
function FieldToDoSync.isCompatibleSchemaVersion(version)
    version = tonumber(version)
    return version ~= nil and version == FieldToDoSync.SCHEMA_VERSION
end

FieldToDoSync.OP = {
    ADD_MANUAL = 1,
    ADD_FIELD = 2,
    UPDATE_TEXT = 3,
    DELETE = 4,
    MOVE = 5,
    TOGGLE_DONE = 6,
    AUTO_COMPLETE = 7,
    SET_PRESET = 8,
    SET_ORGANIC = 9,
    SET_MULCH = 10,
    SET_WORKERS_EDIT = 11,
    SET_PLANNED_CROP = 12,
    DENY = 13,
    REQUEST_STATE = 14,
    SET_USER_TODO_EDIT = 15,
    SET_ALL_WORKERS_TODO_EDIT = 16,
}

local OP = FieldToDoSync.OP

--- ToDoManager method invoked for each op once permission/farm checks pass.
FieldToDoSync.APPLY_METHOD_BY_OP = {
    [OP.ADD_MANUAL] = "applyAddManualTask",
    [OP.ADD_FIELD] = "applyAddFieldTask",
    [OP.UPDATE_TEXT] = "applyUpdateTaskText",
    [OP.DELETE] = "applyDeleteTask",
    [OP.MOVE] = "applyMoveTask",
    [OP.TOGGLE_DONE] = "applyToggleTaskDone",
    [OP.AUTO_COMPLETE] = "applyAutoCompleteTask",
    [OP.SET_PRESET] = "applySetWorkOrderPreset",
    [OP.SET_ORGANIC] = "applySetOrganicMultiPass",
    [OP.SET_MULCH] = "applySetMulching",
    [OP.SET_WORKERS_EDIT] = "applySetWorkersMayEdit",
    [OP.SET_PLANNED_CROP] = "applySetPlannedCrop",
    [OP.SET_USER_TODO_EDIT] = "applySetUserTodoEdit",
    [OP.SET_ALL_WORKERS_TODO_EDIT] = "applySetAllWorkersTodoEdit",
}

--- Fields serialized for a task in FieldToDoStateEvent, mirroring ToDoManager's XML schema
--- (see ToDoManager.registerSavegameXMLPaths / loadTaskFromXML / saveTaskToXML).
FieldToDoSync.TASK_FIELDS = {
    { name = "id", kind = "int" },
    { name = "sortIndex", kind = "int" },
    { name = "text", kind = "string" },
    { name = "completed", kind = "bool" },
    { name = "source", kind = "string" },
    { name = "autoComplete", kind = "bool" },
    { name = "farmId", kind = "int" },
    { name = "fieldId", kind = "int" },
    { name = "fieldName", kind = "string" },
    { name = "fruit", kind = "string" },
    { name = "actionType", kind = "string" },
    { name = "fertPass", kind = "int" },
    { name = "fertPassTotal", kind = "int" },
    { name = "suggestion", kind = "string" },
}

---@param streamId number
---@param value string|nil
function FieldToDoSync.writeString(streamId, value)
    streamWriteString(streamId, value or "")
end

---@param streamId number
---@return string
function FieldToDoSync.readString(streamId)
    return streamReadString(streamId)
end

---@return ToDoManager|nil
function FieldToDoSync.getManager()
    if g_currentMission == nil then
        return nil
    end

    return g_currentMission.fieldToDoList
end

---@return boolean
function FieldToDoSync.isRunningAsServer()
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil then
        local ok, result = pcall(g_currentMission.getIsServer, g_currentMission)
        if ok then
            return result == true
        end
    end

    return g_server ~= nil
end

-- ============================================================================
-- Payload (de)serialization — one op = one shape. Only streamWriteBool / Int32 /
-- String primitives are used (no Float32 payload fields exist yet).
-- ============================================================================

---@param streamId number
---@param payload table|nil
local function writePayloadFarmId(streamId, payload)
    streamWriteInt32(streamId, tonumber(payload ~= nil and payload.farmId) or 0)
end

---@param streamId number
---@param payload table
local function readPayloadFarmId(streamId, payload)
    local farmId = streamReadInt32(streamId)
    if farmId ~= 0 then
        payload.farmId = farmId
    end
end

---@param streamId number
---@param op number
---@param payload table|nil
function FieldToDoSync.writePayload(streamId, op, payload)
    payload = payload or {}

    if op == OP.ADD_MANUAL then
        FieldToDoSync.writeString(streamId, payload.text)
        local taskId = tonumber(payload.taskId) or (payload.task ~= nil and tonumber(payload.task.id)) or 0
        local sortIndex = tonumber(payload.sortIndex) or (payload.task ~= nil and tonumber(payload.task.sortIndex)) or 0
        streamWriteInt32(streamId, taskId)
        streamWriteInt32(streamId, sortIndex)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.ADD_FIELD then
        streamWriteInt32(streamId, tonumber(payload.fieldId) or 0)
        FieldToDoSync.writeString(streamId, payload.actionType)
        FieldToDoSync.writeString(streamId, payload.text)
        streamWriteBool(streamId, payload.autoComplete == true)
        streamWriteInt32(streamId, tonumber(payload.fertPass) or 0)
        streamWriteInt32(streamId, tonumber(payload.fertPassTotal) or 0)
        FieldToDoSync.writeString(streamId, payload.fruit)
        FieldToDoSync.writeString(streamId, payload.fieldName)
        FieldToDoSync.writeString(streamId, payload.suggestion)
        local taskId = tonumber(payload.taskId) or (payload.task ~= nil and tonumber(payload.task.id)) or 0
        local sortIndex = tonumber(payload.sortIndex) or (payload.task ~= nil and tonumber(payload.task.sortIndex)) or 0
        streamWriteInt32(streamId, taskId)
        streamWriteInt32(streamId, sortIndex)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.UPDATE_TEXT then
        streamWriteInt32(streamId, tonumber(payload.taskId) or 0)
        FieldToDoSync.writeString(streamId, payload.text)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.DELETE then
        streamWriteInt32(streamId, tonumber(payload.taskId) or 0)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.MOVE then
        streamWriteInt32(streamId, tonumber(payload.taskId) or 0)
        streamWriteInt32(streamId, tonumber(payload.delta) or 0)
        local swapTasks = payload.swapTasks or {}
        local swapA = swapTasks[1] or {}
        local swapB = swapTasks[2] or {}
        streamWriteInt32(streamId, tonumber(swapA.id) or 0)
        streamWriteInt32(streamId, tonumber(swapA.sortIndex) or 0)
        streamWriteInt32(streamId, tonumber(swapB.id) or 0)
        streamWriteInt32(streamId, tonumber(swapB.sortIndex) or 0)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.TOGGLE_DONE then
        streamWriteInt32(streamId, tonumber(payload.taskId) or 0)
        streamWriteBool(streamId, payload.completed == true)
        streamWriteInt32(streamId, tonumber(payload.sortIndex) or 0)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.AUTO_COMPLETE then
        streamWriteInt32(streamId, tonumber(payload.taskId) or 0)
        streamWriteBool(streamId, payload.completed == true)
        streamWriteInt32(streamId, tonumber(payload.sortIndex) or 0)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.SET_PRESET then
        FieldToDoSync.writeString(streamId, payload.presetKey)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.SET_ORGANIC then
        streamWriteBool(streamId, payload.enabled == true)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.SET_MULCH then
        streamWriteBool(streamId, payload.enabled == true)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.SET_WORKERS_EDIT then
        streamWriteBool(streamId, payload.enabled == true)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.SET_PLANNED_CROP then
        streamWriteInt32(streamId, tonumber(payload.fieldId) or 0)
        streamWriteInt32(streamId, tonumber(payload.fruitTypeIndex) or 0)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.SET_USER_TODO_EDIT then
        FieldToDoSync.writeString(streamId, payload.uniqueUserId)
        streamWriteBool(streamId, payload.enabled == true)
        writePayloadFarmId(streamId, payload)
    elseif op == OP.SET_ALL_WORKERS_TODO_EDIT then
        streamWriteBool(streamId, payload.enabled == true)
        local uniqueUserIds = payload.uniqueUserIds or {}
        streamWriteInt32(streamId, #uniqueUserIds)
        for i = 1, #uniqueUserIds do
            FieldToDoSync.writeString(streamId, uniqueUserIds[i])
        end
        writePayloadFarmId(streamId, payload)
    elseif op == OP.DENY then
        streamWriteUInt8(streamId, tonumber(payload.deniedOp) or 0)
        FieldToDoSync.writeString(streamId, payload.reason)
    end
end

---@param streamId number
---@param op number
---@return table payload
function FieldToDoSync.readPayload(streamId, op)
    local payload = {}

    if op == OP.ADD_MANUAL then
        payload.text = FieldToDoSync.readString(streamId)
        payload.taskId = streamReadInt32(streamId)
        payload.sortIndex = streamReadInt32(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.ADD_FIELD then
        payload.fieldId = streamReadInt32(streamId)
        payload.actionType = FieldToDoSync.readString(streamId)
        payload.text = FieldToDoSync.readString(streamId)
        payload.autoComplete = streamReadBool(streamId)
        payload.fertPass = streamReadInt32(streamId)
        payload.fertPassTotal = streamReadInt32(streamId)
        payload.fruit = FieldToDoSync.readString(streamId)
        payload.fieldName = FieldToDoSync.readString(streamId)
        payload.suggestion = FieldToDoSync.readString(streamId)
        payload.taskId = streamReadInt32(streamId)
        payload.sortIndex = streamReadInt32(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.UPDATE_TEXT then
        payload.taskId = streamReadInt32(streamId)
        payload.text = FieldToDoSync.readString(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.DELETE then
        payload.taskId = streamReadInt32(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.MOVE then
        payload.taskId = streamReadInt32(streamId)
        payload.delta = streamReadInt32(streamId)
        local swapAId = streamReadInt32(streamId)
        local swapASort = streamReadInt32(streamId)
        local swapBId = streamReadInt32(streamId)
        local swapBSort = streamReadInt32(streamId)
        if swapAId ~= 0 and swapBId ~= 0 then
            payload.swapTasks = {
                { id = swapAId, sortIndex = swapASort },
                { id = swapBId, sortIndex = swapBSort },
            }
        end
        readPayloadFarmId(streamId, payload)
    elseif op == OP.TOGGLE_DONE then
        payload.taskId = streamReadInt32(streamId)
        payload.completed = streamReadBool(streamId)
        payload.sortIndex = streamReadInt32(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.AUTO_COMPLETE then
        payload.taskId = streamReadInt32(streamId)
        payload.completed = streamReadBool(streamId)
        payload.sortIndex = streamReadInt32(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.SET_PRESET then
        payload.presetKey = FieldToDoSync.readString(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.SET_ORGANIC then
        payload.enabled = streamReadBool(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.SET_MULCH then
        payload.enabled = streamReadBool(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.SET_WORKERS_EDIT then
        payload.enabled = streamReadBool(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.SET_PLANNED_CROP then
        payload.fieldId = streamReadInt32(streamId)
        payload.fruitTypeIndex = streamReadInt32(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.SET_USER_TODO_EDIT then
        payload.uniqueUserId = FieldToDoSync.readString(streamId)
        payload.enabled = streamReadBool(streamId)
        readPayloadFarmId(streamId, payload)
    elseif op == OP.SET_ALL_WORKERS_TODO_EDIT then
        payload.enabled = streamReadBool(streamId)
        local idCount = streamReadInt32(streamId) or 0
        payload.uniqueUserIds = {}
        for _ = 1, idCount do
            payload.uniqueUserIds[#payload.uniqueUserIds + 1] = FieldToDoSync.readString(streamId)
        end
        readPayloadFarmId(streamId, payload)
    elseif op == OP.DENY then
        payload.deniedOp = streamReadUInt8(streamId)
        payload.reason = FieldToDoSync.readString(streamId)
    end

    return payload
end

-- ============================================================================
-- Task (de)serialization for full-state sync.
-- ============================================================================

---@param streamId number
---@param task table
function FieldToDoSync.writeTask(streamId, task)
    task = task or {}
    for _, field in ipairs(FieldToDoSync.TASK_FIELDS) do
        local value = task[field.name]
        if field.kind == "int" then
            streamWriteInt32(streamId, tonumber(value) or 0)
        elseif field.kind == "bool" then
            streamWriteBool(streamId, value == true)
        else
            FieldToDoSync.writeString(streamId, tostring(value or ""))
        end
    end
end

---@param streamId number
---@return table task
function FieldToDoSync.readTask(streamId)
    local task = {}
    for _, field in ipairs(FieldToDoSync.TASK_FIELDS) do
        if field.kind == "int" then
            task[field.name] = streamReadInt32(streamId)
        elseif field.kind == "bool" then
            task[field.name] = streamReadBool(streamId)
        else
            task[field.name] = FieldToDoSync.readString(streamId)
        end
    end

    -- 0 is the "absent" sentinel for optional numeric fields (mirrors nil in the XML schema).
    if task.farmId == 0 then
        task.farmId = nil
    end

    if task.fieldId == 0 then
        task.fieldId = nil
        task.fieldName = nil
        task.fruit = nil
        task.actionType = nil
        task.fertPass = nil
        task.fertPassTotal = nil
        task.suggestion = nil
    end

    return task
end

---@param task table
---@return table copy containing only the synced fields
function FieldToDoSync.copyTaskForState(task)
    local copy = {}
    for _, field in ipairs(FieldToDoSync.TASK_FIELDS) do
        copy[field.name] = task[field.name]
    end

    return copy
end

-- ============================================================================
-- Full-state (de)serialization.
-- ============================================================================

---@param streamId number
---@param state table
function FieldToDoSync.writeState(streamId, state)
    state = state or {}

    streamWriteUInt8(streamId, FieldToDoSync.SCHEMA_VERSION)
    streamWriteInt32(streamId, tonumber(state.farmId) or 0)
    FieldToDoSync.writeString(streamId, state.workOrderPreset)
    streamWriteBool(streamId, state.organicMultiPassEnabled == true)
    streamWriteBool(streamId, state.mulchingEnabled ~= false)
    streamWriteBool(streamId, state.workersMayEditTodos ~= false)
    streamWriteBool(streamId, state.todoEditDefaultAllow ~= false)

    local todoEditUsers = state.todoEditUsers or {}
    streamWriteInt32(streamId, #todoEditUsers)
    for _, entry in ipairs(todoEditUsers) do
        FieldToDoSync.writeString(streamId, entry.uniqueUserId)
        streamWriteBool(streamId, entry.mayEdit == true)
    end

    local plannedCrops = state.plannedCrops or {}
    streamWriteInt32(streamId, #plannedCrops)
    for _, entry in ipairs(plannedCrops) do
        streamWriteInt32(streamId, tonumber(entry.fieldId) or 0)
        streamWriteInt32(streamId, tonumber(entry.fruitTypeIndex) or 0)
    end

    local tasks = state.tasks or {}
    streamWriteInt32(streamId, #tasks)
    for _, task in ipairs(tasks) do
        FieldToDoSync.writeTask(streamId, task)
    end
end

---@param streamId number
---@return table state
function FieldToDoSync.readState(streamId)
    local state = {}

    state.schemaVersion = streamReadUInt8(streamId)
    local farmId = streamReadInt32(streamId)
    state.farmId = farmId ~= 0 and farmId or nil
    state.workOrderPreset = FieldToDoSync.readString(streamId)
    state.organicMultiPassEnabled = streamReadBool(streamId)
    state.mulchingEnabled = streamReadBool(streamId)
    state.workersMayEditTodos = streamReadBool(streamId)
    state.todoEditDefaultAllow = streamReadBool(streamId)

    state.todoEditUsers = {}
    local todoEditUserCount = streamReadInt32(streamId) or 0
    for _ = 1, todoEditUserCount do
        state.todoEditUsers[#state.todoEditUsers + 1] = {
            uniqueUserId = FieldToDoSync.readString(streamId),
            mayEdit = streamReadBool(streamId),
        }
    end

    state.plannedCrops = {}
    local plannedCropCount = streamReadInt32(streamId) or 0
    for _ = 1, plannedCropCount do
        local fieldId = streamReadInt32(streamId)
        local fruitTypeIndex = streamReadInt32(streamId)
        state.plannedCrops[#state.plannedCrops + 1] = { fieldId = fieldId, fruitTypeIndex = fruitTypeIndex }
    end

    state.tasks = {}
    local taskCount = streamReadInt32(streamId) or 0
    for _ = 1, taskCount do
        state.tasks[#state.tasks + 1] = FieldToDoSync.readTask(streamId)
    end

    return state
end

-- ============================================================================
-- Request / notify dispatch.
-- ============================================================================

--- Resolve userId from a client connection (server-side). Prefer UserManager.
---@param connection table|nil
---@return number|nil
function FieldToDoSync.resolveUserIdFromConnection(connection)
    if connection == nil then
        return nil
    end

    if g_currentMission ~= nil and g_currentMission.userManager ~= nil then
        local userManager = g_currentMission.userManager
        if userManager.getUserByConnection ~= nil then
            local ok, user = pcall(userManager.getUserByConnection, userManager, connection)
            if ok and user ~= nil then
                if user.getId ~= nil then
                    local okId, userId = pcall(user.getId, user)
                    if okId and userId ~= nil then
                        return tonumber(userId) or userId
                    end
                end
                if user.id ~= nil then
                    return tonumber(user.id) or user.id
                end
            end
        end
    end

    if connection.getUserId ~= nil then
        local ok, result = pcall(connection.getUserId, connection)
        if ok and result ~= nil then
            return tonumber(result) or result
        end
    end

    return nil
end

--- Resolve the requester's farm on the server; never trust client-supplied farmId.
---@param userId number|nil
---@return number|nil
function FieldToDoSync.resolveFarmIdForUser(userId)
    userId = tonumber(userId) or userId

    local override = FieldToDoPermissions ~= nil and FieldToDoPermissions._testOverride or nil
    if override ~= nil and override.resolveFarmId ~= nil then
        return tonumber(override.resolveFarmId)
    end

    if userId == nil then
        return nil
    end

    if g_farmManager ~= nil and g_farmManager.getFarmByUserId ~= nil then
        local ok, farm = pcall(g_farmManager.getFarmByUserId, g_farmManager, userId)
        if ok and farm ~= nil then
            local farmId = tonumber(farm.farmId)
            if farmId ~= nil and farmId > 0 then
                return farmId
            end
        end
    end

    if g_currentMission ~= nil and g_currentMission.playerSystem ~= nil then
        local playerSystem = g_currentMission.playerSystem
        if playerSystem.getPlayerByUserId ~= nil then
            local ok, player = pcall(playerSystem.getPlayerByUserId, playerSystem, userId)
            if ok and player ~= nil then
                local farmId = tonumber(player.farmId)
                if farmId ~= nil and farmId > 0 then
                    return farmId
                end
            end
        end
    end

    if g_farmManager ~= nil and g_farmManager.farms ~= nil then
        for _, farm in pairs(g_farmManager.farms) do
            if farm.isUserInFarm ~= nil then
                local ok, inFarm = pcall(farm.isUserInFarm, farm, userId)
                if ok and inFarm == true then
                    return tonumber(farm.farmId)
                end
            end

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
                    local uid = entry
                    if FieldToDoPermissions ~= nil
                        and FieldToDoPermissions.extractUserIdFromFarmUserEntry ~= nil then
                        uid = FieldToDoPermissions.extractUserIdFromFarmUserEntry(entry)
                    elseif type(entry) == "table" then
                        uid = nil
                    end
                    if uid ~= nil and (tonumber(uid) == tonumber(userId) or uid == userId) then
                        return tonumber(farm.farmId)
                    end
                end
            end
        end
    end

    return nil
end

---@param op number
---@param farmId number|nil
---@param userId number|nil
---@return boolean
function FieldToDoSync.canExecuteOp(op, farmId, userId)
    if FieldToDoPermissions == nil then
        return true
    end

    if op == OP.AUTO_COMPLETE then
        return FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId)
    end

    if op == OP.SET_WORKERS_EDIT then
        return FieldToDoPermissions.canChangeWorkersEditSetting(farmId, userId)
    end

    if op == OP.SET_USER_TODO_EDIT or op == OP.SET_ALL_WORKERS_TODO_EDIT then
        return FieldToDoPermissions.canManageTodoEditGrants(farmId, userId)
    end

    if op == OP.DENY then
        return false
    end

    return FieldToDoPermissions.canEditFarmTodos(farmId, userId)
end

---@param manager ToDoManager|nil
---@param op number
---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return boolean ok
---@return table|nil result
function FieldToDoSync.applyOp(manager, op, payload, farmId, userId)
    if manager == nil then
        return false, nil
    end

    local methodName = FieldToDoSync.APPLY_METHOD_BY_OP[op]
    if methodName == nil or manager[methodName] == nil then
        return false, nil
    end

    local ok, result = pcall(manager[methodName], manager, payload, farmId, userId)
    if not ok then
        if FieldToDoLog ~= nil then
            FieldToDoLog.warning("FieldToDoSync: apply %s failed (%s)", methodName, tostring(result))
        end
        return false, nil
    end

    if result == nil or result == false then
        return false, nil
    end

    return true, result
end

--- Merge apply result with request fields for notify serialization.
---@param op number
---@param requestPayload table
---@param applyResult table|nil
---@param farmId number|nil
---@return table
function FieldToDoSync.buildNotifyPayload(op, requestPayload, applyResult, farmId)
    local notify = {}
    requestPayload = requestPayload or {}
    applyResult = applyResult or {}

    for key, value in pairs(requestPayload) do
        notify[key] = value
    end
    for key, value in pairs(applyResult) do
        notify[key] = value
    end

    notify.farmId = notify.farmId or farmId

    if notify.task ~= nil then
        notify.taskId = notify.taskId or notify.task.id
        notify.sortIndex = notify.sortIndex or notify.task.sortIndex
    end

    return notify
end

---@param op number
---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return boolean ok
---@return table|string|nil resultPayload
function FieldToDoSync.executeOnServer(op, payload, farmId, userId)
    local manager = FieldToDoSync.getManager()
    if manager == nil then
        return false, "no_manager"
    end

    farmId = tonumber(farmId)
    if farmId == nil or farmId <= 0 then
        return false, "no_farm"
    end

    if not FieldToDoSync.canExecuteOp(op, farmId, userId) then
        local isManager = FieldToDoPermissions ~= nil
            and FieldToDoPermissions.isFarmManager ~= nil
            and FieldToDoPermissions.isFarmManager(farmId, userId)
        local uniqueId = FieldToDoPermissions ~= nil
            and FieldToDoPermissions.resolveUniqueUserId ~= nil
            and FieldToDoPermissions.resolveUniqueUserId(userId)
            or nil
        if FieldToDoLog ~= nil then
            FieldToDoLog.warning(
                "FieldToDoSync: canExecuteOp=false op=%s farmId=%s userId=%s manager=%s uniqueUserId=%s",
                tostring(op),
                tostring(farmId),
                tostring(userId),
                tostring(isManager),
                tostring(uniqueId)
            )
        end
        return false, "denied"
    end

    local ok, applyResult = FieldToDoSync.applyOp(manager, op, payload, farmId, userId)
    if not ok then
        return false, "apply_failed"
    end

    return true, FieldToDoSync.buildNotifyPayload(op, payload, applyResult, farmId)
end

---@param connection table|nil
---@param deniedOp number
---@param reason string|nil
function FieldToDoSync.sendDeny(connection, deniedOp, reason)
    reason = tostring(reason or "denied")
    recordSyncDebug("lastDeny", deniedOp, reason, nil)
    if FieldToDoLog ~= nil then
        FieldToDoLog.warning("FieldToDoSync: denying op=%s reason=%s", tostring(deniedOp), reason)
    end

    -- Local/SP deny (no connection): still surface UI feedback.
    if connection == nil then
        if FieldToDoInGameMenuIntegration ~= nil and FieldToDoInGameMenuIntegration.menuScreen ~= nil then
            local screen = FieldToDoInGameMenuIntegration.menuScreen
            if screen.notifyEditDenied ~= nil then
                pcall(screen.notifyEditDenied, screen, reason)
            end
        elseif InfoDialog ~= nil and InfoDialog.show ~= nil then
            local message = reason
            if FieldToDoL10n ~= nil and FieldToDoL10n.getText ~= nil then
                message = FieldToDoL10n.getText("ftdl_edit_denied", "No permission to change to-dos")
                if reason ~= nil and reason ~= "" and reason ~= "denied" then
                    message = message .. " (" .. reason .. ")"
                end
            end
            pcall(InfoDialog.show, message)
        end
        return
    end

    if FieldToDoNotifyEvent == nil then
        return
    end

    connection:sendEvent(FieldToDoNotifyEvent.new(OP.DENY, {
        deniedOp = deniedOp,
        reason = reason,
    }))
end

--- Client or local-server entry point for a user-initiated change.
---@param op number
---@param payload table|nil
function FieldToDoSync.request(op, payload)
    payload = payload or {}
    recordSyncDebug("lastRequest", op, nil, nil)

    if not FieldToDoSync.isRunningAsServer() then
        if g_client ~= nil
            and g_client.getServerConnection ~= nil
            and FieldToDoRequestEvent ~= nil then
            local connection = g_client:getServerConnection()
            if connection ~= nil then
                connection:sendEvent(FieldToDoRequestEvent.new(op, payload))
                return
            end
        end

        -- Pure client without a server connection must not mint tasks locally.
        FieldToDoSync.sendDeny(nil, op, "no_connection")
        return
    end

    -- SP / host: apply locally, no network round trip.
    FieldToDoSync.handleRequest(op, payload, nil, nil)
end

--- Server-side (or local SP) application of a request.
---@param op number
---@param payload table
---@param userId number|nil
---@param connection table|nil originating client connection (nil for local/SP)
function FieldToDoSync.handleRequest(op, payload, userId, connection)
    payload = payload or {}

    -- Local/SP calls pass connection=nil; only then may we fall back to getLocalFarmId.
    local allowLocalFarmFallback = connection == nil

    if op == OP.REQUEST_STATE then
        if connection == nil then
            return
        end

        local farmId = FieldToDoSync.resolveFarmIdForUser(userId)
        if farmId == nil and allowLocalFarmFallback then
            local manager = FieldToDoSync.getManager()
            if manager ~= nil and manager.getLocalFarmId ~= nil then
                farmId = manager:getLocalFarmId()
            end
        end

        FieldToDoSync.sendStateToConnection(connection, farmId)
        return
    end

    local manager = FieldToDoSync.getManager()
    if manager == nil then
        FieldToDoSync.sendDeny(connection, op, "no_manager")
        return
    end

    local farmId = FieldToDoSync.resolveFarmIdForUser(userId)
    if farmId == nil and allowLocalFarmFallback and manager.getLocalFarmId ~= nil then
        farmId = manager:getLocalFarmId()
    end

    local ok, resultPayload = FieldToDoSync.executeOnServer(op, payload, farmId, userId)
    if not ok then
        FieldToDoSync.sendDeny(connection, op, resultPayload)
        return
    end

    -- Include the requester: pure clients need applyNotify; host/listen-server skips re-apply in NotifyEvent:run.
    FieldToDoSync.broadcastNotify(op, resultPayload, farmId, nil)
end

--- Client-side application of a server-broadcast notify (server already validated the op).
---@param op number
---@param payload table|nil
function FieldToDoSync.applyNotify(op, payload)
    payload = payload or {}

    if op == OP.DENY then
        local reason = tostring(payload.reason or "denied")
        recordSyncDebug("lastDeny", payload.deniedOp, reason, tonumber(payload.farmId))
        if FieldToDoLog ~= nil then
            FieldToDoLog.warning(
                "FieldToDoSync: request denied by server (op=%s reason=%s)",
                tostring(payload.deniedOp),
                reason
            )
        end
        if FieldToDoInGameMenuIntegration ~= nil and FieldToDoInGameMenuIntegration.menuScreen ~= nil then
            local screen = FieldToDoInGameMenuIntegration.menuScreen
            if screen.notifyEditDenied ~= nil then
                pcall(screen.notifyEditDenied, screen, reason)
            end
        elseif InfoDialog ~= nil and InfoDialog.show ~= nil then
            local message = reason
            if FieldToDoL10n ~= nil and FieldToDoL10n.getText ~= nil then
                message = FieldToDoL10n.getText("ftdl_edit_denied", "No permission to change to-dos")
                if reason ~= nil and reason ~= "" and reason ~= "denied" then
                    message = message .. " (" .. reason .. ")"
                end
            end
            pcall(InfoDialog.show, message)
        end
        return
    end

    local manager = FieldToDoSync.getManager()
    if manager == nil then
        return
    end

    local notifyFarmId = tonumber(payload.farmId)
    local localFarm = nil
    if manager.getLocalFarmId ~= nil then
        localFarm = manager:getLocalFarmId()
    end

    -- Multi-farm safety: never apply another farm's notify into this peer's state.
    if localFarm ~= nil and notifyFarmId ~= nil and notifyFarmId ~= localFarm then
        if FieldToDoLog ~= nil then
            FieldToDoLog.warning(
                "FieldToDoSync: drop notify op=%s notifyFarmId=%s localFarm=%s",
                tostring(op),
                tostring(notifyFarmId),
                tostring(localFarm)
            )
        end
        return
    end

    local applied = FieldToDoSync.applyOp(manager, op, payload, notifyFarmId, nil)
    if applied then
        recordSyncDebug("lastNotify", op, nil, notifyFarmId or localFarm)
        FieldToDoSync.refreshAfterNotify(op)
    elseif FieldToDoLog ~= nil then
        FieldToDoLog.warning(
            "FieldToDoSync: applyNotify failed op=%s farmId=%s taskId=%s",
            tostring(op),
            tostring(notifyFarmId or localFarm),
            tostring(payload.taskId)
        )
    end
end

--- Refresh ESC/HUD after a successful mutation notify (fixes silent adopt on MP client).
---@param op number|nil
function FieldToDoSync.refreshAfterNotify(op)
    local manager = FieldToDoSync.getManager()
    if manager ~= nil then
        if manager.markManualTasksDirty ~= nil then
            manager:markManualTasksDirty()
        end
        if op == OP.SET_PLANNED_CROP or op == OP.SET_PRESET or op == OP.SET_ORGANIC or op == OP.SET_MULCH then
            if manager.markOwnedFieldsOverviewStale ~= nil then
                manager:markOwnedFieldsOverviewStale()
            end
        end
    end

    if FieldToDoHudOverlay ~= nil and FieldToDoHudOverlay.instance ~= nil then
        FieldToDoHudOverlay.instance.displayRows = {}
    end

    if FieldToDoInGameMenuIntegration ~= nil and FieldToDoInGameMenuIntegration.menuScreen ~= nil then
        local screen = FieldToDoInGameMenuIntegration.menuScreen
        if screen.refreshManualTaskList ~= nil then
            pcall(screen.refreshManualTaskList, screen, false, true)
        end
        if screen.updateEditPermissionUi ~= nil then
            pcall(screen.updateEditPermissionUi, screen)
        end
    end
end

--- Log sync/farm/edit diagnostics for ftdlSync.
function FieldToDoSync.dumpDebugSummary()
    local function fmtEntry(entry)
        if entry == nil then
            return "nil"
        end
        return string.format(
            "op=%s reason=%s farmId=%s time=%s",
            tostring(entry.op),
            tostring(entry.reason),
            tostring(entry.farmId),
            tostring(entry.time)
        )
    end

    local manager = FieldToDoSync.getManager()
    local farmId = nil
    if FieldToDoPermissions ~= nil and FieldToDoPermissions.resolveLocalFarmId ~= nil then
        farmId = FieldToDoPermissions.resolveLocalFarmId()
    end
    if farmId == nil and manager ~= nil and manager.getLocalFarmId ~= nil then
        farmId = manager:getLocalFarmId()
    end

    local canEdit = FieldToDoPermissions ~= nil and FieldToDoPermissions.canEditLocal ~= nil
        and FieldToDoPermissions.canEditLocal() or false
    local isServer = FieldToDoSync.isRunningAsServer()
    local isClient = g_client ~= nil
    local dedicated = g_dedicatedServer ~= nil

    if FieldToDoLog ~= nil then
        FieldToDoLog.info("SYNC schema=%s isServer=%s isClient=%s dedicated=%s farmId=%s manager=%s canEdit=%s",
            tostring(FieldToDoSync.SCHEMA_VERSION),
            tostring(isServer),
            tostring(isClient),
            tostring(dedicated),
            tostring(farmId),
            tostring(manager ~= nil),
            tostring(canEdit)
        )
        FieldToDoLog.info("SYNC lastRequest %s", fmtEntry(FieldToDoSync.lastRequest))
        FieldToDoLog.info("SYNC lastDeny %s", fmtEntry(FieldToDoSync.lastDeny))
        FieldToDoLog.info("SYNC lastNotify %s", fmtEntry(FieldToDoSync.lastNotify))
    end
end

--- Server -> all clients (requester included). SP (no g_server) applies locally via applyNotify.
---@param op number
---@param payload table
---@param farmId number|nil
---@param excludeConnection table|nil optional connection to skip (unused; kept for API compat)
function FieldToDoSync.broadcastNotify(op, payload, farmId, excludeConnection)
    payload = payload or {}
    payload.farmId = payload.farmId or farmId

    if g_server == nil then
        FieldToDoSync.applyNotify(op, payload)
        return
    end

    if FieldToDoNotifyEvent == nil then
        return
    end

    g_server:broadcastEvent(FieldToDoNotifyEvent.new(op, payload), false, excludeConnection, nil)
end

-- ============================================================================
-- Full-state sync.
-- ============================================================================

---@param farmId number|nil
---@return table state
function FieldToDoSync.buildStateForFarm(farmId)
    farmId = tonumber(farmId)

    local todoEditDefaultAllow = true
    local todoEditUsers = {}
    local manager = FieldToDoSync.getManager()
    if manager ~= nil and farmId ~= nil and manager.getTodoEditStateForFarm ~= nil then
        local editState = manager:getTodoEditStateForFarm(farmId)
        if editState ~= nil then
            todoEditDefaultAllow = editState.defaultAllow ~= false
            for uniqueUserId, mayEdit in pairs(editState.byUniqueUserId or {}) do
                todoEditUsers[#todoEditUsers + 1] = {
                    uniqueUserId = tostring(uniqueUserId),
                    mayEdit = mayEdit == true,
                }
            end
        end
    elseif FieldAdvisorSettings ~= nil then
        todoEditDefaultAllow = FieldAdvisorSettings.todoEditDefaultAllow ~= false
        for uniqueUserId, mayEdit in pairs(FieldAdvisorSettings.todoEditByUniqueUserId or {}) do
            todoEditUsers[#todoEditUsers + 1] = {
                uniqueUserId = tostring(uniqueUserId),
                mayEdit = mayEdit == true,
            }
        end
    end

    local state = {
        schemaVersion = FieldToDoSync.SCHEMA_VERSION,
        farmId = farmId,
        workOrderPreset = FieldAdvisorSettings ~= nil and FieldAdvisorSettings.getWorkOrderPreset() or nil,
        organicMultiPassEnabled = FieldAdvisorSettings ~= nil and FieldAdvisorSettings.isOrganicMultiPassEnabled() or false,
        mulchingEnabled = FieldAdvisorSettings == nil or FieldAdvisorSettings.isMulchingEnabled(),
        workersMayEditTodos = todoEditDefaultAllow,
        todoEditDefaultAllow = todoEditDefaultAllow,
        todoEditUsers = todoEditUsers,
        plannedCrops = {},
        tasks = {},
    }

    if FieldPlannedCrop ~= nil and FieldPlannedCrop.byFieldId ~= nil then
        for fieldId, fruitTypeIndex in pairs(FieldPlannedCrop.byFieldId) do
            state.plannedCrops[#state.plannedCrops + 1] = { fieldId = fieldId, fruitTypeIndex = fruitTypeIndex }
        end
    end

    if manager ~= nil and manager.manualTasks ~= nil and farmId ~= nil then
        for _, task in pairs(manager.manualTasks) do
            if tonumber(task.farmId) == farmId then
                state.tasks[#state.tasks + 1] = FieldToDoSync.copyTaskForState(task)
            end
        end
        if manager.nextTaskId ~= nil then
            state.nextTaskId = manager.nextTaskId
        end
    end

    return state
end

--- Replaces this farm's local tasks + shared settings + planned crops from a received state.
---@param state table
function FieldToDoSync.applyState(state)
    if type(state) ~= "table" then
        return
    end

    if state.schemaVersion ~= nil
        and not FieldToDoSync.isCompatibleSchemaVersion(state.schemaVersion) then
        if FieldToDoLog ~= nil then
            FieldToDoLog.warning(
                "FieldToDoSync.applyState: schema mismatch (got %s want %s)",
                tostring(state.schemaVersion),
                tostring(FieldToDoSync.SCHEMA_VERSION)
            )
        end
        return
    end

    local manager = FieldToDoSync.getManager()
    if manager == nil or manager.manualTasks == nil then
        return
    end

    local farmId = tonumber(state.farmId)
    local localFarm = nil
    if manager.getLocalFarmId ~= nil then
        localFarm = manager:getLocalFarmId()
    end

    -- Ignore full-state for a different farm (or empty farm before join).
    if localFarm ~= nil and (farmId == nil or farmId ~= localFarm) then
        return
    end

    if farmId ~= nil then
        for taskId, task in pairs(manager.manualTasks) do
            if tonumber(task.farmId) == farmId then
                manager.manualTasks[taskId] = nil
            end
        end
    end

    if type(state.tasks) == "table" then
        for _, task in ipairs(state.tasks) do
            if task.id ~= nil then
                manager.manualTasks[task.id] = task
                if manager.nextTaskId ~= nil and task.id >= manager.nextTaskId then
                    manager.nextTaskId = task.id + 1
                end
            end
        end
    end

    if farmId ~= nil and manager.getTodoEditStateForFarm ~= nil then
        local editState = manager:getTodoEditStateForFarm(farmId)
        local defaultAllow = state.todoEditDefaultAllow
        if defaultAllow == nil then
            defaultAllow = state.workersMayEditTodos ~= false
        end
        editState.defaultAllow = defaultAllow
        editState.byUniqueUserId = {}
        if type(state.todoEditUsers) == "table" then
            for _, entry in ipairs(state.todoEditUsers) do
                local uniqueUserId = entry.uniqueUserId ~= nil and tostring(entry.uniqueUserId) or ""
                if uniqueUserId ~= "" then
                    editState.byUniqueUserId[uniqueUserId] = entry.mayEdit == true
                end
            end
        end
        if manager.syncTodoEditSettingsCache ~= nil then
            manager:syncTodoEditSettingsCache(farmId)
        end
    end

    if FieldAdvisorSettings ~= nil then
        if not string.isNilOrWhitespace(state.workOrderPreset) then
            FieldAdvisorSettings.setWorkOrderPreset(state.workOrderPreset)
        end
        FieldAdvisorSettings.setOrganicMultiPassEnabled(state.organicMultiPassEnabled == true)
        FieldAdvisorSettings.setMulchingEnabled(state.mulchingEnabled ~= false)
    end

    if FieldPlannedCrop ~= nil and type(state.plannedCrops) == "table" then
        for _, entry in ipairs(state.plannedCrops) do
            FieldPlannedCrop.set(entry.fieldId, entry.fruitTypeIndex)
        end
    end

    if manager.normalizeTaskSortIndices ~= nil then
        manager:normalizeTaskSortIndices()
    end

    FieldToDoSync.refreshAfterStateSync()
end

--- Mark menu/HUD stale after a full-state replace (join or farm switch).
function FieldToDoSync.refreshAfterStateSync()
    local manager = FieldToDoSync.getManager()
    if manager ~= nil then
        if manager.markManualTasksDirty ~= nil then
            manager:markManualTasksDirty()
        end
        if manager.markOwnedFieldsOverviewStale ~= nil then
            manager:markOwnedFieldsOverviewStale()
        end
    end

    if FieldToDoHudOverlay ~= nil and FieldToDoHudOverlay.instance ~= nil then
        FieldToDoHudOverlay.instance.displayRows = {}
    end
end

--- Server -> one connection (on join / manual resync).
---@param connection table
---@param farmId number|nil
function FieldToDoSync.sendStateToConnection(connection, farmId)
    if connection == nil or FieldToDoStateEvent == nil then
        return
    end

    local state = FieldToDoSync.buildStateForFarm(farmId)
    connection:sendEvent(FieldToDoStateEvent.new(state))
end

--- Client-side resync request (join or farm change).
function FieldToDoSync.requestFullState()
    if FieldToDoSync.isRunningAsServer() then
        return
    end

    if g_client == nil or g_client.getServerConnection == nil or FieldToDoRequestEvent == nil then
        return
    end

    local connection = g_client:getServerConnection()
    if connection == nil then
        return
    end

    connection:sendEvent(FieldToDoRequestEvent.new(OP.REQUEST_STATE, {}))
end

--- Non-host clients request authoritative farm state after savegame load.
function FieldToDoSync.onMissionStarted()
    if FieldToDoPermissions ~= nil and FieldToDoPermissions.registerFarmPermission ~= nil then
        FieldToDoPermissions._farmPermissionRegistered = false
        FieldToDoPermissions.registerFarmPermission()
    end

    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer() then
        return
    end

    FieldToDoSync.requestFullState()
end

--- Local player switched farm — pull fresh state for the new farm.
function FieldToDoSync.onPlayerFarmChanged()
    FieldToDoSync.requestFullState()
    FieldToDoSync.refreshAfterStateSync()
end
