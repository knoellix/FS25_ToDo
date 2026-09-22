--[[
    FieldToDoHudOverlay.lua
    In-world To-Do list styled like the vanilla field info panel (compact, top-right).
]]

FieldToDoHudOverlay = {}
FieldToDoHudOverlay.__index = FieldToDoHudOverlay

FieldToDoHudOverlay.MAX_ENTRIES = 5
FieldToDoHudOverlay.DRAG_MOVE_THRESHOLD = 0.005
FieldToDoHudOverlay.PANEL_MARGIN = 0.01
FieldToDoHudOverlay.PANEL_W = 0.168
FieldToDoHudOverlay.PANEL_X = 0.827
FieldToDoHudOverlay.PANEL_Y = 0.72
FieldToDoHudOverlay.ROW_H = 0.020
FieldToDoHudOverlay.HEADER_H = 0.022
FieldToDoHudOverlay.PADDING = 0.006
FieldToDoHudOverlay.ACCENT_W = 0.003
FieldToDoHudOverlay.TEXT_SIZE = 0.0125
FieldToDoHudOverlay.HEADER_TEXT_SIZE = 0.014
FieldToDoHudOverlay.MAX_TEXT_CHARS = 46

FieldToDoHudOverlay.COLOR_BG = { 0.00439, 0.00478, 0.00368, 0.72 }       -- fs25_colorMainDark
FieldToDoHudOverlay.COLOR_HEADER = { 0.33716, 0.55834, 0.0003, 1.00 }    -- fs25_colorGreen
FieldToDoHudOverlay.COLOR_TEXT = { 0.89627, 0.92158, 0.81485, 1.00 }     -- fs25_colorMainLight
FieldToDoHudOverlay.COLOR_DONE = { 0.89627, 0.92158, 0.81485, 0.45 }
FieldToDoHudOverlay.COLOR_DIM = { 0.89627, 0.92158, 0.81485, 0.55 }
FieldToDoHudOverlay.COLOR_ACCENT = { 0.22323, 0.40724, 0.00368, 0.95 }   -- fs25_colorMainHighlight
FieldToDoHudOverlay.instance = nil
FieldToDoHudOverlay.xmlSchema = nil

function FieldToDoHudOverlay.initXMLSchema()
    if FieldToDoHudOverlay.xmlSchema ~= nil or XMLSchema == nil then
        return FieldToDoHudOverlay.xmlSchema
    end

    local schema = XMLSchema.new("fieldToDoHud")
    schema:register(XMLValueType.FLOAT, "fieldToDoHud#panelX", "HUD panel X (0–1)")
    schema:register(XMLValueType.FLOAT, "fieldToDoHud#panelY", "HUD panel Y (0–1)")
    FieldToDoHudOverlay.xmlSchema = schema
    return schema
end

function FieldToDoHudOverlay.clampPanelPosition(panelX, panelY, panelW, panelH, margin)
    margin = margin or FieldToDoHudOverlay.PANEL_MARGIN
    panelW = panelW or FieldToDoHudOverlay.PANEL_W
    panelH = panelH or 0.08
    local minX = margin
    local maxX = 1 - margin - panelW
    local minY = margin
    local maxY = 1 - margin - panelH
    if maxX < minX then
        panelX = minX
    else
        panelX = math.max(minX, math.min(maxX, panelX))
    end
    if maxY < minY then
        panelY = minY
    else
        panelY = math.max(minY, math.min(maxY, panelY))
    end
    return panelX, panelY
end

function FieldToDoHudOverlay.getHeaderRect(panelX, panelY, panelW, panelH, headerH)
    headerH = headerH or FieldToDoHudOverlay.HEADER_H
    return panelX, panelY + panelH - headerH, panelW, headerH
end

