-- Pure HUD layout cases (no FS runtime).
return {
  {
    name = "clamp_keeps_panel_on_screen",
    panelX = 0.95,
    panelY = -0.1,
    panelW = 0.168,
    panelH = 0.08,
    margin = 0.01,
    expectXMin = 0.01,
    expectXMax = 0.99 - 0.168,
    expectYMin = 0.01,
    expectYMax = 0.99 - 0.08,
  },
  {
    name = "header_is_top_strip",
    panelX = 0.5,
    panelY = 0.4,
    panelW = 0.2,
    panelH = 0.1,
    headerH = 0.022,
    expectHeaderY = 0.4 + 0.1 - 0.022,
  },
  {
    name = "row1_below_header",
    panelX = 0.5,
    panelY = 0.4,
    panelW = 0.2,
    panelH = 0.1,
    headerH = 0.022,
    rowH = 0.020,
    rowIndex = 1,
    -- listTopY = panelY + panelH - headerH; rowY = listTopY - rowIndex * rowH
    expectRowY = (0.4 + 0.1 - 0.022) - 0.020,
  },
  {
    name = "point_in_header",
    px = 0.51,
    py = 0.4 + 0.1 - 0.011,
    rect = { x = 0.5, y = 0.4 + 0.1 - 0.022, w = 0.2, h = 0.022 },
    expectInside = true,
  },
  {
    name = "drag_threshold_constant",
    expectThreshold = 0.005,
  },
}
