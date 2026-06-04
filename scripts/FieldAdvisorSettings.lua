--[[
    FieldAdvisorSettings.lua
    User preferences for field suggestion ordering (persisted in savegame sidecar).
]]

FieldAdvisorSettings = {}

FieldAdvisorSettings.DEFAULT_PRESET = "standard"

FieldAdvisorSettings.PRESETS = {
    standard = {
        labelKey = "ftdl_preset_standard",
        label = "Pflügen → Kalk → Säen → Düngen",
        order = {
            "harvest", "mulch", "stones", "cultivate", "plow", "roller", "lime", "pf_ph", "sow", "pf_n",
            "weed_hoe", "weed_combat", "weed_watch", "scs_moisture", "scs_stress_high", "scs_stress_watch",
            "grass_swath", "grass_collect", "grass_bale", "grass_silage_bale", "grass_bale_collect", "grass_mow",
            "harvest_info", "growing", "none",
        },
    },
    lime_before_plow = {
        labelKey = "ftdl_preset_lime_before_plow",
        label = "Kalk → Pflügen → Säen → Düngen",
        order = {
            "harvest", "mulch", "stones", "cultivate", "lime", "plow", "roller", "pf_ph", "sow", "pf_n",
            "weed_hoe", "weed_combat", "weed_watch", "scs_moisture", "scs_stress_high", "scs_stress_watch",
            "grass_swath", "grass_collect", "grass_bale", "grass_silage_bale", "grass_bale_collect", "grass_mow",
            "harvest_info", "growing", "none",
        },
    },
    fert_before_sow = {
        labelKey = "ftdl_preset_fert_before_sow",
        label = "Düngen → Pflügen → Kalk → Säen",
        order = {
            "harvest", "mulch", "stones", "cultivate", "plow", "roller", "pf_ph", "pf_n", "lime", "sow",
            "weed_hoe", "weed_combat", "weed_watch", "scs_moisture", "scs_stress_high", "scs_stress_watch",
            "grass_swath", "grass_collect", "grass_bale", "grass_silage_bale", "grass_bale_collect", "grass_mow",
            "harvest_info", "growing", "none",
        },
    },
    sow_before_fert = {
        labelKey = "ftdl_preset_sow_before_fert",
        label = "Pflügen → Kalk → Säen → N-Düngen",
        order = {
            "harvest", "mulch", "stones", "cultivate", "plow", "roller", "lime", "sow", "pf_ph", "pf_n",
            "weed_hoe", "weed_combat", "weed_watch", "scs_moisture", "scs_stress_high", "scs_stress_watch",
            "grass_swath", "grass_collect", "grass_bale", "grass_silage_bale", "grass_bale_collect", "grass_mow",
            "harvest_info", "growing", "none",
        },
    },
    soil_then_fert = {
        labelKey = "ftdl_preset_soil_then_fert",
        label = "Bodenarbeit → Säen → Düngen",
        order = {
            "harvest", "mulch", "stones", "cultivate", "lime", "plow", "roller", "pf_ph", "sow", "pf_n",
            "weed_hoe", "weed_combat", "weed_watch", "scs_moisture", "scs_stress_high", "scs_stress_watch",
            "grass_swath", "grass_collect", "grass_bale", "grass_silage_bale", "grass_bale_collect", "grass_mow",
            "harvest_info", "growing", "none",
        },
    },
}

FieldAdvisorSettings.PRESET_KEYS = {
    "standard",
    "lime_before_plow",
    "fert_before_sow",
    "sow_before_fert",
    "soil_then_fert",
}

FieldAdvisorSettings.workOrderPreset = FieldAdvisorSettings.DEFAULT_PRESET
FieldAdvisorSettings.organicMultiPassEnabled = false
-- Mulching has no FS25 game-rule gate (unlike stones/weeds/lime/plowing); it is an optional
-- yield bonus. We expose a mod-side toggle so players who never mulch can hide the suggestion.
FieldAdvisorSettings.mulchingEnabled = true

---@return boolean
function FieldAdvisorSettings.isOrganicMultiPassEnabled()
    return FieldAdvisorSettings.organicMultiPassEnabled == true
end

---@return boolean
function FieldAdvisorSettings.isMulchingEnabled()
    return FieldAdvisorSettings.mulchingEnabled == true
end

---@return string
function FieldAdvisorSettings.getMulchingLabel()
    if FieldAdvisorSettings.isMulchingEnabled() then
        return FieldToDoL10n.getText("ftdl_mulch_on", "Mulchen: an")
    end

    return FieldToDoL10n.getText("ftdl_mulch_off", "Mulchen: aus")
end

function FieldAdvisorSettings.toggleMulching()
    FieldAdvisorSettings.mulchingEnabled = not FieldAdvisorSettings.isMulchingEnabled()
    return FieldAdvisorSettings.mulchingEnabled
end

---@param enabled boolean|nil
function FieldAdvisorSettings.setMulchingEnabled(enabled)
    FieldAdvisorSettings.mulchingEnabled = enabled ~= false
end

---@return string
function FieldAdvisorSettings.getOrganicMultiPassLabel()
    if FieldAdvisorSettings.isOrganicMultiPassEnabled() then
        return FieldToDoL10n.getText("ftdl_organic_multi", "Mist/Gülle: mehrfach")
    end

    return FieldToDoL10n.getText("ftdl_organic_once", "Mist/Gülle: einmal")
