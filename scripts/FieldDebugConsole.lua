--[[
    FieldDebugConsole.lua
    Debug command entry with TextInputDialog fallback when the native console is unavailable.
    Hotkey F9 (or LCtrl+F9) tries the native dev console first; otherwise opens a command
    dialog that runs mod debug commands and forwards other input to executeConsoleCommand
    when the engine exposes it.
]]

FieldDebugConsole = {}
FieldDebugConsole.lastCommand = ""
FieldDebugConsole.isDialogOpen = false

---@param message string
local function logInfo(message)
    if FieldToDoLog ~= nil then
        FieldToDoLog.info(message)
    elseif Logging ~= nil and Logging.info ~= nil then
        Logging.info("[FS25_FieldToDoList] %s", message)
    end
end

---@return boolean
function FieldDebugConsole.tryOpenNativeConsole()
    local attempts = {
        function()
            if g_gui ~= nil and g_gui.toggleConsole ~= nil then
                g_gui:toggleConsole()
                return true
            end
        end,
        function()
            if g_gui ~= nil and g_gui.showConsole ~= nil then
                g_gui:showConsole()
                return true
            end
        end,
        function()
            if g_console ~= nil then
                if g_console.toggle ~= nil then
                    g_console:toggle()
                    return true
                end
                if g_console.setIsVisible ~= nil then
                    g_console:setIsVisible(true)
                    return true
                end
                if g_console.open ~= nil then
                    g_console:open()
                    return true
                end
            end
        end,
        function()
            if g_developerConsole ~= nil and g_developerConsole.toggle ~= nil then
                g_developerConsole:toggle()
                return true
            end
        end,
    }

    for _, attempt in ipairs(attempts) do
        local ok, result = pcall(attempt)
        if ok and result == true then
            logInfo("Native dev console toggled via hotkey.")
            return true
        end
    end

    return false
end

---@param line string
---@return string
function FieldDebugConsole.getHelpText()
    return table.concat({
        "ftdlHelp — this help",
        "ftdlDump <fieldId> — dump one field to log.txt",
        "ftdlStrawScan <fieldId> [x z] — probe all straw/windrow APIs (search STRAW_SCAN in log.txt)",
        "ftdlFruits — list fruit types to log.txt",
        "ftdlAll — dump all owned fields to log.txt",
        "ftdlSync — sync/farm/edit diagnostics (search SYNC)",
        "ftdlOwned — owned-field / farmId diagnostics (search OWNED DIAG)",
        "Other lines are passed to executeConsoleCommand when available.",
    }, "\n")
end

