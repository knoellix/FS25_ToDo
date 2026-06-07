--[[
    InGameMenuIntegration.lua
    Registers the field overview / To-Do page in the ESC in-game menu.
    Registration runs after mission load (CropStress pattern), not at mod parse time.

    Forwards updateMenuFrame -> FieldToDoMenuFrame:onFrameUpdate while the tab is visible
    (vanilla InGameMenu does not tick custom tab pages). syncFieldListFromScan after scan batches.
]]

FieldToDoInGameMenuIntegration = {}
FieldToDoInGameMenuIntegration.MENU_PAGE_NAME = "menuFieldToDo"
FieldToDoInGameMenuIntegration.CLASS_NAME = "FieldToDoMenuFrame"
FieldToDoInGameMenuIntegration.XML_FILENAME = "gui/FieldToDoMenuFrame.xml"
FieldToDoInGameMenuIntegration.MENU_ICON_PATH = "gui/menuIcon.dds"
FieldToDoInGameMenuIntegration.MENU_ICON_UVS = { 0, 0, 1024, 1024 }
FieldToDoInGameMenuIntegration.menuScreen = nil
FieldToDoInGameMenuIntegration._menuFrameUpdateTime = nil

local LOG_PREFIX = "[FS25_FieldToDoList]"
local pendingRegistration = false
local pendingModDirectory = nil

local function logWarning(message, ...)
    if FieldToDoLog ~= nil then
        FieldToDoLog.warning(message, ...)
        return
    end

    if Logging == nil or Logging.warning == nil then
        return
    end

    Logging.warning("%s %s", LOG_PREFIX, string.format(message, ...))
end

local function logError(message, ...)
    if FieldToDoLog ~= nil then
        FieldToDoLog.error(message, ...)
        return
    end

    if Logging == nil or Logging.error == nil then
        logWarning(message, ...)
        return
    end

    Logging.error("%s %s", LOG_PREFIX, string.format(message, ...))
end

local function logInfo(message, ...)
    if FieldToDoLog ~= nil then
        FieldToDoLog.info(message, ...)
        return
    end

    if Logging == nil or Logging.info == nil then
        return
    end

    Logging.info("%s %s", LOG_PREFIX, string.format(message, ...))
end

---@param inGameMenu table
---@param screen table|nil
---@return boolean
local function isScreenRegistered(inGameMenu, screen)
    if screen == nil or inGameMenu == nil or inGameMenu.pagingElement == nil then
        return false
    end

    if inGameMenu.pagingElement.elements == nil then
        return false
    end

    for _, element in ipairs(inGameMenu.pagingElement.elements) do
        if element == screen then
            return true
        end
    end

    return false
end

---@param menu table|nil
---@param screen table|nil
---@return boolean
function FieldToDoInGameMenuIntegration.isFieldToDoPageVisible(menu, screen)
    if screen == nil then
        return false
    end

    if menu ~= nil then
        if menu.currentPage == screen or menu.pageFrame == screen then
            return true
        end

        local paging = menu.pagingElement
        if paging ~= nil then
            if paging.currentPage == screen or paging.currentElement == screen then
                return true
            end

            if paging.getCurrentPageIndex ~= nil and paging.elements ~= nil then
                local pageIndex = paging:getCurrentPageIndex()
                if pageIndex ~= nil and paging.elements[pageIndex + 1] == screen then
                    return true
                end
            end
        end
    end

    if type(screen.getIsVisible) == "function" and screen:getIsVisible() == true then
        return true
    end

    return screen.isVisible == true
end

function FieldToDoInGameMenuIntegration.syncFieldListFromScan()
    local screen = FieldToDoInGameMenuIntegration.menuScreen
    if screen == nil and g_inGameMenu ~= nil then
        screen = g_inGameMenu[FieldToDoInGameMenuIntegration.MENU_PAGE_NAME]
    end

    if screen == nil or type(screen.syncOwnedFieldsFromScan) ~= "function" then
        return
    end

    pcall(screen.syncOwnedFieldsFromScan, screen)
end

---@param menu table|nil
---@param dt number|nil
function FieldToDoInGameMenuIntegration.updateMenuFrame(menu, dt)
    if dt == nil or dt <= 0 then
        return
    end

    local now = g_time
    if now ~= nil and now == FieldToDoInGameMenuIntegration._menuFrameUpdateTime then
        return
    end
    FieldToDoInGameMenuIntegration._menuFrameUpdateTime = now

    local screen = FieldToDoInGameMenuIntegration.menuScreen
    if screen == nil and menu ~= nil then
        screen = menu[FieldToDoInGameMenuIntegration.MENU_PAGE_NAME]
    end

    if screen == nil or type(screen.onFrameUpdate) ~= "function" then
        return
    end

    if not FieldToDoInGameMenuIntegration.isFieldToDoPageVisible(menu, screen) then
        return
    end

    pcall(screen.onFrameUpdate, screen, dt)
end

