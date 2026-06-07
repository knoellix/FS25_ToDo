# Audit-Inventar (Phase 1)

Vorlage und Tabellen: siehe `CONSOLIDATION_AND_NAMING_PLAN.md` § Phase 1.

## Vollständigkeit (keine Abkürzung — Standard)

- [x] **Audit:** jede Datei unter `scripts/`, `gui/`, relevante `translations/`, `tools/` — jede `function`, jeder widersprüchliche Zweig.
- [x] **Kommentare FieldAdvisor.lua:** Block 1–4/4 gelesen (`COMMENT_PASS_LOG.md` 2026-06-06).
- [x] **Kommentare:** `FieldAdvisor` 4/4 + gesamte `scripts/` + `gui/FieldToDoMenuFrame` 3/3 + `translations/` — **2026-06-06** (`COMMENT_PASS_LOG.md`).
- [x] **Namen:** Glossar + Kanon/Fassade dokumentiert; `shouldTrackArableWeed` → `isArableWeedSamplingContext` (2026-06-06). Einklappen `hasActiveCrop`/`isFieldSown`/`isFieldUnsown` → Phase 2-Rest, nicht Naming.

Das ist **nicht** „nur Gras“ oder „nur FieldAdvisor“. FieldAdvisor zuerst (größtes Risiko), Rest **pflichtig** in derselben Kampagne.

---

## Feature-Umfang nach Konsolidierung

**Festgelegt: A — alle Features bleiben.**

Ziel ist **nicht** Features wegwerfen, sondern **dieselben Features** mit **weniger, widerspruchsfreiem Code** (eine Pipeline statt vieler `is*`-Doppelungen).

| Was bleibt | |
|------------|--|
| Multi-Probe / Feldklassifikation | ja |
| Gras (Mähen, Schwaden, Sammeln, Ballen, Nachwuchs) | ja |
| Unkraut (Striegeln, Spritzen, erledigt-Erkennung) | ja |
| Auto-Erledigen / Aufgaben | ja |
| Acker (Ernte, Stoppel, Pflügen, Kalk, Säen, …) | ja |
| PF / SCS / HUD / To-dos | ja |

B/C im Plan sind **nur Notfall**, falls ein Audit belegen würde, dass der Codebase nicht konsolidierbar ist — **kein Ziel**, nichts planen.

**Gewählt:** **A**

## Entscheidungs-Matrix (Phase 1 — Stand 2026-06-04)

Quelle: `FieldAdvisor.lua` (202 Funktionen), Aufrufer aus `scripts/`+`gui/`. Zeilennummern = Definition in `FieldAdvisor.lua`.

### A) Feldphase (wachsend / erntbereit / Stoppel / leer / Gras)

> **Status 2026-06-04:** Phasenentscheidung konsolidiert. `getCropPhase` ist jetzt dünn: `buildFieldPhaseFacts` (Engine) → `FieldPhase.deriveFieldPhase` (rein, getestet) → `mapFieldPhaseToCropPhase`. W1/W6 grün in `tests/`.

| Funktion | Zeile | Rolle heute | Ziel |
|----------|-------|-------------|------|
| `getCropPhase` | 5959 | dünner Wrapper: facts → `deriveFieldPhase` → Legacy-Map | **erledigt** |
| `hasActiveCrop` | 5690 | „hat Frucht“ — auch von aggregate/getCropPhase | in `deriveFieldPhase` einklappen |
| `isFieldSown` | 5662 | „gesät“ — überlappt `hasActiveCrop` | einklappen |
| `isFieldUnsown` | 5631 | Gegenteil, separate Regeln | einklappen |
| `isArableHarvestedStubble` | 5255 | Stoppel-Erkennung | als **eine** Stoppelregel behalten, von Kanon genutzt |
| `isPostHarvestSoilWorkPhase` | 5793 | „nach Ernte Bodenarbeit?“ | aus Phase ableiten |
| `isWithered` | 5735 | Verdorrt | bleibt (klar abgegrenzt) |

