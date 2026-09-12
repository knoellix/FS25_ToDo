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
    local ok, xmlFile = pcall(XMLFile.load, "fieldToDoHudLoad", filePath)
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
    local ok, xmlFile = pcall(XMLFile.create, "fieldToDoHudSave", filePath, "fieldToDoHud")
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
    local px = FieldToDoHudOverlay.PANEL_X
    local py = FieldToDoHudOverlay.PANEL_Y
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
