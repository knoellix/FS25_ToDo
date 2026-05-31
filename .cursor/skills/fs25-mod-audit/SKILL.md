---
name: fs25-mod-audit
description: >-
  Code-Audit für die Mod FS25_FieldToDoList (Giants/FS25 Lua).
  Prüft Runtime-Sicherheit, Engine-API-Korrektheit, Feld-/Frucht-Klassifikation,
  Ernte-/Wachstumslogik, Unkraut-/Gras-Logistik und UI/HUD-Verhalten – verteilt
  auf parallele Subagenten. Verwende dieses Skill, wenn der User die Mod (oder
  Teile davon) auditieren, prüfen, reviewen, checken oder "drüberschauen" will.
---

# FS25_FieldToDoList – Audit-Koordinator

Dieses Skill koordiniert ein strukturiertes Audit der Mod. Es delegiert die
Prüf-Dimensionen an **parallele, readonly Subagenten** (`Task`, `subagent_type: explore`)
und fasst deren Befunde zu einem Report zusammen.

**Quelle der Wahrheit:** `.cursor/rules/fs25-project-memory.mdc` — bei Widersprüchen
zwischen diesem Skill und den Projektregeln gelten die Regeln.

## Wann verwenden
- Voll-Audit der Mod oder eines geänderten Bereichs (z. B. nach einem Refactor).
- Wenn der User „audit / prüfen / review / check / schau mal drüber" zur Mod sagt.

## Scope festlegen (zuerst)
1. **Voll-Audit** (Standard): alle Dimensionen, ganzer `scripts/` + `gui/`.
2. **Diff-Audit**: nur geänderte Dateien. Erst `git status` + `git diff` lesen,
   den Subagenten nur die betroffenen Dateien/Funktionen als Fokus geben.

Wenn unklar, kurz per `AskQuestion` fragen (Voll vs. Diff). Sonst Voll-Audit.

## Pflichtkontext für jeden Subagenten
Jeder Subagent ist readonly und bekommt im Prompt mit:
- Projekt-Memory: `.cursor/rules/fs25-project-memory.mdc` (zuerst lesen).
- Sein Dimensions-Fokus (siehe unten) + die konkret zu prüfenden Dateien.
- Auftrag: **nur Befunde melden** (Datei:Zeile, Schweregrad, kurze Begründung,
  konkreter Fix-Vorschlag). Keine Änderungen vornehmen.

## Ablauf
1. **Init**: `.cursor/rules/fs25-project-memory.mdc` lesen, bei Diff-Audit `git diff`.
2. **Delegation (parallel)**: Die 6 Dimensions-Subagenten in **einer** Nachricht
   starten (`run_in_background: true`, `readonly: true`, `subagent_type: explore`).
3. **Zusammenführen**: Befunde deduplizieren, nach Schweregrad sortieren, Report bauen.
4. **Abschluss**: Report ausgeben, Rückfrage zum Beheben (siehe Report-Format).

Kleines Diff-Audit (1–2 Dateien)? Dann ohne Subagenten direkt prüfen.

---

## Dimensionen (je 1 Subagent)

### 1. Runtime-Sicherheit (Lua 5.1)
Dateien: alle `scripts/*.lua`, v. a. `FieldSavegameReader.lua`, `ToDoManager.lua`,
`SeasonalCropStressReader.lua`, `InGameMenuIntegration.lua`, `gui/FieldToDoMenuFrame.lua`.
- Kein `goto` / `::label::` (Giants-Runtime ist Lua-5.1-Stil → Datei lädt sonst nicht).
- Kein Laufzeit-Lesen von `savegame*/fields.xml`: `FieldSavegameReader.ENABLE_DISK_READ`
  muss `false` bleiben; `deferReadsUntilGameplay` aktiv; Save/Load-Guards intakt.
