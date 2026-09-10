--[[
    FieldToDoMenuFrame.lua
    In-game menu page: manual To-Do list (left) and owned field overview (right).

    Custom tab pages do not receive frame updates from the engine alone — InGameMenuIntegration
    calls onFrameUpdate while this page is visible. During scan progress use fieldList:reloadData
    (reloadVisibleItems does not reliably replace "..." placeholders).
]]

---@class FieldToDoMenuFrame : TabbedMenuFrameElement
---@field taskList SmoothList
---@field fieldList SmoothList
---@field categoryHeaderText Text
---@field selectedTaskId number|nil
FieldToDoMenuFrame = {}
local FieldToDoMenuFrame_mt = Class(FieldToDoMenuFrame, TabbedMenuFrameElement)

FieldToDoMenuFrame.TASK_STATUS_OPEN = "[ ]"
FieldToDoMenuFrame.TASK_STATUS_DONE = "[x]"

---@return FieldToDoMenuFrame
function FieldToDoMenuFrame.new()
    local self = FieldToDoMenuFrame:superClass().new(nil, FieldToDoMenuFrame_mt)

    self.name = "FieldToDoMenuFrame"
    self.className = "FieldToDoMenuFrame"
    self.returnScreenName = ""
    self.menuButtonInfo = {}
    self.menuButtonInfoDirty = false
    self.hasCustomMenuButtons = true
    self.isInitialized = false

    self.manualTasks = {}
    self.ownedFields = {}
    self.selectedTaskId = nil
    self.selectedFieldId = nil
    self.editingTaskId = nil
    self.deletingTaskId = nil
    self.pendingFieldForPicker = nil
    self.pendingFieldTaskActions = nil
    self.pendingFieldForPlannedCrop = nil
    self.pendingPlannedCropEntries = nil
    self.listRefreshTimer = 0
    self.showPrecisionFarming = false
    self.showCropStress = false
    self.fieldSuggestionIndexByFieldId = {}
    self.scsFieldsReady = false
    self.deferredListReload = false
    self.deferredListReloadTimer = 0
    self.deferredListReloadAttempts = 0
    self.fieldScanBlinkTimer = 0

    return self
end

function FieldToDoMenuFrame:getHasCustomMenuButtons()
    return self.hasCustomMenuButtons == true
end

function FieldToDoMenuFrame:getMenuButtonInfo()
    return self.menuButtonInfo
end

function FieldToDoMenuFrame:isMenuButtonInfoDirty()
    return self.menuButtonInfoDirty == true
end

function FieldToDoMenuFrame:setMenuButtonInfoDirty()
    self.menuButtonInfoDirty = true
end

function FieldToDoMenuFrame:setMenuButtonInfo(info)
    self.menuButtonInfo = info
    self.menuButtonInfoDirty = true
end

function FieldToDoMenuFrame:rebuildMenuButtons()
    -- FS25 footer: InputAction enum; only BACK + ACTIVATE + EXTRA_1/2 render reliably (CropStress).
    self.menuButtonInfo = {
        { inputAction = InputAction.MENU_BACK },
        {
            inputAction = InputAction.MENU_ACTIVATE,
            text = FieldToDoL10n.getText("ftdl_btn_add", "Hinzufügen"),
            callback = function()
                self:onClickAddTask()
            end,
        },
        {
            inputAction = InputAction.MENU_EXTRA_1,
            text = FieldToDoL10n.getText("ftdl_btn_edit", "Bearbeiten"),
            callback = function()
                self:onClickEditTask()
            end,
        },
        {
            inputAction = InputAction.MENU_EXTRA_2,
            text = FieldToDoL10n.getText("ftdl_btn_done", "Erledigt"),
            callback = function()
                self:onClickToggleTask()
            end,
        },
    }
    self:setMenuButtonInfo(self.menuButtonInfo)
end

function FieldToDoMenuFrame:pushMenuButtons()
    self:rebuildMenuButtons()
    self:setMenuButtonInfo(self.menuButtonInfo)
end

function FieldToDoMenuFrame:finalizeListLayout()
    if self.taskList ~= nil and self.taskList.updateAbsolutePosition ~= nil then
        self.taskList:updateAbsolutePosition()
    end

    if self.fieldList ~= nil and self.fieldList.updateAbsolutePosition ~= nil then
        self.fieldList:updateAbsolutePosition()
    end

    if self.updateAbsolutePosition ~= nil then
        self:updateAbsolutePosition()
    end
end

function FieldToDoMenuFrame:initialize()
    if self.isInitialized then
        return
    end

    FieldToDoMenuFrame:superClass().initialize(self)
    self:rebuildMenuButtons()
    self.menuButtonInfoDirty = false
    self.isInitialized = true
end

function FieldToDoMenuFrame:bindGuiControls()
    if type(self.exposeControlsAsFields) == "function" then
        pcall(self.exposeControlsAsFields, self, "menuFieldToDo")
    end
end

function FieldToDoMenuFrame:updateSettingsWorkOrderLabel()
    if self.settingsWorkOrderLabel == nil or FieldAdvisorSettings == nil then
        return
    end

    local scsStatus = SeasonalCropStressReader ~= nil
        and SeasonalCropStressReader.getIntegrationStatusLabel()
        or ""

    self.settingsWorkOrderLabel:setText(FieldToDoL10n.getText(
        "ftdl_settings_work_order",
        "Reihenfolge: %s  |  %s",
        FieldAdvisorSettings.getWorkOrderLabel(),
        scsStatus
    ))
end

function FieldToDoMenuFrame:applyMiniButtonIcons()
    local manager = self:getManager()
    local modDirectory = (manager ~= nil and manager.modDirectory) or g_currentModDirectory
    if string.isNilOrWhitespace(modDirectory) then
        return
    end

    local iconBindings = {
        { button = self.btnAdd, file = "gui/icons/add.dds" },
        { button = self.btnEdit, file = "gui/icons/edit.dds" },
        { button = self.btnDone, file = "gui/icons/done.dds" },
        { button = self.btnDelete, file = "gui/icons/delete.dds" },
    }

    for _, binding in ipairs(iconBindings) do
        if binding.button ~= nil and binding.button.setImageFilename ~= nil then
            local iconPath = Utils.getFilename(binding.file, modDirectory)
            if iconPath ~= nil then
                binding.button:setImageFilename(nil, iconPath)
            end
        end
    end

    self:applyMoveButtonTooltips()
end

function FieldToDoMenuFrame:applyMoveButtonTooltips()
    local moveBindings = {
        { button = self.btnMoveUp, key = "ftdl_btn_up", fallback = "Hoch" },
        { button = self.btnMoveDown, key = "ftdl_btn_down", fallback = "Runter" },
    }

    for _, binding in ipairs(moveBindings) do
        if binding.button ~= nil and binding.button.setToolTipText ~= nil then
            binding.button:setToolTipText(FieldToDoL10n.getText(binding.key, binding.fallback))
        end
    end
