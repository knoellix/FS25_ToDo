# HUD: drag position + click-to-complete

**Date:** 2026-09-12  
**Status:** implemented  
**Plan:** [2026-09-12-hud-drag-complete.md](../plans/2026-09-12-hud-drag-complete.md)  
**Mod:** FS25_FieldToDoList  
**Builds on:** In-world HUD (`FieldToDoHudOverlay` / `FieldToDoHudInput`), MP sync + edit gate  

## Goal

1. **Drag:** With the mouse cursor visible in the 3D view (same mode used for AutoDrive overlays), the player can drag the To-Do HUD by its **title bar** and park it anywhere on screen.
2. **Persist:** The position is stored **client-side per user profile** and restored until the player moves it again.
3. **Complete:** Left-click on a task **row** marks that open task done (same path as ESC “Erledigt”), respecting edit permission.

## Decisions (locked)

| Topic | Choice |
|--------|--------|
| Approach | Extend `FieldToDoHudOverlay` (screen overlays + hit-test); no GuiElement panel |
| Drag grip | **Title / header only** |
| Mouse mode | Only when cursor is available for UI (mouse unlocked in 3D); no LAlt-drag while looking |
| Click complete | **LMB on row** → mark completed |
| Undo from HUD | Out of scope (no right-click reopen) |
| Resize | Out of scope |
| Position sync | **Not** synced over MP; each client keeps its own layout |
| Storage | Mod settings under user profile (not savegame sidecar) |
| Default position | Current constants (`PANEL_X` / `PANEL_Y` top-right) if no file / invalid |
| Permissions | Complete requires `FieldToDoPermissions.canEditLocal()`; deny → same UX as ESC (`notifyEditDenied` / log), no silent success |
| Drag vs click | Small movement while LMB held on header = drag; pure click (no meaningful move) on a **row** = complete |
| Visibility toggle | Unchanged (LCtrl+F5); do **not** persist visible on/off in this change |

## Behavior

### Draw / layout

- Keep normalized screen coords (0–1), existing sizes (`PANEL_W`, row/header heights, colors).
- Runtime `panelX` / `panelY` replace fixed constants for drawing.
- After each drag release, clamp so the full panel (current height for shown rows) stays on-screen with a small margin.

### Input (only when HUD `canDraw()`)

- Poll mouse position from `g_inputBinding` (same pattern as ESC tab wheel).
- **Header hit + LMB down:** start drag; track offset from panel origin.
- **While dragging:** update `panelX` / `panelY` with cursor; do not complete tasks.
- **LMB up after drag:** persist position (debounced optional; at least on release).
- **LMB up on a row without drag:** resolve row → `taskId` → complete via existing manager/sync path (`toggle` / `TOGGLE_DONE` equivalent used by ESC Done).
- Ignore input when `g_gui:getIsGuiVisible()`, dedicated (no local player), or HUD hidden.

### Display rows

- `rebuildDisplayRows` must include `taskId` (and keep truncated display text).
- Still only open tasks, max 5 (unchanged).

### Persistence file

Suggested path (resolve via Giants profile / modSettings helpers already used in ecosystem, pcall-guarded):

```text
<userProfile>/modSettings/FS25_FieldToDoList/hud.xml
```

Minimal schema:

```xml
<fieldToDoHud panelX="0.827" panelY="0.72"/>
```

- Load on HUD `initialize` / mission start.
- Save on drag end (and optionally once when leaving mission if dirty).
- Corrupt / missing → defaults; never crash mission load.

## Out of scope

- Changing HUD size, fonts, or max entry count.
- Persisting HUD visible state.
- Completing tasks without edit grant (server still denies).
- Clicking empty-state text.
- Touch / gamepad pointer drag (mouse cursor path only; gamepad may keep toggle only).

## Success criteria

- With mouse unlocked and HUD on: title drag moves the panel; after reload/rejoin on same profile, position matches last place.
- LMB on an open row completes that task for the local farm when the player may edit; otherwise denied like ESC.
- Header drag does not accidentally complete a task.
- No MP traffic for position; no savegame wipe of other farms.

## Risks / notes

- Mouse APIs differ slightly by input context (on foot / vehicle); guard with pcall and no-op if pos unavailable.
- Hit-test Y must match draw order (header at top of panel, rows below).
- AutoDrive coexistence: only compete for clicks when cursor is over **our** panel bounds.
