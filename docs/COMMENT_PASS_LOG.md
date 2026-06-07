# Kommentar-Durchgang (Phase 4)

Methode: Blockweise **lesen**, nicht Regex-Massenersetzung. Siehe `CONSOLIDATION_AND_NAMING_PLAN.md` § Phase 4.

## FieldAdvisor.lua

| Block | Zeilen | Geändert | Entfernt | Offen |
|-------|--------|----------|----------|-------|
| 1/4 | 1–820 | 3 (Pipeline-Header, buildFieldContext-Bale-Hinweis, mapFieldPhaseToCropPhase doc) | 0 | keine |
| 2/4 | 821–2000 | 0 | 0 | keine — classifyProbe/Unkraut-Proben/Kalk-Kommentare geprüft, inhaltlich korrekt |
| 3/4 | 2001–4200 | 2 (grass residue header, addGrassWorkActions cut-Zweig) | 0 | keine — Unkraut/Coverage/Ballen/Stroh-Scan geprüft |
| 4/4 | 4201–EOF | 1 (buildFieldContext grassResidue-Kommentar) | 0 | keine — Gras-Frucht-Auflösung, Phase-Builder, resolveActionCandidates geprüft |

### Block 3/4 (Zeilen 2001–4200) — 2026-06-06

- **Geändert:** Gras-Residue-Konstanten-Kommentar (Liter-API wie Stroh).
- **Geändert:** `addGrassWorkActions` cut-Zweig — veralteter „nicht sensierbar“-Block entfernt, SWATH-Zweig dokumentiert.
- **Geprüft, belassen:** `sampleWeedCoverage`, `isWeedTaskDoneByCoverage`, Coverage-Cache, `deriveStrawResidueSummary`, Ballen-Sampling.

### Block 4/4 (Zeilen 4201–EOF) — 2026-06-06

- **Geändert:** `buildFieldContext` — grassResidue-Sampling-Kommentar + `hasPostMowSignal`-Gate.
- **Geprüft, belassen:** Gras-Frucht-Scoring, `inferGrassFruitTypeFromWindrowFill`, `PHASE_ACTION_BUILDERS`, `resolveActionCandidates` Reconciliation.

### Block 1/4 (Zeilen 1–820) — 2026-06-04

- **Geändert:** Datei-Header um 5-Zeilen-Pipeline-Kommentar ergänzt (Schichten + Verweis FIELD_PHASE/AUDIT).
- **Geändert:** `mapFieldPhaseToCropPhase` — doppelte/verschobene `---@param`-Blöcke bereinigt.
- **Geändert:** `buildFieldContext` — Kommentar zu Gras-Rest vs. Stroh-Ballen-Sampling präzisiert.
- **Geprüft, belassen:** `classifyProbe`-Schichten (arable/bare/grass), Unkraut-Konstanten (WEED_STATE_DEAD_MIN), Residue-Konstanten (LOOSE/SWATH legacy, nur NONE/BALED produziert).
- **Offen:** keine in diesem Block.

## scripts/ (jede Datei — Pflicht)

| Datei | Kommentare | Namen | Status |
|-------|------------|-------|--------|
| FieldTaskCompletion.lua | REGISTRY grass/straw auto-complete vs suggestions (2026-06-06) | — | geprüft |
| FieldWorkCatalog.lua | grass_swath/collect + straw Liter/Ballen (2026-06-06) | — | geprüft |
| FieldScanner.lua | Header incremental scan vs full scan (2026-06-06) | — | geprüft |
| ToDoManager.lua | Zwei Update-Pfade + refreshFieldRecordSync (2026-06-06) | — | geprüft |
| InGameMenuIntegration.lua | onFrameUpdate-Weiterleitung (2026-06-06) | — | geprüft |
| FieldToDoHudOverlay.lua | Header ok | — | geprüft |
| FieldToDoHudInput.lua | Header ok | — | geprüft |
| FieldActionPicker.lua | Header ok | — | geprüft |
| FieldAdvisorSettings.lua | Header ok | — | geprüft |
| FieldGameRules.lua | Header ok | — | geprüft |
| FieldVisit.lua | Header ok | — | geprüft |
| FieldDebugDump.lua | grassResidue dump-Kommentar (2026-06-06) | — | geprüft |
| FieldDebugConsole.lua | Header ok | — | geprüft |
| FieldDebugConsoleInput.lua | Header ok | — | geprüft |
| FieldToDoLog.lua | Header ok | — | geprüft |
| FieldToDoL10n.lua | Header ok | — | geprüft |
| FieldSavegameReader.lua | ENABLE_DISK_READ/defer ok | — | geprüft |
| PrecisionFarmingReader.lua | Header ok | — | geprüft |
| PrecisionFarmingBridge.lua | Header ok | — | geprüft |
| SeasonalCropStressReader.lua | Header ok | — | geprüft |
| FieldPhase.lua | Header + pure module ok | — | geprüft |
| WeedAdvice.lua | Kanon-Kommentar ok | — | geprüft |
| FieldPlannedCrop.lua | FARMYARD ok | — | geprüft |

## gui/

| Datei | Kommentare | Namen | Status |
|-------|------------|-------|--------|
| FieldToDoMenuFrame.lua | 3/3 Blöcke (s. unten) | — | geprüft |

### FieldToDoMenuFrame.lua

| Block | Zeilen | Geändert | Offen |
|-------|--------|----------|-------|
| 1/3 | 1–430 | Header, syncOwnedFieldsFromScan, onFrameUpdate | keine |
| 2/3 | 431–1100 | refreshLists doc, task tag, adopt allowUntrackable | keine |
| 3/3 | 1101–EOF | Einrückung SmoothList/moveTask; OptionDialog-Kommentare geprüft | keine |

- **Geändert (2026-06-06):** „cannot be sensed“ → auto/manuell-Trennung (populateCell, onClickAdoptFieldSuggestion).
- **Geändert:** `refreshLists` — invalidate=false vs. Scan-Reset dokumentiert.
- **Geprüft, belassen:** SCS-Spalten-Live-Sample, suggestion cycle, task selection by id, planned crop refreshFieldRecordSync.

## translations/

| Datei | Status |
|-------|--------|
| translation_de.xml | Keys grass/straw/scan ok | geprüft |
| translation_en.xml | Keys grass/straw/scan ok | geprüft |

## Docs (Kommentar-Konsistenz)

| Datei | Änderung |
|-------|----------|
| FIELD_PHASE.md | Gras-Residue facts/phases auf Liter+Ballen (2026-06-06) |
| AUDIT_INVENTORY.md | §E deriveGrassResidueSummary Kanon-Beschreibung |

## Phase 5 — Naming (2026-06-06)

| Aktion | Details |
|--------|---------|
| Umbenannt | `shouldTrackArableWeed` → `isArableWeedSamplingContext` (Sampling-Gate, kein Advice-Entscheider) |
| Dokumentiert | `hasActiveCrop` / `isFieldSown` / `isFieldUnsown` = Readout, nicht Phase |
| Dokumentiert | `getCropPhase` = Legacy-UI-Fassade über `deriveFieldPhase` |
| Glossar | `AUDIT_INVENTORY.md` § Naming-Glossar |
| API-Tabelle | `FIELD_PHASE.md` § Öffentliche API |
| Bewusst nicht umbenannt | `getCropPhase` (viele Aufrufer, Rolle klar); `fieldNeedsWeed*` (etablierte Wrapper-Namen) |