### B) Erntbereit (Acker) — **erledigt (verifiziert: Kanon + bewusste Schichten)**

> **Status 2026-06-04:** Kein Parallel-Entscheider — saubere 3-Schicht-Pipeline, **nicht** weiter zusammengelegt
> (Merge würde ETA/Saison brechen). Rollen im Code per Kommentar fixiert.

| Funktion | Rolle | Status |
|----------|-------|--------|
| `isCropHarvestReady` | **Kanon**: Wachstums-Kern + aktives Saisonfenster | **Kanon** |
| `isCropHarvestReadyByGrowth` | Wachstums-Kern (ohne Saisonfenster), von `getExpectedHarvestPeriod` für ETA wiederbenutzt | bleibt (Schicht, kein Merge) |
| `isHarvestReady` | Frucht-Kind-Dispatcher: Gras→`isGrassHarvestable`, Acker→`isCropHarvestReady` | bleibt (Fassade) |
| `evaluateFruitGrowth` | reine API-Hilfe | bleibt |

### C) Gras-Feld vs. Acker (Klassifikation) — **erledigt**

> **Status 2026-06-04:** Das wiederholte Phase-Gras-Gate (`isGrassFieldState(state) OR aggregation.dominant==GRASS`)
> lag **dreimal inline** (`getCropPhase`, `getExpectedHarvestLabel`, `resolveActionCandidates`) → in **eine**
> `isGrassPhaseContext` zusammengefasst (verhaltensidentisch). Bewusst getrennt vom **Feld-Kind-Gate**
> `isGrassCropFieldContext`/`isArableFieldContext` (reicher: center-Situation + Gras-Frucht; dient Ballen-/Unkraut-Sampling).

| Funktion | Rolle | Status |
|----------|-------|--------|
| `classifyProbe` | **Kanon** (eine Probe → arable/grass/bare/unknown) | Kanon |
| `aggregateFieldProbes` | Gitter, nutzt classifyProbe | bleibt |
| `isGrassPhaseContext` | **neu** — Phase-Gras-Gate (eine Quelle, 3 Inline-Kopien ersetzt) | **erledigt** |
| `isGrassFieldState` | Proben-Helfer (classifyProbe==GRASS) | bleibt |
| `isGrassCropFieldContext` / `isArableFieldContext` | Feld-Kind-Gate (Sampling) — eigener Zweck, kein Merge | bleibt |

### D) Gras nach Mähen (Meadow-Phase) — **erledigt (verifiziert)**

> **Status 2026-06-04:** `getGrassMeadowPhase` ist der **einzige** Meadow-Phasen-Entscheider; die übrigen sind
> Readouts/Verfeinerungen, kein Merge (Rollen per Kommentar fixiert).

| Funktion | Rolle | Status |
|----------|-------|--------|
| `getGrassMeadowPhase` | **Kanon** (cut/harvestable/growing/withered/dormant) | Kanon |
| `isGrassPostMowState` | von Kanon genutzt, kein Parallel-Entscheid | bleibt |
| `isGrassHarvestable` / `isGrassCut` | dünne Readouts auf Kanon (`== "harvestable"/"cut"`) | bleibt |
| `isGrassStandingCropPhase` | Verfeinerung (bekommt meadowPhase als Eingabe) | bleibt |
| `isGenericGrassStandingCrop` | bewusst **ohne** Kanon (Rekursion in Frucht-Auflösung vermeiden) | bleibt (begründet) |

### E) Gras-Rest (los / Schwad / Ballen) — **Liter + Layout + Ballen (2026-06-07)**

> **Status 2026-06-07:** `deriveGrassResidueSummary` + `classifyGrassMaterialLayout`: gleiche Liter-API wie Stroh; Layout ⇒ `loose` | `swath` | `none`; Ballen ⇒ `BALED`.
> **`addGrassWorkActions` cut:** `loose`/`none` → Kette ab Schwaden; `swath` → Sammeln/Ballen; Ballen → einsammeln.
> Probe-Gate: `isPositionInsideField` only (P1 erledigt 2026-06-07, `FALLBACK_AUDIT.md`).
> Alte Density-Map-Fusion (~1380 Zeilen) bleibt gelöscht.

