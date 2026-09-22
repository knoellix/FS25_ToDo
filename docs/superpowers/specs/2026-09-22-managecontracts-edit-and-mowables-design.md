# Edit via manageContracts + grass recognition hardening

**Date:** 2026-09-22  
**Status:** approved (2026-09-22)  
**Mod:** FS25_FieldToDoList  
**Builds on:** dedicated MP farm permission (`2026-09-18-…`), grass post-mow / cut-ratio DECISIONS (2026-09-20 / 2026-09-22)

## Goal

1. **Edit rights:** Multiplayer farm To-Do edit follows vanilla Hofverwaltung **`manageContracts` only**. Singleplayer always edits. Remove ESC grants and custom `ftdlEditTodos` from the edit path (no parallel grants / `defaultAllow` fallback).
2. **Grass recognition:** Root out **illogical grass classification / post-mow / label** behaviour for **all** `isGrassCrop` mowables (Wiese, Luzerne, Klee, …). Auto-complete policy for mow/logistics is **already in place** — do not churn it this round unless a recognition fix forces a tiny registry tweak.

## Locked decisions

| Topic | Choice |
|--------|--------|
| MP edit | Membership + vanilla `Farm.PERMISSION` / key **`manageContracts`** |
| SP edit | Always allowed (after membership / local farm) |
| Manager special-case | **No** — managers use the same `manageContracts` bit (vanilla typically grants it) |
| ESC grant UI | **Remove** |
| Custom `ftdlEditTodos` | **Remove** from gate + stop registering |
| Sidecar `todoEditByFarmId` / `defaultAllow` / per-user map | **Stop using for edit**; clean UI/ops (persistence can be retired in same change or left unread one release) |
| Auto-complete (farm membership) | Unchanged: **all same-farm members** via `canAutoCompleteFarmTodos` |
| Grass logistics auto | **Keep current:** swath/collect manual; `grass_mow` ≥98%; bale-collect on objects; press auto as already shipped — **no further auto redesign** |
| Recognition focus | Fix unlogical label / standing-vs-cut / generic-vs-specific fruit paths |
| New swath/liter completion API | **Out of scope** this round |
| Personal / owner-only todos | **Out of scope** (later list feature) |

---

## Part 1 — Edit gate

### Current code (audit)

```
canEditFarmTodos:
  membership → isFarmManager → hasFarmTodoEditPermission(ftdlEditTodos) → getTodoEditAllowed(defaultAllow / byUniqueUserId)
```

- Custom permission registered but Hofverwaltung often does not show it → ESC grants kept as working toggle (`shouldShowWorkersEditUi`).
- Auto-complete already bypasses edit (`OP.AUTO_COMPLETE` → `canAutoCompleteFarmTodos` only).
- Manual Done / HUD Done / Planfrucht / CRUD use edit.

### Target gate

```
canEditFarmTodos(farmId, userId):
  if not same-farm membership → false
  if not multiplayer session → true          -- SP
  return hasUserPermission(manageContracts)  -- MP; API missing → false (server fail-closed)
```

No manager OR, no `ftdlEditTodos`, no sidecar grant fallback.

### SP vs MP detection

Use the same notion as the menu (`isMultiplayerSession` / mission multiplayer flag). Listen-server host is **MP** and must have `manageContracts` (or be denied). Do not treat “has g_server” alone as SP.

### Permission read

Reuse the existing get/hasUserPermission / `farm.users[].permissions[key]` pattern in `hasFarmTodoEditPermission`, but key = `Farm.PERMISSION.MANAGE_CONTRACTS` or string `"manageContracts"`. Prefer engine constant when present.

### Removals (edit path)

| Area | Action |
|------|--------|
| `FieldToDoPermissions` | Drop `PERMISSION_KEY` / `registerFarmPermission` / grant helpers from edit; rewrite `canEditFarmTodos` |
| ESC UI | Hide/remove member list + Alle-Worker (`FieldToDoMenuFrame` + XML) |
| Sync ops 11 / 15 / 16 | Stop applying for grants; prefer remove or hard-deny |
| State stream of todoEdit maps | Stop; **bump sync schema** if wire shrinks (current v4) |
| Settings / sidecar grant attrs | Stop reading for gate; retire writers when safe |
| l10n | Drop grant + `ftdlEditTodos` permission strings; keep `ftdl_edit_denied` |

