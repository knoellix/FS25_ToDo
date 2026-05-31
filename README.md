# FS25_FieldToDoList

**To-Do and field work list** for Farming Simulator 25 — track your own tasks, see what to do next on each owned field, optional Precision Farming and Seasonal Crop Stress columns.

**Author:** Christian Möllmann ([knoellix](https://github.com/knoellix))  
**License:** [GNU GPL v3](LICENSE)  
**Version:** `0.1.0.5` (pre-release)

## Features

- **ESC menu** (dedicated tab): manual to-dos on the left, owned fields with crop status and suggested work on the right
- **In-world HUD:** `Left Ctrl + F5` — compact list of open tasks (top right, up to 5 entries)
- **Work order:** presets (e.g. plow → lime → sow → fertilize) and **alternating manure/slurry** for organic multi-pass spreading
- **Field workflow:** adopt suggestions, visit field (teleport), auto-complete when the game detects the job is done
- **List order:** `Hoch` / `Runter` mini buttons (`^` / `v`) move the selected task (no drag-and-drop in the Giants UI)
- **Done behavior:** completed tasks are grouped below open tasks; newly completed go to the top of the done group; max 10 completed (oldest pruned)
- **Selection UX:** after move, the moved task stays selected; after delete, selection is cleared
- **Harvest hints:** field suggestion column shows month labels instead of ambiguous month counts
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

1. Download `FS25_FieldToDoList.zip` from the [latest release](https://github.com/knoellix/FS25_FieldToDoList/releases/latest).
2. Copy the ZIP (**do not extract**) to your mods folder:


| Platform               | Path                                                                                                                          |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Windows                | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`                                                                 |
| macOS                  | `~/Library/Application Support/FarmingSimulator2025/mods/`                                                                    |
| Linux (Steam) | `~/.local/share/Steam/steamapps/compatdata/2300320/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/mods/` |

3. Enable **Field To-Do List** in the in-game mod manager.
4. Load any career save — the mod activates automatically on load.
5. **Restart the game completely** after installing or updating the mod.

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

Search for `[FS25_FieldToDoList] DUMP`. Useful lines: `meadowPhase`, `grassResidue`, `grassCrossScan`, `heightReader`, `harvestState`, `aggregation`.

Example:

```text
ftdlDump 63
```

No auto-dump on menu open — commands are manual only.

## Contributing

Contributions are welcome (bugfixes, features, translations).

- Start here: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Translation workflow: [Open translation issue](https://github.com/knoellix/FS25_FieldToDoList/issues/new?template=translation.yml)
- General bugs/features: [GitHub Issues](https://github.com/knoellix/FS25_FieldToDoList/issues)

## Issues

Use issue templates for bug reports, feature requests, and translations:
[GitHub Issues](https://github.com/knoellix/FS25_FieldToDoList/issues)

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes.

**0.1.0.5** — incremental field scan and scan status; multi-probe field advisor (crop, growth, harvest, grass logistics); windrow/residue detection; menu and task-list performance; targeted row refresh and 15 s passive rescan.

## Current Work In Progress

- Auto-completion still needs broader real-save testing (especially organic multi-pass and mod fruits).
- Optional mod columns (Seasonal Crop Stress) remain partial.

## License

Copyright (C) 2026 Christian Möllmann (knoelliX).  
Released under the GNU General Public License v3 — see [LICENSE](LICENSE).