| Funktion | Status |
|----------|--------|
| `deriveGrassResidueSummary` | **Kanon** (Liter + Ballen: `BALED` > `SWATH` > `NONE`) |
| `isGrassBalingWorkComplete` | bleibt, rein ballen-basiert (auto-complete) |
| `detectGrassResidue`, `fuseGrassResidueSignals`, `refineGrassResidueSummary`, `sampleGrassResidueCoverage` | **gelöscht** |
| `shouldTreatGrassResidueAsSwath`, `isUniformCutFieldIdleResidue`, `hasGrassSwathMaterialRemaining` | **gelöscht** |
| `isGrassCollectEffectivelyDone`, `isGrassSwathWorkComplete`, `hasGrassWindrowLineEvidence`, `isGrassWindrowPileRemnant`, `applyFieldBaleResidueOverlay` | **gelöscht** |
| Scan-/Mess-Helfer (`collectGrassResidueSamplePoints`, `scanCrossForMaxGrassMaterial`, `measureGrassCrossAxisLineTransitions`, `countGrassWindrowMaterialHits`, `measureHeightMaterialAtPoint`, `measureHeightFillTypeAtPoint`, `measureWindrowLitersAtPoint`, `getTerrainSampleY`, `getHeightDetailPlaneId`, `buildWindrowFillTypeSet`, `isKnownWindrowFillType`, `collectWindrowFillTypeIndices`, `getWindrowFillTypes`, `getWindrowFillTypeIndexForFruit`, `measureFillLevelAtArea`, `reduceGrassResidueSamplePoints`, `countAxisMaterialTransitions`) | **gelöscht** |
| Density-Map-Plumbing (`resolveDensityMapHeightUtil`, `callFillLevelAtArea`, `getMinValidHeightLiters`, `invalidateDensityMapHeightUtil`) | bleibt (von Frucht-ID `inferGrassFruitTypeFromWindrowFill` genutzt) |

### F) Unkraut

> **Status 2026-06-04:** Entscheidung konsolidiert. **`WeedAdvice.deriveWeedAdvice(facts)`** (rein, headless getestet) ist die einzige Quelle; die vier `fieldNeedsWeed*`/`fieldShouldSuggestWeedSpray` sind dünne Wrapper über `buildWeedAdviceFacts`. `getWeedSuggestionPressure` gelöscht. W4/W5 als Tests fixiert (`tests/weed_fixtures.lua`).

| Funktion | Zeile | Rolle heute | Ziel |
|----------|-------|-------------|------|
| `WeedAdvice.deriveWeedAdvice` | (WeedAdvice.lua) | **Kanon** (done/hoe/watch/needsCombat/spray) | **erledigt** |
| `buildWeedAdviceFacts` | – | Engine→facts (Sammelstelle) | bleibt |
| `sampleWeedCoverage` | 1903 | Datensammlung | bleibt |
| `isWeedProbeLive` / `isWeedProbeDead` | 1842 / 1861 | Proben-Klassifikation (in sampleWeedCoverage) | bleibt als Daten-Helfer |
| `isWeedDeadOrSprayed` | 1785 | State-Fallback-Signal | speist facts |
| `isWeedTaskDoneByCoverage` | 1988 | done-by-coverage | speist facts + Completion |
| `getEffectiveWeedPressure` | 1880 | State-Druck | speist facts |
| `fieldNeedsWeedHoe/Combat/Watch` + `fieldShouldSuggestWeedSpray` | 4190+ | dünne Wrapper über Advice | **erledigt** |
| `getWeedSuggestionPressure` | – | gelöscht (Logik in WeedAdvice) | **entfernt** |

### G) Vorschläge + Auto-Erledigen — **erledigt**