end

function FieldToDoMenuFrame:onGuiSetupFinished()
    FieldToDoMenuFrame:superClass().onGuiSetupFinished(self)
    self:bindGuiControls()

    if self.categoryHeaderText ~= nil then
        self.title = self.categoryHeaderText.text
    end

    if self.taskList ~= nil then
        self.taskList.dataSource = self
        self.taskList.delegate = self
    end

    if self.fieldList ~= nil then
        self.fieldList.dataSource = self
        self.fieldList.delegate = self
    end

    self:updateSettingsWorkOrderLabel()
    self:applyMiniButtonIcons()
end

---@return table
function FieldToDoMenuFrame:getOptionalColumnVisibility()
    return {
        pf = PrecisionFarmingReader ~= nil and PrecisionFarmingReader.isModLoaded(),
        scs = SeasonalCropStressReader ~= nil and SeasonalCropStressReader.isModLoaded(),
    }
end

---@param element GuiElement|nil
---@param visible boolean
function FieldToDoMenuFrame:setElementVisible(element, visible)
    if element ~= nil and element.setVisible ~= nil then
        element:setVisible(visible)
    end
end

function FieldToDoMenuFrame:updateOptionalColumns()
    local visibility = self:getOptionalColumnVisibility()
    self.showPrecisionFarming = visibility.pf
    self.showCropStress = visibility.scs

    self:setElementVisible(self.hdr_ph, visibility.pf)
    self:setElementVisible(self.hdr_nitrogen, visibility.pf)
    self:setElementVisible(self.hdr_moisture, visibility.scs)
    self:setElementVisible(self.hdr_stress, visibility.scs)

    self:updateSettingsWorkOrderLabel()

    if self.organicMultiPassBtnText ~= nil and FieldAdvisorSettings ~= nil then
        self.organicMultiPassBtnText:setText(FieldAdvisorSettings.getOrganicMultiPassLabel())
        self:applyToggleBtnColor(self.organicMultiPassBtnText, FieldAdvisorSettings.isOrganicMultiPassEnabled())
    end

    if self.mulchBtnText ~= nil and FieldAdvisorSettings ~= nil then
        self.mulchBtnText:setText(FieldAdvisorSettings.getMulchingLabel())
        self:applyToggleBtnColor(self.mulchBtnText, FieldAdvisorSettings.isMulchingEnabled())
    end
end

-- Toggle labels: FS green = active, muted grey = off.
function FieldToDoMenuFrame:applyToggleBtnColor(textElement, enabled)
    if textElement == nil or textElement.setTextColor == nil then
        return
    end

    if enabled then
        -- $preset_fs25_colorGreen
        textElement:setTextColor(0.33716, 0.55834, 0.0003, 1.0)
    else
        textElement:setTextColor(0.62, 0.64, 0.68, 1.0)
    end
end

function FieldToDoMenuFrame:onFrameOpen()
    FieldToDoMenuFrame:superClass().onFrameOpen(self)
    local manager = self:getManager()
    if manager ~= nil and manager.setOwnedFieldsScanActive ~= nil then
        manager:setOwnedFieldsScanActive(true)
    end
    self:pushMenuButtons()
    self.listRefreshTimer = 0
    self.fieldRescanTimer = 0
    self.deferredListReload = true
    self.deferredListReloadTimer = 0
    self.deferredListReloadAttempts = 0
    self.scsFieldsReady = SeasonalCropStressReader ~= nil and SeasonalCropStressReader.isRuntimeReady()
    self:bindGuiControls()
    self:applyMiniButtonIcons()
    self:updateOptionalColumns()
    self:finalizeListLayout()
    if manager ~= nil and manager.consumeOwnedFieldsOverviewStale ~= nil and manager:consumeOwnedFieldsOverviewStale() then
        self:refreshLists(true)
    else
        self:refreshLists()
    end
end

function FieldToDoMenuFrame:onOpen()
    self:onFrameOpen()
end

