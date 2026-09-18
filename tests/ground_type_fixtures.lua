local M = {}

M.resolveCases = {
    { name = "nil_raw", raw = nil, expected = "" },
    { name = "empty_string", raw = "", expected = "" },
    { name = "named_grass", raw = "GRASS", expected = "GRASS" },
    { name = "named_meadow_lower", raw = "meadow", expected = "MEADOW" },
    { name = "numeric_zero", raw = 0, expected = "NONE" },
    { name = "numeric_string_zero", raw = "0", expected = "NONE" },
    { name = "unknown_number_no_enum", raw = 99999, expected = "" },
    { name = "table_raw", raw = {}, expected = "" },
}

--- Proxy fieldState whose groundType getter re-enters getGroundTypeName.
function M.makeReentrantFieldState()
    local state = {}
    local calls = { n = 0 }
    setmetatable(state, {
        __index = function(t, key)
            if key == "groundType" then
                calls.n = calls.n + 1
                FieldAdvisor.getGroundTypeName(t)
                return "GRASS"
            end
            if key == "getGroundType" then
                return nil
            end
            return rawget(t, key)
        end,
    })
    return state, calls
end

return M
