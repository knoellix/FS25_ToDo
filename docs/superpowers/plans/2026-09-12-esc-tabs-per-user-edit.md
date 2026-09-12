# ESC Tab Scroll + Per-User To-Do Edit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve ESC left-tab visibility/scroll with many mods (Phase B), then replace the farm-wide edit toggle with per-**online** same-farm user grants on our ESC page (Phase C).

**Architecture:** Keep vanilla `InGameMenu` tab strip; add safe ensure-visible + optional mouse-wheel hooks in `InGameMenuIntegration`. Edit gate moves from boolean `workersMayEditTodos` to farm-scoped `{ defaultAllow, byUniqueUserId }` resolved on the server via `userManager` unique ids; sync extends `FieldToDoSync` state + two manager-only ops.

**Tech Stack:** FS25 Lua 5.1 (no `goto`), existing `FieldToDoPermissions` / `FieldToDoSync` / ESC GUI, headless `lua tests/run.lua`.

**Spec:** `docs/superpowers/specs/2026-09-12-esc-tabs-per-user-edit-design.md`

## Global Constraints

- No `goto` / labels (Lua 5.1 load failure).
- Do **not** bump `modDesc.xml` version until the release task (target **0.1.0.9** unless maintainer says otherwise).
- Logging via `FieldToDoLog` / `Logging`, not `print()`.
- Do **not** replace or suppress the vanilla ESC shell / full tab strip.
- Do **not** inject into vanilla Hofverwaltung permission UI.
- Do **not** mutate `pagingTabList` as a Lua array of GuiElements (hang risk — see existing comment in `InGameMenuIntegration`).
- Phase order: **B before C**. Permissions audit is **out of this plan** (separate pass after C).
- Auto-complete remains all same-farm members; manual Done / Planfrucht / task CRUD / work settings require edit grant.
- Maintainer shell is **fish** — commit with single `-m` or fish-safe strings.

## File map

| File | Role |
|------|------|
| `scripts/InGameMenuIntegration.lua` | Phase B: ensure tab visible; optional wheel scroll |
| `scripts/FieldToDoPermissions.lua` | Phase C: per-user edit + uniqueUserId resolve; keep membership fix |
| `scripts/FieldAdvisorSettings.lua` | Migrate defaultAllow; helpers for per-user map accessors used by UI (or thin wrappers) |
| `scripts/ToDoManager.lua` | Persist farm-scoped edit maps in sidecar; apply helpers |
| `scripts/FieldToDoSync.lua` | State encode/decode; `SET_USER_TODO_EDIT` / `SET_ALL_WORKERS_TODO_EDIT` |
| `gui/FieldToDoMenuFrame.xml` / `.lua` | Replace workers toggle with Alle an/aus + online member list |
| `translations/translation_de.xml` / `_en.xml` | Labels |
| `tests/permissions_fixtures.lua` + `tests/run.lua` | Updated permission matrix |
| `CHANGELOG.md` / `modDesc.xml` | Release notes + version on final task |
| Spec status line | Mark approved/implemented when done |

---

### Task 0: Land MP deny-root-cause fix (already in working tree)

**Files:**
- Modify (already): `scripts/FieldToDoPermissions.lua`, `scripts/FieldToDoSync.lua`, `scripts/events/FieldToDoRequestEvent.lua`, `CHANGELOG.md`

**Interfaces:**
- Produces (must remain):
  - `FieldToDoSync.resolveUserIdFromConnection(connection) -> number|nil`
  - `FieldToDoPermissions.userBelongsToFarm(farmId, userId) -> boolean|nil`
  - Client requests must **not** fall back to host `getLocalFarmId()` when `connection ~= nil`

- [ ] **Step 1: Verify working tree contains the fix**

Run:

```bash
rg -n "resolveUserIdFromConnection|userBelongsToFarm|allowLocalFarmFallback" scripts/
```

Expected: matches in `FieldToDoSync.lua`, `FieldToDoPermissions.lua`, `FieldToDoRequestEvent.lua`.

- [ ] **Step 2: Run headless tests**

Run: `lua tests/run.lua`  
Expected: `39 passed` (or higher if later tasks already merged) and `0 failed`.

- [ ] **Step 3: Commit**

