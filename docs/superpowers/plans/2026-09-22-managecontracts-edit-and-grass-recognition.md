# manageContracts edit + grass recognition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MP To-Do edit = vanilla `manageContracts` only (SP always); remove ESC/custom grant paths; harden grass recognition so cut vs standing and Gras vs Luzerne stay logical for all mowables — without redesigning logistics auto-complete.

**Architecture:** Rewrite `FieldToDoPermissions.canEditFarmTodos` to membership + (SP allow | MP `manageContracts`). Strip grant UI/ops/state fields (schema bump v4→v5). Separately fix `getDefaultGrassFruitTypeIndex` to prefer true generic GRASS and close meadow-phase paths that trust specific-fruit `harvestReady` on cut stands.

**Tech Stack:** FS25 Lua 5.1, existing `tests/run.lua` fixtures, sidecar XML, `FieldToDoSync` binary state.

**Spec:** `docs/superpowers/specs/2026-09-22-managecontracts-edit-and-mowables-design.md`

## Global Constraints

- No `goto` / labels (Lua 5.1).
- Keep `modDesc.xml` version unchanged unless user asks for a release bump.
- Auto-complete membership and grass logistics auto flags: **do not churn** (swath/collect already manual; `grass_mow` ≥98%; press/bale-collect as shipped).
- Sync schema bump required when grant payload is removed from `writeState`/`readState`.
- Maintainer fish shell: fish-safe commit messages.

## File map

| File | Responsibility |
|------|----------------|
| `scripts/FieldToDoPermissions.lua` | New edit gate; `isMultiplayerSession` helper; `manageContracts` read; drop custom register from gate |
| `scripts/FieldToDoSync.lua` | Schema v5; drop grant stream fields; deny/remove grant ops; drop re-register on mission start |
| `scripts/ToDoManager.lua` | Stop using/writing `todoEditByFarmId` for gate (retire apply/save of grants) |
| `scripts/FieldAdvisorSettings.lua` | Stop using todo-edit settings for gate (retire getters used only by grants) |
| `gui/FieldToDoMenuFrame.lua` + `.xml` | Hide/remove ESC grant UI |
| `translations/translation_{de,en}.xml` | Drop grant + `ftdlEditTodos` strings; keep `ftdl_edit_denied` |
| `scripts/FieldAdvisor.lua` | Generic grass index; meadow phase / recognition fixes |
| `scripts/FieldTaskCompletion.lua` | Cut-ratio / nil fallback use same generic index (only if needed) |
| `tests/permissions_fixtures.lua` + `tests/run.lua` | New permission + grass recognition fixtures |
| `docs/DECISIONS.md`, `docs/REGRESSION.md`, `.cursor/rules/fs25-project-memory.mdc`, `CHANGELOG.md` | Document decisions |

---

### Task 1: Permission fixtures — manageContracts gate

**Files:**
- Modify: `tests/permissions_fixtures.lua`
- Modify: `tests/run.lua` (permission loop)

- [ ] **Step 1: Rewrite fixtures** for:
  - SP (not MP) + member → edit true
  - MP + `manageContracts` true → edit true
  - MP + `manageContracts` false → edit false
  - MP + other farm → edit false
  - MP + manageContracts false + auto-complete → still true (membership)
  - Remove fixtures that assume `defaultAllow` / per-user grants / manager-always-edit without contracts

- [ ] **Step 2: Extend test harness** so `_testOverride` (or a small farm stub) can inject `manageContracts` and `isMultiplayer` for `canEditFarmTodos`.

- [ ] **Step 3: Run** `lua tests/run.lua` — expect new/changed permission cases **fail** until Task 2.

- [ ] **Step 4: Commit** `test: manageContracts edit gate fixtures`

---

### Task 2: Implement `canEditFarmTodos` = SP | manageContracts

**Files:**
- Modify: `scripts/FieldToDoPermissions.lua`

- [ ] **Step 1: Add** `FieldToDoPermissions.isMultiplayerSession()` mirroring menu logic (`missionDynamicInfo.isMultiplayer`).

