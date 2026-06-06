# Changelog

All notable changes to **FS25_FieldToDoList** are documented here.

## [0.1.0.6] — 2026-06-06

### Added

- **Planfrucht pro Feld:** Spalte „Plan“, Button/ Klick **Planfrucht** — manuelle Wahl der Sä-Frucht (inkl. Luzerne/Klee), persistent im Savegame; Säen-Vorschläge und To-Dos mit Fruchtname und **Sä-Monat** (`getIsPlantableInPeriod`).
- **Hof-Kennzeichnung:** Planfrucht **Hof** für Grundstücke mit Hof/Halle/Tierhaltung — kein Schwergewichts-Scan, kein Auto-Erledigen-Probe-Loop; Vorschlag „Hof“.
- **Stroh-Logistik:** Strohballen erkennen (FillType STRAW), Aktionen `straw_bale` / `straw_bale_collect` auf Acker-Stoppeln; typ-bewusstes Auto-Erledigen.
- **Mulchen:** optionaler Arbeitsschritt nach Ernte (Menü-Schalter, manuell).
- **Eigene Grundstücks-Felder:** Pseudo-Felder für gekauftes Ackerland ohne Engine-Feld-ID (immer aktiv).

### Improved

- **Ernte-Spalte vs. Vorschlag:** Spalte „Ernte“ nur noch Status (Wächst, Nachwuchs, Mähen, Stoppeln …); **Ernte-Monat** (`Ernte Okt`) in der Vorschlags-Spalte, ggf. vor Arbeitsschritten (`Ernte Okt → Striegeln …`).
- **Ballen-Auto-Erledigen:** `grass_bale_collect` zählt nur Gras-/Silageballen; Scheunen-Ballen nicht mehr dem Feld zugeordnet (Polygon zuerst, keine areaHa-Raten-Box).
- **Feldübersicht-Layout:** Spalten nach Planfrucht-Einführung korrigiert (pH/N/Wechseln/Vorschlag); Precision-Farming-Spalten überlappen nicht mehr.
- **Gras-Rest:** Ballen-basierte Logik (Density-Map-Residue-Detektion entfernt); ehrliche manuelle Erinnerungen für Schwaden/Ladewagen.
- **Unkraut-Advice:** eine Entscheidungsfunktion (`WeedAdvice.deriveWeedAdvice`); Spray nur ab Stufe 3 / 10 % Druck.
- **Feldphase:** `FieldPhase.deriveFieldPhase` (headless getestet); Konsolidierung Advisor (Gras-Phase, Mulch, Stoppel-Frucht `-`).

### Fixed

- Planfrucht-Dialog: `table: 0x…` Untertitel (OptionDialog zweites Argument `nil`).
- Ballen einsammeln blieb offen, obwohl nur Gras-Ballen weg waren (gemischte Ballen auf Grasfeldern).
- Frisch gepflügtes Leerboden zeigte stale Frucht-ID (z. B. Erbsen auf Feld 72).
- Luzerne/Klee nach Nachwuchs fälschlich als „gemäht“ / erneut Mähen-Vorschlag.

### Known limitations

- Lose Schwaden/Heu und loses Stroh am Boden nicht sensierbar — nur Ballen-Objekte für Auto-Erledigen.
- Mulchen und Gras-Schwaden/Ladewagen: manuelle Erinnerungen, kein Auto-Erledigen.
- Seasonal Crop Stress: Spalten optional, nicht voll integriert.

## [0.1.0.5] — 2026-05-30

### Added

- **Incremental field overview scan:** all owned fields appear immediately with `…` placeholders, then fill in batch-by-batch while the ESC tab is open.
- **Scan status indicator:** yellow blinking dot next to „Feldübersicht“ / „Field overview“ while scanning; solid green when done (tooltip shows progress, e.g. `12/45`).
- **Event-driven refresh:** `FINISHED_GROWTH_PERIOD` and `FARMLAND_OWNER_CHANGED` mark the overview stale (immediate rescan if tab open).
- Scan start/complete lines in `log.txt` (`FieldToDoLog.info`).

### Improved

- Field overview **performance:** lighter 3×3 probe grid for display (5×5 kept for auto-complete); probe aggregation, fruit-name, and completion fingerprint caches.
- **Auto-complete → overview sync:** when a field task is marked done, only that field row is re-read (`refreshFieldRecordSync`) — no wait for a full rescan.
- Passive full rescan while menu open: **5 s → 15 s** (enough for fields without open tasks).
- **Multi-probe field advisor:** dominant situation + representative state from a 3×3 grid; fruit, growth, and harvest labels share one path (`buildFieldLabels`).
- **Growth column:** overview growth state comes from the same harvest projection as suggestions (not a separate center-only read).
- **Grass / meadow logistics:** post-mow residue chain (loose → swath → collect / bale → bale collect) uses live height-map and windrow signals; permissive inside-field checks when the engine polygon test returns false.
- **Luzerne / clover / alfalfa:** after mow, swath/collect hints instead of a misleading next-harvest month while logistics are pending.
- **Harvest projection:** effective growth state for withered crops; calendar month clamped 1–12; non-seasonal period estimate without max-harvest-state fallback.
- **Engine API hardening:** shared `getFieldCenterWorldPosition` (pcall) across advisor, scanner, visit, PF/SCS readers, debug dump, and completion baselines; `g_fieldManager.getFields` guarded.
- **Task list UX:** `Hoch` / `Runter` refreshes order without full SmoothList reload; open ↔ done toggle triggers partition reload.
- **Menu performance:** `onFrameUpdate` runs only while the Field-To-Do ESC tab is visible (scan still ticks in the background).
- **Debug dump:** harvest projection lines use `harvestState` (aligned with in-game advisor).