```bash
git add scripts/FieldToDoPermissions.lua scripts/FieldToDoSync.lua scripts/events/FieldToDoRequestEvent.lua CHANGELOG.md
git commit -m "fix(mp): resolve farm edit deny via user membership, not host farm"
```

---

### Task 1: Phase B — ensure Field To-Do tab scrolled into view

**Files:**
- Modify: `scripts/InGameMenuIntegration.lua`
- Modify: `CHANGELOG.md` (Known / Fixed note under next version section draft)

**Interfaces:**
- Consumes: `FieldToDoInGameMenuIntegration.menuScreen`, `MENU_PAGE_NAME`, existing `onOpen` hook
- Produces:
  - `FieldToDoInGameMenuIntegration.ensureTabVisible(inGameMenu, screen) -> boolean`
  - Called from existing `onOpen` append and when our page becomes current (see steps)

- [ ] **Step 1: Add ensureTabVisible with pcall probes**

Append to `scripts/InGameMenuIntegration.lua` (near `placeTabAfterMap`):

```lua
--- Try to scroll the ESC tab strip so our tab button is visible.
---@param inGameMenu table|nil
---@param screen table|nil
---@return boolean handled
function FieldToDoInGameMenuIntegration.ensureTabVisible(inGameMenu, screen)
    if inGameMenu == nil or screen == nil then
        return false
    end

    local tabList = inGameMenu.pagingTabList
    if tabList == nil then
        return false
    end

    -- Prefer vanilla helpers if present; never treat tabList as a plain array to mutate.
    if type(tabList.scrollTo) == "function" and type(tabList.elements) == "table" then
        for i = 1, #tabList.elements do
            local btn = tabList.elements[i]
            if btn ~= nil and (btn.target == screen or btn.pageElement == screen) then
                local ok = pcall(tabList.scrollTo, tabList, i)
                return ok == true
            end
        end
    end

    if type(tabList.setSelectedIndex) == "function" and type(inGameMenu.pageFrames) == "table" then
        for i = 1, #inGameMenu.pageFrames do
            if inGameMenu.pageFrames[i] == screen then
                local ok = pcall(tabList.setSelectedIndex, tabList, i, true)
                return ok == true
            end
        end
    end

    return false
end
```

If button↔page binding differs at runtime, extend match conditions using whatever fields exist (`btn.pageName == MENU_PAGE_NAME`, etc.) behind additional `pcall` checks — still no GuiElement array mutation.

- [ ] **Step 2: Call ensureTabVisible from onOpen hook**

In the existing `inGameMenu.onOpen` appended function, after `placeTabAfterMap`, add:

```lua
pcall(FieldToDoInGameMenuIntegration.ensureTabVisible, menu or g_inGameMenu, page)
```

- [ ] **Step 3: Call ensureTabVisible when our page is shown**

In `FieldToDoInGameMenuIntegration.updateMenuFrame`, when `isFieldToDoPageVisible` becomes true (edge: was false / first visible this open), call `ensureTabVisible` once per open. Use a flag `FieldToDoInGameMenuIntegration._ensuredVisibleThisOpen` reset in the `onOpen` hook to `false`, set `true` after a successful/attempted ensure while visible.

- [ ] **Step 4: Manual SP smoke**

1. Load a save with many ESC-tab mods if available (or accept few-tab no-op).
2. Open ESC → Field To-Do tab reachable; no hang/garbage.
3. Log has no new spam beyond optional single warning.

- [ ] **Step 5: Commit**

```bash
git add scripts/InGameMenuIntegration.lua CHANGELOG.md
git commit -m "fix(ui): ensure Field To-Do ESC tab scrolls into view"
```

---

### Task 2: Phase B — mouse wheel on tab strip (best-effort)

**Files:**
- Modify: `scripts/InGameMenuIntegration.lua`

**Interfaces:**
- Produces: `FieldToDoInGameMenuIntegration.onTabListMouseWheel(inGameMenu, delta) -> nil` wired only if safe

- [ ] **Step 1: Implement wheel helper**