- `deferDiskReads` nur clearen wenn `ENABLE_DISK_READ == true`.
- Keine SCS-Feldmap-Loops (`buildFieldMap`/`enumerateFields`) in Menü-/Update-Pfaden.
- Keine wiederholten/Schleifen-Datei-Reads in Menü-/Update-Pfaden; Live-`FieldState`/Engine bevorzugen.
- **Inkrementeller Feld-Scan:** kein synchrones Voll-`normalizeField` pro Menü-Refresh; Queue + Batch in `ToDoManager`.
- **`deferredListReload` darf den Feld-Cache nicht invalidieren** (`refreshLists(false)`); nur expliziter Rescan (z. B. 5 s) mit `refreshLists(true)`.
- Scan-Tick bei offenem Tab: `ToDoManager:tickOwnedFieldsScan(dt, 1)` in `ToDoManager:update` wenn `ownedFieldsScanActive`; UI-Sync zusätzlich aus `InGameMenu.update` / Menü-Frame — nicht ungebremst drainen.
- `Logging.info`/`Logging.warning` statt `print()` (besonders `InGameMenuIntegration`).
- Engine-Calls in `pcall`; keine harten Crashes bei `nil` Globals.
- Debug: **F9** / `ftdlDump` nur manuell — kein Auto-Dump in Menü-/Load-Pfaden.

### 2. Engine-API-Korrektheit
Fokus: jede Verwendung von FS-Globals/Manager-APIs.
- **Statische Funktionen ohne `self` aufrufen.** Z. B. `FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)`
  und `DensityMapHeightUtil.getFillLevelAtArea(...)` sind plain functions – NICHT
  `pcall(fn, util, x, z)` (das schiebt `util` als 1. Argument rein). Echte Bug-Klasse.
- Parallelogramm für `getFillLevelAtArea`: **6 Koordinaten** (x0,z0, x1,z1, x2,z2).
- Manager-Methoden mit `:`/self korrekt; `g_fruitTypeManager`/`g_fillTypeManager` nil-guarded.
- `rawget(_G, "FSDensityMapUtil")` vor optionalen Globals (kann nil sein).
- `DensityMapHeightUtil`-Calls in Proben-Loops mit `pcall` absichern.
- Rückgaben mit `tonumber`/Typprüfung absichern; `pcall`-`ok` auswerten.

### 3. Feld- & Frucht-Klassifikation
Dateien: `FieldAdvisor.lua` (`classifyProbe`, `aggregateFieldProbes`,
`resolveGrassFruitTypeIndex`, `refineGrassFruitTypeIndex`, `getFieldFruitDisplayLabel`,
`getLocalizedFruitTitle`), `FieldScanner.lua`.
- Mehrschichtig (`arable`/`grass`/`bare_soil`/`unknown`) auf Basis **mehrerer** Proben.
- **Zwei Probe-Rollen:** `representativeState` = höchstes Wachstum (Phase/Vorschläge);
  `harvestState` = **Feldmittelpunkt** für Ernte-Monat — nie max-Growth-Rand (Jul) oder
  min-Growth-Rand ohne Fruit (→ „Wächst“ ohne Prognose).
- Operator-Präzedenz bei `(worldX == nil or worldZ == nil) and …` — Klammern setzen.
- Dominanz bei Gleichstand deterministisch (Center-Tie-Break oder feste Priorität).
- Kein blind-grass-Fallback auf bearbeitetem Boden → Frucht `-` (Feld-14-Klasse).
- Spezifische Gras-Frucht (Luzerne/Klee) gewinnt vor generischem GRASS; bei
  `fieldHasPartialSoilWork` spezifischen Namen behalten, nicht „Gras (teilw. bearb.)“.
- `clearStaleGrassMetadata` muss Engine-Gras-Flags (`isGrass`/`isGrassCrop`) mit löschen.
- `FieldScanner:getFruitName` veraltet — Overview nutzt `buildFieldLabels`/`getFieldFruitDisplayLabel`.