--- Pull scan snapshot; reload field list when ToDoManager marks scan dirty.
function FieldToDoMenuFrame:syncOwnedFieldsFromScan()
    local manager = self:getManager()
    if manager == nil then
        return false
    end

    self.ownedFields = manager:getOwnedFields()

    if self.fieldEmptyHint ~= nil then
        self.fieldEmptyHint:setVisible(#self.ownedFields == 0)
    end

    if self.fieldList == nil then
        return false
    end

    if manager:consumeOwnedFieldsScanDirty() then
        self.fieldList:reloadData()
        return true
    end

    return false
end

---@param dt number
---@param manager ToDoManager|nil
function FieldToDoMenuFrame:updateFieldScanIndicator(dt, manager)
    if self.fieldScanStatusDot == nil then
        return
    end

    manager = manager or self:getManager()
    local scanning = manager ~= nil and manager:isOwnedFieldsScanInProgress()
    self.fieldScanStatusDot:setVisible(true)

    if scanning then
        self.fieldScanBlinkTimer = (self.fieldScanBlinkTimer or 0) + dt
        local phase = math.floor(self.fieldScanBlinkTimer / 400) % 2
        if phase == 0 then
            self.fieldScanStatusDot:setTextColor(0.95, 0.82, 0.15, 1.0)
        else
            self.fieldScanStatusDot:setTextColor(0.95, 0.82, 0.15, 0.25)
        end

        if manager.getOwnedFieldsScanProgress ~= nil then
            local done, total = manager:getOwnedFieldsScanProgress()
            if total > 0 and self.fieldScanStatusDot.setToolTipText ~= nil then
                self.fieldScanStatusDot:setToolTipText(
                    string.format(g_i18n:getText("ftdl_scan_status_scanning"), done, total)
                )
            end
        end
        return
    end

    self.fieldScanBlinkTimer = 0
    -- $preset_fs25_colorGreen
    self.fieldScanStatusDot:setTextColor(0.33716, 0.55834, 0.0003, 1.0)
    if self.fieldScanStatusDot.setToolTipText ~= nil then
        self.fieldScanStatusDot:setToolTipText(g_i18n:getText("ftdl_scan_status_ready"))
    end
end

function FieldToDoMenuFrame:onFrameUpdate(dt)
    FieldToDoMenuFrame:superClass().onFrameUpdate(self, dt)

    local manager = self:getManager()
    if manager ~= nil then
        if manager:consumeOwnedFieldsOverviewStale() then
            self:refreshLists(true)
        end
        if manager.consumeManualTasksDirty ~= nil and manager:consumeManualTasksDirty() then
            self:refreshManualTaskList(true, true)
        end
        self:syncOwnedFieldsFromScan()
        self:updateFieldScanIndicator(dt, manager)
    end

    if self.deferredListReload then
        self.deferredListReloadTimer = self.deferredListReloadTimer + dt
        if self.deferredListReloadTimer >= 500 then
            self.deferredListReloadTimer = 0
            self.deferredListReloadAttempts = self.deferredListReloadAttempts + 1
            self:pushMenuButtons()
            -- Repaint without cache invalidate (sync scan progress only when dirty).
            self:refreshLists(false)
            local deferredManager = self:getManager()
            local hasFields = deferredManager ~= nil and #self.ownedFields > 0
            if hasFields or self.deferredListReloadAttempts >= 30 then
                self.deferredListReload = false
            end
        end
        return
    end

    manager = self:getManager()
    if manager == nil then
        return
    end

    self.listRefreshTimer = self.listRefreshTimer + dt
    if self.listRefreshTimer < 1000 then
        return
    end

    self.listRefreshTimer = 0

    self.fieldRescanTimer = (self.fieldRescanTimer or 0) + 1000
    local rescanMs = ToDoManager.OWNED_FIELDS_MENU_RESCAN_MS or 15000
    if self.fieldRescanTimer >= rescanMs then
        self.fieldRescanTimer = 0
        self:refreshLists(true)
    end
end

function FieldToDoMenuFrame:onFrameClose()
    local manager = self:getManager()
    if manager ~= nil and manager.setOwnedFieldsScanActive ~= nil then
        manager:setOwnedFieldsScanActive(false)
    end
    self.selectedTaskId = nil
    self.selectedFieldId = nil
    self.pendingFieldForPicker = nil
    self.pendingFieldTaskActions = nil
    self.pendingFieldForCustomTask = nil
    FieldToDoMenuFrame:superClass().onFrameClose(self)
end

---@return ToDoManager|nil
function FieldToDoMenuFrame:getManager()
    if g_currentMission == nil then
        return nil
    end

    return g_currentMission.fieldToDoList
end

--- invalidateFieldsCache=false: repaint only when scan dirty (no cache reset — avoids restarting scan).
function FieldToDoMenuFrame:refreshLists(invalidateFieldsCache)
    local manager = self:getManager()
    if manager ~= nil and manager.setOwnedFieldsScanActive ~= nil then
        manager:setOwnedFieldsScanActive(true)
    end

    if invalidateFieldsCache ~= false
        and manager ~= nil
        and manager.invalidateOwnedFieldsCache ~= nil then
        manager:invalidateOwnedFieldsCache()
    end

    if manager == nil then
        self.manualTasks = {}
        self.ownedFields = {}
    else
        self.manualTasks = manager:getManualTasks()
        self.ownedFields = manager:getOwnedFields()
    end

    if self.selectedTaskId ~= nil and manager ~= nil and manager:getManualTask(self.selectedTaskId) == nil then
        self.selectedTaskId = nil
    end

    if self.todoEmptyHint ~= nil then
        self.todoEmptyHint:setVisible(#self.manualTasks == 0)
    end

    if self.fieldEmptyHint ~= nil then
        self.fieldEmptyHint:setVisible(#self.ownedFields == 0)
    end

    if self.taskList ~= nil then
        self:reloadTaskListData(true)
    end

    if self.fieldList ~= nil then
        if invalidateFieldsCache == false and manager ~= nil and manager.consumeOwnedFieldsScanDirty ~= nil then
            if not manager:consumeOwnedFieldsScanDirty() then
                return
            end
        end
        self.fieldList:reloadData()
    end
end

--- Refresh manual tasks only (order/text). Keeps selectedTaskId; used after move/toggle.
---@param skipAutoCheck boolean|nil
---@param fullReload boolean|nil use reloadData when open/completed partition changes
function FieldToDoMenuFrame:refreshManualTaskList(skipAutoCheck, fullReload)
    local manager = self:getManager()
    if manager == nil then
        self.manualTasks = {}
    else
        if skipAutoCheck ~= true then
            manager:updateAutoCompletion()
        end
        self.manualTasks = manager:getManualTasks()
    end

    if self.selectedTaskId ~= nil and manager ~= nil and manager:getManualTask(self.selectedTaskId) == nil then
        self.selectedTaskId = nil
    end

    if self.todoEmptyHint ~= nil then
        self.todoEmptyHint:setVisible(#self.manualTasks == 0)
    end

    if self.taskList ~= nil then
        self:reloadTaskListData(fullReload == true)
    end
end

---@param fullReload boolean|nil when true, rebuild list (menu open); else repaint rows only (reorder/toggle)
function FieldToDoMenuFrame:reloadTaskListData(fullReload)
    if self.taskList == nil then
        return
    end

    self.ignoreTaskSelectionChanged = true
    if fullReload == true or self.taskList.reloadVisibleItems == nil then
        self.taskList:reloadData()
    else
        self.taskList:reloadVisibleItems()
    end
    self:syncTaskListSelection()
    self.ignoreTaskSelectionChanged = false
end

---@param taskId number|nil
---@return number|nil
function FieldToDoMenuFrame:getTaskListIndexForId(taskId)
    if taskId == nil then
        return nil
    end

    for index, task in ipairs(self.manualTasks) do
        if task.id == taskId then
            return index
        end
    end

    return nil
end

function FieldToDoMenuFrame:syncTaskListSelection()
    if self.taskList == nil then
        return
    end

    if self.selectedTaskId == nil then
        self:clearTaskListSelectionVisual()
        return
    end

    local listIndex = self:getTaskListIndexForId(self.selectedTaskId)
    if listIndex == nil then
        self.selectedTaskId = nil
        self:clearTaskListSelectionVisual()
        return
    end

    -- FS25 SmoothList: selectedIndex is 1-based; set selection before repainting cells.
    local wasIgnoring = self.ignoreTaskSelectionChanged == true

    if not wasIgnoring then
        self.ignoreTaskSelectionChanged = true
    end

    local section = 1
    if self.taskList.setSelectedItem ~= nil then
        self.taskList:setSelectedItem(section, listIndex, true)
    else
        self.taskList.selectedSectionIndex = section
        self.taskList.selectedIndex = listIndex
        if self.taskList.applyElementSelection ~= nil then
            self.taskList:applyElementSelection()
        end
    end

    if self.taskList.reloadVisibleItems ~= nil then
        self.taskList:reloadVisibleItems()
    elseif self.taskList.applyElementSelection ~= nil then
        self.taskList:applyElementSelection()
    end

    if not wasIgnoring then
        self.ignoreTaskSelectionChanged = false
    end
end

function FieldToDoMenuFrame:clearTaskListSelectionVisual()
    if self.taskList == nil then
        return
    end

    local wasIgnoring = self.ignoreTaskSelectionChanged == true

    if not wasIgnoring then
        self.ignoreTaskSelectionChanged = true
    end

    if self.taskList.clearElementSelection ~= nil then
        self.taskList:clearElementSelection()
    else
        self.taskList.selectedSectionIndex = 0
        self.taskList.selectedIndex = 0
        if self.taskList.applyElementSelection ~= nil then
            self.taskList:applyElementSelection()
        end
    end

    if self.taskList.reloadVisibleItems ~= nil then
        self.taskList:reloadVisibleItems()
    end

    if not wasIgnoring then
        self.ignoreTaskSelectionChanged = false
    end
end

---@param list SmoothList
---@param section number
---@return number
function FieldToDoMenuFrame:getNumberOfItemsInSection(list, section)
    if list == self.taskList then
        return #self.manualTasks
    end

    if list == self.fieldList then
        return #self.ownedFields
    end

    return 0
end

---@param list SmoothList
---@param section number
---@param index number
---@param cell ListItemElement
function FieldToDoMenuFrame:populateCellForItemInSection(list, section, index, cell)
    if list == self.taskList then
        local task = self.manualTasks[index]
        if task == nil then
            return
        end

        local statusElement = cell:getAttribute("status")
        local textElement = cell:getAttribute("text")

        if statusElement ~= nil then
            statusElement:setText(task.completed and FieldToDoMenuFrame.TASK_STATUS_DONE or FieldToDoMenuFrame.TASK_STATUS_OPEN)
        end

        if textElement ~= nil then
            local displayText = task.text
            if not task.completed then
                -- (auto) = engine tracks completion; (manuell) = reminder only (e.g. grass_swath/collect).
                local tag = task.autoComplete == true
                    and FieldToDoL10n.getText("ftdl_task_tag_auto", "auto")
                    or FieldToDoL10n.getText("ftdl_task_tag_manual", "manuell")
                displayText = string.format("%s  (%s)", task.text, tag)
            end
            textElement:setText(displayText)
            if task.completed then
                -- muted main-light
                textElement.textColor = { 0.89627, 0.92158, 0.81485, 0.45 }
            else
                textElement.textColor = { 0.89627, 0.92158, 0.81485, 1 }
            end
        end

        cell.ftdlTaskId = task.id

        return
    end

    if list == self.fieldList then
        local field = self.ownedFields[index]
        if field == nil then
            return
        end

        cell:getAttribute("fieldName"):setText(field.name)
        cell:getAttribute("fruit"):setText(field.fruit)
        local plannedElement = cell:getAttribute("plannedSow")
        if plannedElement ~= nil then
            plannedElement:setText(field.plannedSow or "-")
        end

        local plannedHit = cell:getAttribute("plannedSowHit")
        if plannedHit ~= nil then
            plannedHit.ftdlFieldId = field.id
            if plannedHit.setToolTipText ~= nil then
                plannedHit:setToolTipText(FieldToDoL10n.getText(
                    "ftdl_btn_planned_crop",
                    "Planfrucht"
                ))
            end
        end
        cell:getAttribute("growth"):setText(field.growthState)
        cell:getAttribute("harvest"):setText(field.expectedHarvest or "-")
        cell:getAttribute("weed"):setText(field.weed or "-")
        cell:getAttribute("stones"):setText(field.stones or "-")
        cell:getAttribute("lime"):setText(field.lime or "-")
        cell:getAttribute("roller"):setText(field.roller or "-")

        local phElement = cell:getAttribute("ph")
        if phElement ~= nil then
            phElement:setVisible(self.showPrecisionFarming)
            if self.showPrecisionFarming then
                phElement:setText(field.ph or "-")
            end
        end

        local nitrogenElement = cell:getAttribute("nitrogen")
        if nitrogenElement ~= nil then
            nitrogenElement:setVisible(self.showPrecisionFarming)
            if self.showPrecisionFarming then
                nitrogenElement:setText(field.nitrogen or "-")
            end
        end

        local moistureElement = cell:getAttribute("moisture")
        local stressElement = cell:getAttribute("stress")
        if moistureElement ~= nil then
            moistureElement:setVisible(self.showCropStress)
        end
        if stressElement ~= nil then
            stressElement:setVisible(self.showCropStress)
        end

        if self.showCropStress and SeasonalCropStressReader ~= nil then
            SeasonalCropStressReader.ensureInitialized()

            local scsSample = nil
            local manager = self:getManager()
            local engineField = manager ~= nil and manager.fieldScanner ~= nil
                and manager.fieldScanner:getEngineFieldById(field.id)
                or nil

            local scsFieldId = field.scsFieldId or field.farmlandId
            if scsFieldId == nil and engineField ~= nil then
                scsFieldId = SeasonalCropStressReader.resolveScsFieldId(engineField, nil)
            end
            if scsFieldId == nil and field.worldX ~= nil and field.worldZ ~= nil then
                scsFieldId = SeasonalCropStressReader.resolveFarmlandIdAtPosition(field.worldX, field.worldZ)
            end

            if scsFieldId ~= nil then
                scsSample = SeasonalCropStressReader.sampleFarmlandId(scsFieldId)
            end

            if scsSample == nil and engineField ~= nil then
                scsSample = SeasonalCropStressReader.sampleField(engineField)
            end

            if scsSample == nil then
                scsSample = SeasonalCropStressReader.sampleAtWorldPosition(field.worldX, field.worldZ, engineField)
            end

            local fallback = "-"
            local moistureText = scsSample ~= nil and scsSample.moistureLabel or field.moisture or fallback
            local stressText = scsSample ~= nil and scsSample.stressLabel or field.stress or fallback

            if moistureElement ~= nil then
                moistureElement:setText(moistureText)
            end
            if stressElement ~= nil then
                stressElement:setText(stressText)
            end
        else
            if moistureElement ~= nil then
                moistureElement:setText(field.moisture or "-")
            end
            if stressElement ~= nil then
                stressElement:setText(field.stress or "-")
            end
        end

        cell:getAttribute("suggestion"):setText(self:getFieldSuggestionDisplayText(field))
        cell.ftdlFieldId = field.id

        local cycleable = FieldAdvisor ~= nil and FieldAdvisor.getCycleableActions(field.suggestionDetails) or {}
        local hasMultipleSuggestions = #cycleable > 1
        local cycleElements = {
            cell:getAttribute("cycleSuggestion"),
            cell:getAttribute("cycleSuggestionLabel"),
        }

        for _, cycleElement in ipairs(cycleElements) do
            if cycleElement ~= nil then
                cycleElement:setVisible(hasMultipleSuggestions)
                cycleElement.ftdlFieldId = field.id
                if cycleElement.setDisabled ~= nil then
                    cycleElement:setDisabled(not hasMultipleSuggestions)
                end
            end
        end
    end
end

---@param fieldId number|nil
---@return number
function FieldToDoMenuFrame:getFieldSuggestionIndex(fieldId)
    if fieldId == nil then
        return 1
    end

    local index = self.fieldSuggestionIndexByFieldId[fieldId]
    if index == nil or index < 1 then
        return 1
    end

    return index
end

---@param field table|nil
---@return table|nil action
---@return number index
---@return number total
function FieldToDoMenuFrame:getFieldSuggestionSelection(field)
    if field == nil or field.suggestionDetails == nil or FieldAdvisor == nil then
        return nil, 1, 0
    end

    return FieldAdvisor.getCycleableActionAt(field.suggestionDetails, self:getFieldSuggestionIndex(field.id))
end

---@param field table|nil
---@return string
function FieldToDoMenuFrame:getFieldSuggestionDisplayText(field)
    if field == nil or FieldAdvisor == nil then
        return "-"
    end

    if self:getFieldSuggestionIndex(field.id) > 1 then
        local action, index, total = self:getFieldSuggestionSelection(field)
        return FieldAdvisor.formatCycledSuggestionLabel(action, index, total)
    end

    if field.suggestionDetails ~= nil then
        local preview = FieldAdvisor.formatWorkOrderSuggestionPreview(field.suggestionDetails, 4)
        if preview ~= nil and preview ~= "" then
            return preview
        end
    end

    if field.suggestion ~= nil and field.suggestion ~= "" and field.suggestion ~= "-" then
        return field.suggestion
    end

    return "-"
end

---@param field table|nil
---@param delta number
function FieldToDoMenuFrame:cycleFieldSuggestion(field, delta)
    if field == nil or field.suggestionDetails == nil or FieldAdvisor == nil then
        return
    end

    local cycleable = FieldAdvisor.getCycleableActions(field.suggestionDetails)
    if #cycleable <= 1 then
        return
    end

    local currentIndex = self:getFieldSuggestionIndex(field.id)
    local nextIndex = currentIndex + delta
    if nextIndex < 1 then
        nextIndex = #cycleable
    elseif nextIndex > #cycleable then
        nextIndex = 1
    end

    self.fieldSuggestionIndexByFieldId[field.id] = nextIndex

    local action = cycleable[nextIndex]
    if action ~= nil then
        field.actionType = action.actionType
        field.autoComplete = action.autoComplete == true
        field.fertPass = action.fertPass
        field.fertPassTotal = action.fertPassTotal
    end
end

function FieldToDoMenuFrame:refreshFieldSuggestionCell()
    if self.fieldList == nil then
        return
    end

    self.fieldList:reloadData()
end

---@param element GuiElement|nil
---@return number|nil fieldId
function FieldToDoMenuFrame:resolveFieldIdFromGuiElement(element)
    local current = element
    while current ~= nil do
        if current.ftdlFieldId ~= nil then
            return current.ftdlFieldId
        end

        current = current.parent
    end

    return nil
end

---@param fieldId number|nil
---@return table|nil
function FieldToDoMenuFrame:getFieldById(fieldId)
    if fieldId == nil then
        return nil
    end

    for _, field in ipairs(self.ownedFields) do
        if field.id == fieldId then
            return field
        end
    end

    return nil
end

---@param listIndex number|nil
---@return table|nil
function FieldToDoMenuFrame:getFieldAtListIndex(listIndex)
    if listIndex == nil then
        return nil
    end

    local index = math.floor(tonumber(listIndex) or -1)
    if index < 1 then
        return nil
    end

    return self.ownedFields[index]
end

---@param listIndex number|nil
function FieldToDoMenuFrame:setSelectedFieldByListIndex(listIndex)
    local field = self:getFieldAtListIndex(listIndex)
    self.selectedFieldId = field ~= nil and field.id or nil
end

---@param listItem ListItemElement|nil
function FieldToDoMenuFrame:onFieldSelectionChanged()
    if self.fieldList == nil then
        return
    end

    self:setSelectedFieldByListIndex(self.fieldList.selectedIndex)
end

function FieldToDoMenuFrame:onClickFieldRow(listItem)
    if listItem == nil then
        return
    end

    if listItem.ftdlFieldId ~= nil then
        self.selectedFieldId = listItem.ftdlFieldId
        local field = self:getSelectedField()
        if field ~= nil then
            local action, _, _ = self:getFieldSuggestionSelection(field)
            if action ~= nil then
                field.actionType = action.actionType
                field.autoComplete = action.autoComplete == true
                field.fertPass = action.fertPass
                field.fertPassTotal = action.fertPassTotal
            end
        end
        return
    end

    if self.fieldList ~= nil then
        self:setSelectedFieldByListIndex(self.fieldList.selectedIndex)
    end
end

---@return table|nil
function FieldToDoMenuFrame:getSelectedField()
    if self.selectedFieldId == nil then
        if self.fieldList ~= nil then
            self:setSelectedFieldByListIndex(self.fieldList.selectedIndex)
        end
    end

    if self.selectedFieldId == nil then
        return nil
    end

    for _, field in ipairs(self.ownedFields) do
        if field.id == self.selectedFieldId then
            return field
        end
    end

    return nil
end

function FieldToDoMenuFrame:onClickAdoptFieldSuggestion()
    local field = self:getSelectedField()
    if field == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_select_field_overview",
            "Bitte zuerst eine Feldzeile in der Feldübersicht anklicken."
        ))
        return
    end

    local manager = self:getManager()
    if manager == nil then
        return
    end

    local action, _, _ = self:getFieldSuggestionSelection(field)
    if action == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_no_work_needed",
            "%s: Kein Arbeitsschritt nötig (Alles ok).",
            field.name
        ))
        return
    end

    local actionType = action.actionType
    -- grass_swath/collect: adopt as manual reminder (allowUntrackable), not rejected as not_trackable.
    local isManualGrassLogistics = actionType == "grass_swath" or actionType == "grass_collect"

    -- For a non-actionable info primary, swap to a real trackable action when available,
    -- but never override an explicit manual grass-logistics pick.
    if not isManualGrassLogistics
        and not FieldWorkCatalog.isTrackable(action.actionType)
        and field.suggestionDetails ~= nil then
        for _, candidate in ipairs(field.suggestionDetails) do
            if candidate ~= nil
                and candidate.autoComplete == true
                and FieldWorkCatalog.isTrackable(candidate.actionType) then
                action = candidate
                break
            end
        end
    end

    if FieldWorkCatalog.isTrackable(action.actionType) and action.autoComplete ~= true then
        action.autoComplete = true
    end

    local task, errorKey = manager:addTaskFromFieldAction(field, action, isManualGrassLogistics)
    if task == nil then
        if errorKey == "no_suggestion" then
            InfoDialog.show(FieldToDoL10n.getText(
                "ftdl_info_no_work_needed",
                "%s: Kein Arbeitsschritt nötig (Alles ok).",
                field.name
            ))
        elseif errorKey == "not_trackable" then
            InfoDialog.show(FieldToDoL10n.getText(
                "ftdl_info_reminder_only",
                "%s: „%s“ ist nur eine Erinnerung — nutze „Feld-Aufgabe“ für eigene Notizen.",
                field.name,
                action.label or "-"
            ))
        elseif errorKey == nil then
            self:refreshManualTaskList(false, true)
        else
            InfoDialog.show(FieldToDoL10n.getText(
                "ftdl_info_adopt_failed",
                "Vorschlag konnte nicht übernommen werden."
            ))
        end
        return
    end

    if errorKey == "already_exists" then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_already_in_list",
            "Bereits in der To-Do-Liste:\n%s",
            "\n" .. task.text
        ))
    end

    self.selectedTaskId = task.id
    self:refreshManualTaskList(false, true)
