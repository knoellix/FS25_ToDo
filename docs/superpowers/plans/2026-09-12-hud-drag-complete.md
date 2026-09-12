# HUD Drag + Click-to-Complete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the in-world To-Do HUD draggable by its title (mouse cursor visible), persist `panelX`/`panelY` client-side per user profile, and let LMB on a row mark that task done via the existing toggle/sync path.

**Architecture:** Keep `FieldToDoHudOverlay` as a screen overlay (no GuiElement). Add pure layout/hit-test helpers (unit-tested), load/save a tiny `modSettings/…/hud.xml`, and poll mouse in `update(dt)` while `canDraw()`. Completes call `ToDoManager:toggleManualTask` after `FieldToDoPermissions.canEditLocal()`.

**Tech Stack:** FS25 Lua 5.1 (no `goto`), existing HUD + `FieldToDoSync` `TOGGLE_DONE`, headless `lua tests/run.lua`.

**Spec:** `docs/superpowers/specs/2026-09-12-hud-drag-complete-design.md`

## Global Constraints

- No `goto` / labels (Lua 5.1 load failure).
- Do **not** bump `modDesc.xml` version unless the user explicitly asks (keep **0.1.0.9** for this unpushed train).
- Logging via `FieldToDoLog` / `Logging`, not `print()`.
- Position is **client-only** — never sync via `FieldToDoSync` / savegame sidecar.
- Do **not** persist HUD visible on/off.
- Drag grip = **header only**; row LMB = complete; no right-click undo; no resize.
- Complete requires edit permission (same as ESC Done).
- Maintainer shell is **fish** — commit with single `-m` or fish-safe strings.
- After mod updates: full FS25 restart for in-game verification.

## File map

| File | Role |
|------|------|
| `scripts/FieldToDoHudOverlay.lua` | Runtime `panelX`/`panelY`, hit-test, drag state, draw, persist hooks, click-complete |
| `scripts/ToDoManager.lua` | Call `FieldToDoHudOverlay.instance:update(dt)` from existing mission `update` |
| `tests/hud_layout_fixtures.lua` | Pure geometry cases (clamp + hit regions + drag threshold) |
| `tests/run.lua` | Register HUD layout tests |
| `CHANGELOG.md` | Added/Fixed bullets under 0.1.0.9 |
| Spec status line | Mark implemented when done |

Optional (only if overlay file grows unwieldy): extract `scripts/FieldToDoHudLayout.lua` for pure helpers — prefer keeping helpers as `FieldToDoHudOverlay.*` static functions first.

---

### Task 1: Pure layout helpers + headless tests

**Files:**
- Modify: `scripts/FieldToDoHudOverlay.lua`
- Create: `tests/hud_layout_fixtures.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Produces:
  - `FieldToDoHudOverlay.clampPanelPosition(panelX, panelY, panelW, panelH, margin) -> panelX, panelY`
  - `FieldToDoHudOverlay.getHeaderRect(panelX, panelY, panelW, panelH, headerH) -> x, y, w, h`  
    (header occupies the **top** of the panel: `y = panelY + panelH - headerH`)
  - `FieldToDoHudOverlay.getRowRect(panelX, panelY, panelW, panelH, headerH, rowH, rowIndex) -> x, y, w, h`  
    (`rowIndex` 1-based from top of list)
  - `FieldToDoHudOverlay.pointInRect(px, py, x, y, w, h) -> boolean`
  - `FieldToDoHudOverlay.DRAG_MOVE_THRESHOLD = 0.005` (normalized screen units)

- [ ] **Step 1: Add failing fixtures**

Create `tests/hud_layout_fixtures.lua`:

```lua
-- Pure HUD layout cases (no FS runtime).
return {
  {
    name = "clamp_keeps_panel_on_screen",
    panelX = 0.95,
    panelY = -0.1,
    panelW = 0.168,
    panelH = 0.08,
    margin = 0.01,
    expectXMin = 0.01,
    expectXMax = 0.99 - 0.168,
    expectYMin = 0.01,
    expectYMax = 0.99 - 0.08,
  },
  {
    name = "header_is_top_strip",
    panelX = 0.5,
    panelY = 0.4,
    panelW = 0.2,
    panelH = 0.1,
    headerH = 0.022,
    expectHeaderY = 0.4 + 0.1 - 0.022,
  },
  {
    name = "row1_below_header",
    panelX = 0.5,
    panelY = 0.4,
    panelW = 0.2,
    panelH = 0.1,
    headerH = 0.022,
    rowH = 0.020,
    rowIndex = 1,
    -- listTopY = panelY + panelH - headerH; rowY = listTopY - rowIndex * rowH
    expectRowY = (0.4 + 0.1 - 0.022) - 0.020,
  },
  {
    name = "point_in_header",
    px = 0.51,
    py = 0.4 + 0.1 - 0.011,
    rect = { x = 0.5, y = 0.4 + 0.1 - 0.022, w = 0.2, h = 0.022 },
    expectInside = true,
  },
  {
    name = "drag_threshold_constant",
    expectThreshold = 0.005,
  },
}
```

- [ ] **Step 2: Wire tests in `tests/run.lua` (expect FAIL until helpers exist)**

After the permissions block, append:

```lua
local hudFixtures = dofile(here .. "/hud_layout_fixtures.lua")
dofile(repoRoot .. "/scripts/FieldToDoHudOverlay.lua")

