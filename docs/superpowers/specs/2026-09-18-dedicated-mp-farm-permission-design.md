# Dedicated MP reliability + vanilla farm To-Do permission

**Date:** 2026-09-18  
**Status:** Phases A–E done; smoke-tested on dedicated MP (0.1.0.11)  
**Mod:** FS25_FieldToDoList  
**Builds on:** MP live sync (`2026-09-10-mp-live-sync-design.md`), per-user ESC grants (`2026-09-12-esc-tabs-per-user-edit-design.md`)  
**Evidence:** Client `log.txt` — overview scan `3 field(s)`; repeated `FieldAdvisor.lua` **stack overflow** on field **17** (grass). Server log silent for overview (expected: scan is client-local).

## Goal

1. Make dedicated MP usable: field overview + adopt / field-todo mutations work reliably.
2. Move To-Do **edit** rights into the **vanilla farm permission list** (on/off checkbox), managers always edit.
3. Remove ESC-only grant UI („Alle Worker“, per-user rows).
4. Add sync/ownership debug commands so Client↔Server failures are diagnosable from `log.txt`.

## Locked decisions

| Topic | Choice |
|--------|--------|
| World read (crop/grass/suggestions/overview) | **Client-local** (`FieldState`, density). Not synced. Dedicated does not run overview scan. |
| Mutations (tasks, Planfrucht, settings, complete) | **Server-authoritative** via `FieldToDoSync` + sidecar save on server only |
| Edit UI location | **Vanilla Hofverwaltung permission list only** (same an/aus list as other mods) |
| ESC grant UI | **Remove** (no per-user list, no „Alle Worker“) |
| Managers | **Always** may edit To-Dos / Planfrucht / settings CRUD |
| Workers | Edit only if farm permission checkbox **on** |
| Default for new workers | **On** (match current `defaultAllow` / prior worker-edit default) |
| Auto-complete | Unchanged: all same-farm members (no edit permission required) |
| Always allowed without edit | View lists/HUD, field overview, visit field, auto-complete |
| Custom Farm.PERMISSION | Register one permission (working name: `FTDL_EDIT_TODOS` / l10n „Feld-To-Dos bearbeiten“) |
| Old `todoEditByFarmId` / opcodes 15–16 | **Retire** after permission path ships (migrate: if old defaultDeny, permission off is manager’s job; no need to copy uniqueUserId map into Farm.PERMISSION) |
| Implementation order | **A → B → C → D → E** below (do not start E before A–C) |

## Architecture (unchanged split)

```
Client: FieldScanner / FieldAdvisor (overview, grass, suggestions)
        │
        │  request (ADD_FIELD, SET_PLANNED_CROP, …)
        ▼
Server: FieldToDoSync → canExecuteOp (farm + manager|permission) → apply + save sidecar
        │
        ▼
        notify / state → same-farm clients
```

**Do not** move field classification to the dedicated server (null render / weak FieldState). Pattern for other features: **read world on client, mutate on server**.

## Phase A — Grass stack overflow (field 17)

**Problem:** Overview scan errors with `stack overflow` at `FieldAdvisor.getGroundTypeName` / `resolveGroundTypeName` for grass field 17 → empty/broken suggestions → adopt feels dead.

**Status:** implemented (code); smoke-tested

**In scope**

- Find and break the recursion (likely `FieldState:getGroundType` / `FieldGroundType` enumeration / groundType metamethod interaction on map/MP).
- Guard: depth/seen flag or never call back into `getGroundTypeName` from ground-type resolution.
- Regression: grass meadow still classifies (mow / post-mow chain) in SP and MP client.

**Out of scope:** Rewriting all grass logistics.

**Done when:** Opening ESC on dedicated MP logs no stack overflow for field 17; grass row shows sensible crop/suggestion or explicit „Alles ok“, not scan error.

## Phase B — Sync visibility + “nothing happens”

**Status:** implemented (code); smoke-tested

**Problem:** Adopt / field-todo request path returns immediately (`errorKey == nil` after `FieldToDoSync.request`); deny/success often invisible → user sees no change.

**In scope**

- Console/debug commands (F9 / `addConsoleCommand`), log to `[FS25_FieldToDoList]`:
  - `ftdlSync` — schema version, isServer/isClient/dedicated flags, local `farmId`, manager?, edit allowed?, last request op/reason/time, last deny reason, last successful notify op.
  - `ftdlOwned` — owned candidate count + field ids (engine + pseudo), farmId used for ownership, scan progress.
  - Extend `ftdlHelp` accordingly.
