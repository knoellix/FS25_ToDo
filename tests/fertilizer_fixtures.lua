-- FertilizerAdvice fixtures (pure, headless). Locks PF vs sprayLevel fallback.

local F = {}

local function case(t) F[#F + 1] = t end

case{
  name = "pf_n_low_needs",
  facts = { isGrass = false, pfReady = true, nitrogenValue = 40, sprayLevel = 2, sprayLevelMax = 2 },
  expect = { needsFertilizer = true, done = false, source = "pf", level = 40, max = 80 },
}

case{
  name = "pf_n_full_done",
  facts = { isGrass = false, pfReady = true, nitrogenValue = 80, sprayLevel = 0, sprayLevelMax = 2 },
  expect = { needsFertilizer = false, done = true, source = "pf", level = 80, max = 80 },
}

case{
  name = "spray_empty_needs",
  facts = { isGrass = false, pfReady = false, nitrogenValue = nil, sprayLevel = 0, sprayLevelMax = 2 },
  expect = { needsFertilizer = true, done = false, source = "spray", level = 0, max = 2 },
}

case{
  name = "spray_full_done",
  facts = { isGrass = false, pfReady = false, nitrogenValue = nil, sprayLevel = 2, sprayLevelMax = 2 },
  expect = { needsFertilizer = false, done = true, source = "spray", level = 2, max = 2 },
}

case{
  name = "spray_mod_once_done",
  facts = { isGrass = false, pfReady = false, nitrogenValue = nil, sprayLevel = 1, sprayLevelMax = 1 },
  expect = { needsFertilizer = false, done = true, source = "spray", level = 1, max = 1 },
}

case{
  name = "grass_never",
  facts = { isGrass = true, pfReady = false, nitrogenValue = nil, sprayLevel = 0, sprayLevelMax = 2 },
  expect = { needsFertilizer = false, done = true, source = "none", level = nil, max = nil },
}

case{
  name = "pf_wins_over_spray",
  facts = { isGrass = false, pfReady = true, nitrogenValue = 90, sprayLevel = 0, sprayLevelMax = 2 },
  expect = { needsFertilizer = false, done = true, source = "pf", level = 90, max = 80 },
}

case{
  name = "no_signal_none",
  facts = { isGrass = false, pfReady = false, nitrogenValue = nil, sprayLevel = nil, sprayLevelMax = 2 },
  expect = { needsFertilizer = false, done = false, source = "none", level = nil, max = nil },
}

-- Pass helpers (attached as expectPass on the case for the runner).
case{
  name = "spray_pass_count_deficit",
  kind = "passCount",
  level = 0, max = 2, expectCount = 2,
}

case{
  name = "spray_pass_count_mod_once",
  kind = "passCount",
  level = 0, max = 1, expectCount = 1,
}

case{
  name = "spray_pass_target_mid",
  kind = "passTarget",
  pass = 1, passTotal = 2, max = 2, expectTarget = 1,
}

return F
