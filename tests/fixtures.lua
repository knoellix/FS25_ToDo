-- Golden fixtures from log.txt dump 2026-06-04 08:23 (mod 0.1.0.5, period 5/July).
-- Pure `facts` per FIELD_PHASE.md + expected phase. No engine dependency.
-- These define the SOLL for deriveFieldPhase (Phase 2). May be red until implemented.

local F = {}

local function case(t) F[#F + 1] = t end

-- ground/flags taken from each field's "meadowPhase growthFlags(...)" + FieldState line.

case{ name = "field_1_soybean_growing",
  facts = { dominant = "arable", isGrassCrop = false, hasFruit = true,
            growth = 4, maxHarvest = 7, ground = "ROLLER_LINES",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 1, residue = "none", residueReliable = false },
  expected = "standing" }

-- Field 3 (2026-06-07): SOYBEAN growth=5 on HARVEST_READY must not read as post-harvest stubble.
case{ name = "field_3_soybean_harvest_ready_ground",
  facts = { dominant = "arable", isGrassCrop = false, hasFruit = true,
            growth = 5, maxHarvest = 7, ground = "HARVEST_READY",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 0, residue = "none", residueReliable = false },
  expected = "standing" }

case{ name = "field_6_grass_cut_unreliable_residue",
  facts = { dominant = "grass", isGrassCrop = true, hasFruit = true,
            growth = 5, maxHarvest = 4, ground = "GRASS_CUT",
            flags = { cut = true, harvestable = false, harvestReady = false, withered = false },
            shred = 0, residue = "loose", residueReliable = false },
  expected = "grass_cut" }

case{ name = "field_9_wheat_growing_weedy",
  facts = { dominant = "arable", isGrassCrop = false, hasFruit = true,
            growth = 6, maxHarvest = 7, ground = "ROLLER_LINES",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 1, residue = "none", residueReliable = false },
  expected = "standing" }

case{ name = "field_14_plowed_empty",
  facts = { dominant = "bare_soil", isGrassCrop = false, hasFruit = false,
            growth = 0, maxHarvest = 0, ground = "PLOWED",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 0, residue = "none", residueReliable = false },
  expected = "empty" }

case{ name = "field_15_maize_growing",
  facts = { dominant = "arable", isGrassCrop = false, hasFruit = true,
            growth = 4, maxHarvest = 8, ground = "PLANTED",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 1, residue = "none", residueReliable = false },
  expected = "standing" }

case{ name = "field_16_triticale_stubble",
  facts = { dominant = "arable", isGrassCrop = false, hasFruit = true,
            growth = 11, maxHarvest = 8, ground = "HARVEST_READY",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 1, residue = "none", residueReliable = false },
  expected = "post_harvest" }

case{ name = "field_17_none_empty",
  facts = { dominant = "unknown", isGrassCrop = false, hasFruit = false,
            growth = 0, maxHarvest = 0, ground = "NONE",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 0, residue = "none", residueReliable = false },
  expected = "empty" }

-- Field 63/76: clover/alfalfa regrown to mowable height (growth=minHarvest, harvestReady).
-- User-confirmed standing & ready to mow despite lingering stubble shred from the prior cut.
-- harvestable MUST beat the ambiguous shred signal -> grass_harvestable (suggest mow).
case{ name = "field_63_clover_regrown_harvestable",
  facts = { dominant = "grass", isGrassCrop = true, hasFruit = true,
            growth = 3, maxHarvest = 5, ground = "GRASS",
            flags = { cut = false, harvestable = true, harvestReady = true, withered = false },
            shred = 1, residue = "swath", residueReliable = false },
  expected = "grass_harvestable" }

case{ name = "field_71_plowed_empty",
  facts = { dominant = "bare_soil", isGrassCrop = false, hasFruit = false,
            growth = 0, maxHarvest = 0, ground = "PLOWED",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 1, residue = "none", residueReliable = false },
  expected = "empty" }

case{ name = "field_72_pea_plowed_empty",
  facts = { dominant = "arable", isGrassCrop = false, hasFruit = true,
            growth = 0, maxHarvest = 5, ground = "PLOWED",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 0, residue = "none", residueReliable = false },
  expected = "empty" }

case{ name = "field_73_plowed_empty",
  facts = { dominant = "bare_soil", isGrassCrop = false, hasFruit = false,
            growth = 0, maxHarvest = 0, ground = "PLOWED",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 1, residue = "none", residueReliable = false },
  expected = "empty" }

case{ name = "field_76_alfalfa_regrown_harvestable",
  facts = { dominant = "grass", isGrassCrop = true, hasFruit = true,
            growth = 3, maxHarvest = 5, ground = "GRASS",
            flags = { cut = false, harvestable = true, harvestReady = true, withered = false },
            shred = 1, residue = "swath", residueReliable = false },
  expected = "grass_harvestable" }

-- Synthetic cases for phases not covered by the current savegame (cover every enum value).

case{ name = "synthetic_wheat_harvest_ready",
  facts = { dominant = "arable", isGrassCrop = false, hasFruit = true,
            growth = 7, maxHarvest = 7, ground = "HARVEST_READY",
            flags = { cut = false, harvestable = true, harvestReady = true, withered = false },
            shred = 0, residue = "none", residueReliable = false },
  expected = "harvest_ready" }

case{ name = "synthetic_withered",
  facts = { dominant = "arable", isGrassCrop = false, hasFruit = true,
            growth = 9, maxHarvest = 7, ground = "HARVEST_READY",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = true },
            shred = 0, residue = "none", residueReliable = false },
  expected = "withered" }

case{ name = "synthetic_grass_standing",
  facts = { dominant = "grass", isGrassCrop = true, hasFruit = true,
            growth = 2, maxHarvest = 4, ground = "GRASS",
            flags = { cut = false, harvestable = false, harvestReady = false, withered = false },
            shred = 0, residue = "none", residueReliable = false },
  expected = "grass_standing" }

case{ name = "synthetic_grass_harvestable",
  facts = { dominant = "grass", isGrassCrop = true, hasFruit = true,
            growth = 4, maxHarvest = 4, ground = "GRASS",
            flags = { cut = false, harvestable = true, harvestReady = true, withered = false },
            shred = 0, residue = "none", residueReliable = false },
  expected = "grass_harvestable" }

case{ name = "synthetic_grass_residue_swath_reliable",
  facts = { dominant = "grass", isGrassCrop = true, hasFruit = true,
            growth = 3, maxHarvest = 5, ground = "GRASS",
            flags = { cut = true, harvestable = false, harvestReady = false, withered = false },
            shred = 1, residue = "swath", residueReliable = true },
  expected = "grass_residue" }

return F