- On DENY: always user-visible feedback (InfoDialog or existing notify) with **reason** string when menu open; always log reason.
- On successful ADD_FIELD notify: ensure ESC list refresh (existing path); if refresh race, fix once.
- Optional: short toast/log on client when request is **sent** (debug-level or one-line info) during diagnosis builds — prefer keep production quiet except deny + `ftdlSync`.

**Out of scope:** Redesigning sync protocol schema unless deny/fix proves schema mismatch.

**Done when:** Failed adopt shows reason; successful adopt shows task (or clear deny); `ftdlSync` explains last attempt without reading source.

## Phase C — Fix adopt / field-todo on dedicated

**Status:** implemented (code); smoke-tested

**Problem:** Mutations appear to do nothing (user: adopt + field todo; free-text manual not tested yet).

**In scope**

- Using Phase B traces: fix root cause(s) — typical candidates: `no_farm`, `canEditLocal` false vs server allow, notify farmId mismatch, apply_failed, silent client early-return.
- Verify: adopt suggestion, custom field task, Planfrucht, manual free-text to-do on dedicated with manager account.
- Keep server authority; no client-only task minting.

**Done when:** Manager on dedicated can adopt + create field todo + free-text todo; worker with permission on can; worker with permission off gets visible deny.

## Phase D — Missing owned fields (−2)

**Status:** implemented (diagnostics via ftdlOwned + farmId harden); smoke-tested

**Problem:** User expects **~5** owned fields; scan reports **3** (17 grass, ~104 farmyard, windrad/production). Two missing.

**In scope**

- Use `ftdlOwned` / existing `ftdlFarmlands` to see whether missing plots are: wrong `farmId`, farmland without `field`, center not field ground, farmyard skip, or ownership API miss on MP client.
- Fix ownership/candidate collection if bug; if plots are non-field (building-only), document as expected exclusion.

**Out of scope:** Listing foreign-farm fields; scanning entire map.

**Done when:** Either 5 candidates appear, or documented reason why the two are excluded (with farmland ids).

## Phase E — Vanilla farm permission

**Status:** implemented (code); Hofverwaltung checkbox depends on Farm.PERMISSION APIs; smoke-tested

**Problem:** ESC grant UI is wrong place; user wants checkbox in vanilla farm rights list.

**In scope**

- Register custom farm permission with Giants farm permission APIs (research at implement time: `Farm.PERMISSION` / `PermissionManager` / FS25 farm frame registration — pcall-safe).
- Wire `FieldToDoPermissions.canEditFarmTodos` / `canEditLocal`:
  - same farm
  - **or** farm manager → allow
  - **else** read custom permission for that user (default **true** when unset)
- Remove ESC UI: per-user grant list, „Alle Worker an/aus“, related l10n strings from that section.
- Stop writing/using `farmTodoEdit` / opcodes `SET_USER_TODO_EDIT` / `SET_ALL_WORKERS_TODO_EDIT` for new grants (remove or no-op after migration).
- Persistence: rely on vanilla farm user permission savegame (no parallel uniqueUserId map for edit).
- Sync: edit checks server-side against farm permission; no need to stream grant maps if vanilla already syncs farm permissions (verify; if not, keep a thin notify only if required).

**Out of scope:** Custom permission UI chrome; admin-only server tools; changing vanilla permissions unrelated to this mod.

**Done when:** Checkbox appears in Hofverwaltung next to other rights; ESC has no grant toggles; manager always edits; worker toggle controls edit; survives reconnect/save.

## Debug / docs

- Client log paths remain as in README (`log.txt` under FS25 user folder).
- Dedicated server log will still rarely show overview errors; sync denies should appear on **both** when Phase B logging is on.
- Update project memory after E: edit gate = Farm.PERMISSION; ESC grants retired.

## Non-goals

- Server-side FieldAdvisor overview for all clients.
- Syncing probe caches between clients.
- Replacing vanilla farm menu shell.

## Test plan (manual, dedicated)

1. Join as manager; ESC overview: no stack overflow on grass; grass row usable.
2. `ftdlOwned` / `ftdlFarmlands`: account for expected fields.
3. Adopt suggestion → task appears for farm mates.
4. Field todo + free-text manual todo → persist after leave/rejoin.
5. Worker with permission off: deny visible; on: edit works.
6. Hofverwaltung: only vanilla checkbox for FTDL edit; ESC has no grant section.

## Implementation plans

Separate plan files per phase (or one phased plan with A–E checkpoints). **Start with Phase A only** unless user asks otherwise.
