--[[
    FertilizerAdvice.lua
    Single decision for fertilize need: Precision Farming nitrogen when ready,
    else vanilla FieldState.sprayLevel vs game sprayLevelMax (1×-fertilizer mods).

    Pure / headless-testable. FieldAdvisor builds facts and suggests pf_n from this.
]]

FertilizerAdvice = FertilizerAdvice or {}

FertilizerAdvice.PF_NITROGEN_TARGET = 80
FertilizerAdvice.SPRAY_LEVEL_MAX_FALLBACK = 2

---@param facts table|nil
---@return table advice { needsFertilizer, done, source, level, max }
function FertilizerAdvice.deriveFertilizerAdvice(facts)
    local f = facts or {}

    if f.isGrass == true then
        return {
            needsFertilizer = false,
            done = true,
            source = "none",
            level = nil,
            max = nil,
        }
    end

    if f.pfReady == true and f.nitrogenValue ~= nil then
        local n = tonumber(f.nitrogenValue) or 0
        local target = FertilizerAdvice.PF_NITROGEN_TARGET
        local needs = n < target
        return {
            needsFertilizer = needs,
            done = not needs,
            source = "pf",
            level = n,
            max = target,
        }
    end

    if f.sprayLevel ~= nil then
        local level = tonumber(f.sprayLevel) or 0
        local max = tonumber(f.sprayLevelMax) or FertilizerAdvice.SPRAY_LEVEL_MAX_FALLBACK
        if max < 1 then
            max = FertilizerAdvice.SPRAY_LEVEL_MAX_FALLBACK
        end
        local needs = level < max
        return {
            needsFertilizer = needs,
            done = not needs,
            source = "spray",
            level = level,
            max = max,
        }
    end

    return {
        needsFertilizer = false,
        done = false,
        source = "none",
        level = nil,
        max = nil,
    }
end

--- Organic multi-pass without PF: one task per missing spray stage.
---@param level number|nil
---@param max number|nil
---@return number
function FertilizerAdvice.getSprayPassCount(level, max)
    local safeLevel = math.max(0, math.floor(tonumber(level) or 0))
    local safeMax = math.max(1, math.floor(tonumber(max) or FertilizerAdvice.SPRAY_LEVEL_MAX_FALLBACK))
    local deficit = safeMax - safeLevel
    if deficit <= 0 then
        return 1
    end
    return math.min(deficit, safeMax)
end

--- Staged spray target for organic pass (pass/total of max).
---@param pass number|nil
---@param passTotal number|nil
---@param max number|nil
---@return number
function FertilizerAdvice.getSprayPassTarget(pass, passTotal, max)
    local safePass = math.max(1, math.floor(tonumber(pass) or 1))
    local safeTotal = math.max(safePass, math.floor(tonumber(passTotal) or safePass))
    local safeMax = math.max(1, math.floor(tonumber(max) or FertilizerAdvice.SPRAY_LEVEL_MAX_FALLBACK))
    return math.floor(safeMax * (safePass / safeTotal))
end

return FertilizerAdvice
