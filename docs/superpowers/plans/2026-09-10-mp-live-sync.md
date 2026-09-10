# MP Live Sync + Farm Edit Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Same-farm players get live To-Do / settings / Planfrucht sync via server-authoritative events, with edit gated by farm manager + `workersMayEditTodos` (default on).

**Architecture:** `FieldToDoPermissions` decides who may edit vs auto-complete. UI and auto-complete call `FieldToDoSync.request*`. Clients send `FieldToDoRequestEvent`; server applies via `ToDoManager` apply helpers, saves sidecar, broadcasts `FieldToDoNotifyEvent` (delta) or `FieldToDoStateEvent` (full). Singleplayer uses the same path (`g_server` local).

**Tech Stack:** FS25 Lua 5.1 (no `goto`), Giants `Event` / `InitEventClass` / `g_client` / `g_server`, existing `ToDoManager` + `FieldAdvisorSettings` + ESC GUI, headless `lua tests/run.lua`.

**Spec:** `docs/superpowers/specs/2026-09-10-mp-live-sync-design.md`

## Global Constraints

- No `goto` / labels (Lua 5.1 load failure).
- Do not bump `modDesc.xml` version until Task 8 (release **0.1.0.9**).
- Logging via `FieldToDoLog` / `Logging`, not `print()`.
- Keep farm filter + `syncForeignFarmTasksFromDisk`; live sync does not replace multi-farm save merge.
- Out of scope: Vanilla farm-rights UI permission row; syncing field-scan/advisor caches.
- Manual Done requires edit permission; auto-complete does not.
- Default `workersMayEditTodos = true`.

## File map

| File | Role |
|------|------|
| `scripts/FieldToDoPermissions.lua` | **Create** — manager / edit / auto-complete gates |
| `scripts/FieldToDoSync.lua` | **Create** — opcodes, request API, server handlers, broadcast helpers |
| `scripts/events/FieldToDoRequestEvent.lua` | **Create** — client → server mutation |
| `scripts/events/FieldToDoNotifyEvent.lua` | **Create** — server → clients delta / deny |
| `scripts/events/FieldToDoStateEvent.lua` | **Create** — full farm snapshot |
| `scripts/FieldAdvisorSettings.lua` | Persist + getters for `workersMayEditTodos` |
| `scripts/ToDoManager.lua` | Apply helpers; route public mutators through sync; auto-complete requests |
| `gui/FieldToDoMenuFrame.xml` / `.lua` | Edit-mode toggle + disable gated buttons |
| `translations/translation_de.xml` / `_en.xml` | Labels / deny message |
| `modDesc.xml` | `extraSourceFiles` order + version in Task 8 |
| `tests/permissions_fixtures.lua` + `tests/run.lua` | Headless permission matrix |
| `CHANGELOG.md` / READMEs | Task 8 |

---

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

### Task 2: Persist `workersMayEditTodos` in FieldAdvisorSettings

**Files:**
- Modify: `scripts/FieldAdvisorSettings.lua`
- Modify: `scripts/ToDoManager.lua` (`registerSavegameXMLPaths`)
- Modify: `translations/translation_de.xml`, `translations/translation_en.xml`

**Interfaces:**
- Consumes: none new
- Produces:
  - `FieldAdvisorSettings.workersMayEditTodos` (default `true`)
  - `isWorkersMayEditTodos() -> boolean`
  - `setWorkersMayEditTodos(enabled)`
  - `toggleWorkersMayEditTodos() -> boolean`
  - `getWorkersMayEditLabel() -> string`

- [ ] **Step 1: Add failing assertion in permissions suite that `isWorkersMayEditTodos` exists**

In `tests/run.lua` permissions block, after dofile settings:

```lua
assert(type(FieldAdvisorSettings.isWorkersMayEditTodos) == "function")
assert(FieldAdvisorSettings.isWorkersMayEditTodos() == true)
FieldAdvisorSettings.setWorkersMayEditTodos(false)
assert(FieldAdvisorSettings.isWorkersMayEditTodos() == false)
FieldAdvisorSettings.setWorkersMayEditTodos(true)
```

