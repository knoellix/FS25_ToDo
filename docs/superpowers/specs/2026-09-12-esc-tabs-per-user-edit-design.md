# ESC tab scroll + per-user To-Do edit permissions

**Date:** 2026-09-12  
**Status:** implemented (0.1.0.9) — plan at `docs/superpowers/plans/2026-09-12-esc-tabs-per-user-edit.md`  
**Mod:** FS25_FieldToDoList  
**Builds on:** MP live sync + farm edit gate (`docs/superpowers/specs/2026-09-10-mp-live-sync-design.md`)  
**Implementation order:** **B first**, then **C**. Permissions gate audit after C (separate pass).

## Goal

1. **B — ESC left tab strip:** With many mods, the vanilla paging tab list becomes scrollable but feels unreliable. Improve scroll / visibility **without** replacing the vanilla ESC shell.
2. **C — Per-user edit:** Farm managers grant/revoke To-Do edit per **online same-farm** member on our ESC page (vanilla farm-rights UI stays out of scope). Offline players are not listed; rights changes while offline are not offered (same idea as vanilla: you need to be present).

## Decisions (locked)

| Topic | Choice |
|--------|--------|
| ESC shell | Keep vanilla InGameMenu / tab strip; do **not** suppress or rebuild full ESC |
| Tab work (B) | Soften vanilla scroll UX: ensure our tab visible; mouse wheel when over strip; leave other mods’ tabs alone |
| Permission UI (C) | On **our** Field To-Do ESC page only |
| Who appears in C list | Same farm **and** online only |
| Offline | Not shown; no offline grant/revoke UI |
| Farm managers | Always may edit; row locked or no deny toggle |
| New / no stored entry | Default **edit allowed** (`true`), matching prior `workersMayEditTodos` default |
| Farm-wide control | Replace ambiguous “Edit: alle / Manager” with **“Alle Worker an/aus”** that sets all **visible** non-manager rows |
| Persistence key | `uniqueUserId` (survives reconnect); farm-scoped map |
| Sync | Server-authoritative (extend existing FieldToDoSync / state) |
| Vanilla farm permissions UI | Out of scope (no inject into Hofverwaltung) |
| Auto-complete | Unchanged: all same-farm members |
| Manual Done / Planfrucht / settings / task CRUD | Require per-user edit (managers always) |
| Always allowed without edit | View lists/HUD, field overview, visit field, auto-complete |

## Phase B — Tab strip

### In scope

- On ESC open and when focusing our page: scroll/paging so our tab is **in view** if the list API allows (`scrollTo`, selected index, or equivalent on `pagingTabList` / parent).
- Optional: mouse-wheel handler when cursor is over the tab strip element (pcall-guarded; no-op if API missing).
- Keep current safe placement after Map (no unsafe array mutation of tab GUI objects).

### Out of scope

- Custom full ESC menu / hiding vanilla tabs.
- Guaranteeing perfect scroll on every third-party menu mod conflict.
- Changing tab **order** beyond existing after-Map rule.

### Success criteria

- With a long mod tab list, opening ESC and selecting Field To-Do reliably shows our tab icon/label without hunting off-screen.
- Wheel/buttons do not crash; failures log once at most.

### Fallback

If Giants exposes no usable scroll API: implement only “select our page / ensure registered”; document limitation in CHANGELOG known limitations.

## Phase C — Per-user edit

### Data model

```text
FieldAdvisorSettings / sidecar (farm-scoped):
  todoEditByUniqueUserId = { [uniqueUserId] = bool }
  # missing key ⇒ true (default allow)
```

- Farm id remains the task/settings farm scope; map is per farm in save/sync state.
- `workersMayEditTodos` farm-wide bool is **retired as the sole gate**; migrate: if old save has `workersMayEditTodos == false`, treat as “default deny” for missing keys until manager sets individuals or uses Alle an/aus. Prefer explicit migration note in plan:
  - **Migration:** `workersMayEditTodos == false` → default for missing unique ids = `false`; `true`/absent → default `true`. Keep reading old attribute for one release.

### Permission check (server + UI hint)

```text
canEditFarmTodos(farmId, userId):
  same farm + online membership checks (existing / fixed MP membership)
  if isFarmManager → true
  else → todoEditByUniqueUserId[uniqueUserId] if set, else migrated default
```

- Resolve `uniqueUserId` via `userManager` on server; never trust client-supplied unique id for auth.

### UI (our ESC page)

- Section visible only to farm managers (workers do not see toggles).
- List rows: nickname + toggle “To-Dos bearbeiten”.
- Source: active users on local farm (`getActiveUsers` / equivalent), exclude spectators / other farms.
- Button **Alle Worker an/aus**: sets all listed non-managers to the same bool; sync one op or batched notifies.
- After state sync / player join-leave / farm change: refresh list.

### Sync ops (sketch)

- Extend state payload with `todoEditByUniqueUserId` (or compact list of pairs).
- New op e.g. `SET_USER_TODO_EDIT` `{ uniqueUserId, enabled }` — manager-only.
- New op e.g. `SET_ALL_WORKERS_TODO_EDIT` `{ enabled }` — manager-only; applies to currently known farm members or only online (locked: **only online listed members** at click time; offline keep previous stored values).

### Success criteria

- Manager sees only online same-farm players; can toggle each; Alle an/aus works.
- Worker without grant: UI disabled + server deny (with reason in log).
- Reconnect keeps grant via uniqueUserId.
- SP: single local user behaves as manager / unrestricted as today.

## Non-goals

- Patching vanilla MultiplayerUsersFrame / Farm.PERMISSION list.
- Per-user rights for auto-complete.
- Dedicated “offline permission editor”.

## Implementation sequence

1. Ship/fix MP membership deny fix already in tree (userId / same-farm) if not released yet.
2. **Phase B** tab visibility/scroll.
3. **Phase C** data + sync + UI; migrate `workersMayEditTodos`.
4. Permissions **audit** pass (separate): gates, deny reasons, UI vs server parity.

## Open points (none blocking)

- Exact Giants API names for tab scroll — discover at implement time with pcall probes.
- Compact binary encoding for uniqueUserId strings in events — follow existing `FieldToDoSync.writeString`.

## References

- `scripts/InGameMenuIntegration.lua` — tab placement after Map  
- `scripts/FieldToDoPermissions.lua` / `FieldToDoSync.lua` — edit gate + sync  
- Prior design: `2026-09-10-mp-live-sync-design.md`