### 4. Ernte- & Wachstumslogik
Dateien: `FieldAdvisor.lua` (`evaluateFruitGrowth`, `isCropHarvestReady`,
`getExpectedHarvestPeriod`, `getHarvestWindowHint`, `isFruitPrimaryHarvestInPeriod`,
`resolveHarvestFieldState`, `getCalendarMonthForSeasonPeriod`).
- Erntereife über `FruitTypeDesc`-APIs + min/max-Harvesting-Fallback.
- **Saison-Periode (1..12) ≠ Kalendermonat** — `getCalendarMonthForSeasonPeriod`
  (period 5=Jul, 8=Okt, …).
- Dual-window crops (maize): `getIsHarvestableInPeriod` allein reicht **nicht** —
  **`isFruitPrimaryHarvestInPeriod`** mit projiziertem Wachstum + **`getIsHarvestReady`**
  (nicht `getIsHarvestable` / Silage-Fenster). Bei `getIsHarvestReady`-API: kein
  `projectedGrowth <= 0` → true ohne Projection.
- ETA zielt auf **`minHarvestingGrowthState`** bzw. ersten `getIsHarvestReady`-State,
  nicht `maxHarvestingGrowthState` (tot/verdorrt).
- `isCropHarvestReady` saisonal: Primary-Harvest-Perioden-Check, nicht nur Silage-Fenster.
- Kein unsicherer Letztfallback `getNextHarvestablePeriod` ohne Growth-Projection.
- `getGrassHarvestWindowLabel` nutzt `resolveHarvestFieldState` (Center).
- `isWithered` → Pflügen/Walzen bleiben in Auto-Complete-Checks unfertig.

### 5. Unkraut & Gras-Logistik
Dateien: `FieldAdvisor.lua` (Weed-/Residue-Funktionen), `FieldTaskCompletion.lua`.
- `WEED_STATE_DEAD_MIN = 6`; Coverage-first wenn `weedSummary.classified > 0`.
- 5%-Regel: `WEED_LIVE_RATIO_DONE_THRESHOLD`; dead/live **exklusiv** pro Probe zählen.
- Mehrdeutige Proben (weder dead noch live) nicht künstlich „erledigt“ wirken lassen.
- `FieldTaskCompletion` Weed: bei Coverage nur `isWeedTaskDoneByCoverage`.
- Gras-Reststoff: `loose → swath → (collect/bale/silage) → bale_collect` aus Live-Daten.
- `DensityMapHeightUtil` nil: Residue-Tasks/Progress nicht als `NONE`=leer werten.
- `grass_swath` complete nur bei `SWATH`/`BALED`, nicht bei `NONE`.
- `hasCompletionProgress` für Gras: braucht `grassResidueSummary`/`baleSummary` im Context.
- Ballen nur innerhalb Feldpolygon; Auto-Complete = gleiche Signale wie Vorschläge.

### 6. UI / To-Do / HUD
Dateien: `gui/FieldToDoMenuFrame.lua` + `.xml`, `ToDoManager.lua`,
`FieldToDoHudOverlay.lua`, `FieldToDoHudInput.lua`.
- To-Do-Reihenfolge per `sortIndex` (User-Order), nicht Work-Order-Presets.
- Hoch/Runter: verschobene Task bleibt selektiert; nach Delete Selektion clearen.
- SmoothList-Reload-Guard (`ignoreTaskSelectionChanged`), Sync per Task-ID statt Row-Index.
- Mini-Button Hoch/Runter: Pfeil-Icons (↑/↓) mit L10n-Tooltip (`$l10n_ftdl_btn_up`/`down`), kein Drag-and-drop.
- HUD: nur **offene** manuelle Tasks (`getManualTasksForDisplay`), max 5 — kein Fallback auf erledigte.
- Offene Tasks über erledigten; erledigte cap 10; neueste erledigte oben.
- **Inkrementeller Feld-Scan (Performance):**
  - `setOwnedFieldsScanActive` on menu open/close; Scan-Tick in `ToDoManager:update` wenn Tab offen; UI-Sync via Menü-Frame/`syncFieldListFromScan`.
  - `syncOwnedFieldsFromScan` / `reloadData()` when scan dirty — not `reloadVisibleItems()` for placeholder → value updates.
  - `deferredListReload` → `refreshLists(false)` (must not call default invalidate every 500 ms).
  - Placeholders visible immediately; real labels fill batch-by-batch (not stuck on `...`, not instant full sync unless `getOwnedFields(true)`).