io.write("\n")
for _, c in ipairs(hudFixtures) do
  local mismatch = nil
  if c.name == "clamp_keeps_panel_on_screen" then
    if type(FieldToDoHudOverlay.clampPanelPosition) ~= "function" then
      mismatch = "clampPanelPosition missing"
    else
      local x, y = FieldToDoHudOverlay.clampPanelPosition(c.panelX, c.panelY, c.panelW, c.panelH, c.margin)
      if x < c.expectXMin - 1e-6 or x > c.expectXMax + 1e-6 then
        mismatch = string.format("x=%s out of range", tostring(x))
      elseif y < c.expectYMin - 1e-6 or y > c.expectYMax + 1e-6 then
        mismatch = string.format("y=%s out of range", tostring(y))
      end
    end
  elseif c.name == "header_is_top_strip" then
    if type(FieldToDoHudOverlay.getHeaderRect) ~= "function" then
      mismatch = "getHeaderRect missing"
    else
      local _, hy = FieldToDoHudOverlay.getHeaderRect(c.panelX, c.panelY, c.panelW, c.panelH, c.headerH)
      if math.abs(hy - c.expectHeaderY) > 1e-6 then
        mismatch = string.format("headerY expected %s got %s", c.expectHeaderY, tostring(hy))
      end
    end
  elseif c.name == "row1_below_header" then
    if type(FieldToDoHudOverlay.getRowRect) ~= "function" then
      mismatch = "getRowRect missing"
    else
      local _, ry = FieldToDoHudOverlay.getRowRect(
        c.panelX, c.panelY, c.panelW, c.panelH, c.headerH, c.rowH, c.rowIndex
      )
      if math.abs(ry - c.expectRowY) > 1e-6 then
        mismatch = string.format("rowY expected %s got %s", c.expectRowY, tostring(ry))
      end
    end
  elseif c.name == "point_in_header" then
    if type(FieldToDoHudOverlay.pointInRect) ~= "function" then
      mismatch = "pointInRect missing"
    else
      local r = c.rect
      local inside = FieldToDoHudOverlay.pointInRect(c.px, c.py, r.x, r.y, r.w, r.h)
      if inside ~= c.expectInside then
        mismatch = string.format("inside expected %s got %s", tostring(c.expectInside), tostring(inside))
      end
    end
  elseif c.name == "drag_threshold_constant" then
    if FieldToDoHudOverlay.DRAG_MOVE_THRESHOLD ~= c.expectThreshold then
      mismatch = string.format(
        "threshold expected %s got %s",
        tostring(c.expectThreshold),
        tostring(FieldToDoHudOverlay.DRAG_MOVE_THRESHOLD)
      )
    end
  end

  if mismatch == nil then
    pass = pass + 1
    io.write(string.format(GREEN .. "PASS" .. RESET .. " %-44s -> hud layout ok\n", c.name))
  else
    fail = fail + 1
    io.write(string.format(RED .. "FAIL" .. RESET .. " %-44s %s\n", c.name, mismatch))
  end