> **Status 2026-06-04:** `resolveActionCandidates` leitet die Endphase **einmal** ab (Reconciliation-Block:
> Ballen→growing, Acker-Stoppel→post_harvest) und **dispatcht** dann über `FieldAdvisor.PHASE_ACTION_BUILDERS`
> (`harvest_ready`/`withered`/`growing`/`empty`/`post_harvest`) an je **einen** Builder. Keine Inline-`if`-Kette
> mehr, keine zweite Stelle, die pro Phase entscheidet. Tote Locals (`growthState`, `needsPlowing`, `plowLevel`,
> `limeLevel`, `weedState`) entfernt. Completion bleibt **pro Aktion** (erkennt, ob die getrackte Arbeit geschah —
> Ballenzahl, `needsPlowing` etc.), re-leitet aber keine Phase ab; `grass_swath`/`grass_collect` (nicht sensbar)
> sind manuell und nicht mehr in der Completion.

| Funktion | Status |
|----------|--------|
| `resolveActionCandidates` | **erledigt** — Phase-Reconciliation + Dispatch-Tabelle |
| `PHASE_ACTION_BUILDERS` + `add{HarvestReady,Withered,Growing,EmptyOrPostHarvest}Actions` | je ein Builder pro Phase |
| `addGrassWorkActions` | nur aus Gras-Phase (cut/harvestable) + Ballen abgeleitet |
| `selectPrimaryAction` / `finishActionCandidates` | bleibt (reine Auswahl/Anzeige) |
| `FieldTaskCompletion.isGrassLogisticsComplete` / `isActionComplete` | pro Aktion, keine eigene Phasen-Heuristik |

## Aufrufer-Zahlen (Treffer inkl. Definition/Kommentare, grob)

| Funktionsgruppe | FieldAdvisor | FieldTaskCompletion | FieldDebugDump |
|-----------------|-------------:|--------------------:|---------------:|
| Phase/Ernte/Stoppel (A+B) | 60 | 3 | 2 |
| Klassifikation/Meadow (C+D) | 70 | 3 | 4 |
| Gras-Rest (E) | ~6 (nach Ausmisten) | 1 | 1 |
| Unkraut (F) | 41 | 1 | 6 |

→ Hoher Verflechtungsgrad bestätigt: Konsolidierung lohnt, aber Aufrufer-Umstellung sorgfältig.

## Widerspruchs-Liste (aus Golden-Snapshot + Historie)

| # | Symptom | Funktion A | Funktion B | Gewünscht | Bleibt (Kanon) |
|---|---------|------------|------------|-----------|----------------|
| W1 | Stoppel als „Wächst“ (Roggen/Triticale, growth>max) | `hasActiveCrop`/`isFieldSown` (growth>0 ⇒ aktiv) | `isArableHarvestedStubble` (growth>max ⇒ Stoppel) | growth>maxHarvest ⇒ post_harvest | `deriveFieldPhase` (nutzt Stoppelregel) |
| W2 | Feld 6 Schwad aus Höhen-Rauschen | (gelöscht) | (gelöscht) | Liter-API statt Höhe | `deriveGrassResidueSummary` |
| W3 | Rest vor „fertig“ | (gelöscht) | (gelöscht) | eine Summary, dann Actions | `deriveGrassResidueSummary` |
| W4 | Feld 72 „tot“ aber needsWatch+Hoe | `isWeedTaskDoneByCoverage` (done) | `fieldNeedsWeedWatch`/`Hoe` (aktiv) | doneByCoverage ⇒ keine Aktion | `deriveWeedAdvice` |
| W5 | Feld 16 6% live: Combat **und** Hoe | `fieldShouldSuggestWeedSpray` | `fieldNeedsWeedHoe` | kleine Ratio ⇒ höchstens Hoe | `deriveWeedAdvice` |
| W6 | dominant BARE_SOIL vs. center ARABLE-Stoppel | `getCropPhase` BARE-Zweig | Stoppelregel | Stoppel vor empty | `deriveFieldPhase` |