Run: `lua tests/run.lua` — Expected: FAIL on missing API.

- [ ] **Step 2: Implement settings API + XML**

In `FieldAdvisorSettings.lua` after `mulchingEnabled`:

```lua
FieldAdvisorSettings.workersMayEditTodos = true

function FieldAdvisorSettings.isWorkersMayEditTodos()
    return FieldAdvisorSettings.workersMayEditTodos ~= false
end

function FieldAdvisorSettings.setWorkersMayEditTodos(enabled)
    FieldAdvisorSettings.workersMayEditTodos = enabled ~= false
end

function FieldAdvisorSettings.toggleWorkersMayEditTodos()
    FieldAdvisorSettings.workersMayEditTodos = not FieldAdvisorSettings.isWorkersMayEditTodos()
    return FieldAdvisorSettings.workersMayEditTodos
end

function FieldAdvisorSettings.getWorkersMayEditLabel()
    if FieldAdvisorSettings.isWorkersMayEditTodos() then
        return FieldToDoL10n.getText("ftdl_edit_all", "Edit: all")
    end
    return FieldToDoL10n.getText("ftdl_edit_managers", "Edit: managers")
end
```

In `loadFromXMLFile` (absent attribute keeps default **on**):

```lua
local workersEdit = xmlFile:getValue(key .. "#workersMayEditTodos")
if workersEdit ~= nil then
    FieldAdvisorSettings.setWorkersMayEditTodos(workersEdit == true)
end
```

In `saveToXMLFile`:

```lua
xmlFile:setValue(key .. "#workersMayEditTodos", FieldAdvisorSettings.isWorkersMayEditTodos())
```

In `ToDoManager.registerSavegameXMLPaths`:

```lua
schema:register(XMLValueType.BOOL, basePath .. "#workersMayEditTodos", "Non-managers may edit farm to-dos")
```

Translations:

```xml
<!-- de -->
<text name="ftdl_edit_all" text="Edit: alle"/>
<text name="ftdl_edit_managers" text="Edit: Manager"/>
<text name="ftdl_edit_denied" text="Keine Berechtigung für To-Do-Änderungen"/>

<!-- en -->
<text name="ftdl_edit_all" text="Edit: all"/>
<text name="ftdl_edit_managers" text="Edit: managers"/>
<text name="ftdl_edit_denied" text="No permission to change to-dos"/>
```

- [ ] **Step 3: Run `lua tests/run.lua`** — Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/FieldAdvisorSettings.lua scripts/ToDoManager.lua translations/translation_de.xml translations/translation_en.xml tests/run.lua
git commit -m "feat: persist workersMayEditTodos farm edit setting."
```

---

### Task 3: Sync core + Event classes (scaffold)

**Files:**
- Create: `scripts/FieldToDoSync.lua`
- Create: `scripts/events/FieldToDoRequestEvent.lua`
- Create: `scripts/events/FieldToDoNotifyEvent.lua`
- Create: `scripts/events/FieldToDoStateEvent.lua`
- Modify: `modDesc.xml` (sourceFiles after Permissions, events before ToDoManager)

**Interfaces:**
- Produces opcodes on `FieldToDoSync.OP`:
  - `ADD_MANUAL`, `ADD_FIELD`, `UPDATE_TEXT`, `DELETE`, `MOVE`, `TOGGLE_DONE`, `AUTO_COMPLETE`
  - `SET_PRESET`, `SET_ORGANIC`, `SET_MULCH`, `SET_WORKERS_EDIT`
  - `SET_PLANNED_CROP`
  - `DENY` (notify only)
- `FieldToDoSync.request(op, payload)` — client or local server entry
- `FieldToDoSync.handleRequest(op, payload, userId, connection)` — server
- `FieldToDoSync.applyNotify(op, payload)` — client apply
- `FieldToDoSync.buildStateForFarm(farmId) -> table`
- `FieldToDoSync.applyState(state)` — replace local farm tasks + settings + planned crops for that farm
- `FieldToDoSync.broadcastNotify(op, payload, farmId, excludeConnection)`
- `FieldToDoSync.sendStateToConnection(connection, farmId)` / `requestFullState()`

- [ ] **Step 1: Implement opcode table + stream helpers in `FieldToDoSync.lua`**

Use a single numeric `op` (`streamWriteUInt8` / `streamReadUInt8`). Payload fields vary by op; document a shared writer:

```lua
FieldToDoSync = {}
FieldToDoSync.SCHEMA_VERSION = 1
FieldToDoSync.OP = {
    ADD_MANUAL = 1,
    ADD_FIELD = 2,
    UPDATE_TEXT = 3,
    DELETE = 4,
    MOVE = 5,
    TOGGLE_DONE = 6,
    AUTO_COMPLETE = 7,
    SET_PRESET = 8,
    SET_ORGANIC = 9,
    SET_MULCH = 10,
    SET_WORKERS_EDIT = 11,
    SET_PLANNED_CROP = 12,
    DENY = 13,
}

