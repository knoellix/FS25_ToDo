--[[
    FieldWorkCatalog.lua
    Canonical field-work action types for picker UI and task validation.
]]

FieldWorkCatalog = {}

FieldWorkCatalog.PICKER_ACTIONS = {
    { actionType = "cultivate", l10nKey = "ftdl_action_cultivate", fallback = "Grubbern", autoComplete = true },
    { actionType = "plow", l10nKey = "ftdl_action_plow", fallback = "Pflügen", autoComplete = true },
    { actionType = "lime", l10nKey = "ftdl_action_lime", fallback = "Kalken", autoComplete = true },
    { actionType = "sow", l10nKey = "ftdl_action_sow", fallback = "Säen", autoComplete = true },
    { actionType = "roller", l10nKey = "ftdl_action_roller", fallback = "Walzen", autoComplete = true },
    { actionType = "weed_hoe", l10nKey = "ftdl_action_weed_hoe", fallback = "Striegeln", autoComplete = true },
    { actionType = "weed_combat", l10nKey = "ftdl_action_weed_combat", fallback = "Spritzen", autoComplete = true },
    { actionType = "stones", l10nKey = "ftdl_action_stones", fallback = "Steine", autoComplete = true },
    { actionType = "grass_mow", l10nKey = "ftdl_action_grass_mow", fallback = "Mähen", autoComplete = true },
    { actionType = "grass_swath", l10nKey = "ftdl_action_grass_swath", fallback = "Schwaden", autoComplete = true },
    { actionType = "grass_collect", l10nKey = "ftdl_action_grass_collect", fallback = "Heu sammeln (Ladewagen)", autoComplete = true },
    { actionType = "grass_bale", l10nKey = "ftdl_action_grass_bale", fallback = "Ballen pressen", autoComplete = true },
    { actionType = "grass_silage_bale", l10nKey = "ftdl_action_grass_silage_bale", fallback = "Silageballen pressen", autoComplete = true },
    { actionType = "grass_bale_collect", l10nKey = "ftdl_action_grass_bale_collect", fallback = "Ballen einsammeln", autoComplete = true },
    { actionType = "harvest", l10nKey = "ftdl_action_harvest", fallback = "Ernten", autoComplete = true },
}

---@param textFn function
---@return table[]
function FieldWorkCatalog.buildPickerActions(textFn)
    local actions = {}

    for _, entry in ipairs(FieldWorkCatalog.PICKER_ACTIONS) do
        actions[#actions + 1] = {
            actionType = entry.actionType,
            pickerLabel = textFn(entry.l10nKey, entry.fallback),
            autoComplete = entry.autoComplete,
        }
    end

    return actions
end

---@param actionType string|nil
---@return boolean
function FieldWorkCatalog.isTrackable(actionType)
    if FieldTaskCompletion ~= nil and FieldTaskCompletion.isAutoTrackable ~= nil then
        return FieldTaskCompletion.isAutoTrackable(actionType)
    end

    return false
end
