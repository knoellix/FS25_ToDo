-- Weed-advice fixtures for WeedAdvice.deriveWeedAdvice (pure, headless).
-- `facts` mirror FieldAdvisor.buildWeedAdviceFacts output. `expect` lists the advice flags.
-- Locks the W4/W5 contradictions from docs/AUDIT_INVENTORY.md so future changes can't regress.

local W = {}

local function case(t) W[#W + 1] = t end

-- W4: dead-dominant field still has 1 live misread probe, but coverage says done.
-- Must suppress all action (was: watch+hoe). Field 72 class of bug.
case{ name = "w4_dead_dominant_done_no_action",
  facts = { enabled = true, hasSummary = true, hasCoverage = true,
            live = 1, classified = 30, liveRatio = 1/30,
            doneByCoverage = true, deadOrSprayed = true, pressure = 0, weedState = 6 },
  expect = { done = true, hoe = false, watch = false, needsCombat = false, spray = false } }

-- W5: light live weed (6%) with low growth stage -> hoe only, never spray. Field 16 class.
case{ name = "w5_light_live_hoe_only",
  facts = { enabled = true, hasSummary = true, hasCoverage = true,
            live = 6, classified = 100, liveRatio = 0.06,
            doneByCoverage = false, deadOrSprayed = false, pressure = 0.06, weedState = 2 },
  expect = { done = false, hoe = true, watch = false, needsCombat = true, spray = false } }

-- Heavy live weed (12%) or advanced stage -> spray (and hoe in work-order preview).
case{ name = "heavy_live_spray_and_hoe",
  facts = { enabled = true, hasSummary = true, hasCoverage = true,
            live = 12, classified = 100, liveRatio = 0.12,
            doneByCoverage = false, deadOrSprayed = false, pressure = 0.12, weedState = 4 },
  expect = { done = false, hoe = true, watch = false, needsCombat = true, spray = true } }

-- Watch band (2%..5% live): monitor + hoe, no spray.
case{ name = "watch_band_hoe_no_spray",
  facts = { enabled = true, hasSummary = true, hasCoverage = true,
            live = 3, classified = 100, liveRatio = 0.03,
            doneByCoverage = false, deadOrSprayed = false, pressure = 0.03, weedState = 1 },
  expect = { done = false, hoe = true, watch = true, needsCombat = false, spray = false } }

-- Below complete threshold (1% live): effectively clean, no action.
case{ name = "below_complete_no_action",
  facts = { enabled = true, hasSummary = true, hasCoverage = true,
            live = 1, classified = 100, liveRatio = 0.01,
            doneByCoverage = false, deadOrSprayed = false, pressure = 0.01, weedState = 1 },
  expect = { done = false, hoe = false, watch = false, needsCombat = false, spray = false } }

-- No probe coverage: fall back to field-state pressure. High pressure + stage -> spray+hoe.
case{ name = "no_coverage_state_pressure_spray",
  facts = { enabled = true, hasSummary = false, hasCoverage = false,
            live = 0, classified = 0, liveRatio = 0,
            doneByCoverage = false, deadOrSprayed = false, pressure = 0.08, weedState = 4 },
  expect = { done = false, hoe = true, watch = false, needsCombat = true, spray = true } }

-- No coverage, weeds sprayed/dead by state -> no action.
case{ name = "no_coverage_dead_no_action",
  facts = { enabled = true, hasSummary = false, hasCoverage = false,
            live = 0, classified = 0, liveRatio = 0,
            doneByCoverage = false, deadOrSprayed = true, pressure = 0, weedState = 6 },
  expect = { done = false, hoe = false, watch = false, needsCombat = false, spray = false } }

-- Feature disabled -> never any advice.
case{ name = "disabled_no_action",
  facts = { enabled = false, hasSummary = true, hasCoverage = true,
            live = 20, classified = 100, liveRatio = 0.20,
            doneByCoverage = false, deadOrSprayed = false, pressure = 0.20, weedState = 5 },
  expect = { done = false, hoe = false, watch = false, needsCombat = false, spray = false } }

-- Coverage present but all probes dead (live 0) -> done, no action.
case{ name = "coverage_all_dead_done",
  facts = { enabled = true, hasSummary = true, hasCoverage = true,
            live = 0, classified = 40, liveRatio = 0,
            doneByCoverage = true, deadOrSprayed = true, pressure = 0, weedState = 6 },
  expect = { done = true, hoe = false, watch = false, needsCombat = false, spray = false } }

return W