end

---@param field table|nil
function FieldToDoMenuFrame:openPlannedCropPicker(field)
    if field == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_select_field_overview",
            "Bitte zuerst eine Feldzeile in der Feldübersicht anklicken."
        ))
        return
    end

    if FieldPlannedCrop == nil or FieldPlannedCrop.buildPickerOptions == nil then
        return
    end

    local entries, texts = FieldPlannedCrop.buildPickerOptions()
    if entries == nil or texts == nil or #texts == 0 then
        return
    end

    local defaultIndex = 1
    local currentValue = FieldPlannedCrop.getRaw(field.id)
    if currentValue ~= nil then
        for index, entry in ipairs(entries) do
            if entry.fruitTypeIndex == currentValue then
                defaultIndex = index
                break
            end
        end
    end

    self.pendingFieldForPlannedCrop = field
    self.pendingPlannedCropEntries = entries

    local title = FieldToDoL10n.getText(
        "ftdl_dialog_planned_crop_title",
        "Planfrucht für %s",
        field.name
    )

    if OptionDialog == nil or OptionDialog.show == nil then
        self.pendingFieldForPlannedCrop = nil
        self.pendingPlannedCropEntries = nil
        return
    end

    -- Second arg must be nil — passing self renders as "table: 0x..." subtitle in FS25.
    local boundCallback = function(...)
        return self:onPlannedCropPicked(...)
    end
    OptionDialog.show(boundCallback, nil, title, texts, defaultIndex)
