# Multiplayer live sync + farm edit permissions

**Date:** 2026-09-10  
**Status:** implemented (0.1.0.8)  
**Mod:** FS25_FieldToDoList  
**Builds on:** farm-scoped tasks (`farmId`, save merge) from 0.1.0.7; ships with vanilla green UI in the same release

## Goal

Same-farm players see To-Dos / settings / Planfrucht **live** while online. Mutations are **server-authoritative**. Edit access is gated by **farm manager** plus a **mod setting**; a custom Vanilla farm-UI permission is **out of scope** for this iteration.

## Decisions (locked)

| Topic | Choice |
|--------|--------|
| Sync model | Server authority + mutation events (approach A) |
| Setting default | `workersMayEditTodos = true` (current SP/MP behavior) |
| When setting off | Only farm managers may edit |
| Who may change the setting | Farm managers only |
| Auto-complete (field state) | All same-farm members |
| Manual Done button | Requires edit permission |
| Scope when edit denied | To-Dos + Planfrucht + work-order / mulch / organic settings |
| Always allowed | View lists/HUD, field overview, visit field, auto-complete |

## Architecture

```
UI / HUD / auto-complete
        │
        ▼
 FieldToDoSync.request*(…)     ← permission hint client-side (disable UI)
        │
        ▼
 Request*Event ──► Server
                     │  canEdit / canAutoComplete
                     ▼
              ToDoManager apply + save
                     │
                     ▼
 Apply*Event / StateEvent ──► same-farm clients
                     │
                     ▼
              local state + refresh ESC/HUD
```

- **Singleplayer:** same path; local process is server — no special-case write APIs.
- **Dedicated:** server holds state; clients never write sidecar alone for farm data.
- **Persistence:** keep `fieldToDoList.xml`; server saves after successful mutations (existing debounce OK).

## Components

### `FieldToDoPermissions` (new, small)

- `isLocalFarmManager()` via `g_farmManager` + `farm:isUserFarmManager(userId)` (pcall-safe).
- `workersMayEditTodos` read from settings.
- `canEditFarmTodos()` — same farm and (`workersMayEditTodos` or manager).
- `canChangeWorkersEditSetting()` — manager only.
- `canAutoCompleteFarmTodos()` — same farm (always true for members).
- Stable API so a later Vanilla `Farm.PERMISSION` can plug in without rewriting callers.

### `FieldAdvisorSettings` (extend)

- Persist `workersMayEditTodos` (bool, default `true`) in sidecar with other settings.
- Sync changes through the same request/apply path as other settings.

### `FieldToDoSync` + Events (new)

Thin layer; no business rules beyond routing and broadcast targeting.

**Client → Server (requests):**

- Task: add manual, add from field action, edit text, delete, move, manual complete/uncomplete
- Auto-complete: mark task completed (trackable field detection)
- Settings: work-order preset, organic multi-pass, mulching, `workersMayEditTodos`
- Planfrucht: set / clear planned sow fruit for field

**Server → Clients (apply / state):**

- Delta apply for single task / setting / planned crop
- Full farm state snapshot on join and `PLAYER_FARM_CHANGED` (or equivalent)

Broadcast only to connections whose player is on the **same `farmId`** as the mutated data (or include `farmId` and let clients ignore foreign farms).

**IDs:** server assigns `task.id` / `nextTaskId` so clients do not mint conflicting IDs. Client may send a temporary client hint; server reply carries canonical id.

### `ToDoManager` (adapt)

- Split **apply** (mutate in-memory + schedule save) from **request** (network).
- Public UI entry points call sync requests when MP/sync active; apply functions remain the single mutation core.
- Keep farm filter (`taskBelongsToLocalFarm`) for display.
- `syncForeignFarmTasksFromDisk` remains for multi-farm save coexistence; live sync does not replace that for offline farms.

### GUI

- ESC toggle: Edit alle / nur Manager (l10n DE+EN).
- Manager-only clickable; non-managers see current mode disabled/grey.
- When `canEditFarmTodos` is false: disable Add/Edit/Delete/↑↓, Adopt, Planfrucht, work-order, mulch, organic, **manual Done**.
- Leave Visit + list browsing enabled.
- On denied server response: short user-visible message (existing feedback pattern / log), no throw.

### HUD

- Display only (unchanged). Refresh when apply/state events arrive.

## Data flow notes

1. Auto-complete loop still runs on each client (field probes local). When a trackable task should complete, client sends **AutoComplete request**; server validates farm membership + task exists/open + trackable policy, then broadcasts complete. No edit permission required.
2. Manual Done uses **Complete request** gated by `canEditFarmTodos`.
3. Join: client requests or server pushes **State** for local farm after mission start / farm switch.

## Error handling

- Missing farm / not on farm → ignore or deny quietly.
- Permission denied → deny event or bool; UI message.
- Unknown task id on server → deny; client may request full state.
- Stream/version: keep payloads simple (primitives + short strings); bump an internal sync schema byte if format changes later.

## Out of scope (this iteration)

- Custom permission row in Vanilla farm rights UI
- Cross-farm task visibility
- Conflict UI / operational transform
- Syncing owned-field scan cache / advisor probe results (local per client is fine)
- Dedicated admin tools beyond farm manager check

## Testing / verification

- SP: create/edit/complete as today with default setting on.
- SP: toggle setting off — still works for local player (manager).
- MP two clients same farm: A adds task → B HUD/ESC updates without save/reload.
- MP setting off: worker cannot add/edit/manual-done/settings/plan; can auto-complete and visit; manager can edit and toggle setting.
- MP different farms: no cross-leak of tasks.
- Save/load still restores tasks + `workersMayEditTodos`.

## Success criteria

- No last-write-wins races for concurrent same-farm edits while both online.
- Permissions match the locked decision table.
- `canEditFarmTodos` remains the single gate for future Vanilla permission work.