end

function FieldAdvisorSettings.toggleOrganicMultiPass()
    FieldAdvisorSettings.organicMultiPassEnabled = not FieldAdvisorSettings.isOrganicMultiPassEnabled()
    return FieldAdvisorSettings.organicMultiPassEnabled
end

---@param enabled boolean|nil
function FieldAdvisorSettings.setOrganicMultiPassEnabled(enabled)
    FieldAdvisorSettings.organicMultiPassEnabled = enabled == true
end

---@return string
function FieldAdvisorSettings.getWorkOrderPreset()
    if FieldAdvisorSettings.PRESETS[FieldAdvisorSettings.workOrderPreset] == nil then
        FieldAdvisorSettings.workOrderPreset = FieldAdvisorSettings.DEFAULT_PRESET
    end

    return FieldAdvisorSettings.workOrderPreset
end

---@return string
function FieldAdvisorSettings.getWorkOrderLabel()
    local preset = FieldAdvisorSettings.PRESETS[FieldAdvisorSettings.getWorkOrderPreset()]
    if preset == nil then
        return "-"
    end

    if preset.labelKey ~= nil and FieldToDoL10n ~= nil then
        return FieldToDoL10n.getText(preset.labelKey, preset.label)
    end

    return preset.label
end

--- Shown in HUD/menu when organic multi-pass is active (manure/slurry between soil work).
---@return string
function FieldAdvisorSettings.getWorkOrderDisplayLabel()
    if FieldAdvisorSettings.isOrganicMultiPassEnabled() then
        return FieldToDoL10n.getText(
            "ftdl_organic_workflow",
            "Mist/Gülle → Pflügen → Mist/Gülle → Säen → Mist/Gülle → Walzen"
        )
    end

    return FieldAdvisorSettings.getWorkOrderLabel()
end

---@param actionType string|nil
---@return number
function FieldAdvisorSettings.getActionRank(actionType)
    if actionType == nil or actionType == "" then
        return 999
    end

    local preset = FieldAdvisorSettings.PRESETS[FieldAdvisorSettings.getWorkOrderPreset()]
    if preset == nil or preset.order == nil then
        return 999
    end

    for index, orderedType in ipairs(preset.order) do
        if orderedType == actionType then
            return index
        end
    end

    return 999
end

function FieldAdvisorSettings.cycleWorkOrderPreset()
    local currentIndex = 1
    for index, key in ipairs(FieldAdvisorSettings.PRESET_KEYS) do
        if key == FieldAdvisorSettings.workOrderPreset then
            currentIndex = index
            break
        end
    end

    local nextIndex = (currentIndex % #FieldAdvisorSettings.PRESET_KEYS) + 1
    FieldAdvisorSettings.workOrderPreset = FieldAdvisorSettings.PRESET_KEYS[nextIndex]
    return FieldAdvisorSettings.workOrderPreset
end

---@param presetKey string|nil
function FieldAdvisorSettings.setWorkOrderPreset(presetKey)
    if presetKey ~= nil and FieldAdvisorSettings.PRESETS[presetKey] ~= nil then
        FieldAdvisorSettings.workOrderPreset = presetKey
    end
end

---@param actions table[]
---@return table[]
function FieldAdvisorSettings.sortActions(actions)
    if actions == nil or #actions <= 1 then
        return actions
    end

    local preset = FieldAdvisorSettings.PRESETS[FieldAdvisorSettings.getWorkOrderPreset()]
    if preset == nil or preset.order == nil then
        return actions
    end

    local rank = {}
    for index, actionType in ipairs(preset.order) do
        rank[actionType] = index
    end

    table.sort(actions, function(a, b)
        local rankA = rank[a.actionType] or 999
        local rankB = rank[b.actionType] or 999
        if rankA == rankB then
            local passA = tonumber(a.fertPass) or 0
            local passB = tonumber(b.fertPass) or 0
            if passA ~= passB then
                return passA < passB
            end

            return (a.label or "") < (b.label or "")
        end
        return rankA < rankB
    end)

    return actions
end

---@param xmlFile XMLFile|nil
---@param key string|nil
function FieldAdvisorSettings.loadFromXMLFile(xmlFile, key)
    if xmlFile == nil or key == nil then
        return
    end

    local preset = xmlFile:getValue(key .. "#workOrderPreset")
    FieldAdvisorSettings.setWorkOrderPreset(preset)

    local organicMultiPass = xmlFile:getValue(key .. "#organicMultiPassEnabled")
    FieldAdvisorSettings.setOrganicMultiPassEnabled(organicMultiPass == true)

    -- Absent attribute (older saves) keeps the default-on behaviour; only explicit false hides it.
    local mulching = xmlFile:getValue(key .. "#mulchingEnabled")
    FieldAdvisorSettings.setMulchingEnabled(mulching ~= false)
end

---@param xmlFile XMLFile|nil
---@param key string|nil
function FieldAdvisorSettings.saveToXMLFile(xmlFile, key)
    if xmlFile == nil or key == nil then
        return
    end

    xmlFile:setValue(key .. "#workOrderPreset", FieldAdvisorSettings.getWorkOrderPreset())
    xmlFile:setValue(key .. "#organicMultiPassEnabled", FieldAdvisorSettings.isOrganicMultiPassEnabled())
    xmlFile:setValue(key .. "#mulchingEnabled", FieldAdvisorSettings.isMulchingEnabled())
end
