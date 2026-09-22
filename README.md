# FS25_FieldToDoList

**To-Do and field work list** for Farming Simulator 25 — track your own tasks, see what to do next on each owned field, optional Precision Farming and Seasonal Crop Stress columns.

**Author:** Christian Möllmann ([knoellix](https://github.com/knoellix))  
**License:** [GNU GPL v3](LICENSE)  
**Version:** `0.1.0.14`
**Repository:** [github.com/knoellix/FS25_ToDo](https://github.com/knoellix/FS25_ToDo)

## Features

- **ESC menu** (dedicated tab): manual to-dos on the left, owned fields with crop status and suggested work on the right
- **In-world HUD:** `Left Ctrl + F5` — compact list of open tasks (top right, up to 5 entries)
- **Work order:** presets (e.g. plow → lime → sow → fertilize) and **alternating manure/slurry** for organic multi-pass spreading
- **Field workflow:** adopt suggestions, visit field (teleport), auto-complete when the game detects the job is done
- **List order:** `Hoch` / `Runter` mini buttons (`^` / `v`) move the selected task (no drag-and-drop in the Giants UI)
- **Done behavior:** completed tasks are grouped below open tasks; newly completed go to the top of the done group; max 10 completed (oldest pruned)
- **Selection UX:** after move, the moved task stays selected; after delete, selection is cleared
- **Planned crop:** set per field (**Plan** column / **Planned crop** button) — sow suggestions with crop name and sow month; **Farmyard** skips field scans
- **Harvest column:** status only (Growing, Regrowth, Mow …); **harvest month** in the suggestion column
- **Straw bales:** press/collect on cereal stubble (type-aware auto-complete)
- **Field overview:** multi-probe classification (crop, growth, harvest month, grass logistics) — not a single center sample
- **Grass logistics:** post-mow chain (swath → collect / bale → bale collect) from live residue signals
- **Save data:** `fieldToDoList.xml` in the savegame folder (tasks debounced ~2 s after edits; settings saved immediately)
- **Field status:** live ground/crop readout from the game (the mod does not read `fields.xml` at runtime — avoids save-file conflicts while the game is running)
- **Grass meadows:** mow when ready; post-mow hints for swath/collect/bale; avoids suggesting sow on grass

## Optional mods


| Mod                                                                                       | Status                                                                                 |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| FS25_precisionFarming                                                                     | Supported — pH / nitrogen columns when PF is loaded                                    |
| [FS25_SeasonalCropStress](https://github.com/TheCodingDad-TisonK/FS25_SeasonalCropStress) | Partial / limited — moisture and stress columns may show `-` or loading; no full runtime integration yet |


Works fully without add-ons using base game field data.

## Installation

1. Download `FS25_FieldToDoList.zip` from the [latest release](https://github.com/knoellix/FS25_ToDo/releases/latest).
2. Copy the ZIP (**do not extract**) to your mods folder:

| Platform               | Path                                                                                                                          |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Windows                | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`                                                                 |
| macOS                  | `~/Library/Application Support/FarmingSimulator2025/mods/`                                                                    |
| Linux (Steam) | `~/.local/share/Steam/steamapps/compatdata/2300320/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/mods/` |

3. Enable **Field To-Do List** in the in-game mod manager.
4. Load any career save — the mod activates automatically on load.
5. **Restart the game completely** after installing or updating the mod.

**Windows auto-update helper (optional):** download [`tools/Update-FS25_FieldToDoList.bat`](tools/Update-FS25_FieldToDoList.bat) only and double-click it. It compares your local zip with the latest GitHub release and replaces it when newer. Edit `MODS_DIR` at the top of the `.bat` if your mods path differs from the default Documents path.

## Development

Build from source and install to your local mods folder:

```bash
python3 tools/generate_assets.py   # optional if DDS assets are missing
./build.sh
```

Default target (Linux Steam):
`~/.local/share/Steam/steamapps/compatdata/2300320/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/mods/FS25_FieldToDoList.zip`

Custom target:

```bash
FS25_MODS_DIR=/path/to/mods ./build.sh
```

## Debug (field advisor)

Works on **Windows, macOS, and Linux**. Use when a field shows wrong crop, harvest month, or grass logistics in the overview.

| Input | Action |
| ----- | ------ |
| **F9** or **Left Ctrl + F9** | Open Giants dev console, or mod fallback dialog if console is unavailable |
| `ftdlHelp` | List mod debug commands |
| `ftdlDump 63` | Dump one field (replace `63` with field ID) to `log.txt` |
| `ftdlFruits` | Dump fruit types and harvest growth states |
| `ftdlAll` | Dump all owned fields |

**Log file** (`log.txt` in your FS25 user folder):

| Platform | Path |
| -------- | ---- |
| Windows | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\log.txt` |
| macOS | `~/Library/Application Support/FarmingSimulator2025/log.txt` |
| Linux (Steam) | `~/.local/share/Steam/steamapps/compatdata/2300320/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/log.txt` |

Search for `[FS25_FieldToDoList] DUMP`. Useful lines: `meadowPhase`, `grassResidue`, `baleCoverage`, `weedCoverage`, `harvestState`, `aggregation`.

Example:

```text
ftdlDump 63
```

No auto-dump on menu open — commands are manual only.

## Releases

Tagged releases build `FS25_FieldToDoList.zip` via GitHub Actions (`ubuntu-latest`). See [`docs/RELEASE.md`](docs/RELEASE.md) for the pre-tag checklist and manual fallback.

## Contributing

Contributions are welcome (bugfixes, features, translations).

- Start here: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Translation workflow: [Open translation issue](https://github.com/knoellix/FS25_ToDo/issues/new?template=translation.yml)
- General bugs/features: [GitHub Issues](https://github.com/knoellix/FS25_ToDo/issues)

## Issues

Use issue templates for bug reports, feature requests, and translations:
[GitHub Issues](https://github.com/knoellix/FS25_ToDo/issues)

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes.

**0.1.0.14** — MP edit via `manageContracts` (sync v5); grass/lucerne standing vs post-mow recognition; HUD schema + auto-complete crash fixes.
**0.1.0.13** — grass≠lucerne / mow ≥98% coverage; fertilize via sprayLevel without PF; logo/menu icon refresh.
**0.1.0.12** — dedicated MP: adopt/field-todo farmId on notify (schema v4); list Hof/Windrad parcels; restore ESC worker grants.
**0.1.0.11** — grass scan reentrancy fix; visible sync deny + list refresh; `ftdlSync`/`ftdlOwned`; Farm.PERMISSION registration attempt.
**0.1.0.10** — dedicated MP: honor `defaultAllow` without uniqueUserId; farm User-id extract; register `todoEditDefaultAllow` schema.

**0.1.0.9** — per-user online edit grants, ESC tab scroll (ensure-visible + mouse wheel).

**0.1.0.8** — multiplayer live To-Do sync + farm edit permissions, vanilla FS25 green UI, tab under Map.

## Known limitations

Full regression checklist: [`docs/REGRESSION.md`](docs/REGRESSION.md). Architecture: [`docs/FIELD_PHASE.md`](docs/FIELD_PHASE.md).

| Area | Works | Manual / not detectable |
| ---- | ----- | ----------------------- |
| **Grass after mowing** | Bale press/collect (auto via field bales) | Loose swath/hay on ground not readable → swath/loader steps are reminders only |
| **Straw after harvest** | Straw bale detect, press/collect (auto via STRAW bales) | Loose straw not readable → press step completes only when bales appear |
| **Mulching** | Suggestion after harvest (optional menu toggle) | No readable mulched state → never auto-completed |
| **Weeds** | Hoe/spray, done when dead (coverage) | — |
| **Custom fields** | Owned farmland without engine field ID (pseudo-fields) | Only when field center shows field ground |
| **Planned crop / farmyard** | Sow month in suggestions; farmyard = no field scan | Planned crop does not replace the current crop column |
| **Multiplayer** | Live sync for same-farm To-Dos, settings, and planned crop; edit gate (managers always, workers via setting); auto-complete for all farm members | Custom Vanilla farm permission UI out of scope |

Debug: `ftdlDump <fieldId>` — line `baleCoverage: total/straw/grass/other` for bale diagnosis.

## License

Copyright (C) 2026 Christian Möllmann (knoelliX).  
Released under the GNU General Public License v3 — see [LICENSE](LICENSE).