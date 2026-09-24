--[[
    FieldDebugConsoleInput.lua
    F9 / LCtrl+F9 — open mod debug command dialog (always; no native-console guessing).
    Registered via addModEventListener so the engine rebinds across input contexts
    (on foot, in vehicle, after keybind changes). Player/Vehicle-only registration
    left F9 dead in the ESC menu and after context switches.
]]

FieldDebugConsoleInput = {}
FieldDebugConsoleInput.ACTION_NAME = "FTDTL_DEBUG_CONSOLE"
FieldDebugConsoleInput.eventId = nil

local function ftdlDebugConsoleCallback(_, _, inputValue)
    if (inputValue or 0) <= 0 then
        return
    end
    if FieldDebugConsole ~= nil and FieldDebugConsole.openCommandDialog ~= nil then
        FieldDebugConsole.openCommandDialog()
    end
end

function FieldDebugConsoleInput:removeActionEvents()
    if self.eventId ~= nil and g_inputBinding ~= nil and g_inputBinding.removeActionEvent ~= nil then
        pcall(g_inputBinding.removeActionEvent, g_inputBinding, self.eventId)
    end
    self.eventId = nil
end

function FieldDebugConsoleInput:registerActionEvents()
    if g_inputBinding == nil or InputAction == nil or InputAction.FTDTL_DEBUG_CONSOLE == nil then
        return
    end

    self:removeActionEvents()

    local ok, eventId = g_inputBinding:registerActionEvent(
        InputAction.FTDTL_DEBUG_CONSOLE,
        self,
        ftdlDebugConsoleCallback,
        false,
        true,
        false,
        true
    )

    if ok and eventId ~= nil then
        g_inputBinding:setActionEventTextVisibility(eventId, false)
        self.eventId = eventId
    end
end

--- Engine calls this on mod listeners when input contexts refresh.
function FieldDebugConsoleInput:onRegisterActionEvents()
    self:registerActionEvents()
end

function FieldDebugConsoleInput:loadMap(_name)
    self:registerActionEvents()
end

function FieldDebugConsoleInput.install()
    if addModEventListener ~= nil then
        addModEventListener(FieldDebugConsoleInput)
    end
end

FieldDebugConsoleInput.install()
