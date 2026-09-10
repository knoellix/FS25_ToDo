### Task 1: FieldToDoPermissions + headless tests

**Files:**
- Create: `scripts/FieldToDoPermissions.lua`
- Create: `tests/permissions_fixtures.lua`
- Modify: `tests/run.lua`
- Modify: `modDesc.xml` (add sourceFile before `FieldAdvisorSettings.lua`)

**Interfaces:**
- Produces:
  - `FieldToDoPermissions.isFarmManager(farmId, userId) -> boolean`
  - `FieldToDoPermissions.canEditFarmTodos(farmId, userId) -> boolean`
  - `FieldToDoPermissions.canChangeWorkersEditSetting(farmId, userId) -> boolean`
  - `FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) -> boolean`
  - `FieldToDoPermissions.canEditLocal() -> boolean` (convenience using local farm/user)
  - `FieldToDoPermissions._testOverride` table (nil in production; tests inject booleans)

- [ ] **Step 1: Write failing fixtures**

Create `tests/permissions_fixtures.lua`:

```lua
return {
  {
    name = "workers_on_non_manager_can_edit",
    workersMayEdit = true,
    isManager = false,
    sameFarm = true,
    expect = { edit = true, changeSetting = false, autoComplete = true },
  },
  {
    name = "workers_off_non_manager_cannot_edit",
    workersMayEdit = false,
    isManager = false,
    sameFarm = true,
    expect = { edit = false, changeSetting = false, autoComplete = true },
  },
  {
    name = "workers_off_manager_can_edit_and_setting",
    workersMayEdit = false,
    isManager = true,
    sameFarm = true,
    expect = { edit = true, changeSetting = true, autoComplete = true },
  },
  {
    name = "other_farm_denied",
    workersMayEdit = true,
    isManager = true,
    sameFarm = false,
    expect = { edit = false, changeSetting = false, autoComplete = false },
  },
}
```

- [ ] **Step 2: Extend `tests/run.lua` to load fixtures and call pure helpers**

At end of runner (after existing suites), add a block that:

1. `dofile` `FieldAdvisorSettings.lua` then `FieldToDoPermissions.lua`
2. For each fixture, set `FieldAdvisorSettings.workersMayEditTodos = c.workersMayEdit`
3. Set `FieldToDoPermissions._testOverride = { farmId = 1, userId = 1, isManager = c.isManager, resolveFarmId = c.sameFarm and 1 or 2 }`
4. Assert `canEditFarmTodos(1, 1)`, `canChangeWorkersEditSetting(1, 1)`, `canAutoCompleteFarmTodos(1, 1)` match `expect`

Run: `lua tests/run.lua`  
Expected: FAIL — `FieldToDoPermissions` missing or functions nil.

- [ ] **Step 3: Implement `scripts/FieldToDoPermissions.lua`**

```lua
FieldToDoPermissions = {}
FieldToDoPermissions._testOverride = nil

local function resolveUserId(userId)
    if userId ~= nil then
        return userId
    end
    if FieldToDoPermissions._testOverride ~= nil then
        return FieldToDoPermissions._testOverride.userId
    end
    if g_currentMission ~= nil and g_currentMission.playerUserId ~= nil then
        return g_currentMission.playerUserId
    end
    if g_localPlayer ~= nil and g_localPlayer.userId ~= nil then
        return g_localPlayer.userId
    end
    return nil
end

function FieldToDoPermissions.isFarmManager(farmId, userId)
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.isManager ~= nil then
        return override.isManager == true
    end
    farmId = tonumber(farmId)
    userId = resolveUserId(userId)
    if farmId == nil or userId == nil or g_farmManager == nil then
        -- SP / missing API: treat as manager so local play keeps working
        return true
    end
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.isUserFarmManager == nil then
        return true
    end
    local ok, result = pcall(farm.isUserFarmManager, farm, userId)
    return ok and result == true
end

function FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId)
    farmId = tonumber(farmId)
    if farmId == nil or farmId <= 0 then
        return false
    end
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.resolveFarmId ~= nil and override.resolveFarmId ~= farmId then
        return false
    end
    if override == nil then
        local localFarm = nil
        if ToDoManager ~= nil and g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil then
            localFarm = g_currentMission.fieldToDoList:getLocalFarmId()
        end
        if localFarm ~= nil and localFarm ~= farmId then
            return false
        end
    end
    return true
end

function FieldToDoPermissions.canEditFarmTodos(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    local workersOk = true
    if FieldAdvisorSettings ~= nil and FieldAdvisorSettings.isWorkersMayEditTodos ~= nil then
        workersOk = FieldAdvisorSettings.isWorkersMayEditTodos()
    elseif FieldAdvisorSettings ~= nil then
        workersOk = FieldAdvisorSettings.workersMayEditTodos ~= false
    end
    if workersOk then
        return true
    end
    return FieldToDoPermissions.isFarmManager(farmId, userId)
end

function FieldToDoPermissions.canChangeWorkersEditSetting(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    return FieldToDoPermissions.isFarmManager(farmId, userId)
end

function FieldToDoPermissions.canEditLocal()
    local farmId = nil
    if g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil then
        farmId = g_currentMission.fieldToDoList:getLocalFarmId()
    end
    return FieldToDoPermissions.canEditFarmTodos(farmId, nil)
end
```

Add to `modDesc.xml` `extraSourceFiles` **before** `FieldAdvisorSettings.lua` is wrong — permissions needs settings. Place **after** `FieldAdvisorSettings.lua`:

```xml
<sourceFile filename="scripts/FieldAdvisorSettings.lua"/>
<sourceFile filename="scripts/FieldToDoPermissions.lua"/>
```

- [ ] **Step 4: Run tests**

Run: `lua tests/run.lua`  
Expected: all previous suites PASS; new permission fixtures PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/FieldToDoPermissions.lua tests/permissions_fixtures.lua tests/run.lua modDesc.xml
git commit -m "feat: add FieldToDoPermissions gate helpers and tests."
```

---