- [ ] **Step 2: Change permission key** used for farm edit to `"manageContracts"` (prefer `Farm.PERMISSION.MANAGE_CONTRACTS` when table present). Rename/repurpose `hasFarmTodoEditPermission` to read that key only.

- [ ] **Step 3: Rewrite** `canEditFarmTodos`:
  ```lua
  -- after membership:
  if not FieldToDoPermissions.isMultiplayerSession() then
      return true
  end
  local perm = FieldToDoPermissions.hasFarmTodoEditPermission(farmId, userId)
  return perm == true  -- nil/false → false (no fallback)
  ```
  Remove calls to `isFarmManager` and `getTodoEditAllowed` from this function.

- [ ] **Step 4: Stop calling** `registerFarmPermission` at file load (delete function or leave dead unused — prefer delete + remove `onMissionStarted` re-register in Task 3).

- [ ] **Step 5: Run** `lua tests/run.lua` — permission fixtures pass.

- [ ] **Step 6: Commit** `feat(mp): gate todo edit on manageContracts`

---

### Task 3: Sync schema v5 — drop grant wire + ops

**Files:**
- Modify: `scripts/FieldToDoSync.lua`
- Modify: `scripts/ToDoManager.lua` (apply methods / state build)
- Modify: project memory if schema version documented

- [ ] **Step 1: Bump** `FieldToDoSync.SCHEMA_VERSION` from `4` to `5`.

- [ ] **Step 2: Remove** from `writeState` / `readState` / `buildStateForFarm` / apply-state:
  - `workersMayEditTodos`, `todoEditDefaultAllow`, `todoEditUsers` stream block

- [ ] **Step 3: Grant ops** (`SET_WORKERS_EDIT`, `SET_USER_TODO_EDIT`, `SET_ALL_WORKERS_TODO_EDIT`): hard-deny or remove from `APPLY_METHOD_BY_OP` + request serialize; `canExecuteOp` no longer needs grant-manager branches for those ops.

- [ ] **Step 4: Remove** `FieldToDoPermissions.registerFarmPermission()` from `onMissionStarted`.

- [ ] **Step 5: Run tests**; smoke that schema mismatch still rejects old peers cleanly (`isCompatibleSchema`).

- [ ] **Step 6: Commit** `feat(mp): sync schema v5 drop todo-edit grants`

---

### Task 4: Remove ESC grant UI + settings writers

**Files:**
- Modify: `gui/FieldToDoMenuFrame.lua`
- Modify: `gui/FieldToDoMenuFrame.xml`
- Modify: `scripts/FieldAdvisorSettings.lua` (stop gate-related APIs if unused)
- Modify: `scripts/ToDoManager.lua` (stop save/load of `farmTodoEdit` for gate; ignore orphan XML)
- Modify: `translations/translation_de.xml`, `translations/translation_en.xml`

- [ ] **Step 1:** `shouldShowWorkersEditUi` → always `false` (or delete callers + XML nodes for member list / Alle Worker).

- [ ] **Step 2:** Remove click handlers for grant toggles; keep `requireEditPermission` / deny dialog.

- [ ] **Step 3:** Stop writing `farmTodoEdit` / `#todoEditDefaultAllow` / grant maps on save; keep reading optional for one release only if needed — prefer ignore.

- [ ] **Step 4:** Drop l10n keys for grants + `ftdlEditTodos` permission labels; keep `ftdl_edit_denied`.

- [ ] **Step 5: Run tests**; quick UI sanity in SP (no grant block).

- [ ] **Step 6: Commit** `refactor(ui): remove ESC todo edit grants`

---

### Task 5: Docs + memory for Part 1

**Files:**
- Modify: `docs/DECISIONS.md`
- Modify: `CHANGELOG.md` (Unreleased)
- Modify: `.cursor/rules/fs25-project-memory.mdc`

- [ ] **Step 1:** DECISIONS entry: edit = SP always / MP `manageContracts`; ESC + `ftdlEditTodos` retired; schema v5.
- [ ] **Step 2:** Update project memory Multiplayer / edit gate bullets.
- [ ] **Step 3:** CHANGELOG Unreleased note.
- [ ] **Step 4: Commit** `docs: manageContracts edit gate`

