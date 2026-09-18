### Task 1: Headless fixtures for `resolveGroundTypeName`

**Files:**
- Create: `tests/ground_type_fixtures.lua`
- Modify: `tests/run.lua`
- Modify: `scripts/FieldAdvisor.lua` (only if helpers need export — prefer testing existing functions)

**Interfaces:**
- Consumes: `FieldAdvisor.resolveGroundTypeName(raw) -> string` (already exists)
- Produces: fixture table `{ name, raw, expected }` consumed by `tests/run.lua`

- [ ] **Step 1: Create fixtures file**

Create `tests/ground_type_fixtures.lua` as a module (Task 2 adds reentrancy helper to the same file):

```lua
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

return M
```

- [ ] **Step 2: Wire runner (fail if resolve missing)**

In `tests/run.lua`, after existing FieldAdvisor dofile section (same place other FieldAdvisor tests run), add:

```lua
io.write("\n")
local groundFixtures = dofile(here .. "/ground_type_fixtures.lua")
for _, c in ipairs(groundFixtures.resolveCases) do
    local ok, got = pcall(FieldAdvisor.resolveGroundTypeName, c.raw)
    if ok and got == c.expected then
        pass = pass + 1
        io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> %s\n", c.name, tostring(got)))
    else
        fail = fail + 1
        local detail = ok and tostring(got) or ("error: " .. tostring(got))
        io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s expected %s got %s\n", c.name, c.expected, detail))
    end
end
```

Ensure `FieldAdvisor` is in scope (existing `dofile(.../FieldAdvisor.lua)` already loads it into global `FieldAdvisor`).

- [ ] **Step 3: Run tests**

Run: `lua tests/run.lua`

Expected: existing tests still pass; new ground fixtures PASS (current `resolveGroundTypeName` already matches these cases). If any FAIL, fix `resolveGroundTypeName` minimally before Task 2.

- [ ] **Step 4: Commit**

```bash
git add tests/ground_type_fixtures.lua tests/run.lua
git commit -m "test: add groundType name resolution fixtures"
```

---