## Metrik Vorher

- `function FieldAdvisor.*` Anzahl: **202** → **186** (nach Konsolidierung + Stroh-Logistik, 2026-06-04)
- Entscheider „Feldphase/nach Ernte“ (A): **7** → Ziel 1 Kanon + 1 Stoppelregel
- Entscheider „Gras-Rest“ (E): **11** → Ziel 1 Kanon + Roh-Signale
- Entscheider „Unkraut“ (F): **10** → Ziel 1 Kanon (`deriveWeedAdvice`)

## Empfehlung Phase 2 (Reihenfolge nach Risiko/Nutzen)

1. **`deriveFieldPhase`** (A+B) — größter, klarster Gewinn; behebt W1/W6.
2. **`deriveWeedAdvice`** (F) — abgegrenzt, gut testbar; behebt W4/W5.
3. ✅ **`deriveGrassResidueSummary`** (E) — Liter + Ballen (2026-06-06); W2/W3 obsolet.
4. ✅ **`resolveActionCandidates`** — `PHASE_ACTION_BUILDERS`-Dispatch erledigt.

---

## Naming-Glossar (Phase 5)

### Entscheider (`derive*` / `classify*`)

| Name | Modul | Frage |
|------|-------|-------|
| `deriveFieldPhase` | FieldPhase | In welcher Arbeitsphase ist das Feld? |
| `deriveGrassResidueSummary` | FieldAdvisor | Gras nach Mähen: none/swath/baled? |
| `deriveStrawResidueSummary` | FieldAdvisor | Stroh-Schwaden auf Stoppel? |
| `deriveWeedAdvice` | WeedAdvice | Unkraut: done/hoe/watch/spray? |
| `classifyProbe` | FieldAdvisor | Eine Probe: arable/grass/bare/unknown? |
| `resolveActionCandidates` | FieldAdvisor | Welche Arbeitsschritte vorschlagen? |

### Fassaden (UI/Legacy-String)

| Name | Delegiert an |
|------|----------------|
| `getCropPhase` | `buildFieldPhaseFacts` → `deriveFieldPhase` → `mapFieldPhaseToCropPhase` |
| `fieldNeedsWeedHoe` / `Combat` / `Watch` / `fieldShouldSuggestWeedSpray` | `deriveWeedAdvice` |
| `isFieldTaskComplete` | `FieldTaskCompletion.isTaskComplete` |

### Readouts (`is*` — kein Phasen-Entscheid)

| Name | Zweck | Nicht nutzen für |
|------|-------|------------------|
| `hasActiveCrop` | cultivate-Completion | Feldphase |
| `isFieldSown` | sow-Completion | Feldphase |
| `isFieldUnsown` | Ernte-Spalte „-“ | Feldphase |
| `isArableHarvestedStubble` | Stoppel-Erkennung (facts) | alleinige Phase |
| `isGrassHarvestable` / `isGrassCut` | Meadow-Readouts | Meadow-Phase |
| `isArableWeedSamplingContext` | Unkraut-Proben nur auf Acker | Unkraut-Advice |

### Variablen (ein Begriff pro Scope)

| Variable | Bedeutung |
|----------|-----------|
| `fieldState` | Live-`FieldState` an einer Weltposition |
| `harvestState` | Center-Probe für Ernte-Spalte/Monat (`resolveHarvestFieldState`) |
| `probeState` | Repräsentant in `buildFieldContext` (oft = center) |
| `representativeState` | Dominante/max-growth-Probe in Aggregation |
| `aggregation.harvestState` | Immer Center — für Ernte-Fenster, nicht representative |
| `grassResidueSummary` / `strawResidueSummary` | Ausgabe der jeweiligen `derive*ResidueSummary` |
| `baleSummary` | `{total, straw, grass, other}` aus `sampleBaleCoverage` |
| `weedSummary` | Coverage aus `sampleWeedCoverage` |
| `pfSample` / `scsSample` | Precision Farming / Crop Stress Mod-Daten |