```lua
function FieldToDoInGameMenuIntegration.onTabListMouseWheel(inGameMenu, delta)
    if inGameMenu == nil or delta == nil or delta == 0 then
        return
    end
    local tabList = inGameMenu.pagingTabList
    if tabList == nil then
        return
    end
    if type(tabList.mouseEvent) == "function" then
        -- Prefer letting list handle wheel if API exists; otherwise adjust slider.
        return
    end
    if type(tabList.setSliderValue) == "function" and type(tabList.getSliderValue) == "function" then
        local ok, value = pcall(tabList.getSliderValue, tabList)
        if ok and type(value) == "number" then
            pcall(tabList.setSliderValue, tabList, value - delta)
        end
    end
end
```

- [ ] **Step 2: Wire wheel only when ESC open and cursor over tab list**

In the existing `InGameMenu.update` append (or a dedicated input hook if the project already uses one), when `g_gui.currentGui == inGameMenu` (or menu visible) and mouse is over `pagingTabList` absolute box (`getIsVisible` + position/size checks via pcall), read wheel delta from available input API (`InputAction` / `g_inputBinding` — probe in-game; if none found, **skip wiring** and document in CHANGELOG known limitations).

Do **not** invent a hard dependency on a missing global; empty hook + changelog note is an acceptable completion for this task.

- [ ] **Step 3: Commit**

```bash
git add scripts/InGameMenuIntegration.lua CHANGELOG.md
git commit -m "fix(ui): best-effort mouse wheel scroll on ESC tab strip"
```

---

### Task 3: Phase C — settings model + headless permission fixtures

**Files:**
- Modify: `scripts/FieldAdvisorSettings.lua`
- Modify: `scripts/FieldToDoPermissions.lua`
- Modify: `tests/permissions_fixtures.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Produces:
  - `FieldAdvisorSettings.todoEditDefaultAllow` (boolean, default `true`)
  - `FieldAdvisorSettings.todoEditByUniqueUserId` (table map string→bool) — **client/local cache for current farm state**
  - `FieldAdvisorSettings.getTodoEditAllowedForUniqueUser(uniqueUserId) -> boolean`
  - `FieldAdvisorSettings.setTodoEditAllowedForUniqueUser(uniqueUserId, enabled)`
  - `FieldAdvisorSettings.setAllTodoEditDefaultsFromLegacyWorkersFlag(workersMayEditTodosBool)` for migration helper
  - `FieldToDoPermissions.resolveUniqueUserId(userId) -> string|nil`
  - `FieldToDoPermissions.canEditFarmTodos(farmId, userId)` uses manager OR per-user/defaultAllow
  - `FieldToDoPermissions.canManageTodoEditGrants(farmId, userId) -> boolean` (alias of manager check; replaces `canChangeWorkersEditSetting` callers)

- [ ] **Step 1: Replace fixtures**

Replace `tests/permissions_fixtures.lua` with:

```lua
return {
  {
    name = "default_allow_non_manager_can_edit",
    defaultAllow = true,
    userGrant = nil,
    isManager = false,
    sameFarm = true,
    expect = { edit = true, manageGrants = false, autoComplete = true },
  },
  {
    name = "default_deny_non_manager_cannot_edit",
    defaultAllow = false,
    userGrant = nil,
    isManager = false,
    sameFarm = true,
    expect = { edit = false, manageGrants = false, autoComplete = true },
  },
  {
    name = "default_deny_but_user_grant_can_edit",
    defaultAllow = false,
    userGrant = true,
    isManager = false,
    sameFarm = true,
    expect = { edit = true, manageGrants = false, autoComplete = true },
  },
  {
    name = "default_allow_but_user_deny_cannot_edit",
    defaultAllow = true,
    userGrant = false,
    isManager = false,
    sameFarm = true,
    expect = { edit = false, manageGrants = false, autoComplete = true },
  },
  {
    name = "manager_always_edit_and_manage",
    defaultAllow = false,
    userGrant = false,
    isManager = true,
    sameFarm = true,
    expect = { edit = true, manageGrants = true, autoComplete = true },
  },
  {
    name = "other_farm_denied",
    defaultAllow = true,
    userGrant = true,
    isManager = true,
    sameFarm = false,
    expect = { edit = false, manageGrants = false, autoComplete = false },
  },
}
```

- [ ] **Step 2: Update tests/run.lua permission loop**

For each fixture:

```lua
FieldAdvisorSettings.todoEditDefaultAllow = c.defaultAllow
FieldAdvisorSettings.todoEditByUniqueUserId = {}
FieldToDoPermissions._testOverride = {
  farmId = 1,
  userId = 1,
  uniqueUserId = "u1",
  isManager = c.isManager,
  resolveFarmId = c.sameFarm and 1 or 2,
}
if c.userGrant ~= nil then
  FieldAdvisorSettings.todoEditByUniqueUserId["u1"] = c.userGrant
