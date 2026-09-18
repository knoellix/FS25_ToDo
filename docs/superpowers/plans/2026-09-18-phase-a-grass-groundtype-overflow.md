# Phase A — Grass groundType stack overflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `FieldAdvisor.getGroundTypeName` / `resolveGroundTypeName` from stack-overflowing on grass fields (client log: field 17) so overview scan completes and grass suggestions can resolve.

**Architecture:** Harden pure ground-type name resolution with headless tests; add a reentrancy guard on `getGroundTypeName` so metamethod/`getGroundType` callbacks cannot recurse; make `FieldGroundType` enum caching one-shot and exception-safe without calling back into advisor ground helpers.

**Tech Stack:** FS25 Lua 5.1 (no `goto`), `scripts/FieldAdvisor.lua`, headless `lua tests/run.lua`.

**Spec:** `docs/superpowers/specs/2026-09-18-dedicated-mp-farm-permission-design.md` (Phase A only).

## Global Constraints

- No `goto` / labels (Lua 5.1 load failure).
- Do **not** bump `modDesc.xml` version unless the user explicitly asks (remain on **0.1.0.10** until a release is requested).
- Logging via `FieldToDoLog` / `Logging`, not `print()`.
- Do **not** implement Phases B–E in this plan.
- Do **not** move field scan to the dedicated server.
- Maintainer shell is **fish** — commit with single `-m` or fish-safe strings.
- After in-game verify: full FS25 restart (dedicated: server + clients).

## File map

| File | Role |
|------|------|
| `scripts/FieldAdvisor.lua` | `resolveGroundTypeName`, `getGroundTypeName`, `groundTypeNameByValue` cache |
| `tests/ground_type_fixtures.lua` | Headless cases for resolve + reentrancy |
| `tests/run.lua` | Register ground-type tests |
| `CHANGELOG.md` | Fixed bullet (under Unreleased or next version section) |
| Spec Phase A | Mark done when verified |

---

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

### Task 2: Reentrancy guard on `getGroundTypeName`

**Files:**
- Modify: `scripts/FieldAdvisor.lua` (`getGroundTypeName`, ~312–326)
- Modify: `tests/ground_type_fixtures.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `FieldAdvisor.resolveGroundTypeName`
- Produces: `FieldAdvisor.getGroundTypeName(fieldState) -> string` never re-enters; on reentry returns `""`

**Root-cause hypothesis (locked for this fix):** On some MP/map FieldState objects, reading `fieldState.groundType` or calling `fieldState:getGroundType()` re-enters mod code that calls `getGroundTypeName` again → stack overflow at the `resolveGroundTypeName` call site (client log field 17).

- [ ] **Step 1: Add failing reentrancy fixture**

Add to `tests/ground_type_fixtures.lua` before `return M`:

```lua
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
```

Update `tests/run.lua` ground section to keep `groundFixtures.resolveCases` loop and append:

```lua
do
    local state, calls = groundFixtures.makeReentrantFieldState()
    local ok, got = pcall(FieldAdvisor.getGroundTypeName, state)
    local passReentry = ok and got == "" and calls.n >= 1
    if passReentry then
        pass = pass + 1
        io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> reentrancy guarded\n", "getGroundTypeName_reentrant"))
    else
        fail = fail + 1
        io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s ok=%s got=%s calls=%s\n",
            "getGroundTypeName_reentrant", tostring(ok), tostring(got), tostring(calls and calls.n)))
    end
end
```

- [ ] **Step 2: Run — expect FAIL or stack overflow before fix**

Run: `lua tests/run.lua`

Expected before fix: `getGroundTypeName_reentrant` FAIL or runner abort with stack overflow.

- [ ] **Step 3: Implement guard**

Replace `FieldAdvisor.getGroundTypeName` in `scripts/FieldAdvisor.lua` with:

```lua
FieldAdvisor._getGroundTypeNameDepth = 0

---@param fieldState table|nil
---@return string
function FieldAdvisor.getGroundTypeName(fieldState)
    if fieldState == nil then
        return ""
    end

    if FieldAdvisor._getGroundTypeNameDepth > 0 then
        return ""
    end

    FieldAdvisor._getGroundTypeNameDepth = FieldAdvisor._getGroundTypeNameDepth + 1
    local raw = nil
    local okRead, errRead = pcall(function()
        raw = fieldState.groundType
        if raw == nil and type(fieldState.getGroundType) == "function" then
            local ok, groundType = pcall(fieldState.getGroundType, fieldState)
            if ok then
                raw = groundType
            end
        end
    end)
    FieldAdvisor._getGroundTypeNameDepth = FieldAdvisor._getGroundTypeNameDepth - 1

    if not okRead then
        return ""
    end

    return FieldAdvisor.resolveGroundTypeName(raw)
