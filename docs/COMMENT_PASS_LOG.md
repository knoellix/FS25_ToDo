# Kommentar-Durchgang (Phase 4)

Methode: Blockweise **lesen**, nicht Regex-Massenersetzung. Siehe `CONSOLIDATION_AND_NAMING_PLAN.md` § Phase 4.

## FieldAdvisor.lua

| Block | Zeilen | Geändert | Entfernt | Offen |
|-------|--------|----------|----------|-------|
| 1/4 | 1–820 | 3 (Pipeline-Header, buildFieldContext-Bale-Hinweis, mapFieldPhaseToCropPhase doc) | 0 | keine |
| 2/4 | 821–2000 | 0 | 0 | keine — classifyProbe/Unkraut-Proben/Kalk-Kommentare geprüft, inhaltlich korrekt |
| 3/4 | 2001–4200 | | | |
| 4/4 | 4201–EOF | | | |

### Block 1/4 (Zeilen 1–820) — 2026-06-04

- **Geändert:** Datei-Header um 5-Zeilen-Pipeline-Kommentar ergänzt (Schichten + Verweis FIELD_PHASE/AUDIT).
- **Geändert:** `mapFieldPhaseToCropPhase` — doppelte/verschobene `---@param`-Blöcke bereinigt.
- **Geändert:** `buildFieldContext` — Kommentar zu Gras-Rest vs. Stroh-Ballen-Sampling präzisiert.
- **Geprüft, belassen:** `classifyProbe`-Schichten (arable/bare/grass), Unkraut-Konstanten (WEED_STATE_DEAD_MIN), Residue-Konstanten (LOOSE/SWATH legacy, nur NONE/BALED produziert).
- **Offen:** keine in diesem Block.

## scripts/ (jede Datei — Pflicht)

| Datei | Kommentare | Namen | Status |
|-------|------------|-------|--------|
| FieldTaskCompletion.lua | Pipeline-Header (straw/point) | — | Block geprüft |
| FieldWorkCatalog.lua | | | |
| FieldScanner.lua | | | |
| ToDoManager.lua | | | |
| InGameMenuIntegration.lua | | | |
| FieldToDoHudOverlay.lua | | | |
| FieldToDoHudInput.lua | | | |
| FieldActionPicker.lua | | | |
| FieldAdvisorSettings.lua | | | |
| FieldGameRules.lua | | | |
| FieldVisit.lua | | | |
| FieldDebugDump.lua | | | |
| FieldDebugConsole.lua | | | |
| FieldDebugConsoleInput.lua | | | |
| FieldToDoLog.lua | | | |
| FieldToDoL10n.lua | | | |
| FieldSavegameReader.lua | | | |
| PrecisionFarmingReader.lua | | | |
| PrecisionFarmingBridge.lua | | | |
| SeasonalCropStressReader.lua | | | |

## gui/

| Datei | Kommentare | Namen | Status |
|-------|------------|-------|--------|
| FieldToDoMenuFrame.lua | | | |

## translations/

| Datei | Status |
|-------|--------|
| translation_de.xml | |
| translation_en.xml | |