function FieldToDoSync.writeString(streamId, value)
    streamWriteString(streamId, value or "")
end

function FieldToDoSync.readString(streamId)
    return streamReadString(streamId)
end

-- writePayload / readPayload: switch on op; use streamWriteBool / Int32 / Float only.
-- For ADD_FIELD include fieldId, actionType, text, autoComplete, fertPass, fertPassTotal, fruit, fieldName, suggestion.
-- For SET_PLANNED_CROP: fieldId + fruitTypeIndex (use -1 farmyard, 0 clear).
```

Stub `handleRequest` / `applyNotify` to call into ToDoManager apply methods added in Task 4 (for now leave TODO comments only if functions missing — prefer empty `if manager == nil then return end` guards).

- [ ] **Step 2: Implement three Event files** (Giants pattern)

`FieldToDoRequestEvent.lua`:

```lua
FieldToDoRequestEvent = {}
local FieldToDoRequestEvent_mt = Class(FieldToDoRequestEvent, Event)
InitEventClass(FieldToDoRequestEvent, "FieldToDoRequestEvent")

function FieldToDoRequestEvent.emptyNew()
    return Event.new(FieldToDoRequestEvent_mt)
end

function FieldToDoRequestEvent.new(op, payload)
    local self = FieldToDoRequestEvent.emptyNew()
    self.op = op
    self.payload = payload or {}
    return self
end

function FieldToDoRequestEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, FieldToDoSync.SCHEMA_VERSION)
    streamWriteUInt8(streamId, self.op)
    FieldToDoSync.writePayload(streamId, self.op, self.payload)
end

function FieldToDoRequestEvent:readStream(streamId, connection)
    local version = streamReadUInt8(streamId)
    self.op = streamReadUInt8(streamId)
    self.payload = FieldToDoSync.readPayload(streamId, self.op)
    self:run(connection)
end

function FieldToDoRequestEvent:run(connection)
    if connection:getIsServer() then
        return -- client should not receive requests
    end
    local userId = connection:getUserId() -- if nil, fall back via connection owner patterns used in other mods; pcall
    FieldToDoSync.handleRequest(self.op, self.payload, userId, connection)
end
```

`FieldToDoNotifyEvent`: server→all; `run` on client calls `FieldToDoSync.applyNotify`.  
`FieldToDoStateEvent`: writes schema, farmId, settings triad, planned crop count+pairs, task count+serialized tasks (reuse same field set as XML load: id, text, completed, source, fieldId, …, farmId, sortIndex).

- [ ] **Step 3: Wire `FieldToDoSync.request`**

```lua
function FieldToDoSync.request(op, payload)
    payload = payload or {}
    if g_server ~= nil and g_client ~= nil and g_server == nil then
        -- unreachable; keep simple:
    end
    if g_client ~= nil and g_client.getServerConnection ~= nil and not g_currentMission:getIsServer() then
        g_client:getServerConnection():sendEvent(FieldToDoRequestEvent.new(op, payload))
        return
    end
    -- SP / host: handle locally
    local userId = nil
    FieldToDoSync.handleRequest(op, payload, userId, nil)