end

function FieldToDoMenuFrame:onClickSetPlannedCrop()
    self:openPlannedCropPicker(self:getSelectedField())
end

function FieldToDoMenuFrame:onClickPlannedSowInRow(element)
    local fieldId = self:resolveFieldIdFromGuiElement(element)
    local field = self:getFieldById(fieldId)
    if field == nil then
        field = self:getSelectedField()
    end

    if field == nil then
        return
    end

    self.selectedFieldId = field.id
    self:openPlannedCropPicker(field)
end

---@param ... any
function FieldToDoMenuFrame:onPlannedCropPicked(...)
    local field = self.pendingFieldForPlannedCrop
    local entries = self.pendingPlannedCropEntries

    if field == nil or entries == nil or #entries == 0 then
        return
    end

    local selectedIndex = nil
    local selectedText = nil
    local accepted = true
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "number" then
            selectedIndex = math.floor(value)
        elseif type(value) == "string" then
            selectedText = value
        elseif type(value) == "boolean" then
            accepted = value
        elseif type(value) == "table" then
            selectedIndex = selectedIndex
                or tonumber(value.selectedIndex)
                or tonumber(value.selectedOption)
                or tonumber(value.index)
                or tonumber(value.state)

            if value.accepted ~= nil then
                accepted = value.accepted == true
            elseif value.clickOk ~= nil then
                accepted = value.clickOk == true
            end
        end
    end

    if selectedIndex == nil and not string.isNilOrWhitespace(selectedText) then
        for index, entry in ipairs(entries) do
            if entry.label == selectedText then
                selectedIndex = index
                break
            end
        end
    end

    if not accepted then
        self.pendingFieldForPlannedCrop = nil
        self.pendingPlannedCropEntries = nil
        return
    end

    if selectedIndex == nil then
        return
    end

    if selectedIndex < 1 then
        selectedIndex = selectedIndex + 1
    end

    local entry = entries[selectedIndex]
    if entry == nil then
        return
    end

    self.pendingFieldForPlannedCrop = nil
    self.pendingPlannedCropEntries = nil

    local manager = self:getManager()
    if manager == nil or manager.setFieldPlannedSowFruit == nil then
        return
    end

    manager:setFieldPlannedSowFruit(field.id, entry.fruitTypeIndex)

    if self.fieldSuggestionIndexByFieldId ~= nil then
        self.fieldSuggestionIndexByFieldId[field.id] = nil
    end

    if manager.refreshFieldRecordSync ~= nil then
        manager:refreshFieldRecordSync(field.id)
    end

    self.ownedFields = manager:getOwnedFields()

    if self.fieldList ~= nil then
        self.fieldList:reloadData()
    end
