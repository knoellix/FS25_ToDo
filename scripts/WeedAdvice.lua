--[[
    WeedAdvice.lua
    Single source of truth for the weed recommendation (hoe / spray / watch / done).

    Pure and headless-testable: deriveWeedAdvice(facts) takes a normalized facts table
    (no engine access) and returns the advice. FieldAdvisor builds the facts from live
    probe data (FieldAdvisor.buildWeedAdviceFacts) and exposes thin wrappers
    (fieldNeedsWeedHoe / fieldShouldSuggestWeedSpray / ...) that read this one decision.

    Rule (project memory): when probe coverage exists it is the source of truth; if the
    field is done by coverage, no weed action is suggested (fixes W4: dead field still
    proposing watch/hoe). Hoe for any actionable live weed; spray additionally when
    weedState >= 3 or pressure >= 10% (fixes W5: light live weed -> hoe only, no spray).

    Contract documented in docs/FIELD_PHASE.md (§ Unkraut-Advice).
    Loadable both as an FS25 global and via dofile/require for headless tests (returns the table).
]]

WeedAdvice = WeedAdvice or {}

-- Thresholds mirror FieldAdvisor.WEED_* constants (kept in sync; see docs/DECISIONS.md).
WeedAdvice.COMBAT_THRESHOLD = 0.05         -- live ratio / pressure that makes weed actionable for spray-class
WeedAdvice.COMPLETE_THRESHOLD = 0.02       -- below this live pressure: effectively clean
WeedAdvice.SPRAY_PRESSURE_THRESHOLD = 0.10 -- live pressure at/above which spray is suggested
WeedAdvice.STATE_SPRAY_MIN = 3             -- weedState at/above which spray is suggested
WeedAdvice.STATE_SPRAYED_LIVE_MAX = 2      -- weedState 1..2 = early/sprayed live -> hoe only

---@param f table
---@return boolean
local function needsCombat(f)
    if f.hasCoverage then
        if (f.live or 0) <= 0 then
            return false
        end
        if (f.classified or 0) <= 0 then
            return false
        end
        return (f.liveRatio or 0) >= WeedAdvice.COMBAT_THRESHOLD
    end

    if f.deadOrSprayed then
        return false
    end

    return (f.pressure or 0) >= WeedAdvice.COMBAT_THRESHOLD
end

---@param f table
---@return boolean
local function needsWatch(f)
    if f.hasCoverage then
        if (f.live or 0) <= 0 or (f.classified or 0) <= 0 then
            return false
        end
        local ratio = f.liveRatio or 0
        if ratio >= WeedAdvice.COMBAT_THRESHOLD then
            return false
        end
        return ratio > WeedAdvice.COMPLETE_THRESHOLD and ratio < WeedAdvice.COMBAT_THRESHOLD
    end

    if f.deadOrSprayed then
        return false
    end

    if needsCombat(f) then
        return false
    end

    local pressure = f.pressure or 0
    return pressure > WeedAdvice.COMPLETE_THRESHOLD and pressure < WeedAdvice.COMBAT_THRESHOLD
end

--- Pressure used for spray decision: live coverage ratio when measured, else state pressure.
---@param f table
---@return number
local function suggestionPressure(f)
    if f.hasCoverage and (f.liveRatio or 0) > 0 then
        return f.liveRatio
    end
    return f.pressure or 0
end

---@param f table
---@return boolean
local function shouldSpray(f)
    if not needsCombat(f) then
        return false
    end
    if f.hasSummary and (f.live or 0) <= 0 then
        return false
    end
    if f.deadOrSprayed then
        return false
    end

    return (f.weedState or 0) >= WeedAdvice.STATE_SPRAY_MIN
        or suggestionPressure(f) >= WeedAdvice.SPRAY_PRESSURE_THRESHOLD
end

---@param f table
---@return boolean
local function needsHoe(f)
    if f.hasSummary and (f.live or 0) <= 0 then
        return false
    end
    if needsWatch(f) then
        return true
    end
    if not needsCombat(f) then
        return false
    end
    if shouldSpray(f) then
        return true
    end

    local weedState = f.weedState or 0
    return weedState >= 1 and weedState <= WeedAdvice.STATE_SPRAYED_LIVE_MAX
end

--- Single weed decision. `combat` field = the spray suggestion (weed_combat action).
---@param facts table|nil
---@return table advice { done, hoe, watch, needsCombat, spray }
function WeedAdvice.deriveWeedAdvice(facts)
    local f = facts or {}

    if f.enabled == false then
        return { done = false, hoe = false, watch = false, needsCombat = false, spray = false }
    end

    -- Coverage wins: a field that is done by coverage gets no action (W4).
    if f.hasCoverage and f.doneByCoverage == true then
        return { done = true, hoe = false, watch = false, needsCombat = false, spray = false }
    end

    return {
        done = false,
        hoe = needsHoe(f),
        watch = needsWatch(f),
        needsCombat = needsCombat(f),
        spray = shouldSpray(f),
    }
end

return WeedAdvice