end
```

- [ ] **Step 3: Run tests — expect FAIL**

Run: `lua tests/run.lua`  
Expected: HUD fixture failures (`clampPanelPosition missing` / similar).

- [ ] **Step 4: Implement helpers on `FieldToDoHudOverlay`**

Add near the top constants:

```lua
FieldToDoHudOverlay.DRAG_MOVE_THRESHOLD = 0.005
FieldToDoHudOverlay.PANEL_MARGIN = 0.01
```

Add:

```lua
function FieldToDoHudOverlay.clampPanelPosition(panelX, panelY, panelW, panelH, margin)
    margin = margin or FieldToDoHudOverlay.PANEL_MARGIN
    panelW = panelW or FieldToDoHudOverlay.PANEL_W
    panelH = panelH or 0.08
    local minX = margin
    local maxX = 1 - margin - panelW
    local minY = margin
    local maxY = 1 - margin - panelH
    if maxX < minX then
        panelX = minX
    else
        panelX = math.max(minX, math.min(maxX, panelX))
    end
    if maxY < minY then
        panelY = minY
    else
        panelY = math.max(minY, math.min(maxY, panelY))
    end
    return panelX, panelY
end

function FieldToDoHudOverlay.getHeaderRect(panelX, panelY, panelW, panelH, headerH)
    headerH = headerH or FieldToDoHudOverlay.HEADER_H
    return panelX, panelY + panelH - headerH, panelW, headerH
end

function FieldToDoHudOverlay.getRowRect(panelX, panelY, panelW, panelH, headerH, rowH, rowIndex)
    headerH = headerH or FieldToDoHudOverlay.HEADER_H
    rowH = rowH or FieldToDoHudOverlay.ROW_H
    rowIndex = math.floor(tonumber(rowIndex) or 0)
    local listTopY = panelY + panelH - headerH
    local rowY = listTopY - rowIndex * rowH
    return panelX, rowY, panelW, rowH
end

function FieldToDoHudOverlay.pointInRect(px, py, x, y, w, h)
    if px == nil or py == nil or x == nil or y == nil or w == nil or h == nil then
        return false
    end
    return px >= x and px <= x + w and py >= y and py <= y + h
end
```

- [ ] **Step 5: Run tests — expect PASS for new fixtures**

Run: `lua tests/run.lua`  
Expected: previous 41 + 5 HUD = **46 passed**, `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add scripts/FieldToDoHudOverlay.lua tests/hud_layout_fixtures.lua tests/run.lua
git commit -m "test(hud): add layout helpers for clamp and hit-test regions"
```

---

### Task 2: Client modSettings load/save for panel position

**Files:**
- Modify: `scripts/FieldToDoHudOverlay.lua`

**Interfaces:**
- Consumes: `clampPanelPosition`
- Produces:
  - `FieldToDoHudOverlay.getSettingsDirectory() -> string|nil`
  - `FieldToDoHudOverlay.getSettingsFilePath() -> string|nil`
  - `FieldToDoHudOverlay:loadPositionFromDisk()`
  - `FieldToDoHudOverlay:savePositionToDisk()`
  - Instance fields: `self.panelX`, `self.panelY`, `self.positionDirty`

- [ ] **Step 1: Add path helpers**

```lua
function FieldToDoHudOverlay.getSettingsDirectory()
    local base = nil
    if getUserProfileAppPath ~= nil then
        local ok, path = pcall(getUserProfileAppPath)
        if ok and path ~= nil and path ~= "" then
            base = path
        end
    end
    if base == nil then
        return nil
    end
    -- Normalize trailing slash
    if string.sub(base, -1) ~= "/" and string.sub(base, -1) ~= "\\" then
        base = base .. "/"
    end
    return base .. "modSettings/FS25_FieldToDoList"
end