end

function FieldToDoMenuFrame:resetFieldSuggestionIndices()
    self.fieldSuggestionIndexByFieldId = {}
end

function FieldToDoMenuFrame:persistAdvisorSettings()
    local manager = self:getManager()
    if manager ~= nil and manager.saveSettingsNow ~= nil then
        manager:saveSettingsNow()
    end
end

function FieldToDoMenuFrame:onClickCycleWorkOrder()
    if FieldAdvisorSettings == nil then
        return
    end

    FieldAdvisorSettings.cycleWorkOrderPreset()
    self:resetFieldSuggestionIndices()
    self:updateSettingsWorkOrderLabel()
    self:updateOptionalColumns()
    self:refreshLists()
    self:persistAdvisorSettings()
end

function FieldToDoMenuFrame:onClickToggleOrganicMultiPass()
    if FieldAdvisorSettings == nil then
        return
    end

    FieldAdvisorSettings.toggleOrganicMultiPass()
    self:resetFieldSuggestionIndices()
    self:updateOptionalColumns()
    self:refreshLists()
    self:persistAdvisorSettings()
end

function FieldToDoMenuFrame:onClickToggleMulching()
    if FieldAdvisorSettings == nil then
        return
    end

    FieldAdvisorSettings.toggleMulching()
    self:resetFieldSuggestionIndices()
    self:updateOptionalColumns()
    self:refreshLists()
    self:persistAdvisorSettings()