### Fixed

- Field list stuck on `…` placeholders (deferred reload no longer invalidates scan cache every 500 ms; `reloadData()` instead of `reloadVisibleItems()` on scan progress).
- Overview scan not advancing when ESC tab was open (scan tick + UI sync wiring).
- Scan reset loop when growth/ownership events fired during incremental scan; UI sync no longer depends on fragile page-visibility checks (`ownedFieldsScanActive` + direct list sync after tick).
- **Swath regression:** clover/lucerne after mow showed harvest window instead of swath/collect when strict inside-field tests returned false.
- **Plowed empty fields** (e.g. field 14): no longer labeled „Gras“; lone bare center no longer overrides a grass/arable majority.
- **Weed done rule:** `weedState <= 0` no longer counts as dead/sprayed coverage.
- **Auto-complete ground ratio:** correct `FieldGroundType.getValueByType` usage; numeric area coercion.
- **Aggregation cache:** invalidates when center probe situation changes; `SOWN` / `PLANTED` / `RIDGE_SOWN` treated as non-grass ground; early grid exit requires ≥2 edge probes.
- **Field scanner:** normalized rows use advisor labels only (no stale `getFruitName` / `getGrowthLabel` fallback); placeholder records keep field name.
- **Grass fruit labels:** resolve from probe aggregation + refine path instead of generic „Gras“ early return.

### Known limitations

- Auto-completion still work in progress; needs more testing on real savegames and mod fruits.
- Field worked **without** an open task may take up to ~15 s to refresh in the overview while the menu stays open.

## [0.1.0.4] — 2026-05-29

### Added

- **Debug tooling:** hotkey **F9** (or **Left Ctrl + F9**) — works on Windows, macOS, and Linux; opens a fallback dialog when the native dev console is unavailable.
- Console commands: `ftdlDump <fieldId>`, `ftdlFruits`, `ftdlAll`, `ftdlHelp` — output goes to `log.txt` (`[FS25_FieldToDoList] DUMP …`).
- Grass residue **cross scan** (full E–W and N–S bars through field center) to detect narrow swath lines.

### Improved

- Field advisor: harvest month from **center probe** (fixes wrong months for maize, edge strips, etc.).
- Luzerne/clover/alfalfa: correct crop labels and post-mow **„Nachwuchs“** instead of misleading „Wächst“ / harvest month while logistics are pending.
- Weed tasks: **≤ 5 % live weed** on classified probes → treated as done (dead/sprayed coverage).
- Grass logistics: fallback when `DensityMapHeightUtil` global is missing (engine height map + field signals).
- Task list: **↑ / ↓** icon buttons with tooltips; menu/residue scan performance tuning.

### Fixed

- Plowed empty fields no longer shown as grass; plow completion aligned with `needsPlowing`.
- Field overview / HUD stability (cache timing, selection sync, no completed-task HUD fallback).

### Known limitations

- Grass swath → collect/bale chain still being tuned (residue detection varies by map and engine APIs); use `ftdlDump` for diagnosis.

## [0.1.0.3] — 2026-05-27

### Improved

- Field crop and ground detection uses live `FieldState` samples (more reliable than stale cached values).
- Grass/meadow handling: mow when harvest-ready; clearer post-mow hints (swath, collect, bale); reduced false “sow” on meadows.
- Plowed/cultivated ground is prioritized over leftover grass metadata in the fruit column.

### Fixed

- Field overview stability (no runtime read of savegame `fields.xml` — avoids save corruption risk).
- Lua compatibility fix that could hide all owned fields in the overview.

### Docs

- `CONTRIBUTING.md`, translation issue template, README updates.
- Repository renamed to `FS25_FieldToDoList` on GitHub.

### Known limitations

- Auto-completion still work in progress; needs more testing on real savegames.
- Some edge cases in grass classification after soil work may still need tuning.

## [0.1.0.2] — earlier pre-release

- Previous public pre-release on GitHub.

## [0.1.0.1] — earlier pre-release

- Initial public pre-release: ESC to-do list, field overview, HUD, work-order presets, PF/SCS columns (limited), grass-aware suggestions.

[0.1.0.5]: https://github.com/knoellix/FS25_FieldToDoList/compare/v0.1.0.4...v0.1.0.5
[0.1.0.4]: https://github.com/knoellix/FS25_FieldToDoList/compare/v0.1.0.3...v0.1.0.4
[0.1.0.3]: https://github.com/knoellix/FS25_FieldToDoList/compare/v0.1.0.2...v0.1.0.3
[0.1.0.2]: https://github.com/knoellix/FS25_FieldToDoList/releases/tag/v0.1.0.2