end
```

Use `g_currentMission:getIsServer()` when available; else `g_server ~= nil`.

- [ ] **Step 4: Register source files in `modDesc.xml`** (order):

```xml
<sourceFile filename="scripts/FieldToDoPermissions.lua"/>
<sourceFile filename="scripts/FieldToDoSync.lua"/>
<sourceFile filename="scripts/events/FieldToDoRequestEvent.lua"/>
<sourceFile filename="scripts/events/FieldToDoNotifyEvent.lua"/>
<sourceFile filename="scripts/events/FieldToDoStateEvent.lua"/>
<sourceFile filename="scripts/ToDoManager.lua"/>
```

- [ ] **Step 5: Commit**

```bash
git add scripts/FieldToDoSync.lua scripts/events/ modDesc.xml
git commit -m "feat: add FieldToDoSync event scaffold and opcodes."
```

---

### Task 4: ToDoManager apply API + route mutations + auto-complete

**Files:**
- Modify: `scripts/ToDoManager.lua`
- Modify: `scripts/FieldToDoSync.lua` (`handleRequest` / `applyNotify` / state build)

**Interfaces:**
- Produces apply methods (mutate + dirty + save; **no** network):
  - `applyAddManualTask(text, farmId) -> task|nil`
  - `applyUpsertTask(taskTable) -> task` (for field adds / state apply)
  - `applyUpdateManualTask(taskId, text) -> boolean`
  - `applyDeleteManualTask(taskId) -> boolean`
  - `applyToggleManualTask(taskId) -> boolean`
  - `applyMoveTask(taskId, delta) -> boolean`
  - `applyAutoCompleteTask(taskId) -> boolean` (only mark complete if open)
  - `applySettingsPatch(patch)` — keys: workOrderPreset, organicMultiPassEnabled, mulchingEnabled, workersMayEditTodos
  - `applyPlannedCrop(fieldId, fruitTypeIndex)` — wraps `FieldPlannedCrop.set` / clear
- Public UI methods (`addManualTask`, `updateManualTask`, …) become thin wrappers calling `FieldToDoSync.request(...)`.
- `updateAutoCompletion`: replace direct `onTaskMarkedComplete` with `FieldToDoSync.request(OP.AUTO_COMPLETE, { taskId = ... })`.

- [ ] **Step 1: Extract apply bodies**

Refactor existing `addManualTask` body into `applyAddManualTask` (server assigns `id` from `self.nextTaskId`). Keep `farmId` argument (default `getLocalFarmId()`).

Same pattern for update/delete/toggle/move.

For field-task creation: build task table on **server** inside `handleRequest(ADD_FIELD)` using existing `addTaskFromFieldAction` logic moved to `applyAddTaskFromFieldAction(...)` that still needs `fieldRecord` — **problem:** clients should send enough fields so server does not need client fieldRecord.

**Decision (locked for implementer):** `ADD_FIELD` payload is a **complete task draft** without id:

```lua
{
  text, source="field", fieldId, fieldName, fruit, actionType,
  fertPass, fertPassTotal, suggestion, autoComplete, farmId
}
```

Server sets `id`, `sortIndex`, `farmId` (force requester farm), inserts via `applyUpsertTask`.

UI currently calls `addTaskFromFieldAction` — change it to build the draft locally for display text, then `FieldToDoSync.request(ADD_FIELD, draft)` without inserting until notify returns. On SP, `handleRequest` applies immediately and notify applies locally (or apply once with `noEventSend` pattern).

Avoid double-insert on host: `handleRequest` applies once, then `broadcastNotify` with `includeSelf=false` for host that already applied; clients only `applyNotify`. Pattern:

```lua
function FieldToDoSync.handleRequest(op, payload, userId, connection)
    local manager = g_currentMission and g_currentMission.fieldToDoList
    if manager == nil then return end
    local farmId = manager:getLocalFarmId() -- WRONG for dedicated: resolve farm from userId
    farmId = FieldToDoSync.resolveFarmIdForUser(userId) or manager:getLocalFarmId()
    -- permission checks per op
    local ok, resultPayload = FieldToDoSync.executeOnServer(op, payload, farmId, userId)
    if not ok then
        FieldToDoSync.sendDeny(connection, resultPayload or "denied")
        return
    end
    FieldToDoSync.broadcastNotify(op, resultPayload, farmId, nil) -- include all; clients apply; server already applied inside executeOnServer — use flag appliedOnServer=true and notify payload is authoritative task