end

function FieldToDoMenuFrame:onClickVisitField()
    local field = self:getSelectedField()
    if field == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_select_field",
            "Bitte zuerst eine Feldzeile anklicken."
        ))
        return
    end

    local manager = self:getManager()
    local scanner = manager ~= nil and manager.fieldScanner or nil
    local ok, errorKey = FieldVisit.visitField(field, scanner)

    if not ok then
        if errorKey == "no_position" then
            InfoDialog.show(FieldToDoL10n.getText(
                "ftdl_info_field_position_missing",
                "%s: Feldposition nicht gefunden.",
                field.name
            ))
        else
            InfoDialog.show(FieldToDoL10n.getText(
                "ftdl_info_teleport_failed",
                "Teleport zum Feld fehlgeschlagen."
            ))
        end
    end
end

function FieldToDoMenuFrame:onClickCycleFieldSuggestion(delta)
    local field = self:getSelectedField()
    if field == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_select_field_overview",
            "Bitte zuerst eine Feldzeile in der Feldübersicht anklicken."
        ))
        return
    end

    self:cycleFieldSuggestion(field, delta)
    self:refreshFieldSuggestionCell()
end

---@param element GuiElement|nil
function FieldToDoMenuFrame:onClickCycleFieldSuggestionInRow(element)
    local fieldId = self:resolveFieldIdFromGuiElement(element)
    local field = self:getFieldById(fieldId)
    if field == nil then
        field = self:getSelectedField()
    end

    if field == nil then
        return
    end

    self.selectedFieldId = field.id
    self:cycleFieldSuggestion(field, 1)
    self:refreshFieldSuggestionCell()
end

---@param field table
---@return table[]
function FieldToDoMenuFrame:buildFieldTaskPickerActions(field)
    local actions = {}
    local seen = {}

    local function addAction(action)
        if action == nil then
            return
        end

        local actionType = action.actionType or "none"
        if actionType == "none" or actionType == "harvest_info" or actionType == "growing" then
            return
        end

        local key = string.format("%s:%s", actionType, tostring(action.fertPass or 1))
        if seen[key] then
            return
        end

        seen[key] = true
        actions[#actions + 1] = action
    end

    if FieldAdvisor ~= nil and FieldAdvisor.getCycleableActions ~= nil and field.suggestionDetails ~= nil then
        for _, action in ipairs(FieldAdvisor.getCycleableActions(field.suggestionDetails)) do
            addAction(action)
        end
    end

    local function advisorText(key, fallback)
        if FieldAdvisor ~= nil and FieldAdvisor.text ~= nil then
            return FieldAdvisor.text(key, fallback)
        end

        return fallback
    end

    for _, action in ipairs(FieldWorkCatalog.buildPickerActions(advisorText)) do
        addAction(action)
    end

    actions[#actions + 1] = {
        actionType = "custom",
        pickerLabel = FieldToDoL10n.getText("ftdl_picker_custom_text", "Eigener Text ..."),
        autoComplete = false,
        isCustom = true,
    }

    return actions
end

function FieldToDoMenuFrame:onClickAddFieldTask()
    local field = self:getSelectedField()
    if field == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_select_field",
            "Bitte zuerst eine Feldzeile anklicken."
        ))
        return
    end

    self.pendingFieldForPicker = field
    self.pendingFieldTaskActions = self:buildFieldTaskPickerActions(field)

    local title = FieldToDoL10n.getText("ftdl_dialog_field_task_pick_title", "Aktion für %s wählen", field.name)
    local shown = FieldActionPicker ~= nil
        and FieldActionPicker.show ~= nil
        and FieldActionPicker.show(self, self.onFieldTaskActionPicked, title, self.pendingFieldTaskActions, 1)

    if shown then
        return
    end

    self.pendingFieldForCustomTask = field
    TextInputDialog.show(
        self.onAddFieldTaskDialog,
        self,
        "",
        FieldToDoL10n.getText("ftdl_dialog_field_task_title", "Aufgabe für %s", field.name),
        200
    )
end

---@param ... any
function FieldToDoMenuFrame:onFieldTaskActionPicked(...)
    local field = self.pendingFieldForPicker
    local actions = self.pendingFieldTaskActions

    if field == nil or actions == nil or #actions == 0 then
        return
    end

    local selectedIndex = nil
    local selectedText = nil
    local accepted = true
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "number" then
            selectedIndex = math.floor(value)
        elseif type(value) == "string" then
            selectedText = value
        elseif type(value) == "boolean" then
            accepted = value
        elseif type(value) == "table" then
            selectedIndex = selectedIndex
                or tonumber(value.selectedIndex)
                or tonumber(value.selectedOption)
                or tonumber(value.index)
                or tonumber(value.state)

            if value.accepted ~= nil then
                accepted = value.accepted == true
            elseif value.clickOk ~= nil then
                accepted = value.clickOk == true
            end
        end
    end

    if selectedIndex == nil and not string.isNilOrWhitespace(selectedText) and FieldActionPicker ~= nil then
        local optionTexts = FieldActionPicker.buildOptionTexts(actions)
        for index, text in ipairs(optionTexts) do
            if text == selectedText then
                selectedIndex = index
                break
            end
        end
    end

    if not accepted then
        self.pendingFieldForPicker = nil
        self.pendingFieldTaskActions = nil
        return
    end

    -- OptionDialog may emit intermediate callbacks while navigating.
    -- Only consume pending picker state when a concrete selection exists.
    if selectedIndex == nil then
        return
    end

    if selectedIndex < 1 then
        selectedIndex = selectedIndex + 1
    end

    local action = actions[selectedIndex]
    if action == nil then
        return
    end

    self.pendingFieldForPicker = nil
    self.pendingFieldTaskActions = nil

    if action.isCustom == true then
        self.pendingFieldForCustomTask = field
        TextInputDialog.show(
            self.onAddFieldTaskDialog,
            self,
            "",
            FieldToDoL10n.getText("ftdl_dialog_field_task_title", "Aufgabe für %s", field.name),
            200
        )
        return
    end

    local manager = self:getManager()
    if manager == nil then
        return
    end

    local task, errorKey = manager:addTaskFromFieldAction(field, action, true)
    if task == nil then
        if errorKey == nil then
            self:refreshManualTaskList(true, true)
            return
        end
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_adopt_failed",
            "Vorschlag konnte nicht übernommen werden."
        ))
        return
    end

    if errorKey == "already_exists" then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_already_in_list",
            "Bereits in der To-Do-Liste:\n%s",
            "\n" .. task.text
        ))
    end

    self.selectedTaskId = task.id
    self:refreshManualTaskList(true, true)