### Keep

DENY InfoDialog, `requireEditPermission` / `canEditLocal` on menu + HUD, farmId-on-wire, task sidecar, auto-complete membership.

### Risks

| Risk | Mitigation |
|------|------------|
| `getUserPermission` nil on dedicated | Fail-closed for MP edit (user choice: no fallback) |
| Manager without `manageContracts` | Denied — intentional; fix in Hofverwaltung |
| Old clients / schema | Bump `SCHEMA_VERSION` when grant payload removed |
| Orphan `farmTodoEdit` XML | Ignore on load; stop writing |

---

## Part 2 — Grass recognition (not auto redesign)

Auto-complete for mow/logistics is **already decided and shipped** (`grass_mow` ≥98%; swath/collect manual; bale paths as today). This part only removes **illogical recognition**.

### Current code (audit)

- **Mowable set:** `isGrassCrop` = name list (`GRASS`, `MEADOW`, `ALFALFA`, `CLOVER`, …) + engine grass flags + no-plow heuristic.
- **`isGrassPostMowState`:** cut ground → standing-regrowth gate with **generic override** (specific fruit claims harvestReady but generic grass `isCut` → post-mow) → shred → `isCut` / past max harvest. Override is already meant for all specific grass; tests narrate alfalfa.
- **Fragility:** `getDefaultGrassFruitTypeIndex` may return the **first** `isGrassCrop` in manager order, not true `GRASS` → override/cut-ratio retry can no-op when default == specific fruit.
- **Meadow phase:** after post-mow returns false, `getGrassMeadowPhase` can still trust specific-fruit `harvestReady` alone → false „mähen“ on cut stands.
- **Label bias:** `+20` ALFALFA bonus already removed; equal scores prefer generic GRASS — still audit refine/disambiguate/votes for remaining unlogical Luzerne wins.
- **Residue:** liters/layout for **suggestions** only; no new swath API this round.

### Target behavior

1. **Generic meadow index:** Prefer true generic (`GENERIC_GRASS_FRUIT_NAMES`, `GRASS` first) in `getDefaultGrassFruitTypeIndex` (or dedicated helper) so post-mow override + cut-ratio retries work for **all** mowables.
2. **Meadow phase / standing vs cut:** Close paths where specific-fruit `harvestReady` marks `harvestable` on a cut stand without the generic cut check.
3. **Label / fruit resolution:** Keep „Gras unless evidence“; fix remaining unlogical ALFALFA/CLOVER upgrades found in refine/disambiguate/votes (no new score bonuses).
4. **`grass_mow` probes:** Same generic override consistently (including nil-ratio fallback). Leave ≥98% threshold as-is.
5. **Do not** change logistics auto-complete flags; **do not** invent swath completion APIs.
6. **Out of scope:** oilseed radish name expansion; personal todos; ESC/custom edit (Part 1).

### Validation (in-game / regression)

- Field 17 style meadow: label Gras (not Luzerne without evidence); half-mow stays open; full mow completes via existing ≥98% rule.
- Luzerne/Klee cut: post-mow / not re-mow; standing regrowth still „mähen“.
- MP: worker without `manageContracts` denied on Planfrucht/add; with right, edits; auto-complete still works without edit.

---

## Implementation order

1. Part 1 permissions + hide ESC grants + tests + schema/docs/memory.
2. Part 2 generic grass index + meadow phase / recognition hardening + DECISIONS/REGRESSION notes (no auto flag churn).
3. Build + smoke (SP + dedicated MP if available).

## Non-goals

- Personal owner-editable todos.
- Redesigning grass logistics auto-complete.
- New swath liter / height completion APIs.
- Re-introducing ESC or custom Hof checkboxes.