end
```

Simpler rule: **`executeOnServer` mutates server state; `broadcastNotify` sent to everyone; on server connection skip re-apply if `g_server` and event is broadcast with `false` include self — clients apply.** Host player is both: after `executeOnServer`, host already has state; broadcast to clients only (`excludeConnection` for empty on SP). On SP with no clients, skip broadcast.

```lua
function FieldToDoSync.broadcastNotify(op, payload, farmId, excludeConnection)
    if g_server == nil then
        FieldToDoSync.applyNotify(op, payload)
        return
    end
    g_server:broadcastEvent(FieldToDoNotifyEvent.new(op, payload, farmId), false, excludeConnection)
end
```

For SP host-only: after execute, also call `applyNotify` only if execute returned without writing local — **best:** execute writes server memory; NotifyEvent.run on each client; for dedicated clients only; for listen-server broadcast includes clients and host client connection receives notify — then **don't apply in execute for listen-server host** OR apply in execute and make applyNotify idempotent (upsert by task id).

**Locked:** apply methods are **idempotent upserts** by `task.id`. `executeOnServer` always applies; `applyNotify` upserts same data (safe if host receives own broadcast).

- [ ] **Step 2: Permission checks inside `executeOnServer`**

| Op | Gate |
|----|------|
| AUTO_COMPLETE | `canAutoCompleteFarmTodos` |
| SET_WORKERS_EDIT | `canChangeWorkersEditSetting` |
| all other mutations | `canEditFarmTodos` |

- [ ] **Step 3: Wire public methods**

Example:

```lua
function ToDoManager:addManualTask(text)
    if FieldToDoSync ~= nil then
        FieldToDoSync.request(FieldToDoSync.OP.ADD_MANUAL, { text = text })
        return nil -- UI refreshes on dirty/notify; or return provisional
    end
    return self:applyAddManualTask(text, self:getLocalFarmId())
end
```

Menu add-task flow: after request, rely on `markManualTasksDirty` from apply. If UI needs immediate selection, select by id from notify (optional later).

- [ ] **Step 4: Auto-complete**

In `updateAutoCompletion`, when complete:

```lua
if FieldToDoSync ~= nil then
    FieldToDoSync.request(FieldToDoSync.OP.AUTO_COMPLETE, { taskId = taskId })
else
    self:onTaskMarkedComplete(task)
end
```

Do not call `requestDebouncedSave` until apply runs.

- [ ] **Step 5: Clients must not save**

`ToDoManager:canPersistSidecar` currently returns `true` always. Change to server-only:

```lua
function ToDoManager:canPersistSidecar()
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil then
        return g_currentMission:getIsServer() == true
    end
    return g_server ~= nil