---

## Regression-Checkliste (nach Advisor-Refactor)
- Feld 14: frisch gepflügt leer → `-`, nicht Gras.
- Luzerne gemäht: kein erneutes Mähen; Label **Luzerne**, nicht „Gras (teilw. bearb.)“.
- Field 15 Körnermais (growth=1, April): **Ernte Okt**, nicht Jul / nicht nur „Wächst“.
- Field 9 gespritzter Weizen: Unkraut **tot**, keine Combat-Empfehlung bei ≤5 % live.
- Gras-Logistik: `loose → swath → collect/bale → bale_collect` konsistent.
- `ftdlDump` vs UI: Ernte-Monat muss übereinstimmen (Center-Probe).
- **Feldliste Menü:** Zeilen mit `...` füllen sich schrittweise (ca. 5 Felder / 40 ms, bis 2 Batches/Tick); kein Dauer-Reset beim Öffnen.

## Subagent-Prompt-Vorlage
Pro Dimension einen `Task` starten (parallel, readonly):

```
subagent_type: explore   readonly: true   run_in_background: true
description: "FS25 Audit: <Dimension>"
prompt:
  Readonly-Audit der Mod FS25_FieldToDoList in /mnt/Lager/github/LS_25_todo.
  1) Lies .cursor/rules/fs25-project-memory.mdc.
  2) Prüfe NUR Dimension <N: Name>. Relevante Dateien: <Liste>.
     Checkliste: <Punkte aus der Dimension>.
  3) Melde Befunde als Liste: <Datei>:<Zeile> | <🔴/🟠/🟡/⚪> | Problem | Fix-Vorschlag.
  Nimm KEINE Änderungen vor. Wenn ein Bereich sauber ist, melde "ok".
```

Bei Diff-Audit zusätzlich: „Beschränke dich auf diese geänderten Stellen: <Datei:Funktion>."

## Schweregrade
- 🔴 **Bug**: falsches Verhalten / Crash-/Save-Risiko (z. B. Runtime-`fields.xml`-Read,
  Static-Call mit `self`, Silage-Fenster als Körner-Ernte, `NONE`-Residue als complete).
- 🟠 **Risiko**: fragil / Regressionsgefahr (fehlender `pcall`, Loop-Reads in Menüpfad, Scan-Cache-Invalidierung in Poll-Loops, `reloadVisibleItems` statt `reloadData` beim Scan).
- 🟡 **Verbesserung**: Logik-/Lesbarkeits-Schliff, Doppelpfade.
- ⚪ **Hinweis**: Stil, Doku, Kleinigkeiten.

## Report-Format
```
# FS25_FieldToDoList – Audit (<Voll|Diff>)

## Zusammenfassung
<1–3 Sätze: Gesamtzustand, Anzahl je Schweregrad>

## Befunde
### 🔴 Bugs
- <Datei:Zeile> – <Problem> → <Fix>
### 🟠 Risiken
- ...
### 🟡 Verbesserungen
- ...
### ⚪ Hinweise
- ...

## Empfehlung
<Reihenfolge zum Beheben>
```
Beende mit: „Soll ich mit den 🔴 Bugs anfangen?"

## Build/Release-Hinweise (für Folge-Fixes)
- `modDesc.xml`-Version **nicht** ändern, außer der User will explizit ein Release.
- Lokaler Build: `python3 tools/generate_assets.py && ./build.sh`.
- Nach Mod-Updates: voller FS25-Neustart.