---@param modDirectory string
---@return boolean
function FieldToDoInGameMenuIntegration.performRegistration(modDirectory)
    if g_gui == nil or g_inGameMenu == nil then
        return false
    end

    if FieldToDoMenuFrame == nil or FieldToDoMenuFrame.new == nil then
        logWarning("FieldToDoMenuFrame not loaded yet")
        return false
    end

    local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
    if inGameMenu == nil or inGameMenu.pagingElement == nil then
        logWarning("InGameMenu or pagingElement not ready")
        return false
    end

    local existingScreen = g_inGameMenu[FieldToDoInGameMenuIntegration.MENU_PAGE_NAME]
    if isScreenRegistered(inGameMenu, existingScreen) then
        return true
    end

    if existingScreen ~= nil then
        g_inGameMenu[FieldToDoInGameMenuIntegration.MENU_PAGE_NAME] = nil
        if g_inGameMenu.controlIDs ~= nil then
            g_inGameMenu.controlIDs[FieldToDoInGameMenuIntegration.MENU_PAGE_NAME] = nil
        end
    end

    local screen = FieldToDoMenuFrame.new()
    local xmlPath = Utils.getFilename(FieldToDoInGameMenuIntegration.XML_FILENAME, modDirectory)

    local loadOk, loadError = pcall(function()
        g_gui:loadGui(xmlPath, FieldToDoInGameMenuIntegration.CLASS_NAME, screen, true)
    end)

    if not loadOk then
        logError("loadGui failed: %s", tostring(loadError))
        return false
    end

    if type(screen.exposeControlsAsFields) == "function" then
        pcall(screen.exposeControlsAsFields, screen, FieldToDoInGameMenuIntegration.MENU_PAGE_NAME)
    end

    if type(screen.onGuiSetupFinished) == "function" then
        pcall(screen.onGuiSetupFinished, screen)
    end

    if g_inGameMenu.controlIDs ~= nil then
        g_inGameMenu.controlIDs[FieldToDoInGameMenuIntegration.MENU_PAGE_NAME] = nil
    end

    inGameMenu[FieldToDoInGameMenuIntegration.MENU_PAGE_NAME] = screen
    FieldToDoInGameMenuIntegration.menuScreen = screen

    local alreadyAdded = false
    if inGameMenu.pagingElement.elements ~= nil then
        for _, element in ipairs(inGameMenu.pagingElement.elements) do
            if element == screen then
                alreadyAdded = true
                break
            end
        end
    end

    if not alreadyAdded then
        inGameMenu.pagingElement:addElement(screen)
    end

    if type(inGameMenu.exposeControlsAsFields) == "function" then
        pcall(inGameMenu.exposeControlsAsFields, inGameMenu, FieldToDoInGameMenuIntegration.MENU_PAGE_NAME)
    end

    if type(inGameMenu.pagingElement.updateAbsolutePosition) == "function" then
        pcall(inGameMenu.pagingElement.updateAbsolutePosition, inGameMenu.pagingElement)
    end

    if type(inGameMenu.pagingElement.updatePageMapping) == "function" then
        pcall(inGameMenu.pagingElement.updatePageMapping, inGameMenu.pagingElement)
    end

    if type(inGameMenu.registerPage) == "function" then
        pcall(inGameMenu.registerPage, inGameMenu, screen, nil, function()
            return g_currentMission ~= nil
        end)
    end

    local iconFile = Utils.getFilename(FieldToDoInGameMenuIntegration.MENU_ICON_PATH, modDirectory)
    if iconFile ~= nil and type(inGameMenu.addPageTab) == "function" then
        local tabOk, tabError = pcall(
            inGameMenu.addPageTab,
            inGameMenu,
            screen,
            iconFile,
            GuiUtils.getUVs(FieldToDoInGameMenuIntegration.MENU_ICON_UVS)
        )
        if not tabOk then
            logWarning("addPageTab failed: %s", tostring(tabError))
        end
    else
        logWarning("Tab icon missing or addPageTab unavailable")
    end

    if type(inGameMenu.rebuildTabList) == "function" then
        pcall(inGameMenu.rebuildTabList, inGameMenu)
    end

    if type(screen.initialize) == "function" then
        pcall(screen.initialize, screen)
    end

    logInfo("In-game menu page registered")
    return true
end

---@param modDirectory string
function FieldToDoInGameMenuIntegration.register(modDirectory)
    if FieldToDoInGameMenuIntegration.performRegistration(modDirectory) then
        pendingRegistration = false
        pendingModDirectory = nil
        return
    end

    pendingRegistration = true
    pendingModDirectory = modDirectory
end

function FieldToDoInGameMenuIntegration.attemptDeferredRegister()
    if not pendingRegistration or pendingModDirectory == nil then
        return
    end

    if FieldToDoInGameMenuIntegration.performRegistration(pendingModDirectory) then
        pendingRegistration = false
        pendingModDirectory = nil
    end
end

local modDirectory = g_currentModDirectory

local function onMissionReady()
    FieldToDoInGameMenuIntegration.register(modDirectory)
end

if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionReady)
end

if InGameMenu ~= nil and InGameMenu.onGuiSetupFinished ~= nil then
    InGameMenu.onGuiSetupFinished = Utils.appendedFunction(InGameMenu.onGuiSetupFinished, function()
        FieldToDoInGameMenuIntegration.attemptDeferredRegister()
    end)
end

if InGameMenu ~= nil and InGameMenu.update ~= nil then
    InGameMenu.update = Utils.appendedFunction(InGameMenu.update, function(menu, dt)
        FieldToDoInGameMenuIntegration.updateMenuFrame(menu, dt)
    end)
end

FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(_, dt)
    FieldToDoInGameMenuIntegration.attemptDeferredRegister()
    if g_inGameMenu ~= nil and dt ~= nil then
        FieldToDoInGameMenuIntegration.updateMenuFrame(g_inGameMenu, dt)
    end
end)
