# SprayLevel Fertilizer Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Without Precision Farming, suggest and auto-complete `pf_n` from vanilla `sprayLevel` vs game `sprayLevelMax` (adapts to 1× fertilizer mods); with PF, keep nitrogen behaviour unchanged.

**Architecture:** Pure `FertilizerAdvice.deriveFertilizerAdvice(facts)` (WeedAdvice pattern). FieldAdvisor resolves `sprayLevelMax`, builds facts, suggests/completes via that one decision. Organic multi-pass without N uses spray deficit for pass count and staged spray targets.

**Tech Stack:** FS25 Lua 5.1, headless `lua tests/run.lua`, existing `pf_n` / `FieldTaskCompletion`.

**Spec:** `docs/superpowers/specs/2026-09-20-spraylevel-fertilizer-fallback-design.md`

## Global Constraints

- No new action type — keep `pf_n`.
- Max from `fieldGroundSystem:getMaxValue(FieldDensityMap.SPRAY_LEVEL)`; fallback **2**.
- PF wins when ready + `nitrogenValue` present.
- Grass: never suggest fertilize.
- No `goto` / labels; no version bump unless asked.
- Herbicide `hasHerbicideResidue` unchanged.

## File structure

| File | Role |
|------|------|
| `scripts/FertilizerAdvice.lua` | Pure `deriveFertilizerAdvice` + pass helpers |
| `tests/fertilizer_fixtures.lua` | Headless cases |
| `tests/run.lua` | Load fixtures like WeedAdvice |
| `scripts/FieldAdvisor.lua` | Max resolve/cache, facts, suggest, organic expand |
| `scripts/FieldTaskCompletion.lua` | `pf_n` complete via advice / spray targets |
| `scripts/ToDoManager.lua` | Invalidate spray max cache on mission start |
| `scripts/FieldDebugDump.lua` | Dump fertAdvice line |
| `modDesc.xml` | sourceFile before FieldAdvisor |
| `docs/DECISIONS.md`, `CHANGELOG.md` Unreleased, project memory | Record rule |

---

### Task 1: FertilizerAdvice + failing tests

**Files:**
- Create: `scripts/FertilizerAdvice.lua`
- Create: `tests/fertilizer_fixtures.lua`
- Modify: `tests/run.lua` (WeedAdvice block pattern)
- Modify: `modDesc.xml` (sourceFile after WeedAdvice)

**Interfaces:**
- Produces: `FertilizerAdvice.deriveFertilizerAdvice(facts) → { needsFertilizer, done, source, level, max }`
- Produces: `FertilizerAdvice.getSprayPassCount(level, max)`, `getSprayPassTarget(pass, passTotal, max)`

- [ ] **Step 1: Write fixtures** covering: PF N&lt;80 needs; N≥80 done; no PF level0 max2 needs; level2 max2 done; level1 max1 done (mod); grass none; spray ignored when PF N present; pass target 1/2 max2 → 1.

- [ ] **Step 2: Wire runner** — expect FAIL (module missing).

- [ ] **Step 3: Implement `FertilizerAdvice.lua`** (return table at end like WeedAdvice).

- [ ] **Step 4: Run `lua tests/run.lua`** — fertilizer cases PASS.

- [ ] **Step 5: Register in `modDesc.xml`**.

Organic spray pass count (locked here): `deficit = max - level`; if `deficit <= 0` return 1; else `return math.min(deficit, max)` (0/2 → 2; 0/1 → 1; 1/2 → 1).

---

### Task 2: FieldAdvisor resolve max + suggest/complete wiring

**Files:**
- Modify: `scripts/FieldAdvisor.lua` (resolveSprayLevelMax, invalidate, buildFertilizerAdviceFacts, suggest sites, expandOrganic, hasCompletionProgress)
- Modify: `scripts/FieldTaskCompletion.lua` (`pf_n` branch)
- Modify: `scripts/ToDoManager.lua` (invalidate on start)
- Modify: `scripts/FieldDebugDump.lua`

**Interfaces:**
- Consumes: `FertilizerAdvice.deriveFertilizerAdvice`
- Produces: `FieldAdvisor.resolveSprayLevelMax()`, `invalidateSprayLevelMax()`, `buildFertilizerAdviceFacts(...)`, `fieldNeedsFertilizer(...)`

- [ ] **Step 1: Cache helpers** — `resolveSprayLevelMax` / `invalidateSprayLevelMax`; call invalidate beside DensityMapHeightUtil on mission start.

- [ ] **Step 2: Facts + wrapper** — from context: pfReady, nitrogenValue, sprayLevel, sprayLevelMax, isGrass.

- [ ] **Step 3: Suggest** — replace raw N&lt;80 check in `addGrowingActions`; **also** add same `pf_n` block in `addEmptyOrPostHarvestActions` when `needsFertilizer` (arable prep without PF).

- [ ] **Step 4: Organic expand** — if no nitrogen, use `getSprayPassCount(sprayLevel, max)` and pass `sprayLevel` into expand (signature: `expandOrganicFertilizerPasses(actions, pfSample, sprayLevel)`).

- [ ] **Step 5: Completion** — `pf_n`: build advice; if `source=="pf"` keep N≥80 / staged N targets; if `source=="spray"` use spray level vs max / staged spray targets; if PF not ready and spray readable, do **not** early-return true.

- [ ] **Step 6: Dump** one line `fertAdvice: source=… level=… max=… needs=…`.

- [ ] **Step 7: `lua tests/run.lua`** green; build mod.

---

### Task 3: Docs

**Files:**
- Modify: `docs/DECISIONS.md`, `CHANGELOG.md` Unreleased, `.cursor/rules/fs25-project-memory.mdc`
- Modify: spec status → `approved`

- [ ] **Step 1: DECISIONS entry** — fertilize: PF N else sprayLevel vs max.
- [ ] **Step 2: CHANGELOG + memory** one-liners.
- [ ] **Step 3: Spec status approved.**

---

## Manual verify (after build)

1. Save **without** PF, arable `sprayLevel=0`: Düngen suggested; fertilize to max → auto-complete.
2. 1×-fertilizer mod (`max=1`): one pass clears task.
3. With PF: still N-driven when sample present.
