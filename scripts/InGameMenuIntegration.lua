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
--- Fallback tab index if the map page cannot be found (1-based).
FieldToDoInGameMenuIntegration.TAB_POSITION_FALLBACK = 2
FieldToDoInGameMenuIntegration.menuScreen = nil
FieldToDoInGameMenuIntegration._menuFrameUpdateTime = nil
FieldToDoInGameMenuIntegration._tabPlacedAfterMap = false

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

--- True if element looks like the vanilla map overview page.
---@param child table|nil
---@param mapScreen table|nil
---@return boolean
local function isMapPageChild(child, mapScreen)
    if child == nil then
        return false
    end

    if mapScreen ~= nil and (child == mapScreen or child.element == mapScreen) then
        return true
    end

    local element = child
    if type(child) == "table" and child.element ~= nil then
        element = child.element
    end

    if element == nil then
        return false
    end

    local name = element.name or element.id or element.pageName
    if type(name) == "string" then
        local lower = string.lower(name)
        if string.find(lower, "mapoverview", 1, true) ~= nil
            or lower == "pagemap"
            or lower == "menumap"
            or lower == "map" then
            return true
        end
    end

    return false
end

--- Index of the map page in paging lists (1-based), or nil.
---@param inGameMenu table
---@return number|nil
function FieldToDoInGameMenuIntegration.findMapPageIndex(inGameMenu)
    if inGameMenu == nil or inGameMenu.pagingElement == nil then
        return nil
    end

    local mapScreen = inGameMenu.pageMapOverview or inGameMenu.pageMap or inGameMenu.pageMapOverviewFrame
    local lists = {
        inGameMenu.pagingElement.elements,
        inGameMenu.pagingElement.pages,
        inGameMenu.pageFrames,
    }

    for _, list in ipairs(lists) do
        if list ~= nil then
            for i = 1, #list do
                if isMapPageChild(list[i], mapScreen) then
                    return i
                end
            end
        end
    end

    return nil
end

--- Slot directly after the map. Other mods may still insert later; we re-apply on menu open.
---@param inGameMenu table
---@return number
function FieldToDoInGameMenuIntegration.resolveTabPositionAfterMap(inGameMenu)
    local mapIndex = FieldToDoInGameMenuIntegration.findMapPageIndex(inGameMenu)
    if mapIndex ~= nil then
        return mapIndex + 1
    end

    return FieldToDoInGameMenuIntegration.TAB_POSITION_FALLBACK
end

--- Move page/tab to a slot (Courseplay-style). Prefer after map via resolveTabPositionAfterMap.
---@param inGameMenu table
---@param screen table
---@param position number
function FieldToDoInGameMenuIntegration.movePageToPosition(inGameMenu, screen, position)
    if inGameMenu == nil or screen == nil or position == nil or position < 1 then
        return
    end

    local paging = inGameMenu.pagingElement
    if paging == nil then
        return
    end

    local function moveInList(list)
        if list == nil then
            return
        end
        for i = 1, #list do
            local child = list[i]
            local match = child == screen or (type(child) == "table" and child.element == screen)
            if match then
                table.remove(list, i)
                local insertAt = math.min(position, #list + 1)
                table.insert(list, insertAt, child)
                return
            end
        end
    end

    moveInList(paging.elements)
    moveInList(paging.pages)
    moveInList(inGameMenu.pageFrames)

    -- Tab buttons often live in a separate list that addPageTab appends to.
    local tabLists = {
        inGameMenu.pagingButtons,
        inGameMenu.pageTabs,
        paging.buttons,
        paging.tabButtons,
    }
    if inGameMenu.pagingTabList ~= nil then
        tabLists[#tabLists + 1] = inGameMenu.pagingTabList.elements
        tabLists[#tabLists + 1] = inGameMenu.pagingTabList
    end
    for _, list in ipairs(tabLists) do
        if type(list) == "table" and #list > 0 then
            moveInList(list)
        end
    end

    if type(paging.updateAbsolutePosition) == "function" then
        pcall(paging.updateAbsolutePosition, paging)
    end
    if type(paging.updatePageMapping) == "function" then
        pcall(paging.updatePageMapping, paging)
    end
end

--- Place our page immediately after the map and rebuild tabs.
--- If we are already somewhere after the map, leave later mods alone.
---@param inGameMenu table|nil
---@param screen table|nil
---@return number|nil position used
function FieldToDoInGameMenuIntegration.placeTabAfterMap(inGameMenu, screen)
    if inGameMenu == nil or screen == nil then
        return nil
    end

    local paging = inGameMenu.pagingElement
    local mapIndex = FieldToDoInGameMenuIntegration.findMapPageIndex(inGameMenu)
    local ourIndex = nil
    if paging ~= nil and paging.elements ~= nil then
        for i = 1, #paging.elements do
            if paging.elements[i] == screen then
                ourIndex = i
                break
            end
        end
    end

    local tabPosition
    if mapIndex ~= nil then
        if ourIndex ~= nil and ourIndex > mapIndex then
            -- Already after the map (maybe other mods between) — keep slot.
            FieldToDoInGameMenuIntegration._tabPlacedAfterMap = true
            return ourIndex
        end
        tabPosition = mapIndex + 1
    else
        tabPosition = FieldToDoInGameMenuIntegration.TAB_POSITION_FALLBACK
    end

    FieldToDoInGameMenuIntegration.movePageToPosition(inGameMenu, screen, tabPosition)

    if type(inGameMenu.rebuildTabList) == "function" then
        pcall(inGameMenu.rebuildTabList, inGameMenu)
    end

    FieldToDoInGameMenuIntegration._tabPlacedAfterMap = true
    return tabPosition
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

    local tabPosition = FieldToDoInGameMenuIntegration.resolveTabPositionAfterMap(inGameMenu)
    FieldToDoInGameMenuIntegration.movePageToPosition(inGameMenu, screen, tabPosition)

    if type(inGameMenu.registerPage) == "function" then
        pcall(inGameMenu.registerPage, inGameMenu, screen, tabPosition, function()
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

    -- Re-place after tab button creation (addPageTab appends). Map-relative slot.
    tabPosition = FieldToDoInGameMenuIntegration.placeTabAfterMap(inGameMenu, screen) or tabPosition

    if type(screen.initialize) == "function" then
        pcall(screen.initialize, screen)
    end

    if type(screen.updateAbsolutePosition) == "function" then
        pcall(screen.updateAbsolutePosition, screen)
    end

    -- Late mods may insert tabs after us; re-assert after-map slot when ESC opens.
    if type(inGameMenu.onOpen) == "function" and FieldToDoInGameMenuIntegration._tabOpenHooked ~= true then
        FieldToDoInGameMenuIntegration._tabOpenHooked = true
        inGameMenu.onOpen = Utils.appendedFunction(inGameMenu.onOpen, function(menu)
            local page = FieldToDoInGameMenuIntegration.menuScreen
                or (menu ~= nil and menu[FieldToDoInGameMenuIntegration.MENU_PAGE_NAME])
            if page ~= nil then
                FieldToDoInGameMenuIntegration.placeTabAfterMap(menu or g_inGameMenu, page)
            end
        end)
    end

    logInfo("In-game menu page registered (tab after map, slot %d)", tabPosition)
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