function FieldToDoHudOverlay.getSettingsFilePath()
    local dir = FieldToDoHudOverlay.getSettingsDirectory()
    if dir == nil then
        return nil
    end
    return dir .. "/hud.xml"
end
```

- [ ] **Step 2: Load / save (pcall-guarded, no crash)**

Prefer simple file IO if `XMLFile` unavailable in headless; in-game use `XMLFile.load` / `XMLFile.create` when present:

```lua
function FieldToDoHudOverlay:loadPositionFromDisk()
    self.panelX = FieldToDoHudOverlay.PANEL_X
    self.panelY = FieldToDoHudOverlay.PANEL_Y
    local filePath = FieldToDoHudOverlay.getSettingsFilePath()
    if filePath == nil or fileExists == nil or not fileExists(filePath) then
        return
    end
    if XMLFile == nil or XMLFile.load == nil then
        return
    end
    local ok, xmlFile = pcall(XMLFile.load, "fieldToDoHudLoad", filePath)
    if not ok or xmlFile == nil then
        return
    end
    local x = xmlFile.getValue ~= nil and xmlFile:getValue("fieldToDoHud#panelX") or nil
    local y = xmlFile.getValue ~= nil and xmlFile:getValue("fieldToDoHud#panelY") or nil
    if xmlFile.delete ~= nil then
        xmlFile:delete()
    end
    x = tonumber(x)
    y = tonumber(y)
    if x ~= nil and y ~= nil then
        self.panelX, self.panelY = FieldToDoHudOverlay.clampPanelPosition(
            x, y, FieldToDoHudOverlay.PANEL_W, 0.08, FieldToDoHudOverlay.PANEL_MARGIN
        )
    end
end

function FieldToDoHudOverlay:savePositionToDisk()
    local dir = FieldToDoHudOverlay.getSettingsDirectory()
    local filePath = FieldToDoHudOverlay.getSettingsFilePath()
    if dir == nil or filePath == nil then
        return
    end
    if createFolder ~= nil then
        pcall(createFolder, dir)
    end
    if XMLFile == nil or XMLFile.create == nil then
        return
    end
    local ok, xmlFile = pcall(XMLFile.create, "fieldToDoHudSave", filePath, "fieldToDoHud")
    if not ok or xmlFile == nil then
        return
    end
    if xmlFile.setValue ~= nil then
        xmlFile:setValue("fieldToDoHud#panelX", self.panelX)
        xmlFile:setValue("fieldToDoHud#panelY", self.panelY)
    end
    if xmlFile.save ~= nil then
        xmlFile:save()
    end
    if xmlFile.delete ~= nil then
        xmlFile:delete()
    end
    self.positionDirty = false
