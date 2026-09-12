--[[
    ToDoManager.lua
    Manual task storage, savegame I/O hooks, and mod lifecycle.

    Two update paths (do not merge):
      Overview scan — incremental owned-fields fill-in while menu tab is open (tickOwnedFieldsScan).
      Auto-complete — updateAutoCompletion ~1 s; only fields with open trackable tasks; on complete
        refresh that row via refreshFieldRecordSync (not a full cache invalidate).
]]

---@class ToDoManager
---@field mission table
---@field modDirectory string
---@field modName string
---@field fieldScanner FieldScanner
---@field manualTasks table<number, table>
---@field nextTaskId number
---@field autoCheckTimer number
ToDoManager = {}
local ToDoManager_mt = Class(ToDoManager)

ToDoManager.XML_KEY = "fieldToDoList"
ToDoManager.XML_FILENAME = "fieldToDoList.xml"
ToDoManager.AUTO_CHECK_INTERVAL_MS = 1000
ToDoManager.OWNED_FIELDS_CACHE_MS = 4000
--- Fields per scan batch; menu tick runs up to 2 batches per frame (see FieldToDoMenuFrame:onFrameUpdate).
ToDoManager.OWNED_FIELDS_SCAN_BATCH_SIZE = 5
--- Milliseconds between scan batches while the overview tab is open.
ToDoManager.OWNED_FIELDS_SCAN_INTERVAL_MS = 40
ToDoManager.OWNED_FIELDS_MENU_RESCAN_MS = 15000
ToDoManager.SAVE_DEBOUNCE_MS = 2000
--- Keep at most this many completed rows; oldest completed (lowest sortIndex) is removed.
ToDoManager.MAX_COMPLETED_TASKS = 10

local xmlSchema = nil

---@param mission table
---@param modDirectory string
---@param modName string
---@return ToDoManager
function ToDoManager.new(mission, modDirectory, modName)
    local self = setmetatable({}, ToDoManager_mt)

    self.mission = mission
    self.modDirectory = modDirectory
    self.modName = modName
    self.fieldScanner = FieldScanner.new(mission, modDirectory)
    self.manualTasks = {}
    self.nextTaskId = 1
    self.nextSortIndex = 0
    self.autoCheckTimer = 0
    self.saveDebounceMs = nil
    self.didEnsureCompletionBaselines = false
    self.ownedFieldsCache = nil
    self.ownedFieldsCacheAt = -1
    self.fieldAutoCheckCache = {}
    self.ownedFieldsScanQueue = nil
    self.ownedFieldsScanIndex = 1
    self.ownedFieldsScanInProgress = false
    self.ownedFieldsScanActive = false
    self.ownedFieldsScanTimer = 0
    self.ownedFieldsCacheById = nil
    self.ownedFieldsScanDirty = false
    self.ownedFieldsOverviewStale = false
    self.manualTasksDirty = false
    self.todoEditByFarmId = {}

    return self
end

function ToDoManager:markManualTasksDirty()
    self.manualTasksDirty = true
end

---@return boolean
function ToDoManager:consumeManualTasksDirty()
    if self.manualTasksDirty ~= true then
        return false
    end

    self.manualTasksDirty = false
    return true
end

---@param task table
function ToDoManager:assignSortIndex(task)
    self.nextSortIndex = (self.nextSortIndex or 0) + 1
    task.sortIndex = self.nextSortIndex
end

--- Insert a new open task at the top of the open group (lowest sortIndex).
---@param task table
function ToDoManager:assignSortIndexAtTop(task)
    for _, existing in pairs(self.manualTasks) do
        if existing.id ~= task.id and existing.completed ~= true then
            existing.sortIndex = (tonumber(existing.sortIndex) or existing.id) + 1
        end
    end

    task.sortIndex = 1
    self.nextSortIndex = (self.nextSortIndex or 0) + 1
end