function FieldToDoHudOverlay.getRowRect(panelX, panelY, panelW, panelH, headerH, rowH, rowIndex)
    headerH = headerH or FieldToDoHudOverlay.HEADER_H
    rowH = rowH or FieldToDoHudOverlay.ROW_H
    rowIndex = math.floor(tonumber(rowIndex) or 0)
    local listTopY = panelY + panelH - headerH
    local rowY = listTopY - rowIndex * rowH
    return panelX, rowY, panelW, rowH
end

function FieldToDoHudOverlay.pointInRect(px, py, x, y, w, h)
    if px == nil or py == nil or x == nil or y == nil or w == nil or h == nil then
        return false
    end
    return px >= x and px <= x + w and py >= y and py <= y + h
end

function FieldToDoHudOverlay.getSettingsDirectory()
    local base = nil
    if getUserProfileAppPath ~= nil then
        local ok, path = pcall(getUserProfileAppPath)
        if ok and path ~= nil and path ~= "" then
            base = path
        end
    end
    if base == nil then
        return nil
    end
    -- Normalize trailing slash
    if string.sub(base, -1) ~= "/" and string.sub(base, -1) ~= "\\" then
        base = base .. "/"
    end
    return base .. "modSettings/FS25_FieldToDoList"
end

function FieldToDoHudOverlay.getSettingsFilePath()
    local dir = FieldToDoHudOverlay.getSettingsDirectory()
    if dir == nil then
        return nil
    end
    return dir .. "/hud.xml"
end

function FieldToDoHudOverlay:loadPositionFromDisk()
    self.panelX = FieldToDoHudOverlay.PANEL_X
    self.panelY = FieldToDoHudOverlay.PANEL_Y
    local filePath = FieldToDoHudOverlay.getSettingsFilePath()
    if filePath == nil or fileExists == nil or not fileExists(filePath) then
        return
    end
    if XMLFile == nil or XMLFile.load == nil then
        return
    end
    FieldToDoHudOverlay.initXMLSchema()
    local schema = FieldToDoHudOverlay.xmlSchema
    local ok, xmlFile = pcall(XMLFile.load, "fieldToDoHudLoad", filePath, schema)
    if not ok or xmlFile == nil then
        return
    end
    local x = xmlFile.getValue ~= nil and xmlFile:getValue("fieldToDoHud#panelX") or nil
    local y = xmlFile.getValue ~= nil and xmlFile:getValue("fieldToDoHud#panelY") or nil
    if xmlFile.delete ~= nil then
        xmlFile:delete()
    end
    x = tonumber(x)
    y = tonumber(y)
    if x ~= nil and y ~= nil then
        self.panelX, self.panelY = FieldToDoHudOverlay.clampPanelPosition(
            x, y, FieldToDoHudOverlay.PANEL_W, 0.08, FieldToDoHudOverlay.PANEL_MARGIN
        )
    end
end

function FieldToDoHudOverlay:savePositionToDisk()
    local dir = FieldToDoHudOverlay.getSettingsDirectory()
    local filePath = FieldToDoHudOverlay.getSettingsFilePath()
    if dir == nil or filePath == nil then
        return
    end
    if createFolder ~= nil then
        pcall(createFolder, dir)
    end
    if XMLFile == nil or XMLFile.create == nil then
        return
    end
    FieldToDoHudOverlay.initXMLSchema()
    local schema = FieldToDoHudOverlay.xmlSchema
    local ok, xmlFile = pcall(XMLFile.create, "fieldToDoHudSave", filePath, "fieldToDoHud", schema)
    if not ok or xmlFile == nil then
        return
    end
    if xmlFile.setValue ~= nil then
        xmlFile:setValue("fieldToDoHud#panelX", self.panelX)
        xmlFile:setValue("fieldToDoHud#panelY", self.panelY)
    end
    if xmlFile.save ~= nil then
        xmlFile:save()
    end
    if xmlFile.delete ~= nil then
        xmlFile:delete()
    end
    self.positionDirty = false
end