end
```

- [ ] **Step 3: Initialize instance fields**

In `FieldToDoHudOverlay.new()`:

```lua
self.panelX = FieldToDoHudOverlay.PANEL_X
self.panelY = FieldToDoHudOverlay.PANEL_Y
self.positionDirty = false
self.dragActive = false
self.dragMoved = false
self.dragOffsetX = 0
self.dragOffsetY = 0
self.mouseDown = false
self.mouseDownOnHeader = false
self.mouseDownRowIndex = nil
self.mouseDownX = nil
self.mouseDownY = nil
self.lastPanelH = 0.08
```

In `initialize()` after `isInitialized = true`:

```lua
self:loadPositionFromDisk()
```

- [ ] **Step 4: Commit**

```bash
git add scripts/FieldToDoHudOverlay.lua
git commit -m "feat(hud): load and save client panel position in modSettings"
```

---

### Task 3: Draw with runtime position + `taskId` on rows

**Files:**
- Modify: `scripts/FieldToDoHudOverlay.lua`

**Interfaces:**
- Consumes: `self.panelX` / `self.panelY`, layout helpers
- Produces: `displayRows[].taskId`; `draw()` uses runtime position; stores `self.lastPanelH` for input

- [ ] **Step 1: Include `taskId` in `rebuildDisplayRows`**

```lua
self.displayRows[#self.displayRows + 1] = {
    taskId = task.id,
    text = FieldToDoHudOverlay.truncateText(
        FieldToDoHudOverlay.cleanTaskText(task.text),
        FieldToDoHudOverlay.MAX_TEXT_CHARS
    ),
    completed = false,
}
```

- [ ] **Step 2: Use `self.panelX` / `self.panelY` in `draw()`**

Replace:

```lua
local px = FieldToDoHudOverlay.PANEL_X
local py = FieldToDoHudOverlay.PANEL_Y
```

with:

```lua
local px = self.panelX or FieldToDoHudOverlay.PANEL_X
local py = self.panelY or FieldToDoHudOverlay.PANEL_Y
```

After `panelH` is known:

```lua
px, py = FieldToDoHudOverlay.clampPanelPosition(
    px, py, panelW, panelH, FieldToDoHudOverlay.PANEL_MARGIN
)
self.panelX = px
self.panelY = py
self.lastPanelH = panelH
```

(Keep draw visuals otherwise unchanged.)

- [ ] **Step 3: Run headless tests**

Run: `lua tests/run.lua`  
Expected: **46 passed**.

- [ ] **Step 4: Commit**

```bash
git add scripts/FieldToDoHudOverlay.lua
git commit -m "feat(hud): draw at saved position and attach taskId to rows"
```

---

### Task 4: Mouse update — drag header + click row to complete

**Files:**
- Modify: `scripts/FieldToDoHudOverlay.lua`
- Modify: `scripts/ToDoManager.lua` (mission update hook already draws HUD; append `update`)

**Interfaces:**
- Consumes: hit helpers, `toggleManualTask`, `canEditLocal`
- Produces: `FieldToDoHudOverlay:update(dt)`, `FieldToDoHudOverlay:isMouseCursorVisible()`, `FieldToDoHudOverlay:tryCompleteRow(rowIndex)`

- [ ] **Step 1: Cursor visibility helper**

```lua
function FieldToDoHudOverlay:isMouseCursorVisible()
    if g_inputBinding == nil then
        return false
    end
    local ib = g_inputBinding
    if ib.getShowMouseCursor ~= nil then
        local ok, shown = pcall(ib.getShowMouseCursor, ib)
        if ok then
            return shown == true
        end
    end
    if ib.showMouseCursor ~= nil then
        return ib.showMouseCursor == true
    end
    -- Fallback: if last mouse pos exists and HUD can draw, allow interaction
    -- (AutoDrive-style unlock usually sets showMouseCursor; without it, skip).
    return false
end
```

- [ ] **Step 2: Read mouse + LMB edge**

```lua
function FieldToDoHudOverlay:getMouseState()
    if g_inputBinding == nil then
        return nil
    end
    local x = g_inputBinding.mousePosXLast
    local y = g_inputBinding.mousePosYLast
    if x == nil or y == nil then
        return nil
    end
    local down = false
    if Input ~= nil and Input.MOUSE_BUTTON_LEFT ~= nil and Input.isMouseButtonPressed ~= nil then
        local ok, pressed = pcall(Input.isMouseButtonPressed, Input.MOUSE_BUTTON_LEFT)
        if ok then
            down = pressed == true
        end
    end
    return { x = x, y = y, down = down }
end
```

- [ ] **Step 3: Implement `update(dt)` state machine**

Logic (must match draw geometry):

1. If not `canDraw()` or not `isMouseCursorVisible()` → clear drag/mouseDown flags; return.
2. Read mouse state; if nil → return.
3. Compute `panelH = self.lastPanelH` or `calcPanelHeight(...)`.
4. On **LMB down edge** (`down` and not `self.mouseDown`):
   - If point in header → start potential drag (`mouseDownOnHeader=true`, store offset = mouse - panel origin).
   - Else find row index via `getRowRect` for `1..#displayRows`; store `mouseDownRowIndex`.
5. While `down` and `mouseDownOnHeader`:
   - If distance from down point > `DRAG_MOVE_THRESHOLD` → `dragActive=true`, `dragMoved=true`.
   - If `dragActive`: `panelX = mouse.x - dragOffsetX`, `panelY = mouse.y - dragOffsetY`, then clamp with current `panelH`; set `positionDirty=true`.
