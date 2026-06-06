# Audit-Inventar (Phase 1)

Vorlage und Tabellen: siehe `CONSOLIDATION_AND_NAMING_PLAN.md` § Phase 1.

## Vollständigkeit (keine Abkürzung — Standard)

- [x] **Audit:** jede Datei unter `scripts/`, `gui/`, relevante `translations/`, `tools/` — jede `function`, jeder widersprüchliche Zweig.
- [ ] **Kommentare:** jede Zeile Kommentar in diesen Dateien **lesen** (Block für Block), siehe `COMMENT_PASS_LOG.md` — **in Arbeit** (Block 1/4 FieldAdvisor).
- [ ] **Namen:** alle öffentlichen Funktionen und unklare Variablen in denselben Dateien — **ausstehend** (Phase 5).

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

### E) Gras-Rest (los / Schwad / Ballen) — **ausgemistet**

> **Status 2026-06-04:** B1-Befund (Density-Map fehlt) bestätigt → Rest ist **nicht sensierbar**.
> Konsequenz: die gesamte Density-Map-Residue-Detektion **gelöscht** (~1380 Zeilen + 18 tote Tuning-Konstanten).
> Einzige Quelle ist jetzt **`deriveGrassResidueSummary(baleSummary)`** (rein, ballen-basiert):
> Ballen auf dem Feld ⇒ `BALED`, sonst `NONE`. `loose`/`swath` werden nicht mehr erzeugt.
> Vorschlag (`addGrassWorkActions`): bei `cut` ohne Ballen ganze Kette (Schwaden→Sammeln→Ballen→Silageballen,
> `grass_swath`/`grass_collect` = manuell), mit Ballen nur `grass_bale_collect`. Auto-Complete nur über Ballenzahl.

| Funktion | Status |
|----------|--------|
| `deriveGrassResidueSummary` | **Kanon** (ballen-basiert) |
| `isGrassBalingWorkComplete` | bleibt, jetzt rein ballen-basiert |
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
| W2 | Feld 6 loose/swath aus Höhen-Rauschen | `isUniformCutFieldIdleResidue` | `hasGrassSwathMaterialRemaining` | DensityMapUtil fehlt ⇒ kein verlässlicher Rest | `deriveGrassResiduePhase` |
| W3 | `buildFieldContext`-Reihenfolge: collect-done vor swath | `isGrassCollectEffectivelyDone` | `shouldTreatGrassResidueAsSwath` | erst Rest bestimmen, dann „fertig“ | `deriveGrassResiduePhase` |
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
3. **`deriveGrassResiduePhase`** (E) — zuletzt, weil Datenlage (B1) erst ehrlich gemacht werden muss; behebt W2/W3.
4. **`resolveActionCandidates`** auf `phase → actions[]` umstellen; Completion nur aus Phase.