---@return FieldToDoHudOverlay
function FieldToDoHudOverlay.new()
    local self = setmetatable({}, FieldToDoHudOverlay)
    self.isVisible = false
    self.isInitialized = false
    self.fillOverlay = nil
    self.displayRows = {}
    self.panelX = FieldToDoHudOverlay.PANEL_X
    self.panelY = FieldToDoHudOverlay.PANEL_Y
    self.positionDirty = false
    self.dragActive = false
    self.dragMoved = false
    self.dragOffsetX = 0
    self.dragOffsetY = 0
    self.mouseDown = false
    self.mouseDownOnHeader = false
    self.mouseDownRowIndex = nil
    self.mouseDownX = nil
    self.mouseDownY = nil
    self.lastPanelH = 0.08
    return self
end

function FieldToDoHudOverlay:initialize()
    if self.isInitialized then
        return
    end

    if createImageOverlay ~= nil then
        self.fillOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end

    self.isInitialized = true
    self:loadPositionFromDisk()
end

function FieldToDoHudOverlay:delete()
    self.fillOverlay = nil
    self.isInitialized = false
    self.displayRows = {}
end

function FieldToDoHudOverlay:toggle()
    self.isVisible = not self.isVisible
end

---@param visible boolean
function FieldToDoHudOverlay:setVisible(visible)
    self.isVisible = visible == true
end

---@param text string|nil
---@param maxChars number
---@return string
function FieldToDoHudOverlay.truncateText(text, maxChars)
    if text == nil then
        return ""
    end

    if string.len(text) <= maxChars then
        return text
    end

    return string.sub(text, 1, maxChars - 3) .. "..."
end

---@param text string|nil
---@return string
function FieldToDoHudOverlay.cleanTaskText(text)
    if text == nil then
        return ""
    end

    text = string.gsub(text, " / gruppieren", "")
    text = string.gsub(text, " / Gruppieren", "")
    return text
end

function FieldToDoHudOverlay:rebuildDisplayRows()
    self.displayRows = {}

    if g_currentMission == nil or g_currentMission.fieldToDoList == nil then
        return
    end

    local tasks = g_currentMission.fieldToDoList.getManualTasksForDisplay ~= nil
        and g_currentMission.fieldToDoList:getManualTasksForDisplay()
        or g_currentMission.fieldToDoList:getManualTasks()
    local openCount = 0

    for _, task in ipairs(tasks) do
        if not task.completed and openCount < FieldToDoHudOverlay.MAX_ENTRIES then
            openCount = openCount + 1
            self.displayRows[#self.displayRows + 1] = {
                taskId = task.id,
                text = FieldToDoHudOverlay.truncateText(
                    FieldToDoHudOverlay.cleanTaskText(task.text),
                    FieldToDoHudOverlay.MAX_TEXT_CHARS
                ),
                completed = false,
            }
        end
    end
end

---@param rowCount number
---@return number panelHeight
function FieldToDoHudOverlay:calcPanelHeight(rowCount)
    local rows = math.max(1, rowCount)
    return FieldToDoHudOverlay.HEADER_H
        + rows * FieldToDoHudOverlay.ROW_H
        + FieldToDoHudOverlay.PADDING * 2
end

function FieldToDoHudOverlay:clearMouseInteractionState()
    self.dragActive = false
    self.dragMoved = false
    self.mouseDown = false
    self.mouseDownOnHeader = false
    self.mouseDownRowIndex = nil
    self.mouseDownX = nil
    self.mouseDownY = nil
end

function FieldToDoHudOverlay:isMouseCursorVisible()
    if g_inputBinding == nil then
        return false
    end
    local ib = g_inputBinding
    if ib.getShowMouseCursor ~= nil then
        local ok, shown = pcall(ib.getShowMouseCursor, ib)
        if ok then
            return shown == true
        end
    end
    if ib.showMouseCursor ~= nil then
        return ib.showMouseCursor == true
    end
    -- Fallback: if last mouse pos exists and HUD can draw, allow interaction
    -- (AutoDrive-style unlock usually sets showMouseCursor; without it, skip).
    return false