6. On **LMB up edge**:
   - If `dragMoved` → `savePositionToDisk()`.
   - Else if `mouseDownRowIndex ~= nil` and not `dragMoved` → `tryCompleteRow(mouseDownRowIndex)`.
   - Clear drag/mouseDown flags.

- [ ] **Step 4: `tryCompleteRow`**

```lua
function FieldToDoHudOverlay:tryCompleteRow(rowIndex)
    local row = self.displayRows[rowIndex]
    if row == nil or row.taskId == nil then
        return
    end
    if FieldToDoPermissions == nil or not FieldToDoPermissions.canEditLocal() then
        if FieldToDoLog ~= nil then
            FieldToDoLog.info(FieldToDoL10n.getText(
                "ftdl_edit_denied",
                "No permission to change to-dos"
            ))
        end
        return
    end
    if g_currentMission == nil or g_currentMission.fieldToDoList == nil then
        return
    end
    g_currentMission.fieldToDoList:toggleManualTask(row.taskId)
end
```

Note: ESC Done uses **toggle**. Spec says “mark done”; open rows only are listed, so toggle == complete. Keep toggle for consistency with ESC.

- [ ] **Step 5: Hook update from mission**

In `scripts/ToDoManager.lua` where `FieldToDoHudOverlay.instance:draw()` is appended to `FSBaseMission.draw`, also ensure update is called. Prefer calling from existing `todoManager:update(dt)`:

Near end of `ToDoManager:update(dt)` (or mission update wrapper):

```lua
if FieldToDoHudOverlay ~= nil and FieldToDoHudOverlay.instance ~= nil then
    FieldToDoHudOverlay.instance:update(dt)
end
```

- [ ] **Step 6: Run headless tests**

Run: `lua tests/run.lua`  
Expected: **46 passed**.

- [ ] **Step 7: Commit**

```bash
git add scripts/FieldToDoHudOverlay.lua scripts/ToDoManager.lua
git commit -m "feat(hud): drag title bar and click rows to complete tasks"
```

---

### Task 5: CHANGELOG + spec status

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/specs/2026-09-12-hud-drag-complete-design.md`

- [ ] **Step 1: CHANGELOG under `[0.1.0.9]`**

### Added

- **Draggable To-Do HUD:** with mouse cursor visible, drag the green title bar; position saved client-side under `modSettings/FS25_FieldToDoList/hud.xml`.
- **HUD click-to-complete:** left-click an open row to mark it done (edit permission + existing sync path).

### Known limitations (optional one-liner)

- HUD drag/click needs unlocked mouse cursor; gamepad look mode unchanged.

- [ ] **Step 2: Spec status**

Set: `**Status:** implemented` and link this plan path.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md docs/superpowers/specs/2026-09-12-hud-drag-complete-design.md
git commit -m "docs: note HUD drag and click-to-complete in 0.1.0.9 changelog"
```

- [ ] **Step 4: In-game smoke (manual)**

1. Build/install mod; **full FS25 restart**.
2. Toggle HUD (LCtrl+F5); unlock mouse; drag title → move panel; restart mission → position restored.
3. Click a row with edit rights → task completes / leaves HUD list.
4. Worker without edit → denied, no complete.
5. Confirm SP still hides MP grant UI (regression from prior commit).

---

## Spec coverage (self-review)

| Spec item | Task |
|-----------|------|
| Header-only drag, mouse cursor visible | Task 4 |
| Clamp on-screen | Task 1 + 3/4 |
| Client modSettings persist | Task 2 |
| Default PANEL_X/Y | Task 2 |
| Row LMB complete + edit gate | Task 4 |
| `taskId` on rows | Task 3 |
| No visibility persist / no resize / no MP position sync | Constraints + Tasks 2–4 |
| Drag vs click threshold | Task 1 constant + Task 4 |
| Success criteria / risks | Task 5 manual smoke |

No placeholders remaining. Signatures consistent: `clampPanelPosition`, `getHeaderRect`, `getRowRect`, `pointInRect`, `loadPositionFromDisk`, `savePositionToDisk`, `update`, `tryCompleteRow`.