end
local gotEdit = FieldToDoPermissions.canEditFarmTodos(1, 1)
local gotManage = FieldToDoPermissions.canManageTodoEditGrants(1, 1)
local gotAuto = FieldToDoPermissions.canAutoCompleteFarmTodos(1, 1)
```

Assert against `c.expect.edit`, `manageGrants`, `autoComplete`.

- [ ] **Step 3: Run tests — expect FAIL**

Run: `lua tests/run.lua`  
Expected: permission fixtures FAIL (old API / missing helpers).

- [ ] **Step 4: Implement settings helpers**

In `FieldAdvisorSettings.lua`:

```lua
FieldAdvisorSettings.todoEditDefaultAllow = true
FieldAdvisorSettings.todoEditByUniqueUserId = {}

function FieldAdvisorSettings.getTodoEditAllowedForUniqueUser(uniqueUserId)
    if uniqueUserId == nil or uniqueUserId == "" then
        return FieldAdvisorSettings.todoEditDefaultAllow ~= false
    end
    local mapped = FieldAdvisorSettings.todoEditByUniqueUserId[tostring(uniqueUserId)]
    if mapped == nil then
        return FieldAdvisorSettings.todoEditDefaultAllow ~= false
    end
    return mapped == true
end

function FieldAdvisorSettings.setTodoEditAllowedForUniqueUser(uniqueUserId, enabled)
    if uniqueUserId == nil or uniqueUserId == "" then
        return
    end
    FieldAdvisorSettings.todoEditByUniqueUserId[tostring(uniqueUserId)] = enabled == true
end

function FieldAdvisorSettings.migrateWorkersMayEditTodosFlag(workersFlag)
    -- Legacy attribute: false ⇒ default deny; true/nil ⇒ default allow.
    if workersFlag == false then
        FieldAdvisorSettings.todoEditDefaultAllow = false
    else
        FieldAdvisorSettings.todoEditDefaultAllow = true
    end
end
```

Keep `workersMayEditTodos` read path on load calling `migrateWorkersMayEditTodosFlag`; still write both for one release (`workersMayEditTodos` mirrors `todoEditDefaultAllow`).

- [ ] **Step 5: Implement permission resolve + canEdit**

```lua
function FieldToDoPermissions.resolveUniqueUserId(userId)
    local override = FieldToDoPermissions._testOverride
    if override ~= nil and override.uniqueUserId ~= nil then
        return tostring(override.uniqueUserId)
    end
    userId = resolveUserId(userId)
    if userId == nil or g_currentMission == nil or g_currentMission.userManager == nil then
        return nil
    end
    local um = g_currentMission.userManager
    if um.getUniqueUserIdByUserId ~= nil then
        local ok, uid = pcall(um.getUniqueUserIdByUserId, um, userId)
        if ok and uid ~= nil and uid ~= "" then
            return tostring(uid)
        end
    end
    if um.getUserByUserId ~= nil then
        local ok, user = pcall(um.getUserByUserId, um, userId)
        if ok and user ~= nil and user.getUniqueUserId ~= nil then
            local ok2, uid = pcall(user.getUniqueUserId, user)
            if ok2 and uid ~= nil then
                return tostring(uid)
            end
        end
    end
    return nil
end