function ToDoManager:normalizeTaskSortIndices()
    local open = {}
    local done = {}

    for _, task in pairs(self.manualTasks) do
        if task.completed == true then
            done[#done + 1] = task
        else
            open[#open + 1] = task
        end
    end

    -- Open tasks: keep ascending sortIndex (top→bottom).
    table.sort(open, function(a, b)
        return (tonumber(a.sortIndex) or a.id) < (tonumber(b.sortIndex) or b.id)
    end)

    -- Completed tasks: oldest first, so newest ends up with the highest sortIndex.
    table.sort(done, function(a, b)
        return (tonumber(a.sortIndex) or a.id) < (tonumber(b.sortIndex) or b.id)
    end)

    local index = 0
    for _, task in ipairs(open) do
        index = index + 1
        task.sortIndex = index
    end
    for _, task in ipairs(done) do
        index = index + 1
        task.sortIndex = index
    end

    self.nextSortIndex = index
end

---@param a table
---@param b table
---@return boolean
function ToDoManager.compareTasksForDisplay(a, b)
    if a.completed ~= b.completed then
        return not a.completed and b.completed
    end

    local sortA = tonumber(a.sortIndex) or a.id
    local sortB = tonumber(b.sortIndex) or b.id
    if sortA ~= sortB then
        -- Completed tasks show newest first (top of done pile).
        if a.completed == true then
            return sortA > sortB
        end

        return sortA < sortB
    end

    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
end

---@return table[]
function ToDoManager:collectCompletedTasks()
    local completed = {}

    for _, task in pairs(self.manualTasks) do
        if task.completed == true and self:taskBelongsToLocalFarm(task) then
            completed[#completed + 1] = task
        end
    end

    table.sort(completed, function(a, b)
        local sortA = tonumber(a.sortIndex) or a.id
        local sortB = tonumber(b.sortIndex) or b.id
        if sortA ~= sortB then
            return sortA < sortB
        end

        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)

    return completed
end

--- Remove oldest completed tasks (lowest sortIndex = bottom of the done pile).
function ToDoManager:pruneCompletedTasks()
    local completed = self:collectCompletedTasks()
    local limit = ToDoManager.MAX_COMPLETED_TASKS

    while #completed > limit do
        local oldest = completed[1]
        self.manualTasks[oldest.id] = nil
        table.remove(completed, 1)

        if FieldToDoLog ~= nil then
            FieldToDoLog.info("Removed oldest completed task (id %d, max %d kept)", oldest.id, limit)
        end
    end
end

--- Move a newly completed task to the end of the list (below open items, after other done rows).
---@param task table
function ToDoManager:onTaskMarkedComplete(task)
    if task == nil then
        return
    end

    task.completed = true
    self:assignSortIndex(task)
    self:pruneCompletedTasks()
    if task.source == "field" then
        self:invalidateFieldAutoCheckCache(tonumber(task.fieldId))
    end
end

function ToDoManager:delete()
    if self.fieldScanner ~= nil then
        self.fieldScanner:delete()
        self.fieldScanner = nil
    end

    self.mission = nil
    self.manualTasks = nil
end

---@return number|nil
function ToDoManager:getLocalFarmId()
    local mission = self.mission or g_currentMission
    if mission == nil or mission.getFarmId == nil then
        return nil
    end

    local ok, farmId = pcall(mission.getFarmId, mission)
    farmId = tonumber(farmId)
    if ok and farmId ~= nil and farmId > 0 then
        return farmId
    end

    return nil
end

--- True when this peer may write fieldToDoList.xml (server / host only).
---@return boolean
function ToDoManager:canPersistSidecar()
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil then
        return g_currentMission:getIsServer() == true
    end

    return g_server ~= nil
end

---@param farmId number|nil
---@return table|nil
function ToDoManager:getTodoEditStateForFarm(farmId)
    farmId = tonumber(farmId)
    if farmId == nil then
        return nil
    end

    local state = self.todoEditByFarmId[farmId]
    if state == nil then
        state = {
            defaultAllow = true,
            byUniqueUserId = {},
        }
        self.todoEditByFarmId[farmId] = state
    end

    return state
end

--- Copy farm-scoped edit map into FieldAdvisorSettings when it is the local farm.
---@param farmId number|nil
function ToDoManager:syncTodoEditSettingsCache(farmId)
    farmId = tonumber(farmId)
    if farmId == nil or FieldAdvisorSettings == nil then
        return
    end

    local localFarm = self:getLocalFarmId()
    if localFarm == nil or farmId ~= localFarm then
        return
    end

    local state = self:getTodoEditStateForFarm(farmId)
    if state == nil then
        return
    end

    FieldAdvisorSettings.todoEditDefaultAllow = state.defaultAllow ~= false
    FieldAdvisorSettings.workersMayEditTodos = FieldAdvisorSettings.todoEditDefaultAllow
    FieldAdvisorSettings.todoEditByUniqueUserId = {}
    for uniqueUserId, mayEdit in pairs(state.byUniqueUserId) do
        FieldAdvisorSettings.todoEditByUniqueUserId[tostring(uniqueUserId)] = mayEdit == true
    end
end

--- Before writing: replace in-memory tasks of *other* farms with the disk copy so a local
--- save does not erase another farm's list (listen-server / multi-client).
---@param savegameDirectory string
function ToDoManager:syncForeignFarmTasksFromDisk(savegameDirectory)
    local localFarm = self:getLocalFarmId()
    if localFarm == nil or string.isNilOrWhitespace(savegameDirectory) then
        return
    end

    local filePath = savegameDirectory .. "/" .. ToDoManager.XML_FILENAME
    if not fileExists(filePath) then
        return
    end

    ToDoManager.initXMLSchema()
    local xmlFile = XMLFile.load("fieldToDoListMerge", filePath, xmlSchema)
    if xmlFile == nil then
        return
    end

    local diskForeign = {}
    local index = 0
    while true do
        local taskKey = string.format("%s.tasks.task(%d)", ToDoManager.XML_KEY, index)
        local task = self:loadTaskFromXML(xmlFile, taskKey)
        if task == nil then
            break
        end

        local taskFarm = tonumber(task.farmId)
        if taskFarm ~= nil and taskFarm ~= localFarm then
            diskForeign[task.id] = task
        end
        index = index + 1
    end
    xmlFile:delete()

    for taskId, task in pairs(self.manualTasks) do
        local taskFarm = tonumber(task.farmId)
        if taskFarm ~= nil and taskFarm ~= localFarm then
            self.manualTasks[taskId] = nil
        end
    end

    for taskId, task in pairs(diskForeign) do
        self.manualTasks[taskId] = task
        if task.id >= self.nextTaskId then
            self.nextTaskId = task.id + 1
        end
    end
end

--- Before writing: keep other farms' todoEdit maps from disk (listen-server multi-farm).
---@param savegameDirectory string
function ToDoManager:syncForeignFarmTodoEditFromDisk(savegameDirectory)
    local localFarm = self:getLocalFarmId()
    if localFarm == nil or string.isNilOrWhitespace(savegameDirectory) then
        return
    end

    local filePath = savegameDirectory .. "/" .. ToDoManager.XML_FILENAME
    if not fileExists(filePath) then
        return
    end

    ToDoManager.initXMLSchema()
    local xmlFile = XMLFile.load("fieldToDoListEditMerge", filePath, xmlSchema)
    if xmlFile == nil then
        return
    end

    local diskForeign = {}
    local index = 0
    while true do
        local farmKey = string.format("%s.farmTodoEdit(%d)", ToDoManager.XML_KEY, index)
        local farmId = tonumber(xmlFile:getValue(farmKey .. "#farmId"))
        if farmId == nil then
            break
        end

        if farmId ~= localFarm then
            local defaultAllow = xmlFile:getValue(farmKey .. "#defaultAllow")
            local state = {
                defaultAllow = defaultAllow ~= false,
                byUniqueUserId = {},
            }

            local userIndex = 0
            while true do
                local userKey = string.format("%s.user(%d)", farmKey, userIndex)
                local uniqueUserId = xmlFile:getValue(userKey .. "#uniqueUserId")
                if uniqueUserId == nil or uniqueUserId == "" then
                    break
                end

                state.byUniqueUserId[tostring(uniqueUserId)] = xmlFile:getValue(userKey .. "#mayEdit") == true
                userIndex = userIndex + 1
            end

            diskForeign[farmId] = state
        end

        index = index + 1
    end
    xmlFile:delete()

    for farmId in pairs(self.todoEditByFarmId) do
        if farmId ~= localFarm then
            self.todoEditByFarmId[farmId] = nil
        end
    end

    for farmId, state in pairs(diskForeign) do
        self.todoEditByFarmId[farmId] = state
    end
end

--- Assign local farmId to legacy tasks missing it (once a local farm is known).
function ToDoManager:migrateOrphanTaskFarmIds()
    local localFarm = self:getLocalFarmId()
    if localFarm == nil then
        return
    end

    for _, task in pairs(self.manualTasks) do
        if task.farmId == nil then
            task.farmId = localFarm
        end
    end
end

--- Tasks without farmId are hidden once a local farm is known (assign on load/save).
---@param task table|nil
---@return boolean
function ToDoManager:taskBelongsToLocalFarm(task)
    if task == nil then
        return false
    end

    local taskFarm = tonumber(task.farmId)
    local localFarm = self:getLocalFarmId()
    if taskFarm == nil then
        return localFarm == nil
    end

    if localFarm == nil then
        return true
    end

    return taskFarm == localFarm
end

---@param task table|nil
---@param farmId number|nil
---@return boolean
function ToDoManager:taskBelongsToFarm(task, farmId)
    if task == nil then
        return false
    end

    farmId = tonumber(farmId)
    if farmId == nil then
        return self:taskBelongsToLocalFarm(task)
    end

    local taskFarm = tonumber(task.farmId)
    if taskFarm == nil then
        return true
    end

    return taskFarm == farmId
end

---@param farmId number|nil
---@return table[] tasks
function ToDoManager:getManualTasksForFarm(farmId)
    local tasks = {}

    for _, task in pairs(self.manualTasks) do
        if self:taskBelongsToFarm(task, farmId) then
            tasks[#tasks + 1] = task
        end
    end

    table.sort(tasks, ToDoManager.compareTasksForDisplay)

    return tasks
end

---@return table[] tasks
function ToDoManager:getAllManualTasks()
    local tasks = {}

    for _, task in pairs(self.manualTasks) do
        table.insert(tasks, task)
    end

    table.sort(tasks, ToDoManager.compareTasksForDisplay)

    return tasks
end

---@return table[] tasks
function ToDoManager:getManualTasks()
    local tasks = {}

    for _, task in pairs(self.manualTasks) do
        if self:taskBelongsToLocalFarm(task) then
            table.insert(tasks, task)
        end
    end

    table.sort(tasks, ToDoManager.compareTasksForDisplay)

    return tasks
end

--- Same order as the ESC list (manual sortIndex, not work-order preset).
---@return table[] tasks
function ToDoManager:getManualTasksForDisplay()
    return self:getManualTasks()
end

---@param taskId number
---@param delta number
---@return boolean
function ToDoManager:moveTask(taskId, delta)
    if FieldToDoSync ~= nil then
        FieldToDoSync.request(FieldToDoSync.OP.MOVE, { taskId = taskId, delta = delta })
        return true
    end

    return self:applyMoveTask({ taskId = taskId, delta = delta }, self:getLocalFarmId(), nil) ~= nil
end

--- Schedule a sidecar write after task edits (debounced).
function ToDoManager:requestDebouncedSave()
    self.saveDebounceMs = ToDoManager.SAVE_DEBOUNCE_MS
end

---@return boolean
function ToDoManager:isMissionSaving()
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

--- Persist tasks and advisor settings without waiting for a full savegame write.
---@return boolean
function ToDoManager:saveSettingsNow()
    if not self:canPersistSidecar() then
        return false
    end

    if self:isMissionSaving() then
        self:requestDebouncedSave()
        return false
    end

    if self.mission == nil or self.mission.missionInfo == nil then
        return false
    end

    if self.mission.missionInfo.isValid ~= true then
        return false
    end

    local savegameDirectory = self.mission.missionInfo.savegameDirectory
    if savegameDirectory == nil or savegameDirectory == "" then
        return false
    end

    local ok, result = pcall(self.saveToSavegameDirectory, self, savegameDirectory)
    if not ok then
        if FieldToDoLog ~= nil then
            FieldToDoLog.error("fieldToDoList.xml: saveSettingsNow failed (%s)", tostring(result))
        end
        return false
    end

    return result == true
end

---@return table[] fields
function ToDoManager:invalidateOwnedFieldsCache()
    self.ownedFieldsCache = nil
    self.ownedFieldsCacheAt = -1
    self.ownedFieldsScanQueue = nil
    self.ownedFieldsScanIndex = 1
    self.ownedFieldsScanInProgress = false
    self.ownedFieldsCacheById = nil
    self.ownedFieldsScanDirty = false
    self.ownedFieldsOverviewStale = false
end

--- Mark overview data stale (growth day, farmland bought/sold). Refreshes immediately when menu tab is open.
function ToDoManager:markOwnedFieldsOverviewStale()
    self.ownedFieldsOverviewStale = true
    if self.ownedFieldsScanActive ~= true then
        return
    end

    -- Do not reset a running incremental scan; apply after it finishes.
    if self.ownedFieldsScanInProgress == true then
        return
    end

    self:invalidateOwnedFieldsCache()
end

---@return boolean
function ToDoManager:consumeOwnedFieldsOverviewStale()
    if self.ownedFieldsOverviewStale ~= true then
        return false
    end

    self.ownedFieldsOverviewStale = false
    return true
end

---@param active boolean
function ToDoManager:setOwnedFieldsScanActive(active)
    self.ownedFieldsScanActive = active == true
end

---@return boolean
function ToDoManager:isOwnedFieldsScanInProgress()
    return self.ownedFieldsScanInProgress == true
end

---@return boolean
function ToDoManager:isOwnedFieldsScanDirty()
    return self.ownedFieldsScanDirty == true
end

---@return number done
---@return number total
---@return boolean inProgress
function ToDoManager:getOwnedFieldsScanProgress()
    if self.ownedFieldsScanInProgress ~= true then
        local total = self.ownedFieldsCache ~= nil and #self.ownedFieldsCache or 0
        return total, total, false
    end

    local queue = self.ownedFieldsScanQueue or {}
    local total = #queue
    local done = math.max(0, (self.ownedFieldsScanIndex or 1) - 1)
    return done, total, true
end

---@return boolean
function ToDoManager:consumeOwnedFieldsScanDirty()
    if self.ownedFieldsScanDirty ~= true then
        return false
    end

    self.ownedFieldsScanDirty = false
    return true
end

---@param dt number
---@param maxBatchesPerTick number|nil
---@return boolean
function ToDoManager:tickOwnedFieldsScan(dt, maxBatchesPerTick)
    if self.ownedFieldsScanActive ~= true or self.ownedFieldsScanInProgress ~= true then
        return false
    end

    local batchLimit = math.max(1, math.floor(tonumber(maxBatchesPerTick) or 1))
    self.ownedFieldsScanTimer = (self.ownedFieldsScanTimer or 0) + dt
    local changed = false
    local batches = 0

    while self.ownedFieldsScanInProgress
        and self.ownedFieldsScanTimer >= ToDoManager.OWNED_FIELDS_SCAN_INTERVAL_MS
        and batches < batchLimit do
        self.ownedFieldsScanTimer = self.ownedFieldsScanTimer - ToDoManager.OWNED_FIELDS_SCAN_INTERVAL_MS
        if self:advanceOwnedFieldsScan() then
            changed = true
        end
        batches = batches + 1
    end

    return changed
end

function ToDoManager:startOwnedFieldsScan()
    if self.fieldScanner == nil then
        self.ownedFieldsScanInProgress = false
        self.ownedFieldsCache = {}
        self.ownedFieldsCacheAt = g_time or 0
        return
    end

    self.ownedFieldsScanQueue = self.fieldScanner:collectOwnedFieldCandidates()
    self.ownedFieldsScanIndex = 1
    self.ownedFieldsScanInProgress = #self.ownedFieldsScanQueue > 0
    self.ownedFieldsCacheById = {}
    self.ownedFieldsScanLoggedStart = false

    if self.ownedFieldsCache ~= nil then
        for _, record in ipairs(self.ownedFieldsCache) do
            if record ~= nil and record.id ~= nil then
                self.ownedFieldsCacheById[record.id] = record
            end
        end
    end

    if not self.ownedFieldsScanInProgress then
        self.ownedFieldsCache = {}
        self.ownedFieldsCacheAt = g_time or 0
        self.ownedFieldsScanQueue = nil
        self.ownedFieldsCacheById = nil
    else
        self.ownedFieldsCache = self:buildOwnedFieldsSnapshot()
        self.ownedFieldsScanDirty = true
        if self.ownedFieldsScanLoggedStart ~= true and FieldToDoLog ~= nil then
            self.ownedFieldsScanLoggedStart = true
            FieldToDoLog.info(
                "Field overview scan started (%d field(s))",
                #self.ownedFieldsScanQueue
            )
        end
    end
end

---@return table[]
function ToDoManager:buildOwnedFieldsSnapshot()
    if self.fieldScanner == nil then
        return self.ownedFieldsCache or {}
    end

    local fields = {}
    local queue = self.ownedFieldsScanQueue
    local cacheById = self.ownedFieldsCacheById or {}

    if queue ~= nil then
        for _, candidate in ipairs(queue) do
            local record = cacheById[candidate.id]
            if record == nil then
                record = self.fieldScanner:buildPlaceholderFieldRecord(candidate)
            end
            if record ~= nil then
                fields[#fields + 1] = record
            end
        end
        return self.fieldScanner:sortFieldRecords(fields)
    end

    for _, record in pairs(cacheById) do
        fields[#fields + 1] = record
    end

    return self.fieldScanner:sortFieldRecords(fields)
end

---@param maxBatch number|nil
---@return boolean
function ToDoManager:advanceOwnedFieldsScan(maxBatch)
    if self.fieldScanner == nil or self.ownedFieldsScanInProgress ~= true then
        return false
    end

    local queue = self.ownedFieldsScanQueue
    if queue == nil or #queue == 0 then
        self.ownedFieldsScanInProgress = false
        return false
    end

    local batchSize = math.max(1, math.floor(tonumber(maxBatch) or ToDoManager.OWNED_FIELDS_SCAN_BATCH_SIZE))
    local scanIndex = self.ownedFieldsScanIndex or 1
    local processed = 0
    local changed = false

    while processed < batchSize and scanIndex <= #queue do
        local candidate = queue[scanIndex]
        local ok, record = pcall(function()
            return self.fieldScanner:normalizeField(candidate.field, candidate.forceInclude)
        end)
        if not ok then
            if FieldToDoLog ~= nil then
                FieldToDoLog.warning(
                    "Field overview scan error for field %s: %s",
                    tostring(candidate.id),
                    tostring(record)
                )
            end
        elseif record ~= nil then
            if self.ownedFieldsCacheById == nil then
                self.ownedFieldsCacheById = {}
            end
            self.ownedFieldsCacheById[record.id] = record
            changed = true
        end
        scanIndex = scanIndex + 1
        processed = processed + 1
    end

    self.ownedFieldsScanIndex = scanIndex

    if scanIndex > #queue then
        self.ownedFieldsScanInProgress = false
        self.ownedFieldsCache = self:buildOwnedFieldsSnapshot()
        self.ownedFieldsCacheAt = g_time or 0
        self.ownedFieldsScanQueue = nil
        self.ownedFieldsCacheById = nil
        self.ownedFieldsScanLoggedStart = false
        changed = true
        if FieldToDoLog ~= nil then
            FieldToDoLog.info("Field overview scan complete (%d field(s))", #queue)
        end
        if self.ownedFieldsOverviewStale == true then
            self:invalidateOwnedFieldsCache()
            self:startOwnedFieldsScan()
        end
    elseif changed then
        self.ownedFieldsCache = self:buildOwnedFieldsSnapshot()
    end

    if changed then
        self.ownedFieldsScanDirty = true
    end

    return changed
end

function ToDoManager:runOwnedFieldsScanImmediate()
    self:startOwnedFieldsScan()
    while self.ownedFieldsScanInProgress do
        self:advanceOwnedFieldsScan(9999)
    end
end

--- Re-probe one overview row after auto-complete (or task adopt on a pending placeholder).
---@param fieldId number|nil
---@return table|nil
function ToDoManager:refreshFieldRecordSync(fieldId)
    if fieldId == nil or self.fieldScanner == nil then
        return nil
    end

    local engineField = self.fieldScanner:getEngineFieldById(fieldId)
    if engineField == nil then
        return nil
    end

    local ok, record = pcall(function()
        return self.fieldScanner:normalizeField(engineField, true)
    end)
    if not ok or record == nil then
        return nil
    end

    if self.ownedFieldsCacheById ~= nil then
        self.ownedFieldsCacheById[fieldId] = record
        self.ownedFieldsCache = self:buildOwnedFieldsSnapshot()
        self.ownedFieldsScanDirty = true
    elseif self.ownedFieldsCache ~= nil then
        local replaced = false
        for index, existing in ipairs(self.ownedFieldsCache) do
            if existing.id == fieldId then
                self.ownedFieldsCache[index] = record
                replaced = true
                break
            end
        end
        if not replaced then
            self.ownedFieldsCache[#self.ownedFieldsCache + 1] = record
            self.ownedFieldsCache = self.fieldScanner:sortFieldRecords(self.ownedFieldsCache)
        end
    end

    return record
end

---@param fieldId number|nil
function ToDoManager:invalidateFieldAutoCheckCache(fieldId)
    if self.fieldAutoCheckCache == nil then
        self.fieldAutoCheckCache = {}
        return
    end

    if fieldId == nil then
        self.fieldAutoCheckCache = {}
        return
    end

    self.fieldAutoCheckCache[fieldId] = nil
end

---@param forceComplete boolean|nil
---@return table[] fields
function ToDoManager:getOwnedFields(forceComplete)
    if self.fieldScanner == nil then
        return {}
    end

    if forceComplete == true then
        self:runOwnedFieldsScanImmediate()
        return self.ownedFieldsCache or {}
    end

    local now = g_time or 0
    local cacheValid = self.ownedFieldsCache ~= nil
        and self.ownedFieldsCacheAt >= 0
        and self.ownedFieldsScanInProgress ~= true
        and now - self.ownedFieldsCacheAt <= ToDoManager.OWNED_FIELDS_CACHE_MS

    if cacheValid then
        return self.ownedFieldsCache
    end

    if self.ownedFieldsScanInProgress ~= true then
        self:startOwnedFieldsScan()
    end

    return self.ownedFieldsCache or {}
end

--- Copy task fields needed for sync notify / upsert.
---@param task table
---@return table
function ToDoManager:copyTaskForSync(task)
    if FieldToDoSync ~= nil and FieldToDoSync.copyTaskForState ~= nil then
        return FieldToDoSync.copyTaskForState(task)
    end

    return {
        id = task.id,
        sortIndex = task.sortIndex,
        text = task.text,
        completed = task.completed,
        source = task.source,
        autoComplete = task.autoComplete,
        farmId = task.farmId,
        fieldId = task.fieldId,
        fieldName = task.fieldName,
        fruit = task.fruit,
        actionType = task.actionType,
        fertPass = task.fertPass,
        fertPassTotal = task.fertPassTotal,
        suggestion = task.suggestion,
    }
end

--- Idempotent upsert by task.id (server notify + state apply).
---@param task table|nil
---@return table|nil
function ToDoManager:applyUpsertTask(task)
    if task == nil or task.id == nil then
        return nil
    end

    local isNew = self.manualTasks[task.id] == nil
    self.manualTasks[task.id] = task

    if task.id >= self.nextTaskId then
        self.nextTaskId = task.id + 1
    end

    if isNew and (tonumber(task.sortIndex) == nil or tonumber(task.sortIndex) == 0) then
        self:assignSortIndexAtTop(task)
    end

    if task.source == "field" and task.fieldId ~= nil then
        self:invalidateFieldAutoCheckCache(tonumber(task.fieldId))
    end

    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return task
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applyAddManualTask(payload, farmId, userId)
    payload = payload or {}

    local taskId = tonumber(payload.taskId) or (payload.task ~= nil and tonumber(payload.task.id)) or nil
    if taskId ~= nil and taskId > 0 then
        local task = payload.task or {
            id = taskId,
            sortIndex = payload.sortIndex,
            text = payload.text,
            completed = false,
            source = "manual",
            autoComplete = false,
            farmId = farmId,
        }
        task.farmId = farmId
        self:applyUpsertTask(task)
        return { task = self:copyTaskForSync(task), farmId = farmId, taskId = task.id, sortIndex = task.sortIndex, text = task.text }
    end

    local text = payload.text
    if string.isNilOrWhitespace(text) then
        return nil
    end

    farmId = tonumber(farmId) or self:getLocalFarmId()

    local task = {
        id = self.nextTaskId,
        text = text,
        completed = false,
        source = "manual",
        autoComplete = false,
        farmId = farmId,
    }

    self.manualTasks[task.id] = task
    self.nextTaskId = self.nextTaskId + 1
    self:assignSortIndexAtTop(task)
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return {
        task = self:copyTaskForSync(task),
        farmId = farmId,
        taskId = task.id,
        sortIndex = task.sortIndex,
        text = text,
    }
end

---@param fieldId number
---@param actionType string
---@param action table|nil
---@param farmId number|nil
---@return table|nil
function ToDoManager:findOpenFieldTaskForFarm(fieldId, actionType, action, farmId)
    local fertPass = action ~= nil and action.fertPass or nil

    for _, task in pairs(self.manualTasks) do
        if not task.completed
            and self:taskBelongsToFarm(task, farmId)
            and task.source == "field"
            and task.fieldId == fieldId
            and task.actionType == actionType
            and (tonumber(task.fertPass) or 1) == (tonumber(fertPass) or 1) then
            return task
        end
    end

    return nil
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applyAddFieldTask(payload, farmId, userId)
    payload = payload or {}

    local taskId = tonumber(payload.taskId) or (payload.task ~= nil and tonumber(payload.task.id)) or nil
    if taskId ~= nil and taskId > 0 then
        local task = payload.task
        if task == nil then
            task = {
                id = taskId,
                sortIndex = payload.sortIndex,
                text = payload.text,
                completed = false,
                source = "field",
                autoComplete = payload.autoComplete == true,
                farmId = farmId,
                fieldId = payload.fieldId,
                fieldName = payload.fieldName,
                fruit = payload.fruit,
                actionType = payload.actionType,
                fertPass = payload.fertPass,
                fertPassTotal = payload.fertPassTotal,
                suggestion = payload.suggestion,
            }
        end
        task.farmId = farmId
        self:applyUpsertTask(task)
        return { task = self:copyTaskForSync(task), farmId = farmId, taskId = task.id, sortIndex = task.sortIndex }
    end

    local actionType = payload.actionType or "none"
    if actionType == "none" or string.isNilOrWhitespace(payload.text) then
        return nil
    end

    farmId = tonumber(farmId) or self:getLocalFarmId()
    local fieldId = tonumber(payload.fieldId)
    if fieldId == nil then
        return nil
    end

    local existingTask = self:findOpenFieldTaskForFarm(fieldId, actionType, payload, farmId)
    if existingTask ~= nil then
        return { task = self:copyTaskForSync(existingTask), farmId = farmId, taskId = existingTask.id, sortIndex = existingTask.sortIndex }
    end

    local engineField = self.fieldScanner ~= nil and self.fieldScanner:getEngineFieldById(fieldId) or nil
    local task = {
        id = self.nextTaskId,
        text = payload.text,
        completed = false,
        source = "field",
        farmId = farmId,
        fieldId = fieldId,
        fieldName = payload.fieldName,
        fruit = payload.fruit,
        actionType = actionType,
        suggestion = payload.suggestion,
        autoComplete = payload.autoComplete == true,
        fertPass = payload.fertPass,
        fertPassTotal = payload.fertPassTotal,
        completionBaseline = FieldAdvisor ~= nil
            and engineField ~= nil
            and FieldAdvisor.captureTaskBaseline(engineField, fieldId, nil, nil)
            or nil,
    }

    self.manualTasks[task.id] = task
    self.nextTaskId = self.nextTaskId + 1
    self:assignSortIndexAtTop(task)
    self:invalidateFieldAutoCheckCache(fieldId)
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return {
        task = self:copyTaskForSync(task),
        farmId = farmId,
        taskId = task.id,
        sortIndex = task.sortIndex,
        text = task.text,
        fieldId = fieldId,
        actionType = actionType,
        autoComplete = task.autoComplete,
        fertPass = task.fertPass,
        fertPassTotal = task.fertPassTotal,
        fruit = task.fruit,
        fieldName = task.fieldName,
        suggestion = task.suggestion,
    }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applyUpdateTaskText(payload, farmId, userId)
    payload = payload or {}
    local taskId = tonumber(payload.taskId)
    local text = payload.text
    if taskId == nil or string.isNilOrWhitespace(text) then
        return nil
    end

    local task = self.manualTasks[taskId]
    if task == nil or not self:taskBelongsToFarm(task, farmId) then
        return nil
    end

    task.text = text
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return { taskId = taskId, text = text, farmId = farmId, task = self:copyTaskForSync(task) }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applyDeleteTask(payload, farmId, userId)
    payload = payload or {}
    local taskId = tonumber(payload.taskId)
    if taskId == nil then
        return nil
    end

    local task = self.manualTasks[taskId]
    -- Idempotent: already gone counts as success (avoids deny storms on lagging clients).
    if task == nil then
        return { taskId = taskId, farmId = farmId }
    end
    if not self:taskBelongsToFarm(task, farmId) then
        return nil
    end

    self.manualTasks[taskId] = nil
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return { taskId = taskId, farmId = farmId }
end

---@param payload table
---@param farmId number|nil
---@return table|nil
function ToDoManager:applyMoveTask(payload, farmId, userId)
    payload = payload or {}

    if type(payload.swapTasks) == "table" then
        for _, entry in ipairs(payload.swapTasks) do
            local task = self.manualTasks[tonumber(entry.id)]
            if task ~= nil and self:taskBelongsToFarm(task, farmId) and entry.sortIndex ~= nil then
                task.sortIndex = entry.sortIndex
            end
        end
        self:markManualTasksDirty()
        self:requestDebouncedSave()
        return { farmId = farmId, swapTasks = payload.swapTasks, taskId = payload.taskId, delta = payload.delta }
    end

    local taskId = tonumber(payload.taskId)
    local delta = payload.delta
    if taskId == nil or delta == nil or delta == 0 then
        return nil
    end

    local tasks = self:getManualTasksForFarm(farmId)
    local currentIndex = nil

    for index, task in ipairs(tasks) do
        if task.id == taskId then
            currentIndex = index
            break
        end
    end

    if currentIndex == nil then
        return nil
    end

    local targetIndex = currentIndex + math.floor(delta)
    if targetIndex < 1 or targetIndex > #tasks then
        return nil
    end

    local currentTask = tasks[currentIndex]
    local targetTask = tasks[targetIndex]

    if currentTask.completed ~= targetTask.completed then
        return nil
    end

    local currentSort = currentTask.sortIndex
    currentTask.sortIndex = targetTask.sortIndex
    targetTask.sortIndex = currentSort

    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return {
        farmId = farmId,
        taskId = taskId,
        delta = delta,
        swapTasks = {
            { id = currentTask.id, sortIndex = currentTask.sortIndex },
            { id = targetTask.id, sortIndex = targetTask.sortIndex },
        },
    }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applyToggleTaskDone(payload, farmId, userId)
    payload = payload or {}
    local taskId = tonumber(payload.taskId)
    if taskId == nil then
        return nil
    end

    local task = self.manualTasks[taskId]
    if task == nil or not self:taskBelongsToFarm(task, farmId) then
        return nil
    end

    if payload.completed ~= nil then
        if payload.completed == true then
            if not task.completed then
                self:onTaskMarkedComplete(task)
            elseif payload.sortIndex ~= nil and tonumber(payload.sortIndex) > 0 then
                task.sortIndex = payload.sortIndex
            end
        else
            task.completed = false
            if payload.sortIndex ~= nil and tonumber(payload.sortIndex) > 0 then
                task.sortIndex = payload.sortIndex
            else
                self:assignSortIndexAtTop(task)
            end
        end
    elseif task.completed then
        task.completed = false
        self:assignSortIndexAtTop(task)
    else
        self:onTaskMarkedComplete(task)
    end

    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return {
        taskId = taskId,
        completed = task.completed,
        sortIndex = task.sortIndex,
        farmId = farmId,
        task = self:copyTaskForSync(task),
    }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applyAutoCompleteTask(payload, farmId, userId)
    payload = payload or {}
    local taskId = tonumber(payload.taskId)
    if taskId == nil then
        return nil
    end

    local task = self.manualTasks[taskId]
    if task == nil or not self:taskBelongsToFarm(task, farmId) then
        return nil
    end

    if task.completed then
        return {
            taskId = taskId,
            completed = true,
            sortIndex = task.sortIndex,
            farmId = farmId,
            task = self:copyTaskForSync(task),
        }
    end

    self:onTaskMarkedComplete(task)
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return {
        taskId = taskId,
        completed = true,
        sortIndex = task.sortIndex,
        farmId = farmId,
        task = self:copyTaskForSync(task),
    }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applySetWorkOrderPreset(payload, farmId, userId)
    payload = payload or {}
    if FieldAdvisorSettings == nil or string.isNilOrWhitespace(payload.presetKey) then
        return nil
    end

    farmId = tonumber(farmId) or self:getLocalFarmId()
    local localFarm = self:getLocalFarmId()
    if localFarm == nil or farmId == localFarm then
        FieldAdvisorSettings.setWorkOrderPreset(payload.presetKey)
    end
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return { presetKey = payload.presetKey, farmId = farmId }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applySetOrganicMultiPass(payload, farmId, userId)
    payload = payload or {}
    if FieldAdvisorSettings == nil then
        return nil
    end

    farmId = tonumber(farmId) or self:getLocalFarmId()
    local localFarm = self:getLocalFarmId()
    if localFarm == nil or farmId == localFarm then
        FieldAdvisorSettings.setOrganicMultiPassEnabled(payload.enabled == true)
    end
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return { enabled = payload.enabled == true, farmId = farmId }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applySetMulching(payload, farmId, userId)
    payload = payload or {}
    if FieldAdvisorSettings == nil then
        return nil
    end

    farmId = tonumber(farmId) or self:getLocalFarmId()
    local localFarm = self:getLocalFarmId()
    if localFarm == nil or farmId == localFarm then
        FieldAdvisorSettings.setMulchingEnabled(payload.enabled ~= false)
    end
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return { enabled = payload.enabled ~= false, farmId = farmId }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applySetWorkersMayEdit(payload, farmId, userId)
    payload = payload or {}

    farmId = tonumber(farmId) or self:getLocalFarmId()
    local enabled = payload.enabled ~= false
    if farmId ~= nil then
        local state = self:getTodoEditStateForFarm(farmId)
        state.defaultAllow = enabled
    end
    self:syncTodoEditSettingsCache(farmId)
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return { enabled = enabled, farmId = farmId }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applySetUserTodoEdit(payload, farmId, userId)
    payload = payload or {}
    farmId = tonumber(farmId)
    local uniqueUserId = payload.uniqueUserId ~= nil and tostring(payload.uniqueUserId) or ""
    if farmId == nil or uniqueUserId == "" then
        return nil
    end

    local state = self:getTodoEditStateForFarm(farmId)
    state.byUniqueUserId[uniqueUserId] = payload.enabled == true
    self:syncTodoEditSettingsCache(farmId)
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return { farmId = farmId, uniqueUserId = uniqueUserId, enabled = payload.enabled == true }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applySetAllWorkersTodoEdit(payload, farmId, userId)
    payload = payload or {}
    farmId = tonumber(farmId)
    if farmId == nil then
        return nil
    end

    local enabled = payload.enabled == true
    local ids = payload.uniqueUserIds or {}
    local state = self:getTodoEditStateForFarm(farmId)
    state.defaultAllow = enabled
    for i = 1, #ids do
        local uid = tostring(ids[i])
        if uid ~= "" then
            state.byUniqueUserId[uid] = enabled
        end
    end
    self:syncTodoEditSettingsCache(farmId)
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return { farmId = farmId, enabled = enabled, uniqueUserIds = ids }
end

---@param payload table
---@param farmId number|nil
---@param userId number|nil
---@return table|nil
function ToDoManager:applySetPlannedCrop(payload, farmId, userId)
    payload = payload or {}
    if FieldPlannedCrop == nil then
        return nil
    end

    local fieldId = tonumber(payload.fieldId)
    local fruitTypeIndex = tonumber(payload.fruitTypeIndex)
    if fieldId == nil then
        return nil
    end

    FieldPlannedCrop.set(fieldId, fruitTypeIndex)
    self:markManualTasksDirty()
    self:requestDebouncedSave()

    return { fieldId = fieldId, fruitTypeIndex = fruitTypeIndex, farmId = farmId }
end

---@param text string
---@return table|nil task
function ToDoManager:addManualTask(text)
    if FieldToDoSync ~= nil then
        FieldToDoSync.request(FieldToDoSync.OP.ADD_MANUAL, { text = text })
        return nil
    end

    local result = self:applyAddManualTask({ text = text }, self:getLocalFarmId(), nil)
    if result == nil or result.task == nil then
        return nil
    end

    return self.manualTasks[result.task.id]
end

---@param fieldRecord table
---@param actionLabel string|nil
---@return string
function ToDoManager:buildFieldTaskText(fieldRecord, actionLabel, action)
    local fieldName = fieldRecord.name or string.format("Feld %s", tostring(fieldRecord.id or "?"))
    local fruit = fieldRecord.fruit
    local suggestion = actionLabel or fieldRecord.suggestion or "-"

    if action ~= nil and FieldAdvisor ~= nil and FieldAdvisor.getShortActionLabel ~= nil then
        suggestion = FieldAdvisor.getShortActionLabel(action)
    elseif suggestion ~= nil then
        suggestion = string.gsub(suggestion, " / gruppieren", "")
        suggestion = string.gsub(suggestion, " / Gruppieren", "")
    end

    -- Planned sow crop goes into the work step, not the current-field fruit column.
    if action ~= nil and action.actionType == "sow" then
        return string.format("%s: %s", fieldName, suggestion)
    end

    if fruit ~= nil and fruit ~= "" and fruit ~= "-" then
        return string.format("%s (%s): %s", fieldName, fruit, suggestion)
    end

    return string.format("%s: %s", fieldName, suggestion)
end

---@param fieldId number
---@param actionType string
---@param action table|nil
---@return table|nil
function ToDoManager:findOpenFieldTask(fieldId, actionType, action)
    local fertPass = action ~= nil and action.fertPass or nil

    for _, task in pairs(self.manualTasks) do
        if not task.completed
            and self:taskBelongsToLocalFarm(task)
            and task.source == "field"
            and task.fieldId == fieldId
            and task.actionType == actionType
            and (tonumber(task.fertPass) or 1) == (tonumber(fertPass) or 1) then
            return task
        end
    end

    return nil
end

---@param fieldRecord table
---@param action table|nil
---@param allowUntrackable boolean|nil manual reminders (grass_swath/collect) bypass not_trackable gate
---@return table|nil task
---@return string|nil errorKey
function ToDoManager:addTaskFromFieldAction(fieldRecord, action, allowUntrackable)
    if fieldRecord == nil then
        return nil, "missing_field"
    end

    if fieldRecord.pendingScan == true then
        fieldRecord = self:refreshFieldRecordSync(fieldRecord.id) or fieldRecord
    end

    if action == nil then
        action = {
            actionType = fieldRecord.actionType or "none",
            label = fieldRecord.suggestion or "-",
            autoComplete = fieldRecord.autoComplete == true,
        }
    end

    local actionType = action.actionType or "none"
    if actionType == "none" then
        return nil, "no_suggestion"
    end

    if allowUntrackable ~= true
        and (action.autoComplete ~= true or not FieldWorkCatalog.isTrackable(actionType)) then
        return nil, "not_trackable"
    end

    local existingTask = self:findOpenFieldTask(fieldRecord.id, actionType, action)
    if existingTask ~= nil then
        return existingTask, "already_exists"
    end

    local draft = {
        text = self:buildFieldTaskText(fieldRecord, action.label, action),
        source = "field",
        fieldId = fieldRecord.id,
        fieldName = fieldRecord.name,
        fruit = fieldRecord.fruit,
        actionType = actionType,
        fertPass = action.fertPass,
        fertPassTotal = action.fertPassTotal,
        suggestion = action.label,
        autoComplete = action.autoComplete == true,
    }

    if FieldToDoSync ~= nil then
        FieldToDoSync.request(FieldToDoSync.OP.ADD_FIELD, draft)
        return nil, nil
    end

    local result = self:applyAddFieldTask(draft, self:getLocalFarmId(), nil)
    if result == nil or result.task == nil then
        return nil, "apply_failed"
    end

    return self.manualTasks[result.task.id], nil
end

---@param fieldId number|nil
---@param fruitTypeIndex number|nil
function ToDoManager:setFieldPlannedSowFruit(fieldId, fruitTypeIndex)
    if FieldPlannedCrop == nil then
        return
    end

    if FieldToDoSync ~= nil then
        FieldToDoSync.request(FieldToDoSync.OP.SET_PLANNED_CROP, {
            fieldId = fieldId,
            fruitTypeIndex = fruitTypeIndex,
        })
        return
    end

    self:applySetPlannedCrop({ fieldId = fieldId, fruitTypeIndex = fruitTypeIndex }, self:getLocalFarmId(), nil)
end

---@param fieldRecord table
---@param text string
---@param actionType string|nil
---@param autoComplete boolean|nil
---@return table|nil task
function ToDoManager:addCustomFieldTask(fieldRecord, text, actionType, autoComplete)
    if fieldRecord == nil or string.isNilOrWhitespace(text) then
        return nil
    end

    local resolvedActionType = actionType or "custom"
    local draft = {
        text = self:buildFieldTaskText(fieldRecord, text),
        source = "field",
        fieldId = fieldRecord.id,
        fieldName = fieldRecord.name,
        fruit = fieldRecord.fruit,
        actionType = resolvedActionType,
        suggestion = text,
        autoComplete = autoComplete == true,
    }

    if FieldToDoSync ~= nil then
        FieldToDoSync.request(FieldToDoSync.OP.ADD_FIELD, draft)
        return nil
    end

    local result = self:applyAddFieldTask(draft, self:getLocalFarmId(), nil)
    if result == nil or result.task == nil then
        return nil
    end

    return self.manualTasks[result.task.id]
end

---@return number
function ToDoManager:updateAutoCompletion()
    if self.fieldScanner == nil then
        return 0
    end

    local completedCount = 0
    local tasksByFieldId = {}

    for taskId, task in pairs(self.manualTasks) do
        if not task.completed
            and self:taskBelongsToLocalFarm(task)
            and task.source == "field"
            and task.autoComplete == true then
            local fieldId = tonumber(task.fieldId)
            if fieldId ~= nil then
                if tasksByFieldId[fieldId] == nil then
                    tasksByFieldId[fieldId] = {}
                end
                tasksByFieldId[fieldId][#tasksByFieldId[fieldId] + 1] = taskId
            end
        end
    end

    for fieldId, taskIds in pairs(tasksByFieldId) do
        if FieldPlannedCrop == nil or not FieldPlannedCrop.isFarmyard(fieldId) then
            local field = self.fieldScanner:getEngineFieldById(fieldId)
            local fieldCache = nil

            if field ~= nil then
                local posX, posZ = FieldAdvisor.getFieldCenterWorldPosition(field)
                if posX ~= nil and posZ ~= nil and FieldTaskCompletion ~= nil then
                    fieldCache = FieldTaskCompletion.newFieldCompletionCache(field, posX, posZ)
                    local fieldState = FieldAdvisor.getEnrichedFieldState(field, fieldId, posX, posZ)
                    fieldCache.fieldState = fieldState
                    fieldCache.fingerprint = FieldAdvisor.buildFieldCompletionFingerprint(fieldState)

                    local previousCheck = self.fieldAutoCheckCache[fieldId]
                    fieldCache.fingerprintMatch = previousCheck ~= nil
                        and previousCheck.fingerprint == fieldCache.fingerprint
                    if fieldCache.fingerprintMatch and previousCheck.ratios ~= nil then
                        fieldCache.ratios = previousCheck.ratios
                    end
                end
            end

            local fieldCompleted = false
            for _, taskId in ipairs(taskIds) do
                local task = self.manualTasks[taskId]
                if task ~= nil and not task.completed and FieldAdvisor.isFieldTaskComplete(task, self.fieldScanner, fieldCache) then
                    if FieldToDoSync ~= nil then
                        FieldToDoSync.request(FieldToDoSync.OP.AUTO_COMPLETE, { taskId = taskId })
                    else
                        self:onTaskMarkedComplete(task)
                    end
                    fieldCompleted = true
                    completedCount = completedCount + 1
                end
            end

            if fieldCompleted then
                self:refreshFieldRecordSync(fieldId)
            end

            if fieldCache ~= nil and fieldCache.fingerprint ~= nil then
                self.fieldAutoCheckCache[fieldId] = {
                    fingerprint = fieldCache.fingerprint,
                    ratios = fieldCache.ratios,
                }
            end
        end
    end

    if completedCount > 0 then
        if FieldToDoSync == nil then
            self:requestDebouncedSave()
        end
        self:markManualTasksDirty()
    end

    return completedCount
end

---@return boolean
function ToDoManager:areGameFieldsReady()
    if g_fieldManager == nil or g_fieldManager.fields == nil then
        return false
    end

    return next(g_fieldManager.fields) ~= nil
end

function ToDoManager:update(dt)
    if self.saveDebounceMs ~= nil then
        self.saveDebounceMs = self.saveDebounceMs - dt
        if self.saveDebounceMs <= 0 then
            self.saveDebounceMs = nil
            self:saveSettingsNow()
        end
    end

    -- HUD mouse/drag must run every frame (draw is not fields-gated).
    if FieldToDoHudOverlay ~= nil and FieldToDoHudOverlay.instance ~= nil then
        FieldToDoHudOverlay.instance:update(dt)
    end

    if not self:areGameFieldsReady() then
        return
    end

    if FieldSavegameReader ~= nil
        and FieldSavegameReader.ENABLE_DISK_READ == true
        and FieldSavegameReader.deferDiskReads then
        FieldSavegameReader.deferDiskReads = false
    end

    if not self.didEnsureCompletionBaselines then
        self.didEnsureCompletionBaselines = true
        self:ensureCompletionBaselines()
    end

    if self.ownedFieldsScanActive == true and self.ownedFieldsScanInProgress == true then
        local scanChanged = self:tickOwnedFieldsScan(dt, 2)
        if scanChanged and FieldToDoInGameMenuIntegration ~= nil
            and FieldToDoInGameMenuIntegration.syncFieldListFromScan ~= nil then
            FieldToDoInGameMenuIntegration.syncFieldListFromScan()
        end
    end

    self.autoCheckTimer = self.autoCheckTimer + dt
    if self.autoCheckTimer < ToDoManager.AUTO_CHECK_INTERVAL_MS then
        return
    end

    self.autoCheckTimer = 0
    self:updateAutoCompletion()
end

---@param taskId number
---@param text string
---@return boolean
function ToDoManager:updateManualTask(taskId, text)
    if FieldToDoSync ~= nil then
        FieldToDoSync.request(FieldToDoSync.OP.UPDATE_TEXT, { taskId = taskId, text = text })
        return true
    end

    return self:applyUpdateTaskText({ taskId = taskId, text = text }, self:getLocalFarmId(), nil) ~= nil
end

---@param taskId number
---@return boolean
function ToDoManager:deleteManualTask(taskId)
    if FieldToDoSync ~= nil then
        FieldToDoSync.request(FieldToDoSync.OP.DELETE, { taskId = taskId })
        return true
    end

    return self:applyDeleteTask({ taskId = taskId }, self:getLocalFarmId(), nil) ~= nil
end

---@param taskId number
---@return boolean
function ToDoManager:toggleManualTask(taskId)
    if FieldToDoSync ~= nil then
        FieldToDoSync.request(FieldToDoSync.OP.TOGGLE_DONE, { taskId = taskId })
        return true
    end

    return self:applyToggleTaskDone({ taskId = taskId }, self:getLocalFarmId(), nil) ~= nil
end

---@param taskId number
---@return table|nil
function ToDoManager:getManualTask(taskId)
    return self.manualTasks[taskId]
end

function ToDoManager.initXMLSchema()
    if xmlSchema ~= nil then
        return
    end

    xmlSchema = XMLSchema.new("fieldToDoList")
    ToDoManager.registerSavegameXMLPaths(xmlSchema, ToDoManager.XML_KEY)
end

function ToDoManager.registerSavegameXMLPaths(schema, basePath)
    schema:register(XMLValueType.INT, basePath .. "#nextTaskId", "Next task id counter")
    schema:register(XMLValueType.STRING, basePath .. "#workOrderPreset", "Field work order preset key")
    schema:register(XMLValueType.BOOL, basePath .. "#organicMultiPassEnabled", "Split organic fertilizing into multiple passes")
    schema:register(XMLValueType.BOOL, basePath .. "#mulchingEnabled", "Suggest mulching after harvest for stubble crops")
    schema:register(XMLValueType.BOOL, basePath .. "#workersMayEditTodos", "Legacy default allow (mirrored)")
    schema:register(XMLValueType.BOOL, basePath .. "#todoEditDefaultAllow", "Per-farm default worker edit allow")
    schema:register(XMLValueType.INT, basePath .. ".farmTodoEdit(?)#farmId", "Farm id")
    schema:register(XMLValueType.BOOL, basePath .. ".farmTodoEdit(?)#defaultAllow", "Default worker edit")
    schema:register(XMLValueType.STRING, basePath .. ".farmTodoEdit(?).user(?)#uniqueUserId", "Unique user id")
    schema:register(XMLValueType.BOOL, basePath .. ".farmTodoEdit(?).user(?)#mayEdit", "May edit to-dos")
    schema:register(XMLValueType.INT, basePath .. ".tasks.task(?)#id", "Task id")
    schema:register(XMLValueType.INT, basePath .. ".tasks.task(?)#sortIndex", "Display order in the list")
    schema:register(XMLValueType.STRING, basePath .. ".tasks.task(?)#text", "Task display text")
    schema:register(XMLValueType.STRING, basePath .. ".tasks.task(?)#description", "Legacy task text attribute")
    schema:register(XMLValueType.BOOL, basePath .. ".tasks.task(?)#completed", "Task completed flag")
    schema:register(XMLValueType.STRING, basePath .. ".tasks.task(?)#source", "Task source (manual|field)")
    schema:register(XMLValueType.INT, basePath .. ".tasks.task(?)#fieldId", "Linked field id")
    schema:register(XMLValueType.STRING, basePath .. ".tasks.task(?)#fieldName", "Linked field name")
    schema:register(XMLValueType.STRING, basePath .. ".tasks.task(?)#fruit", "Crop name at creation time")
    schema:register(XMLValueType.STRING, basePath .. ".tasks.task(?)#actionType", "Field action key for auto-complete")
    schema:register(XMLValueType.INT, basePath .. ".tasks.task(?)#fertPass", "Organic fertilizer pass index")
    schema:register(XMLValueType.INT, basePath .. ".tasks.task(?)#fertPassTotal", "Organic fertilizer pass count")
    schema:register(XMLValueType.STRING, basePath .. ".tasks.task(?)#suggestion", "Field suggestion label")
    schema:register(XMLValueType.BOOL, basePath .. ".tasks.task(?)#autoComplete", "Whether task auto-completes from field state")
    schema:register(XMLValueType.INT, basePath .. ".tasks.task(?)#farmId", "Owning farm id (multiplayer)")
    if FieldPlannedCrop ~= nil and FieldPlannedCrop.registerXMLPaths ~= nil then
        FieldPlannedCrop.registerXMLPaths(schema, basePath)
    end
end

---@param xmlFile XMLFile
---@param taskKey string
---@return table|nil
function ToDoManager:loadTaskFromXML(xmlFile, taskKey)
    local taskId = xmlFile:getValue(taskKey .. "#id")
    if taskId == nil then
        return nil
    end

    local text = xmlFile:getValue(taskKey .. "#text")
    if string.isNilOrWhitespace(text) then
        text = xmlFile:getValue(taskKey .. "#description")
    end

    if string.isNilOrWhitespace(text) then
        return nil
    end

    local autoCompleteRaw = xmlFile:getValue(taskKey .. "#autoComplete")

    local task = {
        id = taskId,
        text = text,
        completed = xmlFile:getValue(taskKey .. "#completed") == true,
        source = xmlFile:getValue(taskKey .. "#source") or "manual",
        autoComplete = autoCompleteRaw == true,
        farmId = tonumber(xmlFile:getValue(taskKey .. "#farmId")),
    }

    local fieldId = xmlFile:getValue(taskKey .. "#fieldId")
    if fieldId ~= nil then
        task.fieldId = fieldId
        task.fieldName = xmlFile:getValue(taskKey .. "#fieldName")
        task.fruit = xmlFile:getValue(taskKey .. "#fruit")
        task.actionType = xmlFile:getValue(taskKey .. "#actionType")
        task.fertPass = xmlFile:getValue(taskKey .. "#fertPass")
        task.fertPassTotal = xmlFile:getValue(taskKey .. "#fertPassTotal")
        task.suggestion = xmlFile:getValue(taskKey .. "#suggestion")
    end

    if task.source == "field" and task.actionType ~= nil and task.actionType ~= "" and task.actionType ~= "custom" then
        if autoCompleteRaw == nil then
            task.autoComplete = true
        end
    end

    task.sortIndex = tonumber(xmlFile:getValue(taskKey .. "#sortIndex")) or task.id

    return task
end

---@param xmlFile XMLFile
---@param key string
function ToDoManager:loadTodoEditFromXMLFile(xmlFile, key)
    self.todoEditByFarmId = {}

    local index = 0
    while true do
        local farmKey = string.format("%s.farmTodoEdit(%d)", key, index)
        local farmId = tonumber(xmlFile:getValue(farmKey .. "#farmId"))
        if farmId == nil then
            break
        end

        local defaultAllow = xmlFile:getValue(farmKey .. "#defaultAllow")
        local state = {
            defaultAllow = defaultAllow ~= false,
            byUniqueUserId = {},
        }

        local userIndex = 0
        while true do
            local userKey = string.format("%s.user(%d)", farmKey, userIndex)
            local uniqueUserId = xmlFile:getValue(userKey .. "#uniqueUserId")
            if uniqueUserId == nil or uniqueUserId == "" then
                break
            end

            state.byUniqueUserId[tostring(uniqueUserId)] = xmlFile:getValue(userKey .. "#mayEdit") == true
            userIndex = userIndex + 1
        end

        self.todoEditByFarmId[farmId] = state
        index = index + 1
    end

    local localFarm = self:getLocalFarmId()
    if localFarm ~= nil and self.todoEditByFarmId[localFarm] == nil and FieldAdvisorSettings ~= nil then
        self.todoEditByFarmId[localFarm] = {
            defaultAllow = FieldAdvisorSettings.todoEditDefaultAllow ~= false,
            byUniqueUserId = {},
        }
    end

    if localFarm ~= nil then
        self:syncTodoEditSettingsCache(localFarm)
    end
end

---@param xmlFile XMLFile
---@param key string
function ToDoManager:saveTodoEditToXMLFile(xmlFile, key)
    local localFarm = self:getLocalFarmId()
    if localFarm ~= nil then
        local state = self.todoEditByFarmId[localFarm]
        local defaultAllow = true
        if state ~= nil then
            defaultAllow = state.defaultAllow ~= false
        elseif FieldAdvisorSettings ~= nil then
            defaultAllow = FieldAdvisorSettings.todoEditDefaultAllow ~= false
        end
        xmlFile:setValue(key .. "#workersMayEditTodos", defaultAllow == true)
    end

    local farmIds = {}
    for farmId in pairs(self.todoEditByFarmId) do
        farmIds[#farmIds + 1] = farmId
    end
    table.sort(farmIds)

    for index, farmId in ipairs(farmIds) do
        local state = self.todoEditByFarmId[farmId]
        local farmKey = string.format("%s.farmTodoEdit(%d)", key, index - 1)
        xmlFile:setValue(farmKey .. "#farmId", farmId)
        xmlFile:setValue(farmKey .. "#defaultAllow", state.defaultAllow ~= false)

        local userIds = {}
        for uniqueUserId in pairs(state.byUniqueUserId) do
            userIds[#userIds + 1] = uniqueUserId
        end
        table.sort(userIds)

        for userIndex, uniqueUserId in ipairs(userIds) do
            local userKey = string.format("%s.user(%d)", farmKey, userIndex - 1)
            xmlFile:setValue(userKey .. "#uniqueUserId", uniqueUserId)
            xmlFile:setValue(userKey .. "#mayEdit", state.byUniqueUserId[uniqueUserId] == true)
        end
    end
end

---@param xmlFile XMLFile
---@param key string
function ToDoManager:loadFromXMLFile(xmlFile, key)
    if xmlFile == nil or key == nil then
        return
    end

    self.manualTasks = {}
    self.todoEditByFarmId = {}

    local nextId = xmlFile:getValue(key .. "#nextTaskId")
    self.nextTaskId = math.max(1, tonumber(nextId) or 1)

    if FieldAdvisorSettings ~= nil then
        FieldAdvisorSettings.loadFromXMLFile(xmlFile, key)
    end

    self:loadTodoEditFromXMLFile(xmlFile, key)

    if FieldPlannedCrop ~= nil then
        FieldPlannedCrop.loadFromXMLFile(xmlFile, key)
    end

    local index = 0
    while true do
        local taskKey = string.format("%s.tasks.task(%d)", key, index)
        local task = self:loadTaskFromXML(xmlFile, taskKey)
        if task == nil then
            break
        end

        self.manualTasks[task.id] = task
        if task.id >= self.nextTaskId then
            self.nextTaskId = task.id + 1
        end

        index = index + 1
    end

    self:migrateOrphanTaskFarmIds()
    self:normalizeTaskSortIndices()
    self:pruneCompletedTasks()
    self:normalizeTaskSortIndices()
    self.didEnsureCompletionBaselines = false
    -- Auto-complete runs from update() once fields exist (not here — blocks Enter on mission start).
end

---@return number
function ToDoManager:ensureCompletionBaselines()
    if self.fieldScanner == nil or FieldAdvisor == nil or FieldAdvisor.captureTaskBaseline == nil then
        return 0
    end

    local ensured = 0

    for _, task in pairs(self.manualTasks) do
        if not task.completed
            and task.source == "field"
            and task.autoComplete == true
            and task.fieldId ~= nil
            and task.completionBaseline == nil then
            local field = self.fieldScanner:getEngineFieldById(task.fieldId)
            local posX = task.worldX
            local posZ = task.worldZ
            if field ~= nil then
                posX, posZ = FieldAdvisor.getFieldCenterWorldPosition(field)
            end

            task.completionBaseline = FieldAdvisor.captureTaskBaseline(field, task.fieldId, posX, posZ)
            if task.completionBaseline ~= nil then
                ensured = ensured + 1
            end
        end
    end

    return ensured
end

---@param xmlFile XMLFile
---@param key string
---@param task table
---@param taskKey string
function ToDoManager:saveTaskToXML(xmlFile, key, task, taskKey)
    xmlFile:setValue(taskKey .. "#id", task.id)
    xmlFile:setValue(taskKey .. "#sortIndex", tonumber(task.sortIndex) or task.id)
    xmlFile:setValue(taskKey .. "#text", task.text)
    xmlFile:setValue(taskKey .. "#completed", task.completed == true)
    xmlFile:setValue(taskKey .. "#source", task.source or "manual")
    xmlFile:setValue(taskKey .. "#autoComplete", task.autoComplete == true)
    if task.farmId ~= nil then
        xmlFile:setValue(taskKey .. "#farmId", task.farmId)
    end

    if task.source == "field" then
        if task.fieldId ~= nil then
            xmlFile:setValue(taskKey .. "#fieldId", task.fieldId)
        end

        if task.fieldName ~= nil then
            xmlFile:setValue(taskKey .. "#fieldName", task.fieldName)
        end

        if task.fruit ~= nil then
            xmlFile:setValue(taskKey .. "#fruit", task.fruit)
        end

        if task.actionType ~= nil then
            xmlFile:setValue(taskKey .. "#actionType", task.actionType)
        end

        if task.fertPass ~= nil then
            xmlFile:setValue(taskKey .. "#fertPass", task.fertPass)
        end

        if task.fertPassTotal ~= nil then
            xmlFile:setValue(taskKey .. "#fertPassTotal", task.fertPassTotal)
        end

        if task.suggestion ~= nil then
            xmlFile:setValue(taskKey .. "#suggestion", task.suggestion)
        end
    end
end

---@param xmlFile XMLFile
---@param key string
---@param usedModNames table|nil
function ToDoManager:saveToXMLFile(xmlFile, key, usedModNames)
    if xmlFile == nil or key == nil then
        return
    end

    xmlFile:setValue(key .. "#nextTaskId", self.nextTaskId)

    if FieldAdvisorSettings ~= nil then
        FieldAdvisorSettings.saveToXMLFile(xmlFile, key)
    end

    if FieldPlannedCrop ~= nil then
        FieldPlannedCrop.saveToXMLFile(xmlFile, key)
    end

    self:saveTodoEditToXMLFile(xmlFile, key)

    local sortedTasks = self:getAllManualTasks()
    table.sort(sortedTasks, function(a, b)
        return a.id < b.id
    end)

    for index, task in ipairs(sortedTasks) do
        local taskKey = string.format("%s.tasks.task(%d)", key, index - 1)
        self:saveTaskToXML(xmlFile, key, task, taskKey)
    end
end

---@param savegameDirectory string
---@return "missing"|"failed"|"ok"
function ToDoManager:loadFromSavegameDirectory(savegameDirectory)
    if string.isNilOrWhitespace(savegameDirectory) then
        return "missing"
    end

    ToDoManager.initXMLSchema()

    local filePath = savegameDirectory .. "/" .. ToDoManager.XML_FILENAME
    if not fileExists(filePath) then
        return "missing"
    end

    local xmlFile = XMLFile.load("fieldToDoListLoad", filePath, xmlSchema)
    if xmlFile == nil then
        return "failed"
    end

    self:loadFromXMLFile(xmlFile, ToDoManager.XML_KEY)
    xmlFile:delete()

    return "ok"
end

---@param savegameDirectory string
---@return boolean
function ToDoManager:saveToSavegameDirectory(savegameDirectory)
    if string.isNilOrWhitespace(savegameDirectory) then
        return false
    end

    self:migrateOrphanTaskFarmIds()
    self:syncForeignFarmTasksFromDisk(savegameDirectory)
    self:syncForeignFarmTodoEditFromDisk(savegameDirectory)

    ToDoManager.initXMLSchema()

    local filePath = savegameDirectory .. "/" .. ToDoManager.XML_FILENAME
    local xmlFile = XMLFile.create("fieldToDoListSave", filePath, "fieldToDoList", xmlSchema)
    if xmlFile == nil then
        if FieldToDoLog ~= nil then
            FieldToDoLog.error("fieldToDoList.xml: could not create for save (%s)", filePath)
        end
        return false
    end

    self:saveToXMLFile(xmlFile, ToDoManager.XML_KEY)
    xmlFile:save()
    xmlFile:delete()

    return true
end

-- Mod lifecycle ----------------------------------------------------------------

local modDirectory = g_currentModDirectory
local modName = g_currentModName
---@type ToDoManager|nil
local todoManager

local function isLoaded()
    return todoManager ~= nil
end

local function load(mission)
    if todoManager ~= nil then
        unload()
    end

    todoManager = ToDoManager.new(mission, modDirectory, modName)
    mission.fieldToDoList = todoManager

    if FieldToDoHudOverlay ~= nil then
        FieldToDoHudOverlay.instance = FieldToDoHudOverlay.new()
        FieldToDoHudOverlay.instance:initialize()
    end

    if FieldDebugDump ~= nil and FieldDebugDump.register ~= nil then
        FieldDebugDump.register()
    end

    if FieldDebugConsole ~= nil and FieldDebugConsole.register ~= nil then
        FieldDebugConsole.register()
    end
end

local function unload()
    if not isLoaded() then
        return
    end

    todoManager:delete()
    todoManager = nil

    if FieldToDoHudOverlay ~= nil and FieldToDoHudOverlay.instance ~= nil then
        FieldToDoHudOverlay.instance:delete()
        FieldToDoHudOverlay.instance = nil
    end

    if FieldDebugDump ~= nil and FieldDebugDump.unregister ~= nil then
        FieldDebugDump.unregister()
    end

    if FieldDebugConsole ~= nil and FieldDebugConsole.unregister ~= nil then
        FieldDebugConsole.unregister()
    end

    if g_currentMission ~= nil then
        g_currentMission.fieldToDoList = nil
    end
end

local function onStartMission(mission)
    if not isLoaded() or mission == nil or mission.missionInfo == nil then
        return
    end

    if mission.missionInfo.isValid ~= true then
        return
    end

    local savegameDirectory = mission.missionInfo.savegameDirectory
    local loadStatus = "missing"
    if savegameDirectory ~= nil and savegameDirectory ~= "" then
        loadStatus = todoManager:loadFromSavegameDirectory(savegameDirectory)
        if FieldSavegameReader ~= nil then
            FieldSavegameReader.invalidate()
            FieldSavegameReader.deferReadsUntilGameplay()
        end
        if FieldAdvisor ~= nil and FieldAdvisor.invalidateDensityMapHeightUtil ~= nil then
            FieldAdvisor.invalidateDensityMapHeightUtil()
        end
    end

    if FieldToDoLog ~= nil then
        FieldToDoLog.logSavegameStartup(todoManager, savegameDirectory, loadStatus)
        if savegameDirectory ~= nil and savegameDirectory ~= "" then
            local careerPath = savegameDirectory .. "/careerSavegame.xml"
            if not fileExists(careerPath) then
                FieldToDoLog.warning(
                    "careerSavegame.xml missing — save slot will not appear in the menu until restored from savegameBackup"
                )
            end

            local fieldsPath = savegameDirectory .. "/fields.xml"
            if fileExists(fieldsPath) and getFileSize ~= nil then
                local size = getFileSize(fieldsPath) or 0
                if size < 64 then
                    FieldToDoLog.warning(
                        "fields.xml is empty or truncated (%d bytes) — vanilla save will fail until restored from backup",
                        size
                    )
                end
            elseif not fileExists(fieldsPath) then
                FieldToDoLog.warning("fields.xml missing — restore from savegameBackup before loading this slot")
            end
        end
    end

    if FieldToDoSync ~= nil and FieldToDoSync.onMissionStarted ~= nil then
        FieldToDoSync.onMissionStarted()
    end
end

local function onSaveMission(missionInfo)
    if not isLoaded() or missionInfo == nil or missionInfo.isValid ~= true then
        return
    end

    if todoManager.canPersistSidecar ~= nil and not todoManager:canPersistSidecar() then
        return
    end

    local savegameDirectory = missionInfo.savegameDirectory
    if savegameDirectory == nil or savegameDirectory == "" then
        return
    end

    local ok, result = pcall(todoManager.saveToSavegameDirectory, todoManager, savegameDirectory)
    if not ok then
        if FieldToDoLog ~= nil then
            FieldToDoLog.error("fieldToDoList.xml: career save hook error (%s)", tostring(result))
        end
        return
    end

    if result ~= true and FieldToDoLog ~= nil then
        FieldToDoLog.warning("fieldToDoList.xml: save failed (%s)", savegameDirectory)
    end
end

local function subscribeOverviewStaleEvents()
    if g_messageCenter == nil or MessageType == nil then
        return
    end

    local function markOverviewStale()
        if todoManager ~= nil and todoManager.markOwnedFieldsOverviewStale ~= nil then
            todoManager:markOwnedFieldsOverviewStale()
        end
    end

    local eventNames = {
        "FINISHED_GROWTH_PERIOD",
        "FARMLAND_OWNER_CHANGED",
    }

    for _, eventName in ipairs(eventNames) do
        local messageType = MessageType[eventName]
        if messageType ~= nil then
            g_messageCenter:subscribe(messageType, markOverviewStale)
        end
    end
end

local function subscribeSyncEvents()
    if g_messageCenter == nil or MessageType == nil or FieldToDoSync == nil then
        return
    end

    if MessageType.PLAYER_FARM_CHANGED ~= nil and FieldToDoSync.onPlayerFarmChanged ~= nil then
        g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, FieldToDoSync.onPlayerFarmChanged)
    end
end

local function init()
    ToDoManager.initXMLSchema()
    subscribeOverviewStaleEvents()
    subscribeSyncEvents()

    FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, unload)
    Mission00.load = Utils.prependedFunction(Mission00.load, load)
    Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, onStartMission)

    if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, onSaveMission)
    end

    FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(_, dt)
        if todoManager ~= nil and dt ~= nil then
            todoManager:update(dt)
        end
    end)

    FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function()
        if FieldToDoHudOverlay ~= nil and FieldToDoHudOverlay.instance ~= nil then
            FieldToDoHudOverlay.instance:draw()
        end
    end)
end

init()
