-- FieldPhase: single source of truth for "what work state is this field in?".
-- Pure module — no engine globals. Input is a normalized `facts` table (see docs/FIELD_PHASE.md),
-- output is exactly one phase string. The collecting layer (probes/aggregation) fills `facts`.
-- Loadable both as an FS25 global and via dofile/require for headless tests (returns the table).

FieldPhase = FieldPhase or {}

FieldPhase.PHASE = {
    STANDING = "standing",
    HARVEST_READY = "harvest_ready",
    WITHERED = "withered",
    POST_HARVEST = "post_harvest",
    EMPTY = "empty",
    GRASS_STANDING = "grass_standing",
    GRASS_HARVESTABLE = "grass_harvestable",
    GRASS_CUT = "grass_cut",
    GRASS_RESIDUE = "grass_residue",
    UNKNOWN = "unknown",
}

local RESIDUE_WORK = {
    loose = true,
    swath = true,
    baled = true,
}

local STUBBLE_GROUND = {
    STUBBLE = true,
    HARVEST_READY = true,
}

local function num(value)
    return tonumber(value) or 0
end

local function flagsOf(facts)
    return facts.flags or {}
end

--- Arable stubble after combine: cut/over-ripe/STUBBLE ground without a standing harvestable crop.
---@param facts table
---@return boolean
function FieldPhase.isArableStubble(facts)
    local flags = flagsOf(facts)
    if flags.cut == true then
        return true
    end

    local maxHarvest = num(facts.maxHarvest)
    if maxHarvest > 0 and num(facts.growth) > maxHarvest then
        return true
    end

    if STUBBLE_GROUND[facts.ground] == true then
        if flags.harvestable == true or flags.harvestReady == true then
            return false
        end
        return true
    end

    return false
end

--- Resolve the work phase from normalized facts. See docs/FIELD_PHASE.md for the rule order.
---@param facts table
---@return string phase  one of FieldPhase.PHASE.*
function FieldPhase.deriveFieldPhase(facts)
    if type(facts) ~= "table" then
        return FieldPhase.PHASE.UNKNOWN
    end

    local flags = flagsOf(facts)
    local isGrass = facts.isGrassCrop == true or facts.dominant == "grass"

    if not isGrass then
        if flags.withered == true then
            return FieldPhase.PHASE.WITHERED
        end

        local maxHarvest = num(facts.maxHarvest)
        if facts.hasFruit == true and flags.harvestReady == true
            and (maxHarvest == 0 or num(facts.growth) <= maxHarvest) then
            return FieldPhase.PHASE.HARVEST_READY
        end

        if FieldPhase.isArableStubble(facts) then
            return FieldPhase.PHASE.POST_HARVEST
        end

        if facts.hasFruit == true and num(facts.growth) > 0 then
            return FieldPhase.PHASE.STANDING
        end

        return FieldPhase.PHASE.EMPTY
    end

    -- Grass / meadow.
    if flags.withered == true then
        return FieldPhase.PHASE.WITHERED
    end

    if facts.residueReliable == true and RESIDUE_WORK[facts.residue] == true then
        return FieldPhase.PHASE.GRASS_RESIDUE
    end

    -- Definitive cut signals (cut growth state / cut ground) win outright.
    if flags.cut == true or facts.ground == "GRASS_CUT" then
        return FieldPhase.PHASE.GRASS_CUT
    end

    -- A stand regrown to mowable height is harvestable even if stubble shred still lingers,
    -- so harvestable is decided BEFORE the ambiguous shred signal.
    if flags.harvestable == true or flags.harvestReady == true then
        return FieldPhase.PHASE.GRASS_HARVESTABLE
    end

    -- Lingering shred without regrowth indicates a recent mow.
    if num(facts.shred) > 0 then
        return FieldPhase.PHASE.GRASS_CUT
    end

    if num(facts.growth) > 0 then
        return FieldPhase.PHASE.GRASS_STANDING
    end

    return FieldPhase.PHASE.UNKNOWN
end

return FieldPhase