end
```

Gate `saveSettingsNow` / career save hook with this (host writes; pure clients no-op).

- [ ] **Step 6: Commit**

```bash
git add scripts/ToDoManager.lua scripts/FieldToDoSync.lua
git commit -m "feat: route ToDo mutations through server sync apply path."
```

---

### Task 5: Full state on join / farm change

**Files:**
- Modify: `scripts/FieldToDoSync.lua`
- Modify: `scripts/ToDoManager.lua` (`onStartMission` / message subscribe)

- [ ] **Step 1: Implement `buildStateForFarm` / `applyState`**

State table:

```lua
{
  farmId = number,
  nextTaskId = number,
  settings = {
    workOrderPreset, organicMultiPassEnabled, mulchingEnabled, workersMayEditTodos
  },
  plannedCrops = { { fieldId, value }, ... }, -- only entries; farm-agnostic map is global today — sync full FieldPlannedCrop.byFieldId (acceptable YAGNI) or document farm-local later
  tasks = { task, ... } -- all tasks with farmId == farmId
}
```

`applyState` on client: remove local tasks for that farmId; insert state.tasks; apply settings; merge planned crops.

- [ ] **Step 2: Client requests state after mission start if not server**

In `onStartMission` after load:

```lua
if FieldToDoSync ~= nil and FieldToDoSync.onMissionStarted ~= nil then
    FieldToDoSync.onMissionStarted()
end
```

```lua
function FieldToDoSync.onMissionStarted()
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer() then
        return -- host already loaded XML
    end
    FieldToDoSync.requestFullState()
end
```

Add op `REQUEST_STATE = 14` handled only on server → `sendStateToConnection`.

- [ ] **Step 3: Subscribe farm change**

```lua
if MessageType ~= nil and MessageType.PLAYER_FARM_CHANGED ~= nil then
    g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, FieldToDoSync.onPlayerFarmChanged)
end
```

On change: client `requestFullState()`; refresh HUD dirty flags.

- [ ] **Step 4: Commit**

```bash
git add scripts/FieldToDoSync.lua scripts/ToDoManager.lua
git commit -m "feat: full farm To-Do state sync on join and farm change."
```

---

### Task 6: ESC UI — toggle + disable gated controls

**Files:**
- Modify: `gui/FieldToDoMenuFrame.xml`
- Modify: `gui/FieldToDoMenuFrame.lua`

- [ ] **Step 1: Add button row control**

Beside mulch (may need slight x reposition or second row): add `workersEditBtnText` + hit button `onClickToggleWorkersEdit`, mirroring mulch toggle.

If horizontal space is tight, place at `378px -580px` and shift planned-crop only on bottom row — implementer picks layout that does not overlap; keep vanilla green profiles.

- [ ] **Step 2: `updateEditPermissionUi`**

Call from `onFrameOpen`, `updateOptionalColumns`, and after settings notify:

```lua
function FieldToDoMenuFrame:updateEditPermissionUi()
    local canEdit = FieldToDoPermissions ~= nil and FieldToDoPermissions.canEditLocal()
    local canSetting = false
    if FieldToDoPermissions ~= nil and g_currentMission ~= nil and g_currentMission.fieldToDoList ~= nil then
        local farmId = g_currentMission.fieldToDoList:getLocalFarmId()
        canSetting = FieldToDoPermissions.canChangeWorkersEditSetting(farmId, nil)
    end
    -- setDisabled on: btnAdd, btnEdit, btnDone, btnDelete, move up/down, adopt, planned crop, work order, organic, mulch
    -- workers edit button: setDisabled(not canSetting)
    -- Visit stays enabled
    if self.workersEditBtnText ~= nil and FieldAdvisorSettings ~= nil then
        self.workersEditBtnText:setText(FieldAdvisorSettings.getWorkersMayEditLabel())
        self:applyToggleBtnColor(self.workersEditBtnText, FieldAdvisorSettings.isWorkersMayEditTodos())
    end
