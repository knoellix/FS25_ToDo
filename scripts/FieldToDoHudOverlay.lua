--[[
    FieldToDoHudOverlay.lua
    In-world To-Do list styled like the vanilla field info panel (compact, top-right).
]]

FieldToDoHudOverlay = {}
FieldToDoHudOverlay.__index = FieldToDoHudOverlay

FieldToDoHudOverlay.MAX_ENTRIES = 5
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

---@return FieldToDoHudOverlay
function FieldToDoHudOverlay.new()
    local self = setmetatable({}, FieldToDoHudOverlay)
    self.isVisible = false
    self.isInitialized = false
    self.fillOverlay = nil
    self.displayRows = {}
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
