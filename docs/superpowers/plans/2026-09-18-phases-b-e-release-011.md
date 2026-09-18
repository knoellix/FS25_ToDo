# Phases B–E + 0.1.0.11 Implementation Plan

> **For agentic workers:** Execute sequentially. Prefer implementing in this order without pausing for human between phases. Do **not** `git push` or tag unless the user asks after local smoke.

**Goal:** Finish dedicated MP usability (sync visibility + adopt, ownership diagnostics, vanilla farm permission) and ship as **0.1.0.11**.

**Spec:** `docs/superpowers/specs/2026-09-18-dedicated-mp-farm-permission-design.md` Phases B–E  
**Already done:** Phase A (grass reentrancy) on `main`.

## Global Constraints

- No `goto`. No push/tag in this plan.
- Version bump to **0.1.0.11** only at the end (Task Release).
- Logging: `FieldToDoLog` / `Logging`, not `print()`.
- Server = mutations + save; Client = field scan.
- Farm permission: managers always edit; workers default **on**; ESC grant UI removed.
- Maintainer fish: single `-m` commits OK.

## File map

| Area | Files |
|------|--------|
| B Sync debug | `scripts/FieldToDoSync.lua`, `scripts/FieldDebugDump.lua`, `scripts/FieldDebugConsole.lua`, `gui/FieldToDoMenuFrame.lua` |
| C Adopt feedback | same + deny InfoDialog |
| D Owned diagnose | `scripts/FieldScanner.lua` (farmId resolve), `FieldDebugDump` `ftdlOwned` |
| E Farm.PERMISSION | `scripts/FieldToDoPermissions.lua` (new register + canEdit), `gui/FieldToDoMenuFrame.lua` hide grants, `translations/*.xml`, retire grant ops usage |
| Release | `modDesc.xml`, `CHANGELOG.md`, `README.md`, `README.de.md` |

---

### Task B: Sync debug + visible deny

1. On `FieldToDoSync`: track `lastRequest`, `lastDeny`, `lastNotify` (op, reason, farmId, time via `g_time` or `getTime()`).
2. In `request` / `handleRequest` / `sendDeny` / `applyNotify`: update those fields; log deny with reason.
3. `notifyEditDenied`: show `InfoDialog.show(message)` (not log-only).
4. On DENY notify: InfoDialog with reason when possible.
5. Console: `ftdlSync` dumps sync/farm/edit/last* to log; `ftdlOwned` dumps farmId + owned candidate ids; extend `ftdlHelp`.
6. Commit: `feat(debug): ftdlSync/ftdlOwned and visible edit deny`

### Task C: Adopt / field-todo reliability

1. Ensure successful ADD_FIELD notify refreshes ESC list (call existing refresh hooks).
2. If `canEditLocal` false blocks UI but manager should edit: fix `getLocalFarmId` / membership for dedicated client.
3. When `FieldToDoSync.request` used for adopt: if client-side validation fails, InfoDialog; never silent.
4. Commit: `fix(mp): surface adopt/deny and refresh after ADD_FIELD`

### Task D: Ownership farmId

1. Harden `FieldScanner:getPlayerFarmId()` — try `mission:getFarmId()`, `g_localPlayer.farmId`, `player.farmId`, farmManager by userId.
2. `ftdlOwned` lists engine fields owned vs skipped (reason) for first N.
3. Commit: `fix(scan): harden MP farmId for owned-field candidates`

### Task E: Vanilla Farm.PERMISSION

1. Register `ftdlEditTodos` into `Farm.PERMISSION` + `Farm.PERMISSIONS` + `DEFAULT_PERMISSIONS` (default true) via pcall-safe init at load.
2. Add DE/EN l10n for permission label (key matching how farm UI resolves — try `ui_ftdlEditTodos` / `farm_permission_ftdlEditTodos` / register i18n text).
3. `getTodoEditAllowed` / `canEditFarmTodos`: after manager check, if `farm.getUserPermission` / `hasUserPermission` works for `ftdlEditTodos`, use it; else fall back to existing defaultAllow map (compat).
4. Hide ESC grant list + Alle Worker entirely (`shouldShowWorkersEditUi` → false always, or remove wiring).
5. Keep opcodes 15/16 no-op or unused (no UI); do not require uniqueUserId grants.
6. Commit: `feat(mp): farm permission ftdlEditTodos in Hofverwaltung`

### Task Release: 0.1.0.11

1. Bump `modDesc.xml` version + description lines.
2. Move Unreleased + new bullets into `## [0.1.0.11]`.
3. README / README.de version lines.
4. Spec status Phases B–E implemented (code); in-game verify pending.
5. Commit: `release: FS25_FieldToDoList 0.1.0.11`
6. Run `lua tests/run.lua` — all pass.
7. **Do not push/tag** — user local smoke first.