function FieldToDoPermissions.canEditFarmTodos(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    if FieldToDoPermissions.isFarmManager(farmId, userId) then
        return true
    end
    local uniqueId = FieldToDoPermissions.resolveUniqueUserId(userId)
    if FieldAdvisorSettings == nil or FieldAdvisorSettings.getTodoEditAllowedForUniqueUser == nil then
        return true
    end
    return FieldAdvisorSettings.getTodoEditAllowedForUniqueUser(uniqueId)
end

function FieldToDoPermissions.canManageTodoEditGrants(farmId, userId)
    if not FieldToDoPermissions.canAutoCompleteFarmTodos(farmId, userId) then
        return false
    end
    return FieldToDoPermissions.isFarmManager(farmId, userId)
end

-- Keep old name as alias for one release:
function FieldToDoPermissions.canChangeWorkersEditSetting(farmId, userId)
    return FieldToDoPermissions.canManageTodoEditGrants(farmId, userId)
end
```

- [ ] **Step 6: Run tests — expect PASS**

Run: `lua tests/run.lua`  
Expected: all permission fixtures PASS; total failed = 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/FieldAdvisorSettings.lua scripts/FieldToDoPermissions.lua tests/permissions_fixtures.lua tests/run.lua
git commit -m "feat: per-user todo edit grants with legacy default migration"
```

---

### Task 4: Phase C — persist farm-scoped maps + ToDoManager apply helpers

**Files:**
- Modify: `scripts/ToDoManager.lua` (XML schema, load/save, apply methods)
- Modify: `scripts/FieldAdvisorSettings.lua` (load/save integration already used by manager)

**Interfaces:**
- Produces:
  - `ToDoManager.todoEditByFarmId = { [farmId] = { defaultAllow = bool, byUniqueUserId = { [uid]=bool } } }`
  - `ToDoManager:getTodoEditStateForFarm(farmId) -> table`
  - `ToDoManager:applySetUserTodoEdit(payload, farmId, userId) -> table|nil`
  - `ToDoManager:applySetAllWorkersTodoEdit(payload, farmId, userId) -> table|nil`
  - On apply: update farm map + refresh `FieldAdvisorSettings` cache when `farmId == getLocalFarmId()`

Payload shapes:

```lua
-- SET_USER_TODO_EDIT
{ uniqueUserId = string, enabled = bool }

-- SET_ALL_WORKERS_TODO_EDIT
{ enabled = bool, uniqueUserIds = { string, ... } }  -- online workers only, from UI
```

- [ ] **Step 1: Register XML paths**

Under existing sidecar schema (`fieldToDoList`):

```lua
schema:register(XMLValueType.BOOL, basePath .. "#workersMayEditTodos", "Legacy default allow (mirrored)")
schema:register(XMLValueType.INT, basePath .. ".farmTodoEdit(?)#farmId", "Farm id")
schema:register(XMLValueType.BOOL, basePath .. ".farmTodoEdit(?)#defaultAllow", "Default worker edit")
schema:register(XMLValueType.STRING, basePath .. ".farmTodoEdit(?).user(?)#uniqueUserId", "Unique user id")
schema:register(XMLValueType.BOOL, basePath .. ".farmTodoEdit(?).user(?)#mayEdit", "May edit to-dos")
```

- [ ] **Step 2: Load/save loops**

On load: build `todoEditByFarmId`; call `FieldAdvisorSettings.migrateWorkersMayEditTodosFlag` from legacy attribute; if a `farmTodoEdit` entry exists it wins for that farm.  
On save: write legacy `#workersMayEditTodos` = defaultAllow for **local** farm (compat); write all `farmTodoEdit` entries.

- [ ] **Step 3: Implement apply helpers**

```lua
function ToDoManager:applySetUserTodoEdit(payload, farmId, userId)
    payload = payload or {}
    farmId = tonumber(farmId)
    local uniqueUserId = payload.uniqueUserId ~= nil and tostring(payload.uniqueUserId) or ""
    if farmId == nil or uniqueUserId == "" then
        return nil
    end
    local state = self:getTodoEditStateForFarm(farmId)
    state.byUniqueUserId[uniqueUserId] = payload.enabled == true
    self:syncTodoEditSettingsCache(farmId)
    self:markManualTasksDirty()
    self:requestDebouncedSave()
    return { farmId = farmId, uniqueUserId = uniqueUserId, enabled = payload.enabled == true }
end

function ToDoManager:applySetAllWorkersTodoEdit(payload, farmId, userId)
    payload = payload or {}
    farmId = tonumber(farmId)
    if farmId == nil then
        return nil
    end
    local enabled = payload.enabled == true
    local ids = payload.uniqueUserIds or {}
    local state = self:getTodoEditStateForFarm(farmId)
    for i = 1, #ids do
        local uid = tostring(ids[i])
        if uid ~= "" then
            state.byUniqueUserId[uid] = enabled
        end
    end
    self:syncTodoEditSettingsCache(farmId)
    self:markManualTasksDirty()
    self:requestDebouncedSave()
    return { farmId = farmId, enabled = enabled, uniqueUserIds = ids }
end
```

`syncTodoEditSettingsCache(farmId)` copies that farm’s map into `FieldAdvisorSettings.todoEditDefaultAllow` / `todoEditByUniqueUserId` when it is the local farm (clients always receive state for their farm).

- [ ] **Step 4: Commit**

```bash
git add scripts/ToDoManager.lua scripts/FieldAdvisorSettings.lua
git commit -m "feat: persist farm-scoped per-user todo edit maps"
```

---

### Task 5: Phase C — sync ops + state payload

**Files:**
- Modify: `scripts/FieldToDoSync.lua`
- Modify: `gui/FieldToDoMenuFrame.lua` (only if request wrappers needed later — prefer sync.request from UI in Task 6)

**Interfaces:**
- Produces opcodes (append; do not renumber existing ops):

```lua
SET_USER_TODO_EDIT = 15,
SET_ALL_WORKERS_TODO_EDIT = 16,
```

- `APPLY_METHOD_BY_OP` entries → `applySetUserTodoEdit` / `applySetAllWorkersTodoEdit`
- `canExecuteOp`: both require `canManageTodoEditGrants`
- `writePayload` / `readPayload` for both ops
- `buildStateForFarm` / `readState` / `applyState` include `todoEditDefaultAllow` + list of `{ uniqueUserId, mayEdit }`
- Keep streaming `workersMayEditTodos` bool as **mirror of defaultAllow** for older clients during one release (still SCHEMA_VERSION 1 if payload stays backward compatible — if not, bump `SCHEMA_VERSION` to 2 and document)

**Schema rule (locked for this task):** Bump `FieldToDoSync.SCHEMA_VERSION` to **2**. Old clients will fail join hash anyway when zip updates; server/client zip must match.

- [ ] **Step 1: Add opcodes + serialization**

`SET_USER_TODO_EDIT`: string uniqueUserId + bool enabled.  
`SET_ALL_WORKERS_TODO_EDIT`: bool enabled + uint8/uint16 count + N strings.

State: after existing settings bools, write `defaultAllow`, then count + pairs.

- [ ] **Step 2: applyState applies map to ToDoManager farm entry + settings cache**

- [ ] **Step 3: handleRequest permission**

Managers only; deny reason `denied` if worker calls grant ops.

- [ ] **Step 4: Commit**

```bash
git add scripts/FieldToDoSync.lua
git commit -m "feat(sync): per-user todo edit ops and state schema v2"
```

---

### Task 6: Phase C — ESC UI (online farm members + Alle an/aus)

**Files:**
- Modify: `gui/FieldToDoMenuFrame.xml`
- Modify: `gui/FieldToDoMenuFrame.lua`
- Modify: `translations/translation_de.xml`
- Modify: `translations/translation_en.xml`

**Interfaces:**
- Produces UI:
  - Button `btnWorkersEdit` relabeled to **Alle Worker an/aus** (toggles all **listed** non-managers)
  - SmoothList or simple vertical buttons for online members (keep layout minimal — prefer reuse existing list patterns in this frame)
- `listOnlineFarmMembersForEditUi() -> { { userId, uniqueUserId, nickname, isManager, mayEdit }, ... }`
- Only managers see list + Alle button; workers hide/disable

- [ ] **Step 1: Translations**

```xml
<!-- de -->
<e k="ftdl_edit_all_workers_on" v="Alle Worker: an"/>
<e k="ftdl_edit_all_workers_off" v="Alle Worker: aus"/>
<e k="ftdl_todo_edit_user" v="To-Dos bearbeiten"/>
<!-- en -->
<e k="ftdl_edit_all_workers_on" v="All workers: on"/>
<e k="ftdl_edit_all_workers_off" v="All workers: off"/>
<e k="ftdl_todo_edit_user" v="Edit to-dos"/>
```

(Adapt exact XML element shape to existing translation file style.)

- [ ] **Step 2: Member enumerator**

```lua
function FieldToDoMenuFrame:listOnlineFarmMembersForEditUi()
    local rows = {}
    local farmId = self:getManager() ~= nil and self:getManager():getLocalFarmId() or nil
    if farmId == nil or g_farmManager == nil then
        return rows
    end
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.getActiveUsers == nil then
        return rows
    end
    local ok, users = pcall(farm.getActiveUsers, farm)
    if not ok or type(users) ~= "table" then
        return rows
    end
    for _, userId in pairs(users) do
        local uid = tonumber(userId) or userId
        local uniqueId = FieldToDoPermissions.resolveUniqueUserId(uid)
        local nickname = tostring(uid)
        -- resolve nickname via userManager getUserByUserId:getNickname / getName (pcall)
        local isManager = FieldToDoPermissions.isFarmManager(farmId, uid)
        local mayEdit = isManager or FieldAdvisorSettings.getTodoEditAllowedForUniqueUser(uniqueId)
        rows[#rows + 1] = {
            userId = uid,
            uniqueUserId = uniqueId,
            nickname = nickname,
            isManager = isManager,
            mayEdit = mayEdit,
        }
    end
    return rows
end
```

- [ ] **Step 3: Wire Alle an/aus**

Replace `onClickToggleWorkersEdit` to:

1. `require` manage grants (`canManageTodoEditGrants` / `canChangeWorkersEditSetting`).
2. Build `uniqueUserIds` from listed non-managers with non-nil uniqueUserId.
3. Decide target `enabled` = not “all currently allowed” (if any worker false → turn all on; else all off) **or** simpler: flip based on `todoEditDefaultAllow` — **locked simpler rule:** if every listed worker currently `mayEdit`, set all false; else set all true.
4. `FieldToDoSync.request(OP.SET_ALL_WORKERS_TODO_EDIT, { enabled = enabled, uniqueUserIds = ids })`.

- [ ] **Step 4: Per-row toggle**

On row click (or checkbox): managers only; skip manager rows;  
`FieldToDoSync.request(OP.SET_USER_TODO_EDIT, { uniqueUserId = row.uniqueUserId, enabled = not row.mayEdit })`.

Refresh list on `consumeManualTasksDirty` / after state sync (already refreshes permissions UI).

- [ ] **Step 5: SP smoke + MP checklist (manual)**

SP: manager UI shows local user; edit still works.  
MP (when server updated): online workers only; offline absent; deny still logs reason.

- [ ] **Step 6: Commit**

```bash
git add gui/FieldToDoMenuFrame.lua gui/FieldToDoMenuFrame.xml translations/translation_de.xml translations/translation_en.xml
git commit -m "feat(ui): per-online-user todo edit grants on ESC page"
```

---

### Task 7: Docs + release 0.1.0.9

**Files:**
- Modify: `modDesc.xml` (`<version>0.1.0.9</version>` + description blurb)
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/specs/2026-09-12-esc-tabs-per-user-edit-design.md` (status → implemented)
- Modify: README / DE README only if they mention `Edit: alle`

- [ ] **Step 1: Changelog entries**

Cover: MP deny fix; tab ensure-visible / wheel; per-user grants; legacy `workersMayEditTodos` migration; schema v2.

- [ ] **Step 2: Build**

```bash
python3 tools/generate_assets.py && ./build.sh
```

Expected: zip builds without error.

- [ ] **Step 3: Commit + tag (only if user asked to release)**

```bash
git add modDesc.xml CHANGELOG.md docs/superpowers/specs/2026-09-12-esc-tabs-per-user-edit-design.md
git commit -m "chore: release 0.1.0.9 esc tabs and per-user edit"
```

Do **not** `git push` / `gh release` unless the user explicitly requests it.

---

## Spec coverage check

| Spec item | Task |
|-----------|------|
| MP membership deny fix | 0 |
| Ensure tab visible | 1 |
| Mouse wheel best-effort | 2 |
| Online + same farm only | 6 |
| Managers always edit | 3 |
| Default allow true + legacy false migration | 3–4 |
| Alle Worker an/aus for listed workers | 6 |
| uniqueUserId persistence | 4–5 |
| Server-authoritative sync | 5 |
| No vanilla Hofverwaltung inject | (non-goal) |
| Audit pass | **excluded** (after C) |

## Placeholder / consistency review

- Opcodes **15/16** appended; schema **v2** — consistent across Task 5–6.
- `canManageTodoEditGrants` is the manager-only name; alias keeps old callers compiling during transition.
- No TBD steps; wheel task may no-op with documented limitation if input API absent.
