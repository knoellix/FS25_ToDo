--[[
    FieldDebugConsoleInput.lua
    F9 and LCtrl+F9 — open dev console (best effort) or mod command dialog.
]]

FieldDebugConsoleInput = {}
FieldDebugConsoleInput.ACTION_NAME = "FTDTL_DEBUG_CONSOLE"
FieldDebugConsoleInput.lastEventId = nil

local function ftdlDebugConsoleCallback(_, _, inputValue)
    if (inputValue or 0) <= 0 then
        return
    end
    if FieldDebugConsole ~= nil and FieldDebugConsole.toggle ~= nil then
        FieldDebugConsole.toggle()
    end
end

---@param actionId number|nil
---@param callback function
---@param labelKey string
---@param labelFallback string
local function registerAction(actionId, callback, labelKey, labelFallback)
    if actionId == nil or g_inputBinding == nil then
        return
    end

    if FieldDebugConsoleInput.lastEventId ~= nil then
        local actionEvents = g_inputBinding.actionEvents
        if actionEvents ~= nil and actionEvents[FieldDebugConsoleInput.lastEventId] ~= nil then
            return
        end
        FieldDebugConsoleInput.lastEventId = nil
    end

    local target = FieldDebugConsole or FieldDebugConsoleInput
    local ok, eventId = g_inputBinding:registerActionEvent(
        actionId,
        target,
        callback,
        false,
        true,
        false,
        false,
        nil,
        true
    )

    if ok and eventId ~= nil then
        g_inputBinding:setActionEventActive(eventId, true)
        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
        local label = FieldToDoL10n ~= nil and FieldToDoL10n.getText(labelKey, labelFallback) or labelFallback
        g_inputBinding:setActionEventText(eventId, label)
        FieldDebugConsoleInput.lastEventId = eventId
    end
end

function FieldDebugConsoleInput.install()
    if PlayerInputComponent ~= nil and PlayerInputComponent.registerActionEvents ~= nil then
        PlayerInputComponent.registerActionEvents = Utils.appendedFunction(
            PlayerInputComponent.registerActionEvents,
            function(inputComponent)
                if inputComponent.player == nil or not inputComponent.player.isOwner then
                    return
                end
                if g_inputBinding == nil or InputAction == nil or InputAction.FTDTL_DEBUG_CONSOLE == nil then
                    return
                end

                g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
                registerAction(
                    InputAction.FTDTL_DEBUG_CONSOLE,
                    ftdlDebugConsoleCallback,
                    "input_FTDTL_DEBUG_CONSOLE",
                    "Debug-Konsole"
                )
                g_inputBinding:endActionEventsModification()
            end
        )
    end

    if Vehicle ~= nil and Vehicle.registerActionEvents ~= nil then
        Vehicle.registerActionEvents = Utils.appendedFunction(
            Vehicle.registerActionEvents,
            function(vehicle, isActiveForInput)
                if not isActiveForInput or g_inputBinding == nil or InputAction == nil then
                    return
                end
                if InputAction.FTDTL_DEBUG_CONSOLE == nil then
                    return
                end
                if FieldDebugConsoleInput.lastEventId ~= nil then
                    local actionEvents = g_inputBinding.actionEvents
                    if actionEvents ~= nil and actionEvents[FieldDebugConsoleInput.lastEventId] ~= nil then
                        return
                    end
                    FieldDebugConsoleInput.lastEventId = nil
                end

                registerAction(
                    InputAction.FTDTL_DEBUG_CONSOLE,
                    ftdlDebugConsoleCallback,
                    "input_FTDTL_DEBUG_CONSOLE",
                    "Debug-Konsole"
                )
            end
        )
    end
end

FieldDebugConsoleInput.install()