end
```

- [ ] **Step 3: Click handlers**

`onClickToggleWorkersEdit`: if not `canChangeWorkersEditSetting` return; else `FieldToDoSync.request(SET_WORKERS_EDIT, { enabled = not FieldAdvisorSettings.isWorkersMayEditTodos() })`.

Gate existing click handlers at top with `canEditLocal()` for edit actions; Done uses same gate; Visit unchanged.

On deny notify: set a short status string if a label exists, else `FieldToDoLog.info` + optional `g_currentMission:showBlinkingWarning` / existing FS feedback if already used in mod — prefer `FieldToDoLog` + menu header flash only if easy.

- [ ] **Step 4: Refresh lists when `consumeManualTasksDirty`**

Ensure notify path calls `manager:markManualTasksDirty()` so menu/HUD refresh (HUD already polls dirty — verify).

- [ ] **Step 5: Commit**

```bash
git add gui/FieldToDoMenuFrame.xml gui/FieldToDoMenuFrame.lua
git commit -m "feat: ESC UI for workers-edit toggle and permission gating."
```

---

### Task 7: Manual MP/SP verification checklist (no code unless bugs)

**Files:** none required (fix only)

- [ ] **Step 1: Build**

```bash
python3 tools/generate_assets.py && SKIP_INSTALL=1 ./build.sh
lua tests/run.lua
```

Expected: ZIP builds; all tests PASS.

- [ ] **Step 2: SP smoke**

1. New/load save — add/edit/delete/reorder/Done — works.
2. Toggle Edit to managers — still works (local manager).
3. Toggle mulch/organic/preset/planfrucht — works.
4. Restart — `workersMayEditTodos` persisted.

- [ ] **Step 3: MP smoke (two clients, same farm)**

1. Default edit all: A adds task → B ESC/HUD updates without save.
2. Manager sets Edit: managers; worker cannot Add/Done/settings; worker’s field auto-complete still completes a trackable task.
3. Other farm client does not see farm A tasks.

- [ ] **Step 4: If failures, fix in place with small commits** (`fix: …`).

---

### Task 8: Release 0.1.0.9 docs

**Files:**
- Modify: `modDesc.xml` (`0.1.0.9`)
- Modify: `CHANGELOG.md`, `README.md`, `README.de.md`, `docs/RELEASE.md`
- Modify: `docs/superpowers/specs/2026-09-10-mp-live-sync-design.md` status → implemented

- [ ] **Step 1: CHANGELOG section**

```markdown
## [0.1.0.9] — 2026-09-10

### Added
- Multiplayer live sync for farm To-Dos, settings, and planned crop (server-authoritative events).
- Farm edit gate: managers always; workers via setting `workersMayEditTodos` (default on).
- Auto-complete remains allowed for all same-farm members; manual Done requires edit permission.
```

- [ ] **Step 2: Bump version strings; build once more**

```bash
python3 tools/generate_assets.py && SKIP_INSTALL=1 ./build.sh
```

- [ ] **Step 3: Commit**

```bash
git add modDesc.xml CHANGELOG.md README.md README.de.md docs/RELEASE.md docs/superpowers/specs/2026-09-10-mp-live-sync-design.md
git commit -m "Release 0.1.0.9: multiplayer live To-Do sync and edit permissions."
```

Do **not** tag/push unless the user asks.

---

## Spec coverage (self-review)

| Spec item | Task |
|-----------|------|
| Server-authoritative mutations | 3–4 |
| Manager + workersMayEditTodos | 1–2, 4, 6 |
| Auto-complete all / manual Done edit | 4, 6 |
| Settings + Planfrucht gated | 4, 6 |
| Full sync join / farm change | 5 |
| ESC toggle + disable UI | 6 |
| Persist setting | 2 |
| Stable `canEditFarmTodos` | 1 |
| No Vanilla permission UI | out of scope |
| Tests permissions | 1–2 |
| Release notes | 8 |

## Placeholder / consistency check

- Opcodes and method names are consistent across tasks (`workersMayEditTodos`, `SET_WORKERS_EDIT`, `canEditLocal`).
- No TBD left; ADD_FIELD uses task-draft payload (explicit).
- Listen-server double-apply handled via idempotent upsert.