end

---@param text string|nil
---@param clickOk boolean|nil
function FieldToDoMenuFrame:onAddFieldTaskDialog(text, clickOk)
    local field = self.pendingFieldForCustomTask
    self.pendingFieldForCustomTask = nil

    if not clickOk or string.isNilOrWhitespace(text) or field == nil then
        return
    end

    local manager = self:getManager()
    if manager == nil then
        return
    end

    local task = manager:addCustomFieldTask(field, text, "custom", false)
    if task ~= nil then
        self.selectedTaskId = task.id
    end

    self:refreshManualTaskList(false, true)
end

---@param listIndex number|nil
---@return table|nil
function FieldToDoMenuFrame:getTaskAtListIndex(listIndex)
    if listIndex == nil then
        return nil
    end

    local index = math.floor(tonumber(listIndex) or -1)
    if index < 1 then
        return nil
    end

    return self.manualTasks[index]
end

---@param listIndex number|nil
function FieldToDoMenuFrame:setSelectedTaskByListIndex(listIndex)
    local task = self:getTaskAtListIndex(listIndex)
    self.selectedTaskId = task ~= nil and task.id or nil
end

---@param listItem ListItemElement|nil
function FieldToDoMenuFrame:onClickTaskRow(listItem)
    if listItem == nil then
        return
    end

    if listItem.ftdlTaskId ~= nil then
        self.selectedTaskId = listItem.ftdlTaskId
        return
    end

    if self.taskList ~= nil then
        self:setSelectedTaskByListIndex(self.taskList.selectedIndex)
    end
end

function FieldToDoMenuFrame:onTaskSelectionChanged()
    if self.taskList == nil or self.ignoreTaskSelectionChanged == true then
        return
    end

    self:setSelectedTaskByListIndex(self.taskList.selectedIndex)
end

---@return table|nil
function FieldToDoMenuFrame:getSelectedTask()
    local manager = self:getManager()
    if manager == nil then
        return nil
    end

    if self.selectedTaskId ~= nil then
        local task = manager:getManualTask(self.selectedTaskId)
        if task ~= nil then
            return task
        end
    end

    if self.taskList ~= nil then
        self:setSelectedTaskByListIndex(self.taskList.selectedIndex)
        if self.selectedTaskId ~= nil then
            return manager:getManualTask(self.selectedTaskId)
        end
    end

    return nil
end

---@param text string|nil
---@param clickOk boolean|nil
function FieldToDoMenuFrame:onAddTaskDialog(text, clickOk)
    if not clickOk or string.isNilOrWhitespace(text) then
        return
    end

    local manager = self:getManager()
    if manager == nil then
        return
    end

    local task = manager:addManualTask(text)
    if task ~= nil then
        self.selectedTaskId = task.id
    end

    self:refreshManualTaskList(false, true)
end

---@param text string|nil
---@param clickOk boolean|nil
function FieldToDoMenuFrame:onEditTaskDialog(text, clickOk)
    local taskId = self.editingTaskId
    self.editingTaskId = nil

    if not clickOk or string.isNilOrWhitespace(text) or taskId == nil then
        return
    end

    local manager = self:getManager()
    if manager == nil then
        return
    end

    manager:updateManualTask(taskId, text)
    self.selectedTaskId = taskId
    self:refreshManualTaskList()
end

function FieldToDoMenuFrame:onClickAddTask()
    TextInputDialog.show(
        self.onAddTaskDialog,
        self,
        "",
        FieldToDoL10n.getText("ftdl_dialog_new_task", "Neue Aufgabe"),
        200
    )
end

function FieldToDoMenuFrame:onClickEditTask()
    local task = self:getSelectedTask()
    if task == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_select_task",
            "Bitte zuerst eine Aufgabe in der Liste anklicken."
        ))
        return
    end

    self.editingTaskId = task.id
    TextInputDialog.show(
        self.onEditTaskDialog,
        self,
        task.text,
        FieldToDoL10n.getText("ftdl_dialog_edit_task", "Aufgabe bearbeiten"),
        200
    )
end

function FieldToDoMenuFrame:onClickDeleteTask()
    local task = self:getSelectedTask()
    if task == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_select_task",
            "Bitte zuerst eine Aufgabe in der Liste anklicken."
        ))
        return
    end

    self.deletingTaskId = task.id
    YesNoDialog.show(
        self.onConfirmDeleteTask,
        self,
        FieldToDoL10n.getText("ftdl_dialog_delete_task_body", "Aufgabe löschen?\n%s", "\n" .. task.text),
        FieldToDoL10n.getText("ftdl_dialog_delete_task_title", "Aufgabe löschen")
    )
end

---@param yes boolean
function FieldToDoMenuFrame:onConfirmDeleteTask(yes)
    local taskId = self.deletingTaskId
    self.deletingTaskId = nil

    if not yes or taskId == nil then
        return
    end

    local manager = self:getManager()
    if manager == nil then
        return
    end

    manager:deleteManualTask(taskId)
    self.selectedTaskId = nil
    self:refreshManualTaskList()
end

function FieldToDoMenuFrame:onClickToggleTask()
    local task = self:getSelectedTask()
    if task == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_select_task",
            "Bitte zuerst eine Aufgabe in der Liste anklicken."
        ))
        return
    end

    local manager = self:getManager()
    if manager == nil then
        return
    end

    self.selectedTaskId = task.id
    manager:toggleManualTask(task.id)
    self:refreshManualTaskList(false, true)
end

function FieldToDoMenuFrame:onClickMoveTaskUp()
    self:moveSelectedTask(-1)
end

function FieldToDoMenuFrame:onClickMoveTaskDown()
    self:moveSelectedTask(1)
end

---@param delta number
function FieldToDoMenuFrame:moveSelectedTask(delta)
    if self.selectedTaskId == nil then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_select_task",
            "Bitte zuerst eine Aufgabe in der Liste anklicken."
        ))
        return
    end

    local manager = self:getManager()
    if manager == nil or manager.moveTask == nil then
        return
    end

    local taskId = self.selectedTaskId
    -- Always move by stored task id, not by stale list row index.
    if not manager:moveTask(taskId, delta) then
        InfoDialog.show(FieldToDoL10n.getText(
            "ftdl_info_move_blocked",
            "Reihenfolge hier nicht änderbar (Rand der Liste oder erledigte Aufgabe)."
        ))
        self:syncTaskListSelection()
        return
    end

    self.selectedTaskId = taskId
    self:refreshManualTaskList(true, false)
end
