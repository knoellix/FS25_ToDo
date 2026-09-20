# Vanilla sprayLevel fertilizer fallback (no Precision Farming)

**Date:** 2026-09-20  
**Status:** approved  
**Mod:** FS25_FieldToDoList  
**Builds on:** existing `pf_n` / organic multi-pass / `PrecisionFarmingReader`

## Goal

When **Precision Farming is not runtime-ready**, still suggest and auto-complete fertilizing using vanilla **`FieldState.sprayLevel`** against the **game’s spray-level maximum** (adapts to 1×-fertilizer mods). With PF ready, keep today’s nitrogen-map behaviour unchanged.

## Decisions (locked)

| Topic | Choice |
|--------|--------|
| Approach | Extend existing `pf_n` path (no new action type) |
| Max level source | `fieldGroundSystem:getMaxValue(FieldDensityMap.SPRAY_LEVEL)` (or equivalent mission ground system) |
| Max fallback if API missing | `2` (vanilla default) |
| PF vs spray | **PF wins** when ready + `nitrogenValue` present; else spray |
| Grass | No fertilize suggestion (unchanged) |
| Herbicide | Unchanged: `hasHerbicideResidue` may still read `sprayLevel`/`sprayType`; fertilize advice is separate (`level < max`) |
| Organic multi-pass without PF | Keep menu toggle; pass targets from `pass/total * sprayLevelMax` (not N=80) |
| Labels | Keep `pf_n` / „Düngen“; optional short note in dump that source is `spray` |

## Non-goals

- Detecting which product was applied (mineral vs manure vs slurry).
- Changing PF nitrogen thresholds (still &lt; 80 suggest, ≥ 80 done).
- New ESC setting for fixed 1/2 passes (max comes from the game/mod).
- Reworking weed/`sprayType` semantics.

## Single decision function

```text
deriveFertilizerAdvice(facts) →
  {
    needsFertilizer: boolean,
    source: "pf" | "spray" | "none",
    level: number|nil,      -- sprayLevel or nitrogenValue
    max: number|nil,        -- 80 for pf, sprayLevelMax for spray
    done: boolean,          -- not needsFertilizer when readable
  }
```

**Facts (minimal):**

- `pfReady` (bool), `nitrogenValue` (number|nil)
- `sprayLevel` (number|nil)
- `sprayLevelMax` (number|nil) — resolved once, cached until save load / map delete
- `isGrass` (bool)

**Rules:**

1. If `isGrass` → `source=none`, `needsFertilizer=false`.
2. Else if `pfReady` and `nitrogenValue ~= nil` → PF path (`needs = N < 80`, `max=80`).
3. Else if `sprayLevel` readable → spray path (`needs = sprayLevel < sprayLevelMax`).
4. Else → `source=none` (no suggestion; do not invent need).

## Integration points

| Path | Behaviour |
|------|-----------|
| Suggest (`add*Actions` / standing & empty/post-harvest) | Add `pf_n` when `needsFertilizer` |
| Auto-complete `pf_n` | `done` from advice; organic passes use staged target `floor(max * pass/total)` |
| `expandOrganicFertilizerPasses` | Without PF N: derive pass count from how far `sprayLevel` is below max (e.g. deficit 1 → 1 pass, else up to `max` / interleave slots — exact formula in plan; must not invent passes when already at max) |
| Dump / debug | Log `fertAdvice: source level/max needs` |
| Overview N column | Unchanged (still PF-only display); fertilize task text stays „Düngen“ |

## Max resolution

```text
resolveSprayLevelMax()
  → g_currentMission.fieldGroundSystem (or fieldManager.groundSystem)
  → getMaxValue(FieldDensityMap.SPRAY_LEVEL) if FieldDensityMap.SPRAY_LEVEL defined
  → else fallback 2
Cache on FieldAdvisor; invalidate on save load / map delete (same pattern as DensityMapHeightUtil).
```

1×-fertilizer mods that lower the density-map max are picked up automatically.

## Tests (headless)

- PF facts → spray ignored when N present.
- No PF, `level=0 max=2` → needs; `level=2` → done.
- No PF, `level=1 max=1` (mod) → done.
- Grass → no need.
- Organic pass target: pass 1/2 max=2 → target 1; complete when `sprayLevel >= 1`.

## Acceptance

- Save **without** PF: empty/sown arable with `sprayLevel < max` shows Düngen; after fertilizing to max, auto-complete clears it.
- Save **with** 1× mod (`max=1`): one pass clears the task.
- Save **with** PF: still N-driven; spray fallback not used when N sample exists.
- Regression: weed herbicide logic unchanged; grass still no `pf_n`.

## Open for implementation plan only

- Exact organic pass-count formula without N (mirror PF bands vs. simple `max - sprayLevel`).
- Whether empty bare soil before sow should suggest fertilize (today PF suggests on standing path when N low — keep same phases that already call the pf_n add).
