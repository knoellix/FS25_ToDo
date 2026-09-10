return {
  {
    name = "workers_on_non_manager_can_edit",
    workersMayEdit = true,
    isManager = false,
    sameFarm = true,
    expect = { edit = true, changeSetting = false, autoComplete = true },
  },
  {
    name = "workers_off_non_manager_cannot_edit",
    workersMayEdit = false,
    isManager = false,
    sameFarm = true,
    expect = { edit = false, changeSetting = false, autoComplete = true },
  },
  {
    name = "workers_off_manager_can_edit_and_setting",
    workersMayEdit = false,
    isManager = true,
    sameFarm = true,
    expect = { edit = true, changeSetting = true, autoComplete = true },
  },
  {
    name = "other_farm_denied",
    workersMayEdit = true,
    isManager = true,
    sameFarm = false,
    expect = { edit = false, changeSetting = false, autoComplete = false },
  },
}
