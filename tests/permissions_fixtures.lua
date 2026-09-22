return {
  {
    name = "sp_member_always_edit",
    isMultiplayer = false,
    manageContracts = false,
    sameFarm = true,
    expect = { edit = true, manageGrants = false, autoComplete = true },
  },
  {
    name = "mp_manageContracts_can_edit",
    isMultiplayer = true,
    manageContracts = true,
    sameFarm = true,
    expect = { edit = true, manageGrants = false, autoComplete = true },
  },
  {
    name = "mp_no_manageContracts_cannot_edit",
    isMultiplayer = true,
    manageContracts = false,
    sameFarm = true,
    expect = { edit = false, manageGrants = false, autoComplete = true },
  },
  {
    name = "mp_other_farm_denied",
    isMultiplayer = true,
    manageContracts = true,
    sameFarm = false,
    expect = { edit = false, manageGrants = false, autoComplete = false },
  },
  {
    name = "mp_no_contracts_still_autocomplete",
    isMultiplayer = true,
    manageContracts = false,
    sameFarm = true,
    expect = { edit = false, manageGrants = false, autoComplete = true },
  },
}