end

function FieldToDoHudOverlay:getMouseState()
    if g_inputBinding == nil then
        return nil
    end
    local x = g_inputBinding.mousePosXLast
    local y = g_inputBinding.mousePosYLast
    if x == nil or y == nil then
        return nil
    end
    local down = false
    if Input ~= nil and Input.MOUSE_BUTTON_LEFT ~= nil and Input.isMouseButtonPressed ~= nil then
        local ok, pressed = pcall(Input.isMouseButtonPressed, Input.MOUSE_BUTTON_LEFT)
        if ok then
            down = pressed == true
        end
    end
    return { x = x, y = y, down = down }
end

function FieldToDoHudOverlay:tryCompleteRow(rowIndex)
    local row = self.displayRows[rowIndex]
    if row == nil or row.taskId == nil then
        return
    end
    if FieldToDoPermissions == nil or not FieldToDoPermissions.canEditLocal() then
        if FieldToDoLog ~= nil then
            FieldToDoLog.info(FieldToDoL10n.getText(
                "ftdl_edit_denied",
                "No permission to change to-dos"
            ))
        end
        return
    end
    if g_currentMission == nil or g_currentMission.fieldToDoList == nil then
        return
    end
    g_currentMission.fieldToDoList:toggleManualTask(row.taskId)
end