---@param line string
---@return string
function FieldDebugConsole.executeLine(line)
    line = line ~= nil and string.gsub(tostring(line), "^%s*(.-)%s*$", "%1") or ""
    if line == "" then
        return "Empty command."
    end

    FieldDebugConsole.lastCommand = line
    local command, args = string.match(line, "^(%S+)%s*(.*)$")
    command = command ~= nil and string.lower(command) or line

    if command == "ftdlhelp" or command == "help" then
        return FieldDebugConsole.getHelpText()
    end

    if command == "ftdldump" and FieldDebugDump ~= nil and FieldDebugDump.consoleDump ~= nil then
        local fieldId = args ~= nil and string.match(args, "^(%S+)") or nil
        return FieldDebugDump:consoleDump(fieldId)
    end

    if command == "ftdlfruits" and FieldDebugDump ~= nil and FieldDebugDump.consoleFruits ~= nil then
        return FieldDebugDump:consoleFruits()
    end

    if command == "ftdlstrawscan" and FieldDebugDump ~= nil and FieldDebugDump.consoleStrawScan ~= nil then
        return FieldDebugDump:consoleStrawScan(args)
    end

    if command == "ftdlall" and FieldDebugDump ~= nil then
        local manager = g_currentMission ~= nil and g_currentMission.fieldToDoList or nil
        if manager == nil or manager.getOwnedFields == nil then
            return "No fieldToDoList manager — load a savegame first."
        end
        local fields = manager:getOwnedFields(true)
        if fields == nil or #fields == 0 then
            return "No owned fields found."
        end
        if FieldDebugDump.dumpAllOwnedFields(fields) then
            return string.format("Dumped %d owned field(s) to log.txt (search 'DUMP').", #fields)
        end
        return "Field dump failed — see log.txt."
    end

    if command == "ftdlsync" and FieldDebugDump ~= nil and FieldDebugDump.consoleSync ~= nil then
        return FieldDebugDump:consoleSync()
    end

    if command == "ftdlowned" and FieldDebugDump ~= nil and FieldDebugDump.consoleOwned ~= nil then
        return FieldDebugDump:consoleOwned()
    end

    if command == "ftdlopen" then
        FieldDebugConsole.openCommandDialog()
        return "Debug dialog opened."
    end

    local executeFn = rawget(_G, "executeConsoleCommand")
    if type(executeFn) == "function" then
        local ok, result = pcall(executeFn, line)
        if ok then
            if result == nil or result == "" then
                return "OK"
            end
            return tostring(result)
        end
        return string.format("executeConsoleCommand failed: %s", tostring(result))
    end

    return string.format(
        "Unknown command '%s'. Try: ftdlHelp, ftdlDump <id>, ftdlStrawScan <id>, ftdlFruits, ftdlAll, ftdlSync, ftdlOwned",
        command
    )
end

---@param ... any
function FieldDebugConsole:onCommandDialogClosed(...)
    FieldDebugConsole.isDialogOpen = false

    local text = nil
    local accepted = false
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "string" then
            text = value
        elseif type(value) == "boolean" then
            accepted = value
        end
    end

    if not accepted or text == nil or string.isNilOrWhitespace(text) then
        return
    end

    local result = FieldDebugConsole.executeLine(text)
    if InfoDialog ~= nil and InfoDialog.show ~= nil then
        InfoDialog.show(result, nil, nil, DialogElement.TYPE_INFO)
    else
        logInfo(result)
    end
end

function FieldDebugConsole.openCommandDialog()
    if FieldDebugConsole.isDialogOpen then
        return
    end
    if TextInputDialog == nil or TextInputDialog.show == nil then
        logInfo("TextInputDialog unavailable — use log.txt after ftdlAll.")
        if FieldDebugDump ~= nil and FieldDebugDump.dumpAllOwnedFields ~= nil then
            local manager = g_currentMission ~= nil and g_currentMission.fieldToDoList or nil
            if manager ~= nil and manager.getOwnedFields ~= nil then
                FieldDebugDump.dumpAllOwnedFields(manager:getOwnedFields(true))
            end
        end
        return
    end

    FieldDebugConsole.isDialogOpen = true
    local title = FieldToDoL10n ~= nil
        and FieldToDoL10n.getText("ftdl_dialog_debug_console_title", "Field To-Do Debug-Konsole")
        or "Field To-Do Debug-Konsole"
    TextInputDialog.show(
        FieldDebugConsole.onCommandDialogClosed,
        FieldDebugConsole,
        FieldDebugConsole.lastCommand,
        title,
        120
    )
end

function FieldDebugConsole.toggle()
    if FieldDebugConsole.tryOpenNativeConsole() then
        return
    end
    FieldDebugConsole.openCommandDialog()
end

function FieldDebugConsole:consoleOpen()
    FieldDebugConsole.toggle()
    return "Debug console hotkey action triggered."
end

function FieldDebugConsole.register()
    if addConsoleCommand == nil then
        return
    end
    addConsoleCommand("ftdlOpen", "Open debug console dialog (same as F9)", "consoleOpen", FieldDebugConsole)
end

function FieldDebugConsole.unregister()
    if removeConsoleCommand ~= nil then
        removeConsoleCommand("ftdlOpen")
    end
    FieldDebugConsole.isDialogOpen = false
end