---

### Task 6: Failing tests — generic grass index + cut meadow phase

**Files:**
- Modify: `tests/run.lua`

- [ ] **Step 1: Add test** `getDefaultGrassFruitTypeIndex_prefers_generic_GRASS`: stub `g_fruitTypeManager.getFruitTypes` returning ALFALFA before GRASS; expect resolved index = GRASS (or generic name list winner), not ALFALFA.

- [ ] **Step 2: Add test** `meadow_phase_cut_when_specific_harvestReady_but_generic_cut`: stubs so ALFALFA growth claims harvestReady, generic GRASS `isCut`, `isGrassPostMowState` / `getGrassMeadowPhase` → cut (not harvestable). Extend existing alfalfa post-mow test if overlapping.

- [ ] **Step 3: Run** — expect **fail** before Task 7.

- [ ] **Step 4: Commit** `test: generic grass recognition fixtures`

---

### Task 7: Fix generic grass resolution + meadow recognition

**Files:**
- Modify: `scripts/FieldAdvisor.lua`
- Modify: `scripts/FieldTaskCompletion.lua` (only if nil-ratio / probe path still skips generic)

- [ ] **Step 1: Fix** `getDefaultGrassFruitTypeIndex`:
  - Prefer names in `GENERIC_GRASS_FRUIT_NAMES` / `"GRASS"` first via `getFruitTypeIndexByName`.
  - Only then fall back to scanning `getFruitTypes` for `isGrassCrop`, **skipping** non-generic specifics when a generic exists.
  - Invalidate cache if tests need reset (`_defaultGrassFruitTypeResolved`).

- [ ] **Step 2: Audit** `getGrassMeadowPhase` / `phaseForState`: after `isGrassPostMowState` is false, if specific fruit is harvestable but generic GRASS is cut at same growth → return `"cut"`. Prefer calling the single post-mow predicate with correct default rather than duplicating logic.

- [ ] **Step 3: Grep** remaining unlogical paths (`refineGrassFruitTypeIndex`, vote ties, windrow infer) — fix only clear bugs that upgrade to ALFALFA/CLOVER without evidence; no new score bonuses.

- [ ] **Step 4: Ensure** `getGrassMowCutRatio` / `isGrassLogisticsComplete` nil fallback use the fixed default grass index (already retries default — verify after Step 1).

- [ ] **Step 5: Run** `lua tests/run.lua` — all green.

- [ ] **Step 6: Commit** `fix(advisor): prefer generic GRASS for post-mow recognition`

---

### Task 8: Docs Part 2 + regression note

**Files:**
- Modify: `docs/DECISIONS.md`
- Modify: `docs/REGRESSION.md`
- Modify: `CHANGELOG.md`
- Modify: `.cursor/rules/fs25-project-memory.mdc` (Advisor grass bullets if needed)

- [ ] **Step 1:** DECISIONS: generic meadow index for all mowables; recognition-only change; auto policy unchanged.
- [ ] **Step 2:** REGRESSION checklist: Field 17 Gras label; cut Luzerne ≠ re-mow; half-mow open.
- [ ] **Step 3: Commit** `docs: grass recognition hardening`

---

### Task 9: Build + smoke checklist

**Files:** none (commands + manual)

- [ ] **Step 1:** `python3 tools/generate_assets.py && ./build.sh`
- [ ] **Step 2:** Full FS25 restart (dedicated: server + clients).
- [ ] **Step 3: Smoke**
  - SP: edit works; no ESC grant block
  - MP: without `manageContracts` → Planfrucht/add denied; with right → ok; auto-complete without edit still works
  - Meadow: Gras label without evidence; full mow completes; cut specific grass not re-mow

---

## Out of scope (do not implement)

- Personal owner todos
- Swath liter / height auto-complete APIs
- Changing `grass_bale` / `grass_silage_bale` auto flags
- `modDesc.xml` version bump / GitHub release (unless user asks)