function FieldToDoHudOverlay:update(dt)
    if not self:canDraw() or not self:isMouseCursorVisible() then
        self:clearMouseInteractionState()
        return
    end

    local mouse = self:getMouseState()
    if mouse == nil then
        return
    end

    local panelW = FieldToDoHudOverlay.PANEL_W
    local headerH = FieldToDoHudOverlay.HEADER_H
    local rowH = FieldToDoHudOverlay.ROW_H
    local numRows = math.min(#self.displayRows, FieldToDoHudOverlay.MAX_ENTRIES)
    local panelH = self.lastPanelH
    if panelH == nil or panelH <= 0 then
        panelH = self:calcPanelHeight(numRows == 0 and 1 or numRows)
    end
    local px = self.panelX or FieldToDoHudOverlay.PANEL_X
    local py = self.panelY or FieldToDoHudOverlay.PANEL_Y

    local wasDown = self.mouseDown == true
    local down = mouse.down == true

    if down and not wasDown then
        self.dragActive = false
        self.dragMoved = false
        self.mouseDownOnHeader = false
        self.mouseDownRowIndex = nil
        self.mouseDownX = mouse.x
        self.mouseDownY = mouse.y

        local hx, hy, hw, hh = FieldToDoHudOverlay.getHeaderRect(px, py, panelW, panelH, headerH)
        if FieldToDoHudOverlay.pointInRect(mouse.x, mouse.y, hx, hy, hw, hh) then
            self.mouseDownOnHeader = true
            self.dragOffsetX = mouse.x - px
            self.dragOffsetY = mouse.y - py
        else
            for index = 1, numRows do
                local rx, ry, rw, rh = FieldToDoHudOverlay.getRowRect(
                    px, py, panelW, panelH, headerH, rowH, index
                )
                if FieldToDoHudOverlay.pointInRect(mouse.x, mouse.y, rx, ry, rw, rh) then
                    self.mouseDownRowIndex = index
                    break
                end
            end
        end
    end

    if down and self.mouseDownOnHeader then
        local dx = mouse.x - (self.mouseDownX or mouse.x)
        local dy = mouse.y - (self.mouseDownY or mouse.y)
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist > FieldToDoHudOverlay.DRAG_MOVE_THRESHOLD then
            self.dragActive = true
            self.dragMoved = true
        end
        if self.dragActive then
            self.panelX = mouse.x - self.dragOffsetX
            self.panelY = mouse.y - self.dragOffsetY
            self.panelX, self.panelY = FieldToDoHudOverlay.clampPanelPosition(
                self.panelX, self.panelY, panelW, panelH, FieldToDoHudOverlay.PANEL_MARGIN
            )
            self.positionDirty = true
        end
    end

    if not down and wasDown then
        if self.dragMoved then
            self:savePositionToDisk()
        elseif self.mouseDownRowIndex ~= nil and not self.dragMoved then
            self:tryCompleteRow(self.mouseDownRowIndex)
        end
        self:clearMouseInteractionState()
    else
        self.mouseDown = down
    end
end

function FieldToDoHudOverlay:canDraw()
    if not self.isVisible or not self.isInitialized then
        return false
    end

    if g_currentMission == nil or g_gui == nil then
        return false
    end

    -- Dedicated server / no local player: never draw HUD.
    if g_localPlayer == nil then
        return false
    end

    if g_gui:getIsGuiVisible() then
        return false
    end

    return self.fillOverlay ~= nil
end

function FieldToDoHudOverlay:draw()
    if not self:canDraw() then
        return
    end

    self:rebuildDisplayRows()

    local panelW = FieldToDoHudOverlay.PANEL_W
    local rowH = FieldToDoHudOverlay.ROW_H
    local headerH = FieldToDoHudOverlay.HEADER_H
    local pad = FieldToDoHudOverlay.PADDING
    local numRows = math.min(#self.displayRows, FieldToDoHudOverlay.MAX_ENTRIES)
    local showEmpty = numRows == 0
    local panelH = self:calcPanelHeight(showEmpty and 1 or numRows)
    local px = self.panelX or FieldToDoHudOverlay.PANEL_X
    local py = self.panelY or FieldToDoHudOverlay.PANEL_Y
    px, py = FieldToDoHudOverlay.clampPanelPosition(
        px, py, panelW, panelH, FieldToDoHudOverlay.PANEL_MARGIN
    )
    self.panelX = px
    self.panelY = py
    self.lastPanelH = panelH
    local textX = px + pad + FieldToDoHudOverlay.ACCENT_W

    setOverlayColor(self.fillOverlay, unpack(FieldToDoHudOverlay.COLOR_BG))
    renderOverlay(self.fillOverlay, px, py, panelW, panelH)

    setOverlayColor(self.fillOverlay, unpack(FieldToDoHudOverlay.COLOR_ACCENT))
    renderOverlay(self.fillOverlay, px, py, FieldToDoHudOverlay.ACCENT_W, panelH)

    local title = FieldToDoL10n.getText("ftdl_hud_title", "Aufgaben")
    setTextBold(true)
    setTextColor(unpack(FieldToDoHudOverlay.COLOR_HEADER))
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(textX, py + panelH - headerH + pad * 0.35, FieldToDoHudOverlay.HEADER_TEXT_SIZE, title:upper())
    setTextBold(false)

    local listTopY = py + panelH - headerH

    if showEmpty then
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(unpack(FieldToDoHudOverlay.COLOR_DIM))
        local emptyText = FieldToDoL10n.getText("ftdl_hud_empty", "Keine Aufgaben")
        renderText(textX, py + pad, FieldToDoHudOverlay.TEXT_SIZE, emptyText)
    else
        for index = 1, numRows do
            local row = self.displayRows[index]
            local rowY = listTopY - index * rowH
            local prefix = row.completed and "- " or "* "
            local color = row.completed and FieldToDoHudOverlay.COLOR_DONE or FieldToDoHudOverlay.COLOR_TEXT

            setTextAlignment(RenderText.ALIGN_LEFT)
            setTextColor(unpack(color))
            renderText(textX, rowY + rowH * 0.12, FieldToDoHudOverlay.TEXT_SIZE, prefix .. (row.text or ""))
        end
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
end