end
```

Notes:
- No `goto`.
- Depth must always decrement (use the assignment after `pcall` as above).
- Do **not** call `getGroundTypeName` from inside `resolveGroundTypeName`.

- [ ] **Step 4: Run tests — all green**

Run: `lua tests/run.lua`

Expected: all PASS including `getGroundTypeName_reentrant`.

- [ ] **Step 5: Commit**

```bash
git add scripts/FieldAdvisor.lua tests/ground_type_fixtures.lua tests/run.lua
git commit -m "fix(advisor): guard getGroundTypeName against reentrancy"
```

---

### Task 3: Harden `FieldGroundType` name cache build

**Files:**
- Modify: `scripts/FieldAdvisor.lua` (`resolveGroundTypeName`, ~264–308)

**Interfaces:**
- Consumes: global `FieldGroundType` when present
- Produces: `FieldAdvisor.groundTypeNameByValue` filled once; never partial-nil mid-build on error

- [ ] **Step 1: Replace cache build body**

Inside `resolveGroundTypeName`, replace the `if FieldAdvisor.groundTypeNameByValue == nil then ... end` block with:

```lua
    if FieldGroundType ~= nil then
        if FieldAdvisor.groundTypeNameByValue == nil then
            local map = {}
            local okEnum = pcall(function()
                for name, enumValue in pairs(FieldGroundType) do
                    if type(name) == "string" and type(enumValue) == "number" then
                        map[enumValue] = name
                    elseif type(name) == "string" and type(enumValue) == "string"
                        and FieldGroundType.getValueByType ~= nil then
                        local ok, resolvedValue = pcall(
                            FieldGroundType.getValueByType,
                            FieldGroundType,
                            enumValue
                        )
                        if ok and type(resolvedValue) == "number" then
                            map[resolvedValue] = name
                        end
                    end
                end
            end)
            -- Always assign (even empty) so we never rebuild forever on throw.
            FieldAdvisor.groundTypeNameByValue = map
            if not okEnum and FieldToDoLog ~= nil then
                FieldToDoLog.warning("FieldAdvisor: FieldGroundType enum cache failed")
            end
        end

        local resolvedName = FieldAdvisor.groundTypeNameByValue[value]
        if resolvedName ~= nil then
            return resolvedName
        end
    end
```

Keep the rest of `resolveGroundTypeName` (nil/string/number/0→NONE) unchanged.

- [ ] **Step 2: Run tests**

Run: `lua tests/run.lua`

Expected: PASS (fixtures do not need live `FieldGroundType`).

- [ ] **Step 3: Commit**

```bash
git add scripts/FieldAdvisor.lua
git commit -m "fix(advisor): make FieldGroundType name cache one-shot safe"
```

---

### Task 4: Changelog + in-game verify notes

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/specs/2026-09-18-dedicated-mp-farm-permission-design.md` (Phase A status line only)

- [ ] **Step 1: Changelog**

Under a new `## [Unreleased]` section at top of `CHANGELOG.md` (or append Fixed under next version if Unreleased already exists):

```markdown
## [Unreleased]

### Fixed

- **Grass overview scan:** `getGroundTypeName` reentrancy / stack overflow on some FieldState objects (e.g. meadow field 17 on dedicated MP client) — scan completes instead of aborting the field.
```

- [ ] **Step 2: Spec status**

In the Phase A section of the design spec, add:

`**Status:** implemented (code); in-game verify pending`

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md docs/superpowers/specs/2026-09-18-dedicated-mp-farm-permission-design.md
git commit -m "docs: note grass groundType overflow fix under Unreleased"
```

- [ ] **Step 4: Manual verify (human / same session if FS available)**

1. Build/install mod ZIP (`python3 tools/generate_assets.py && ./build.sh` or copy scripts).
2. Full restart dedicated **and** client.
3. Join farm; open Field To-Do ESC.
4. Client `log.txt` must **not** show `stack overflow` for field 17.
5. Optional: `ftdlDump 17` — groundType line present, no crash.

---

## Spec coverage (Phase A)

| Spec item | Task |
|-----------|------|
| Break recursion / stack overflow | Task 2 |
| Guard depth / no resolve→getGroundTypeName loop | Task 2–3 |
| Grass still classifiable after fix | Task 4 in-game + existing grass fixtures in `run.lua` |
| Done when: no overflow, grass row usable | Task 4 verify |

Phases B–E: **not** in this plan.
